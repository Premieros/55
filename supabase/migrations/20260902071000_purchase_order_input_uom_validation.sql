-- Validate manual PO quantities/costs and UOM compatibility before creating an unreceivable order.
DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='create_purchase_order'
    AND pg_get_function_identity_arguments(p.oid)=
      'p_branch_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_payment_method text, p_notes text, p_items jsonb, p_quotation_id uuid';
  IF v_src IS NULL THEN RAISE EXCEPTION 'create_purchase_order target not found'; END IF;

  v_old := $decl$  v_request_id uuid;$decl$;
  v_new := $decl$  v_request_id uuid;
  v_norm jsonb;$decl$;
  IF position('v_norm jsonb;' IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION 'create_purchase_order declaration block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  v_old := $old$        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        INSERT INTO public.purchase_items$old$;
  v_new := $new$        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        IF COALESCE((v_item->>'quantity')::numeric, 0) <= 0
           OR COALESCE((v_item->>'unit_cost')::numeric, 0) < 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_PURCHASE_QUANTITY_OR_COST');
        END IF;
        IF NULLIF(v_item->>'raw_material_id', '') IS NOT NULL THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.raw_materials rm
            WHERE rm.id = (v_item->>'raw_material_id')::uuid
              AND rm.branch_id = p_branch_id AND rm.is_active = true
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
          v_norm := public._normalize_raw_purchase_uom(
            (v_item->>'raw_material_id')::uuid,
            (v_item->>'quantity')::numeric,
            (v_item->>'unit_cost')::numeric,
            NULLIF(v_item->>'unit_name','')
          );
          IF COALESCE((v_norm->>'success')::boolean, false) IS NOT TRUE THEN
            RETURN v_norm;
          END IF;
        ELSE
          IF NOT EXISTS (
            SELECT 1 FROM public.products p
            WHERE p.id = (v_item->>'product_id')::uuid
              AND p.branch_id = p_branch_id AND p.is_active = true
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH');
          END IF;
        END IF;
        INSERT INTO public.purchase_items$new$;

  IF position(v_new IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION 'create_purchase_order manual validation block changed unexpectedly'; END IF;
    v_src := replace(v_src,v_old,v_new);
  END IF;

  EXECUTE v_src;
END
$do$;

NOTIFY pgrst, 'reload schema';
