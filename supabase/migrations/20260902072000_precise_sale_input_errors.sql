-- Final audit: keep sale input validation explicit so callers can distinguish
-- malformed product identifiers from invalid quantities without weakening P2.

DO $do$
DECLARE
  v_src text;
  v_old_compact text := $old$    IF v_product_id IS NULL OR v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT'); END IF;$old$;
  v_old_multiline text := $old$    IF v_product_id IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT');
    END IF;$old$;
  v_new text := $new$    IF v_product_id IS NULL THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_PRODUCT');
    END IF;
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY');
    END IF;$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'process_sale'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'process_sale target signature not found';
  END IF;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old_compact IN v_src) > 0 THEN
      v_src := replace(v_src, v_old_compact, v_new);
    ELSIF position(v_old_multiline IN v_src) > 0 THEN
      v_src := replace(v_src, v_old_multiline, v_new);
    ELSE
      RAISE EXCEPTION 'process_sale input validation block changed unexpectedly';
    END IF;
    EXECUTE v_src;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
