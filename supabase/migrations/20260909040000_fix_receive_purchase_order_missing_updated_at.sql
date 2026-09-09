-- Fix receive_purchase_order: public.purchases has no updated_at column.
-- The status UPDATE (built by the warehouse-unification era migration) referenced
-- updated_at = now(), which fails on every receipt. Keep everything else identical
-- (partial-receipt raw normalization + full-order journal on completion).

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
      v_res := public._raw_add_in_warehouse(
        p_raw_material_id := v_pitem.raw_material_id,
        p_branch_id := v_purchase.branch_id,
        p_quantity := v_qty,
        p_unit_cost := v_pitem.unit_cost,
        p_movement_type := 'purchase',
        p_reference_type := 'purchase_receipt',
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

  IF v_fully_received THEN
    -- Post the full-order purchase journal once the order is fully received.
    SELECT COALESCE(SUM(CASE WHEN product_id IS NOT NULL THEN quantity * unit_cost END), 0),
           COALESCE(SUM(CASE WHEN raw_material_id IS NOT NULL THEN quantity * unit_cost END), 0)
    INTO v_goods_fg, v_goods_rm
    FROM public.purchase_items
    WHERE purchase_id = p_purchase_id;

    v_paid := round(COALESCE(v_purchase.paid_amount, 0), 2);
    v_ap := round(COALESCE(v_purchase.total, 0) - v_paid, 2);
    v_dr := 0;
    v_cr := 0;
    v_lines := '[]'::jsonb;

    IF v_goods_fg > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_goods_fg, 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + v_goods_fg;
    END IF;
    IF v_goods_rm > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_goods_rm, 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + v_goods_rm;
    END IF;
    IF COALESCE(v_purchase.tax_amount, 0) > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', COALESCE(v_purchase.tax_amount, 0), 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + COALESCE(v_purchase.tax_amount, 0);
    END IF;
    IF v_paid > 0 THEN
      v_lines := v_lines || jsonb_build_object(
        'account_key', CASE WHEN v_purchase.payment_method IN ('card','bank') THEN 'bank' ELSE 'cash' END,
        'debit', 0, 'credit', v_paid, 'note', COALESCE(v_purchase.invoice_number, v_number)
      );
      v_cr := v_cr + v_paid;
    END IF;
    IF v_ap > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'accounts_payable', 'debit', 0, 'credit', v_ap, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_cr := v_cr + v_ap;
    END IF;

    v_diff := round(v_dr - v_cr, 2);
    IF abs(v_diff) > 0 AND abs(v_diff) <= 0.05 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'cogs', 'debit', CASE WHEN v_diff < 0 THEN abs(v_diff) ELSE 0 END, 'credit', CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, 'note', 'Rounding diff');
    END IF;

    IF jsonb_array_length(v_lines) > 0 THEN
      PERFORM public._post_journal_entry(
        v_purchase.branch_id, 'purchase', p_purchase_id,
        COALESCE(v_purchase.invoice_number, v_number),
        'استلام أمر شراء ' || v_number, v_lines
      );
    END IF;
  END IF;

  UPDATE public.purchases
  SET status = CASE WHEN v_fully_received THEN 'received' ELSE 'partial' END
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object(
    'success', true,
    'receipt_id', v_receipt_id,
    'receipt_number', v_number,
    'fully_received', v_fully_received
  );
END;
$function$;