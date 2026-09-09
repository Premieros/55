-- Fix "column reference product_id is ambiguous" raised by get_pos_product_availability.
--
-- Root cause: the function RETURNS TABLE(product_id, available_quantity, is_available),
-- so `product_id` is a PL/pgSQL OUT variable. Inside the body, the query
--
--   SELECT COALESCE(SUM(quantity), 0) INTO v_ready
--   FROM public.inventory_batches WHERE product_id = v_prod.id ...
--
-- references `product_id` unqualified, which now collides with the OUT variable.
-- With the default plpgsql.variable_conflict = error this raises
-- 42702 "column reference "product_id" is ambiguous
--   (It could refer to either a PL/pgSQL variable or a table column.)"
-- for EVERY call, even `SELECT available_quantity FROM ...` without a WHERE clause.
--
-- Fix: qualify resolution through the per-function GUC
--   SET plpgsql.variable_conflict = use_column
-- so unqualified names bind to table columns (the intent of the body). The OUT
-- parameters are still assigned via PL/pgSQL assignments (unaffected by the GUC),
-- preserving the function signature and result contract exactly.

CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
SET plpgsql.variable_conflict = use_column
AS $$
DECLARE
  v_prod RECORD;
  v_ready numeric(14,4);
  v_recipe RECORD;
  v_producible numeric(14,4);
  v_item RECORD;
  v_total numeric(14,4);
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF p_cap IS NULL OR p_cap < 1 THEN
    p_cap := 1;
  END IF;

  FOR v_prod IN
    SELECT p.id
    FROM public.products p
    WHERE p.branch_id = p_branch_id AND p.is_active = true
    ORDER BY p.id
  LOOP
    -- 1. Ready finished product stock in this warehouse
    SELECT COALESCE(SUM(quantity), 0) INTO v_ready
    FROM public.inventory_batches
    WHERE product_id = v_prod.id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id
      AND quantity > 0;

    v_total := v_ready;

    -- 2. Check if product has an active recipe
    SELECT r.id, r.yield_quantity
    INTO v_recipe
    FROM public.recipes r
    WHERE r.product_id = v_prod.id
      AND r.branch_id = p_branch_id
      AND r.is_active = true
    ORDER BY r.version DESC, r.created_at DESC
    LIMIT 1;

    IF v_recipe.id IS NOT NULL AND COALESCE(v_recipe.yield_quantity, 0) > 0 THEN
      v_producible := 999999999;
      FOR v_item IN
        SELECT
          ri.raw_material_id,
          SUM(ri.quantity) AS qty_per_yield
        FROM public.recipe_items ri
        JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
        WHERE ri.recipe_id = v_recipe.id AND rm.is_active = true
        GROUP BY ri.raw_material_id
      LOOP
        IF v_item.qty_per_yield > 0 THEN
          v_producible := LEAST(
            v_producible,
            FLOOR(
              (
                COALESCE((
                  SELECT rmi.quantity FROM public.raw_material_inventory rmi
                  WHERE rmi.raw_material_id = v_item.raw_material_id
                    AND rmi.branch_id = p_branch_id
                    AND rmi.warehouse_id = p_warehouse_id
                ), 0) * v_recipe.yield_quantity
              ) / v_item.qty_per_yield
            )
          );
        END IF;
      END LOOP;

      IF v_producible < 999999999 AND v_producible > 0 THEN
        v_total := v_total + v_producible;
      END IF;
    END IF;

    product_id := v_prod.id;
    available_quantity := LEAST(v_total, p_cap);
    is_available := v_total > 0;
    RETURN NEXT;
  END LOOP;
END;
$$;