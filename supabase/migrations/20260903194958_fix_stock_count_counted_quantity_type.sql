CREATE OR REPLACE FUNCTION public.create_stock_count(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_count_type text,
  p_notes text DEFAULT NULL::text,
  p_items jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count_id uuid;
  v_number text;
  v_item jsonb;
  v_product_id uuid;
  v_system_qty numeric(14,4);
  v_unit_cost numeric(12,2);
  v_user_branch uuid;
  v_rows integer := 0;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Creating stock counts requires the inventory.manage permission.');
    END IF;
    IF p_branch_id IS NULL OR p_warehouse_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_WAREHOUSE');
    END IF;
    IF p_count_type IS NULL OR p_count_type NOT IN ('full', 'partial', 'cycle') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_COUNT_TYPE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id = p_warehouse_id AND branch_id = p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_IN_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    v_number := (public.next_document_number('stock_count')->>'number')::text;

    INSERT INTO public.stock_counts (count_number, branch_id, warehouse_id, status, count_type, notes, created_by)
    VALUES (v_number, p_branch_id, p_warehouse_id, 'draft', p_count_type, p_notes, auth.uid())
    RETURNING id INTO v_count_id;

    IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        v_product_id := (v_item->>'product_id')::uuid;
        IF v_product_id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM', 'item', v_item);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_product_id) THEN
          RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND', 'product_id', v_product_id);
        END IF;

        SELECT COALESCE(i.quantity, 0), COALESCE(p.cost_price, 0)
        INTO v_system_qty, v_unit_cost
        FROM public.products p
        LEFT JOIN public.inventory i
          ON i.product_id = p.id AND i.warehouse_id = p_warehouse_id
        WHERE p.id = v_product_id;

        SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
        INTO v_unit_cost
        FROM public.inventory_batches b
        WHERE b.product_id = v_product_id AND b.warehouse_id = p_warehouse_id AND b.quantity > 0;
        IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

        INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
        VALUES (
          v_count_id,
          v_product_id,
          COALESCE(v_system_qty, 0),
          COALESCE(NULLIF(v_item->>'counted_quantity', '')::numeric, v_system_qty),
          v_unit_cost,
          NULLIF((v_item->>'reason')::text, '')
        );
        v_rows := v_rows + 1;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true, 'stock_count_id', v_count_id,
      'count_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
