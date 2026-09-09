CREATE OR REPLACE FUNCTION public.add_stock_count_item(
  p_stock_count_id uuid,
  p_product_id uuid,
  p_counted_quantity numeric DEFAULT NULL::numeric,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
  v_system_qty numeric(14,4);
  v_unit_cost numeric(12,2);
  v_user_branch uuid;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_count FROM public.stock_counts WHERE id = p_stock_count_id FOR UPDATE;
    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;
    IF v_count.status <> 'draft' THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_DRAFT', 'status', v_count.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.products
      WHERE id = p_product_id AND branch_id = v_count.branch_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', p_product_id);
    END IF;

    SELECT COALESCE(i.quantity, 0) INTO v_system_qty
    FROM public.products p
    LEFT JOIN public.inventory i
      ON i.product_id = p.id AND i.warehouse_id = v_count.warehouse_id
    WHERE p.id = p_product_id;
    IF v_system_qty IS NULL THEN v_system_qty := 0; END IF;

    v_unit_cost := COALESCE((SELECT cost_price FROM public.products WHERE id = p_product_id), 0);
    SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
    INTO v_unit_cost
    FROM public.inventory_batches b
    WHERE b.product_id = p_product_id AND b.warehouse_id = v_count.warehouse_id AND b.quantity > 0;
    IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

    INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
    VALUES (p_stock_count_id, p_product_id, v_system_qty,
      COALESCE(p_counted_quantity, v_system_qty), v_unit_cost, p_reason)
    ON CONFLICT (stock_count_id, product_id) DO UPDATE
      SET counted_quantity = EXCLUDED.counted_quantity,
          unit_cost = EXCLUDED.unit_cost,
          reason = EXCLUDED.reason;

    RETURN jsonb_build_object('success', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
