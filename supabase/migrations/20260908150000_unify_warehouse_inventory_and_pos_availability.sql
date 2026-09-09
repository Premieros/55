-- Migration: Unify warehouse inventory scope for raw materials, inventory units, and products
-- Ensures all consumable inventory movements are strictly scoped to branch_id + warehouse_id.
-- Fixes POS availability and POS deduction to use ready stock first, then recipe ingredients from the same warehouse.
-- Enforces recipe integrity and fixes PostgreSQL ON CONFLICT DO UPDATE collisions via grouping.

BEGIN;

-- 1. Schema Updates: Ensure warehouses exist for all branches
INSERT INTO public.warehouses (branch_id, name, is_default, is_active)
SELECT b.id, 'المستودع الرئيسي', true, true
FROM public.branches b
WHERE NOT EXISTS (
  SELECT 1 FROM public.warehouses w WHERE w.branch_id = b.id
);

-- 2. Add warehouse_id to raw_material_inventory if not exists
ALTER TABLE public.raw_material_inventory
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE CASCADE;

-- Backfill warehouse_id STRICTLY from the SAME branch default/first active warehouse
UPDATE public.raw_material_inventory rmi
SET warehouse_id = (
  SELECT w.id FROM public.warehouses w
  WHERE w.branch_id = rmi.branch_id AND w.is_active = true
  ORDER BY w.is_default DESC, w.created_at ASC
  LIMIT 1
)
WHERE rmi.warehouse_id IS NULL;

-- STRICT INTEGRITY CHECK:
-- Prohibit cross-branch assignment. If any record has no warehouse from its own branch, abort migration.
DO $$
DECLARE
  v_orphan_count integer;
BEGIN
  SELECT count(*) INTO v_orphan_count
  FROM public.raw_material_inventory
  WHERE warehouse_id IS NULL;

  IF v_orphan_count > 0 THEN
    RAISE EXCEPTION 'MIGRATION ABORTED: Found % raw_material_inventory records with no warehouse belonging to their own branch. Assigning a warehouse from another branch is strictly prohibited.', v_orphan_count;
  END IF;
END $$;

-- 3. Add warehouse_id to raw_material_batches if not exists
ALTER TABLE public.raw_material_batches
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE CASCADE;

-- Backfill warehouse_id STRICTLY from the SAME branch default/first active warehouse
UPDATE public.raw_material_batches rmb
SET warehouse_id = (
  SELECT w.id FROM public.warehouses w
  WHERE w.branch_id = rmb.branch_id AND w.is_active = true
  ORDER BY w.is_default DESC, w.created_at ASC
  LIMIT 1
)
WHERE rmb.warehouse_id IS NULL;

-- STRICT INTEGRITY CHECK:
-- Prohibit cross-branch assignment for batches.
DO $$
DECLARE
  v_orphan_batches integer;
BEGIN
  SELECT count(*) INTO v_orphan_batches
  FROM public.raw_material_batches
  WHERE warehouse_id IS NULL;

  IF v_orphan_batches > 0 THEN
    RAISE EXCEPTION 'MIGRATION ABORTED: Found % raw_material_batches records with no warehouse belonging to their own branch. Assigning a warehouse from another branch is strictly prohibited.', v_orphan_batches;
  END IF;
END $$;

-- 4. Deduplicate any duplicate (raw_material_id, branch_id, warehouse_id) rows in raw_material_inventory
DO $$
DECLARE
  r RECORD;
  v_keep_id uuid;
BEGIN
  FOR r IN
    SELECT raw_material_id, branch_id, warehouse_id, count(*)
    FROM public.raw_material_inventory
    WHERE warehouse_id IS NOT NULL
    GROUP BY raw_material_id, branch_id, warehouse_id
    HAVING count(*) > 1
  LOOP
    SELECT id INTO v_keep_id
    FROM public.raw_material_inventory
    WHERE raw_material_id = r.raw_material_id AND branch_id = r.branch_id AND warehouse_id = r.warehouse_id
    ORDER BY quantity DESC, updated_at DESC
    LIMIT 1;

    UPDATE public.raw_material_inventory
    SET
      quantity = (
        SELECT COALESCE(SUM(quantity), 0)
        FROM public.raw_material_inventory
        WHERE raw_material_id = r.raw_material_id AND branch_id = r.branch_id AND warehouse_id = r.warehouse_id
      ),
      avg_cost = (
        SELECT CASE
          WHEN COALESCE(SUM(quantity), 0) > 0 THEN
            ROUND(SUM(quantity * avg_cost) / SUM(quantity), 2)
          ELSE MAX(avg_cost)
        END
        FROM public.raw_material_inventory
        WHERE raw_material_id = r.raw_material_id AND branch_id = r.branch_id AND warehouse_id = r.warehouse_id
      ),
      min_stock = (
        SELECT MAX(min_stock)
        FROM public.raw_material_inventory
        WHERE raw_material_id = r.raw_material_id AND branch_id = r.branch_id AND warehouse_id = r.warehouse_id
      ),
      updated_at = now()
    WHERE id = v_keep_id;

    DELETE FROM public.raw_material_inventory
    WHERE raw_material_id = r.raw_material_id AND branch_id = r.branch_id AND warehouse_id = r.warehouse_id
      AND id <> v_keep_id;
  END LOOP;
END $$;

-- Drop previous unique constraints on raw_material_inventory that lacked warehouse_id
DO $$
DECLARE
  v_c text;
BEGIN
  FOR v_c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.raw_material_inventory'::regclass
      AND contype = 'u'
  LOOP
    EXECUTE 'ALTER TABLE public.raw_material_inventory DROP CONSTRAINT IF EXISTS ' || quote_ident(v_c);
  END LOOP;
END $$;

-- Enforce warehouse_id NOT NULL and new composite UNIQUE constraint
ALTER TABLE public.raw_material_inventory ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE public.raw_material_inventory
  ADD CONSTRAINT uq_raw_material_inventory_warehouse UNIQUE (raw_material_id, branch_id, warehouse_id);

CREATE INDEX IF NOT EXISTS idx_raw_material_inv_wh
  ON public.raw_material_inventory (raw_material_id, branch_id, warehouse_id);
CREATE INDEX IF NOT EXISTS idx_raw_material_batches_wh
  ON public.raw_material_batches (raw_material_id, branch_id, warehouse_id);

-- Enforce strict database integrity: warehouse_id MUST belong to the specified branch_id
CREATE OR REPLACE FUNCTION public.trg_validate_warehouse_branch_integrity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.warehouse_id IS NOT NULL AND NEW.branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.warehouses w
      WHERE w.id = NEW.warehouse_id AND w.branch_id = NEW.branch_id
    ) THEN
      RAISE EXCEPTION 'DATA INTEGRITY VIOLATION: Warehouse % does not belong to branch %', NEW.warehouse_id, NEW.branch_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_val_raw_material_wh_branch ON public.raw_material_inventory;
CREATE TRIGGER trg_val_raw_material_wh_branch
  BEFORE INSERT OR UPDATE OF warehouse_id, branch_id ON public.raw_material_inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_warehouse_branch_integrity();

DROP TRIGGER IF EXISTS trg_val_raw_batches_wh_branch ON public.raw_material_batches;
CREATE TRIGGER trg_val_raw_batches_wh_branch
  BEFORE INSERT OR UPDATE OF warehouse_id, branch_id ON public.raw_material_batches
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_validate_warehouse_branch_integrity();

-- 5. Deduplicate and constrain recipe_items to prevent ON CONFLICT DO UPDATE second-time collision
DO $$
DECLARE
  r RECORD;
  v_keep_id uuid;
BEGIN
  FOR r IN
    SELECT recipe_id, raw_material_id, count(*)
    FROM public.recipe_items
    GROUP BY recipe_id, raw_material_id
    HAVING count(*) > 1
  LOOP
    SELECT id INTO v_keep_id
    FROM public.recipe_items
    WHERE recipe_id = r.recipe_id AND raw_material_id = r.raw_material_id
    ORDER BY created_at ASC
    LIMIT 1;

    UPDATE public.recipe_items
    SET quantity = (
      SELECT SUM(quantity) FROM public.recipe_items
      WHERE recipe_id = r.recipe_id AND raw_material_id = r.raw_material_id
    )
    WHERE id = v_keep_id;

    DELETE FROM public.recipe_items
    WHERE recipe_id = r.recipe_id AND raw_material_id = r.raw_material_id
      AND id <> v_keep_id;
  END LOOP;
END $$;

ALTER TABLE public.recipe_items DROP CONSTRAINT IF EXISTS uq_recipe_items_recipe_raw;
ALTER TABLE public.recipe_items ADD CONSTRAINT uq_recipe_items_recipe_raw UNIQUE (recipe_id, raw_material_id);

-- 6. Updated _raw_add accepting p_warehouse_id
CREATE OR REPLACE FUNCTION public._raw_add(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_movement_type text,
  p_reference_type text,
  p_reference_id uuid,
  p_reference_number text,
  p_notes text DEFAULT NULL,
  p_batch_number text DEFAULT NULL,
  p_created_by uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_qty numeric(14,4) := COALESCE(p_quantity, 0);
  v_cost numeric(14,4) := COALESCE(p_unit_cost, 0);
  v_warehouse_id uuid := p_warehouse_id;
  v_cur_qty numeric(14,4) := 0;
  v_cur_avg numeric(14,4) := 0;
  v_new_qty numeric(14,4);
  v_new_avg numeric(14,4);
  v_batch_id uuid;
BEGIN
  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
  END IF;

  -- Resolve warehouse if missing
  IF v_warehouse_id IS NULL THEN
    SELECT id INTO v_warehouse_id
    FROM public.warehouses
    WHERE branch_id = p_branch_id AND is_active = true
    ORDER BY is_default DESC, created_at ASC
    LIMIT 1;
  END IF;

  IF v_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'No active warehouse found for branch');
  END IF;

  -- Strictly verify warehouse belongs to branch!
  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'Warehouse does not belong to the specified branch'
    );
  END IF;

  -- Lock and fetch existing balance
  SELECT quantity, avg_cost INTO v_cur_qty, v_cur_avg
  FROM public.raw_material_inventory
  WHERE raw_material_id = p_raw_material_id
    AND branch_id = p_branch_id
    AND warehouse_id = v_warehouse_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_new_qty := v_qty;
    v_new_avg := ROUND(v_cost, 2);
    INSERT INTO public.raw_material_inventory (
      raw_material_id, branch_id, warehouse_id, quantity, avg_cost, updated_at
    ) VALUES (
      p_raw_material_id, p_branch_id, v_warehouse_id, v_new_qty, v_new_avg, now()
    );
  ELSE
    v_new_qty := v_cur_qty + v_qty;
    IF v_new_qty > 0 THEN
      v_new_avg := ROUND(((v_cur_qty * v_cur_avg) + (v_qty * v_cost)) / v_new_qty, 2);
    ELSE
      v_new_avg := ROUND(v_cost, 2);
    END IF;
    UPDATE public.raw_material_inventory
    SET quantity = v_new_qty,
        avg_cost = v_new_avg,
        updated_at = now()
    WHERE raw_material_id = p_raw_material_id
      AND branch_id = p_branch_id
      AND warehouse_id = v_warehouse_id;
  END IF;

  -- Insert into batches with warehouse_id
  INSERT INTO public.raw_material_batches (
    raw_material_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, created_at
  ) VALUES (
    p_raw_material_id, p_branch_id, v_warehouse_id,
    COALESCE(p_batch_number, 'B-' || to_char(now(), 'YYYYMMDD-HH24MISS')),
    v_qty, ROUND(v_cost, 2), now()
  ) RETURNING id INTO v_batch_id;

  -- Insert movement with warehouse_id
  INSERT INTO public.raw_material_movements (
    raw_material_id, branch_id, warehouse_id, movement_type,
    quantity, unit_cost, balance_after,
    reference_type, reference_id, reference_number,
    notes, created_by, created_at
  ) VALUES (
    p_raw_material_id, p_branch_id, v_warehouse_id, p_movement_type,
    v_qty, ROUND(v_cost, 2), v_new_qty,
    p_reference_type, p_reference_id, p_reference_number,
    p_notes, p_created_by, now()
  );

  -- Log to global inventory_ledger for unified audit
  INSERT INTO public.inventory_ledger (
    product_id, warehouse_id, branch_id,
    movement_type, quantity, unit_cost, balance_after,
    reference_type, reference_id, reference_number,
    created_by, created_at
  ) VALUES (
    NULL, v_warehouse_id, p_branch_id,
    p_movement_type, v_qty, ROUND(v_cost, 2), v_new_qty,
    p_reference_type, p_reference_id, p_reference_number,
    p_created_by, now()
  );

  RETURN jsonb_build_object(
    'success', true,
    'warehouse_id', v_warehouse_id,
    'new_quantity', v_new_qty,
    'new_avg_cost', v_new_avg,
    'batch_id', v_batch_id
  );
END;
$$;

-- 7. Updated _raw_remove_fifo accepting p_warehouse_id
CREATE OR REPLACE FUNCTION public._raw_remove_fifo(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_quantity numeric,
  p_movement_type text,
  p_reference_type text,
  p_reference_id uuid,
  p_reference_number text,
  p_created_by uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_remaining numeric(14,4) := COALESCE(p_quantity, 0);
  v_warehouse_id uuid := p_warehouse_id;
  v_batch RECORD;
  v_take numeric(14,4);
  v_total_cost numeric(14,4) := 0;
  v_cur_qty numeric(14,4) := 0;
  v_cur_avg numeric(14,4) := 0;
  v_new_qty numeric(14,4);
  v_shortage numeric(14,4) := 0;
BEGIN
  IF v_remaining <= 0 THEN
    RETURN jsonb_build_object('success', true, 'deducted', 0, 'cogs', 0, 'shortage', 0);
  END IF;

  -- Resolve warehouse if missing
  IF v_warehouse_id IS NULL THEN
    SELECT id INTO v_warehouse_id
    FROM public.warehouses
    WHERE branch_id = p_branch_id AND is_active = true
    ORDER BY is_default DESC, created_at ASC
    LIMIT 1;
  END IF;

  IF v_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'No active warehouse found for branch');
  END IF;

  -- Strictly verify warehouse belongs to branch!
  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'Warehouse does not belong to the specified branch'
    );
  END IF;

  -- Lock balance row for this specific warehouse
  SELECT quantity, avg_cost INTO v_cur_qty, v_cur_avg
  FROM public.raw_material_inventory
  WHERE raw_material_id = p_raw_material_id
    AND branch_id = p_branch_id
    AND warehouse_id = v_warehouse_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_cur_qty := 0;
  END IF;

  IF v_cur_qty < v_remaining THEN
    v_shortage := v_remaining - v_cur_qty;
  END IF;

  -- FIFO deduction from raw_material_batches
  FOR v_batch IN
    SELECT id, quantity, unit_cost
    FROM public.raw_material_batches
    WHERE raw_material_id = p_raw_material_id
      AND branch_id = p_branch_id
      AND (warehouse_id = v_warehouse_id OR (v_warehouse_id IS NULL AND warehouse_id IS NULL))
      AND quantity > 0
    ORDER BY created_at ASC, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := LEAST(v_remaining, v_batch.quantity);
    v_total_cost := v_total_cost + (v_take * v_batch.unit_cost);
    v_remaining := v_remaining - v_take;

    UPDATE public.raw_material_batches
    SET quantity = quantity - v_take
    WHERE id = v_batch.id;
  END LOOP;

  v_new_qty := GREATEST(0, v_cur_qty - (p_quantity - v_remaining));

  UPDATE public.raw_material_inventory
  SET quantity = v_new_qty,
      updated_at = now()
  WHERE raw_material_id = p_raw_material_id
    AND branch_id = p_branch_id
    AND warehouse_id = v_warehouse_id;

  -- Record movement
  INSERT INTO public.raw_material_movements (
    raw_material_id, branch_id, warehouse_id, movement_type,
    quantity, unit_cost, balance_after,
    reference_type, reference_id, reference_number,
    created_by, created_at
  ) VALUES (
    p_raw_material_id, p_branch_id, v_warehouse_id, p_movement_type,
    -(p_quantity - v_remaining), v_cur_avg, v_new_qty,
    p_reference_type, p_reference_id, p_reference_number,
    p_created_by, now()
  );

  RETURN jsonb_build_object(
    'success', v_remaining = 0,
    'warehouse_id', v_warehouse_id,
    'deducted', p_quantity - v_remaining,
    'cogs', ROUND(v_total_cost, 2),
    'shortage', v_remaining
  );
END;
$$;

-- 8. Updated check_product_availability with strict warehouse boundary & hybrid calculation
CREATE OR REPLACE FUNCTION public.check_product_availability(
  p_product_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product RECORD;
  v_warehouse RECORD;
  v_ready numeric(14,4) := 0;
  v_shortage numeric(14,4);
  v_recipe RECORD;
  v_item RECORD;
  v_req_qty numeric(14,4);
  v_avail_qty numeric(14,4);
  v_producible_max numeric(14,4) := 999999999;
  v_has_recipe_items boolean := false;
BEGIN
  IF p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', true, 'mode', 'none', 'available', 0);
  END IF;

  IF p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_REQUIRED',
      'detail', 'A warehouse must be specified for availability check.'
    );
  END IF;

  SELECT id, name, is_active INTO v_product
  FROM public.products
  WHERE id = p_product_id AND branch_id = p_branch_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PRODUCT_NOT_FOUND',
      'product_id', p_product_id
    );
  END IF;

  SELECT id, name INTO v_warehouse
  FROM public.warehouses
  WHERE id = p_warehouse_id AND branch_id = p_branch_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_NOT_FOUND',
      'warehouse_id', p_warehouse_id
    );
  END IF;

  -- 1. Check ready stock in the specific warehouse
  SELECT COALESCE(SUM(quantity), 0) INTO v_ready
  FROM public.inventory_batches
  WHERE product_id = p_product_id
    AND branch_id = p_branch_id
    AND warehouse_id = p_warehouse_id
    AND quantity > 0;

  -- 2. If ready stock fully satisfies the requested quantity
  IF v_ready >= p_quantity THEN
    RETURN jsonb_build_object(
      'success', true,
      'mode', 'ready_product',
      'available', v_ready,
      'ready_quantity', v_ready,
      'recipe_quantity', 0,
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name
    );
  END IF;

  -- 3. If ready stock is insufficient, check if an active recipe exists
  SELECT r.id, r.yield_quantity, r.is_active
  INTO v_recipe
  FROM public.recipes r
  WHERE r.product_id = p_product_id
    AND r.branch_id = p_branch_id
    AND r.is_active = true
  ORDER BY r.version DESC, r.created_at DESC
  LIMIT 1;

  IF NOT FOUND OR v_recipe.id IS NULL OR COALESCE(v_recipe.yield_quantity, 0) <= 0 THEN
    -- No recipe available to produce the rest: out of stock
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INSUFFICIENT_STOCK',
      'item_type', 'product',
      'product_id', p_product_id,
      'product_name', v_product.name,
      'required', p_quantity,
      'available', v_ready,
      'shortage', p_quantity - v_ready,
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name,
      'detail', 'الرصيد الجاهز غير كافٍ ولا توجد وصفة إنتاج نشطة للمنتج في هذا المستودع.'
    );
  END IF;

  -- Check recipe items strictly in the same warehouse
  v_shortage := p_quantity - v_ready;

  -- Check Raw Materials (grouped by raw_material_id to prevent duplicate rows)
  FOR v_item IN
    SELECT
      ri.raw_material_id,
      rm.name AS raw_name,
      SUM(ri.quantity) AS qty_per_yield
    FROM public.recipe_items ri
    JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
    WHERE ri.recipe_id = v_recipe.id
      AND rm.is_active = true
    GROUP BY ri.raw_material_id, rm.name
  LOOP
    v_has_recipe_items := true;
    v_req_qty := (v_item.qty_per_yield / v_recipe.yield_quantity) * v_shortage;

    SELECT COALESCE(quantity, 0) INTO v_avail_qty
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_item.raw_material_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;

    v_avail_qty := COALESCE(v_avail_qty, 0);

    IF v_avail_qty < v_req_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
        'item_type', 'raw_material',
        'product_id', p_product_id,
        'product_name', v_product.name,
        'raw_material_id', v_item.raw_material_id,
        'raw_material_name', v_item.raw_name,
        'required', v_req_qty,
        'available', v_avail_qty,
        'shortage', v_req_qty - v_avail_qty,
        'warehouse_id', p_warehouse_id,
        'warehouse_name', v_warehouse.name,
        'detail', format('الخامة (%s) غير كافية في مستودع (%s). المطلوب: %s، المتوفر: %s',
                         v_item.raw_name, v_warehouse.name, v_req_qty, v_avail_qty)
      );
    END IF;

    IF v_item.qty_per_yield > 0 THEN
      v_producible_max := LEAST(v_producible_max, FLOOR((v_avail_qty * v_recipe.yield_quantity) / v_item.qty_per_yield));
    END IF;
  END LOOP;

  IF NOT v_has_recipe_items THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INSUFFICIENT_STOCK',
      'item_type', 'product',
      'product_id', p_product_id,
      'product_name', v_product.name,
      'required', p_quantity,
      'available', v_ready,
      'shortage', v_shortage,
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name,
      'detail', 'وصفة المنتج خالية من المواد الخام النشطة.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'mode', CASE WHEN v_ready > 0 THEN 'hybrid' ELSE 'recipe' END,
    'available', v_ready + v_producible_max,
    'ready_quantity', v_ready,
    'recipe_quantity', v_shortage,
    'warehouse_id', p_warehouse_id,
    'warehouse_name', v_warehouse.name
  );
END;
$$;

-- 9. Updated get_pos_product_availability for instant POS catalog stock numbers
CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

-- 10. Update deduct_sale_inventory_with_modifiers to match availability exactly (hybrid deduction)
CREATE OR REPLACE FUNCTION public._deduct_sale_inventory_with_modifiers_core(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid,
  p_reference_number text,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_check jsonb;
  v_ready_avail numeric(14,4);
  v_take_ready numeric(14,4);
  v_need_recipe numeric(14,4);
  v_recipe RECORD;
  v_rec_item RECORD;
  v_need_row RECORD;
  v_batch RECORD;
  v_res jsonb;
  v_take numeric(14,4);
  v_need numeric(14,4);
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', true);
  END IF;

  IF p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need (
    product_id uuid PRIMARY KEY,
    required_qty numeric(14,4) NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_ready_need;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need (
    raw_material_id uuid PRIMARY KEY,
    required_qty numeric(14,4) NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_raw_need;

  -- 1. Availability and Requirement Aggregation Phase
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);

    IF v_product_id IS NULL OR v_quantity <= 0 THEN
      CONTINUE;
    END IF;

    -- Validate against warehouse availability
    v_check := public.check_product_availability(v_product_id, p_branch_id, p_warehouse_id, v_quantity);
    IF COALESCE((v_check->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_check;
    END IF;

    -- Calculate ready portion vs recipe portion
    v_ready_avail := COALESCE((v_check->>'ready_quantity')::numeric, 0);
    v_take_ready := LEAST(v_quantity, v_ready_avail);
    v_need_recipe := v_quantity - v_take_ready;

    IF v_take_ready > 0 THEN
      INSERT INTO pg_temp.sale_ready_need (product_id, required_qty)
      VALUES (v_product_id, v_take_ready)
      ON CONFLICT (product_id) DO UPDATE
      SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
    END IF;

    IF v_need_recipe > 0 THEN
      SELECT r.id, r.yield_quantity INTO v_recipe
      FROM public.recipes r
      WHERE r.product_id = v_product_id AND r.branch_id = p_branch_id AND r.is_active = true
      ORDER BY r.version DESC, r.created_at DESC
      LIMIT 1;

      IF v_recipe.id IS NOT NULL AND v_recipe.yield_quantity > 0 THEN
        INSERT INTO pg_temp.sale_raw_need (raw_material_id, required_qty)
        SELECT
          ri.raw_material_id,
          SUM((ri.quantity / v_recipe.yield_quantity) * v_need_recipe)
        FROM public.recipe_items ri
        WHERE ri.recipe_id = v_recipe.id
        GROUP BY ri.raw_material_id
        ON CONFLICT (raw_material_id) DO UPDATE
        SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
      END IF;
    END IF;
  END LOOP;

  -- 2. Execution Phase: Deduct Ready Products
  FOR v_need_row IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty > 0 ORDER BY product_id
  LOOP
    v_res := public._product_inv_remove_fifo(
      v_need_row.product_id,
      p_warehouse_id,
      p_branch_id,
      v_need_row.required_qty,
      'sale',
      'sale',
      p_reference_id,
      p_reference_number,
      p_user_id
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% shortage=%', v_need_row.product_id, v_res->>'shortage';
    END IF;
  END LOOP;

  -- 3. Execution Phase: Deduct Raw Materials from the SAME Warehouse
  FOR v_need_row IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty > 0 ORDER BY raw_material_id
  LOOP
    v_res := public._raw_remove_fifo(
      p_raw_material_id := v_need_row.raw_material_id,
      p_branch_id := p_branch_id,
      p_quantity := v_need_row.required_qty,
      p_movement_type := 'sale',
      p_reference_type := 'sale',
      p_reference_id := p_reference_id,
      p_reference_number := p_reference_number,
      p_created_by := p_user_id,
      p_warehouse_id := p_warehouse_id
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% shortage=%', v_need_row.raw_material_id, v_res->>'shortage';
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 11. Update process_purchase to strictly require and enforce warehouse_id on all receipts
CREATE OR REPLACE FUNCTION public.process_purchase(
  p_invoice_number text,
  p_supplier_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_tax_amount numeric,
  p_total numeric,
  p_paid_amount numeric,
  p_payment_method text,
  p_status text,
  p_notes text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase_id uuid;
  v_user_branch uuid;
  v_item jsonb;
  v_product_id uuid;
  v_raw_id uuid;
  v_quantity numeric(14,4);
  v_unit_cost numeric(14,4);
  v_res jsonb;
  v_goods_fg numeric(14,2) := 0;
  v_goods_rm numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_paid numeric(14,2);
  v_ap numeric(14,2);
  v_stock numeric(14,4);
  v_stock_val numeric(14,2);
  v_new_cost numeric(12,2);
  v_unit_name text;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_PURCHASE');
  END IF;

  IF p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_REQUIRED',
      'detail', 'يرجى تحديد المستودع المستلم للمشتريات'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = p_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'المستودع المحدد لا ينتمي إلى فرع الفاتورة'
    );
  END IF;

  IF NOT is_pos_admin() AND get_user_role() NOT IN ('warehouse_manager','branch_manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND p_branch_id IS NOT NULL AND v_user_branch <> p_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;

  -- Validate items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_raw_id := (v_item->>'raw_material_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);

    IF (v_product_id IS NULL) = (v_raw_id IS NULL) THEN
      RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
    END IF;
    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
  END LOOP;

  -- Write purchase header
  INSERT INTO public.purchases (
    invoice_number, supplier_id, branch_id, warehouse_id, buyer_id,
    subtotal, discount_amount, tax_amount, total, paid_amount,
    payment_method, status, notes
  ) VALUES (
    p_invoice_number, p_supplier_id, p_branch_id, p_warehouse_id, auth.uid(),
    p_subtotal, p_discount_amount, p_tax_amount, p_total, p_paid_amount,
    p_payment_method, p_status, p_notes
  ) RETURNING id INTO v_purchase_id;

  -- Write purchase items and credit stock to the selected warehouse
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_raw_id := (v_item->>'raw_material_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
    v_unit_cost := COALESCE((v_item->>'unit_cost')::numeric, 0);

    IF v_product_id IS NOT NULL THEN
      INSERT INTO public.purchase_items (
        purchase_id, product_id, unit_name, quantity, unit_cost, total
      ) VALUES (
        v_purchase_id, v_product_id, COALESCE(v_item->>'unit_name', 'piece'),
        v_quantity, v_unit_cost, v_quantity * v_unit_cost
      );

      v_res := public._product_inv_add(
        v_product_id, p_warehouse_id, p_branch_id, v_quantity,
        v_unit_cost, v_item->>'batch_number',
        (v_item->>'production_date')::date, (v_item->>'expiry_date')::date,
        'purchase', 'purchase', v_purchase_id, p_invoice_number, auth.uid()
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      -- Update weighted-average cost
      SELECT COALESCE(SUM(b.quantity), 0), COALESCE(SUM(b.quantity * b.unit_cost), 0)
      INTO v_stock, v_stock_val
      FROM public.inventory_batches b WHERE b.product_id = v_product_id;
      v_new_cost := CASE WHEN v_stock > 0 THEN round(v_stock_val / v_stock, 2) ELSE v_unit_cost END;
      UPDATE public.products SET cost_price = v_new_cost, updated_at = now() WHERE id = v_product_id;

      v_goods_fg := round(v_goods_fg + v_quantity * v_unit_cost, 2);
    ELSE
      SELECT COALESCE(u.symbol, u.name, 'وحدة') INTO v_unit_name
      FROM public.raw_materials rm LEFT JOIN public.units u ON u.id = rm.unit_id
      WHERE rm.id = v_raw_id;

      INSERT INTO public.purchase_items (
        purchase_id, raw_material_id, unit_name, quantity, unit_cost, total
      ) VALUES (
        v_purchase_id, v_raw_id, COALESCE(NULLIF(v_item->>'unit_name', ''), v_unit_name),
        v_quantity, v_unit_cost, v_quantity * v_unit_cost
      );

      v_res := public._raw_add(
        p_raw_material_id := v_raw_id,
        p_branch_id := p_branch_id,
        p_quantity := v_quantity,
        p_unit_cost := v_unit_cost,
        p_movement_type := 'purchase',
        p_reference_type := 'purchase',
        p_reference_id := v_purchase_id,
        p_reference_number := p_invoice_number,
        p_notes := v_item->>'notes',
        p_batch_number := v_item->>'batch_number',
        p_created_by := auth.uid(),
        p_warehouse_id := p_warehouse_id
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      v_goods_rm := round(v_goods_rm + v_quantity * v_unit_cost, 2);
    END IF;
  END LOOP;

  -- Accounting Entries for completed purchases
  IF COALESCE(p_status, 'completed') = 'completed' THEN
    v_paid := round(COALESCE(p_paid_amount, 0), 2);
    v_ap := round(COALESCE(p_total, 0) - v_paid, 2);

    IF v_goods_fg > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_goods_fg, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + v_goods_fg;
    END IF;
    IF v_goods_rm > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_goods_rm, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + v_goods_rm;
    END IF;
    IF COALESCE(p_tax_amount, 0) > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', p_tax_amount, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + p_tax_amount;
    END IF;
    IF v_paid > 0 THEN
      v_lines := v_lines || jsonb_build_object(
        'account_key', CASE WHEN p_payment_method IN ('card','bank') THEN 'bank' ELSE 'cash' END,
        'debit', 0, 'credit', v_paid, 'note', p_invoice_number
      );
      v_cr := v_cr + v_paid;
    END IF;
    IF v_ap > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'accounts_payable', 'debit', 0, 'credit', v_ap, 'note', p_invoice_number);
      v_cr := v_cr + v_ap;
    END IF;

    v_diff := round(v_dr - v_cr, 2);
    IF abs(v_diff) > 0 AND abs(v_diff) <= 0.05 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'cogs', 'debit', CASE WHEN v_diff < 0 THEN abs(v_diff) ELSE 0 END, 'credit', CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, 'note', 'Rounding diff');
    END IF;

    IF jsonb_array_length(v_lines) > 0 THEN
      PERFORM public._post_journal_entry(p_branch_id, 'purchase', v_purchase_id, p_invoice_number,
        'فاتورة مشتريات ' || p_invoice_number, v_lines, auth.uid());
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'purchase_id', v_purchase_id);
END;
$$;

-- 12. Update receive_purchase_order to enforce warehouse_id and deposit raw materials into that warehouse
CREATE OR REPLACE FUNCTION public.receive_purchase_order(
  p_purchase_id uuid,
  p_receipt_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', pg_temp
AS $function$
DECLARE
  v_purchase record;
  v_user_branch uuid;
  v_receipt_id uuid;
  v_number text;
  v_item jsonb;
  v_pitem record;
  v_qty numeric(14,4);
  v_res jsonb;
  v_stock numeric(14,4);
  v_stock_val numeric(14,2);
  v_new_cost numeric(12,2);
  v_fully_received boolean := true;
  v_rows integer := 0;
  v_goods_fg numeric(14,2) := 0;
  v_goods_rm numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_paid numeric(14,2);
  v_ap numeric(14,2);
BEGIN
  IF p_receipt_items IS NULL OR jsonb_array_length(p_receipt_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_RECEIPT');
  END IF;

  IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_purchase FROM public.purchases WHERE id = p_purchase_id FOR UPDATE;
  IF v_purchase.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF v_purchase.warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'المستودع غير محدد في أمر الشراء');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_purchase.warehouse_id AND branch_id = v_purchase.branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'مستودع الاستلام لا ينتمي إلى فرع أمر الشراء'
    );
  END IF;

  IF v_purchase.status NOT IN ('approved', 'submitted', 'partial') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_RECEIVABLE', 'status', v_purchase.status);
  END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND v_user_branch <> v_purchase.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;

  -- Validate lines
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
  LOOP
    v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
    SELECT * INTO v_pitem FROM public.purchase_items
    WHERE id = (v_item->>'purchase_item_id')::uuid;
    IF v_pitem.id IS NULL OR v_purchase.id <> v_pitem.purchase_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_ITEM_NOT_FOUND');
    END IF;
    IF v_qty > v_pitem.quantity - COALESCE(v_pitem.received_quantity, 0) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'OVER_RECEIPT',
        'purchase_item_id', v_item->>'purchase_item_id',
        'ordered', v_pitem.quantity,
        'already_received', v_pitem.received_quantity,
        'receiving', v_qty
      );
    END IF;
  END LOOP;

  v_number := (public.next_document_number('purchase_receipt')->>'number')::text;

  INSERT INTO public.purchase_receipts (
    receipt_number, purchase_id, branch_id, warehouse_id, received_by, notes
  ) VALUES (
    v_number, p_purchase_id, v_purchase.branch_id, v_purchase.warehouse_id, auth.uid(), NULL
  ) RETURNING id INTO v_receipt_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
  LOOP
    v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);
    SELECT * INTO v_pitem FROM public.purchase_items WHERE id = (v_item->>'purchase_item_id')::uuid;

    INSERT INTO public.purchase_receipt_items (receipt_id, purchase_item_id, quantity_received, unit_cost)
    VALUES (v_receipt_id, v_pitem.id, v_qty, v_pitem.unit_cost);

    IF v_pitem.product_id IS NOT NULL THEN
      v_res := public._product_inv_add(
        v_pitem.product_id, v_purchase.warehouse_id, v_purchase.branch_id,
        v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
        'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid()
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      SELECT COALESCE(SUM(b.quantity), 0), COALESCE(SUM(b.quantity * b.unit_cost), 0)
      INTO v_stock, v_stock_val
      FROM public.inventory_batches b WHERE b.product_id = v_pitem.product_id;
      v_new_cost := CASE WHEN v_stock > 0 THEN round(v_stock_val / v_stock, 2) ELSE v_pitem.unit_cost END;
      UPDATE public.products SET cost_price = v_new_cost, updated_at = now() WHERE id = v_pitem.product_id;

      v_goods_fg := round(v_goods_fg + v_qty * v_pitem.unit_cost, 2);
    ELSE
      v_res := public._raw_add(
        p_raw_material_id := v_pitem.raw_material_id,
        p_branch_id := v_purchase.branch_id,
        p_quantity := v_qty,
        p_unit_cost := v_pitem.unit_cost,
        p_movement_type := 'purchase',
        p_reference_type := 'purchase',
        p_reference_id := p_purchase_id,
        p_reference_number := v_purchase.invoice_number,
        p_created_by := auth.uid(),
        p_warehouse_id := v_purchase.warehouse_id
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
    END IF;

    UPDATE public.purchase_items
    SET received_quantity = COALESCE(received_quantity, 0) + v_qty
    WHERE id = v_pitem.id;

    v_rows := v_rows + 1;
  END LOOP;

  SELECT EXISTS (
    SELECT 1 FROM public.purchase_items
    WHERE purchase_id = p_purchase_id
      AND quantity - COALESCE(received_quantity, 0) > 0
  ) INTO v_fully_received;
  v_fully_received := NOT v_fully_received;

  UPDATE public.purchases
  SET status = CASE WHEN v_fully_received THEN 'received' ELSE 'partial' END,
      updated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object(
    'success', true,
    'receipt_id', v_receipt_id,
    'receipt_number', v_number,
    'fully_received', v_fully_received
  );
END;
$function$;

-- 13. Create unified view for inventory across all item categories
CREATE OR REPLACE VIEW public.unified_inventory_view AS
-- 1. Finished and component products
SELECT
  'product_' || i.id::text AS unique_id,
  i.id AS record_id,
  i.product_id AS item_id,
  p.name AS item_name,
  p.barcode AS item_code,
  CASE
    WHEN pc.component_product_id IS NOT NULL THEN 'product_component'
    ELSE 'product_ready'
  END AS item_type,
  'قطعة' AS unit_name,
  i.branch_id,
  b.name AS branch_name,
  i.warehouse_id,
  w.name AS warehouse_name,
  i.quantity AS stock_quantity,
  0::numeric AS reserved_quantity,
  i.quantity AS available_quantity,
  COALESCE(p.low_stock_threshold, 0)::numeric AS min_stock,
  COALESCE(p.cost_price, 0)::numeric AS unit_cost,
  ROUND(i.quantity * COALESCE(p.cost_price, 0), 2) AS total_value,
  i.updated_at
FROM public.inventory i
JOIN public.products p ON p.id = i.product_id
JOIN public.branches b ON b.id = i.branch_id
JOIN public.warehouses w ON w.id = i.warehouse_id
LEFT JOIN (SELECT DISTINCT component_product_id FROM public.product_components) pc
  ON pc.component_product_id = p.id

UNION ALL

-- 2. Raw Materials
SELECT
  'raw_' || rmi.id::text AS unique_id,
  rmi.id AS record_id,
  rmi.raw_material_id AS item_id,
  rm.name AS item_name,
  rm.code AS item_code,
  'raw_material' AS item_type,
  COALESCE(u.name, u.symbol, 'وحدة') AS unit_name,
  rmi.branch_id,
  b.name AS branch_name,
  rmi.warehouse_id,
  w.name AS warehouse_name,
  rmi.quantity AS stock_quantity,
  0::numeric AS reserved_quantity,
  rmi.quantity AS available_quantity,
  COALESCE(rmi.min_stock, 0)::numeric AS min_stock,
  COALESCE(rmi.avg_cost, 0)::numeric AS unit_cost,
  ROUND(rmi.quantity * COALESCE(rmi.avg_cost, 0), 2) AS total_value,
  rmi.updated_at
FROM public.raw_material_inventory rmi
JOIN public.raw_materials rm ON rm.id = rmi.raw_material_id
JOIN public.branches b ON b.id = rmi.branch_id
JOIN public.warehouses w ON w.id = rmi.warehouse_id
LEFT JOIN public.units u ON u.id = rm.unit_id

UNION ALL

-- 3. Inventory Units (Aggregated by batch warehouse)
SELECT
  'unit_' || iub.unit_id::text || '_' || iub.warehouse_id::text AS unique_id,
  iub.unit_id AS record_id,
  iub.unit_id AS item_id,
  iu.name AS item_name,
  COALESCE(iu.sku, iu.code) AS item_code,
  CASE
    WHEN iu.unit_type = 'manufactured' THEN 'inventory_unit_manufactured'
    ELSE 'inventory_unit_purchased'
  END AS item_type,
  'وحدة'::text AS unit_name,
  iub.branch_id,
  b.name AS branch_name,
  iub.warehouse_id,
  w.name AS warehouse_name,
  SUM(iub.quantity) AS stock_quantity,
  0::numeric AS reserved_quantity,
  SUM(iub.quantity) AS available_quantity,
  COALESCE(iu.min_stock, 0)::numeric AS min_stock,
  CASE WHEN SUM(iub.quantity) > 0 THEN ROUND(SUM(iub.quantity * iub.unit_cost) / SUM(iub.quantity), 2) ELSE 0 END AS unit_cost,
  ROUND(SUM(iub.quantity * iub.unit_cost), 2) AS total_value,
  MAX(iub.created_at) AS updated_at
FROM public.inventory_unit_batches iub
JOIN public.inventory_units iu ON iu.id = iub.unit_id
JOIN public.branches b ON b.id = iub.branch_id
JOIN public.warehouses w ON w.id = iub.warehouse_id
GROUP BY iub.unit_id, iu.name, iu.sku, iu.code, iu.unit_type, iub.branch_id, b.name, iub.warehouse_id, w.name, iu.min_stock;

GRANT SELECT ON public.unified_inventory_view TO authenticated, service_role;

COMMIT;
