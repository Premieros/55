-- Keep direct purchase-order totals, partial raw-material receipts, stock UOM,
-- and the final purchase journal aligned to the complete order.

DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_purchase_order'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_branch_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_payment_method text, p_notes text, p_items jsonb, p_quotation_id uuid';

  IF v_src IS NULL THEN RAISE EXCEPTION 'create_purchase_order target not found'; END IF;

  v_old := $old$          round(COALESCE((v_item->>'quantity')::numeric, 0) * COALESCE((v_item->>'unit_cost')::numeric, 0), 2));
        v_rows := v_rows + 1;
$old$;
  v_new := $new$          round(COALESCE((v_item->>'quantity')::numeric, 0) * COALESCE((v_item->>'unit_cost')::numeric, 0), 2));
        v_total := v_total
          + COALESCE((v_item->>'quantity')::numeric, 0)
          * COALESCE((v_item->>'unit_cost')::numeric, 0);
        v_rows := v_rows + 1;
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'create_purchase_order manual total block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
    EXECUTE v_src;
  END IF;
END
$do$;

DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'receive_purchase_order'
    AND pg_get_function_identity_arguments(p.oid) = 'p_purchase_id uuid, p_receipt_items jsonb';

  IF v_src IS NULL THEN RAISE EXCEPTION 'receive_purchase_order target not found'; END IF;

  v_old := $old$      ELSE
        v_res := public._raw_add(v_pitem.raw_material_id, v_purchase.branch_id,
          v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
          'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
        v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
      END IF;
$old$;
  v_new := $new$      ELSE
        -- Normalize the quantity actually received, not the full ordered line.
        v_res := public._normalize_raw_purchase_uom(
          v_pitem.raw_material_id, v_qty, v_pitem.unit_cost, v_pitem.unit_name);
        IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
          RETURN v_res;
        END IF;
        v_res := public._raw_add(v_pitem.raw_material_id, v_purchase.branch_id,
          (v_res->>'stock_quantity')::numeric, (v_res->>'stock_unit_cost')::numeric,
          NULL, NULL, NULL, 'purchase', 'purchase_receipt', v_receipt_id, v_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
        v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
      END IF;
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'receive_purchase_order raw receipt block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  v_old := $old$    IF v_fully_received THEN
      v_paid := round(COALESCE(v_purchase.paid_amount, 0), 2);
$old$;
  v_new := $new$    IF v_fully_received THEN
      -- Earlier partial receipts were not posted. Rebuild inventory value from
      -- the full order so the completion journal never contains only the last GRN.
      SELECT
        round(COALESCE(SUM(CASE WHEN pi.product_id IS NOT NULL THEN pi.quantity * pi.unit_cost ELSE 0 END), 0), 2),
        round(COALESCE(SUM(CASE WHEN pi.raw_material_id IS NOT NULL THEN pi.quantity * pi.unit_cost ELSE 0 END), 0), 2)
      INTO v_goods_fg, v_goods_rm
      FROM public.purchase_items pi
      WHERE pi.purchase_id = p_purchase_id;

      v_paid := round(LEAST(GREATEST(COALESCE(v_purchase.paid_amount, 0), 0), COALESCE(v_purchase.total, 0)), 2);
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'receive_purchase_order completion journal block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  EXECUTE v_src;
END
$do$;

NOTIFY pgrst, 'reload schema';
