-- Contract fix for the raw-material inventory schema (warehouse-scoped) and the
-- _raw_add/_raw_remove_fifo helpers.
--
-- Live schema facts (pos55_test, post-095/20260908150000/20260909000000):
--   raw_material_inventory : warehouse_id NOT NULL, UNIQUE(raw_material_id,branch_id,warehouse_id),
--                            CHECK quantity >= 0, avg_cost/min_stock/updated_at NOT NULL.
--   raw_material_movements : id, material_id, warehouse_id, movement_type, quantity,
--                            reference_id, notes, branch_id, created_at.
--                            (NO raw_material_id/unit_cost/balance_after/reference_type/
--                             reference_number/created_by.)
--   inventory_ledger       : NO movement_type/balance_after; CHECK
--                            (product_id IS NOT NULL) <> (raw_material_id IS NOT NULL);
--                            has batch_number/before_qty/after_qty/entry_type.
--   raw_material_batches   : has warehouse_id (nullable).
--
-- Root causes addressed here:
--   1. Two 12-arg _raw_add overloads (legacy from 20260902020000 vs new from
--      20260908150000) made every legacy positional call with NULL dates ambiguous
--      ("function _raw_add(uuid,uuid,numeric,numeric,...) is not unique").
--   2. The new overload INSERTed into raw_material_movements (raw_material_id,
--      unit_cost, balance_after, reference_type, reference_number, created_by) and
--      inventory_ledger (movement_type, balance_after) -- columns that do not exist.
--   3. The 9-arg _raw_remove_fifo had the same raw_material_movements column bug.
--   4. The legacy _raw_add never passed raw_material_inventory.warehouse_id (NOT NULL).
--   5. receive_purchase_order logged raw receipts under reference_type='purchase'
--      instead of 'purchase_receipt', breaking the partial-receipt UOM accounting
--      contract.
--
-- Strategy:
--   * Keep _raw_add as the single canonical legacy 12-arg function (warehouse-aware,
--     default warehouse resolution, correct columns). All legacy callers keep working.
--   * Add _raw_add_in_warehouse (explicit warehouse + purchase UOM normalization) and
--     point the two purchase flows (process_purchase, receive_purchase_order) at it.
--   * Drop the ambiguous new _raw_add overload.
--   * Rewrite the 9-arg _raw_remove_fifo with the correct raw_material_movements
--     columns.

-- =============================================================================
-- 1. Merge _raw_add: single legacy 12-arg (warehouse-aware, normalized purchase)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._raw_add(p_raw_material_id uuid, p_branch_id uuid, p_qty numeric, p_unit_cost numeric DEFAULT 0, p_batch_number text DEFAULT NULL::text, p_production_date date DEFAULT NULL::date, p_expiry_date date DEFAULT NULL::date, p_entry_type text DEFAULT 'purchase'::text, p_reference_type text DEFAULT NULL::text, p_reference_id uuid DEFAULT NULL::uuid, p_reference_number text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_inv record;
  v_new_avg numeric(18,6);
  v_before numeric(14,4) := 0;
  v_after numeric(14,4);
  v_batch_no text;
  v_qty numeric(18,6) := p_qty;
  v_cost numeric(18,6) := COALESCE(p_unit_cost, 0);
  v_warehouse_id uuid;
  v_purchase_unit text;
  v_invoice_qty numeric;
  v_invoice_cost numeric;
  v_norm jsonb;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PARAMS');
  END IF;

  -- Resolve the active default warehouse for the branch (raw stock is warehouse-scoped)
  SELECT id INTO v_warehouse_id
  FROM public.warehouses
  WHERE branch_id = p_branch_id AND is_active = true
  ORDER BY is_default DESC, created_at ASC
  LIMIT 1;

  IF v_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'No active warehouse found for branch');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_BRANCH_MISMATCH');
  END IF;

  -- process_purchase inserts purchase_items immediately before calling _raw_add.
  -- Read that invoice line so inventory can be normalized while the invoice stays unchanged.
  IF p_entry_type = 'purchase' AND p_reference_type = 'purchase' AND p_reference_id IS NOT NULL THEN
    SELECT pi.unit_name, pi.quantity, pi.unit_cost
    INTO v_purchase_unit, v_invoice_qty, v_invoice_cost
    FROM public.purchase_items pi
    WHERE pi.purchase_id = p_reference_id
      AND pi.raw_material_id = p_raw_material_id
    ORDER BY pi.created_at DESC NULLS LAST, pi.id DESC
    LIMIT 1;

    IF FOUND THEN
      v_norm := public._normalize_raw_purchase_uom(
        p_raw_material_id,
        COALESCE(v_invoice_qty, p_qty),
        COALESCE(v_invoice_cost, p_unit_cost),
        v_purchase_unit
      );
      IF COALESCE((v_norm->>'success')::boolean, false) IS NOT TRUE THEN
        RETURN v_norm;
      END IF;
      v_qty := (v_norm->>'stock_quantity')::numeric;
      v_cost := (v_norm->>'stock_unit_cost')::numeric;
    END IF;
  END IF;

  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_NORMALIZED_QUANTITY');
  END IF;

  v_batch_no := COALESCE(NULLIF(btrim(COALESCE(p_batch_number, '')), ''),
                         'RB-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  SELECT * INTO v_inv
  FROM public.raw_material_inventory
  WHERE raw_material_id = p_raw_material_id AND branch_id = p_branch_id AND warehouse_id = v_warehouse_id
  FOR UPDATE;

  IF v_inv.id IS NULL THEN
    v_before := 0;
    v_after := v_qty;
    v_new_avg := v_cost;
    INSERT INTO public.raw_material_inventory (raw_material_id, branch_id, warehouse_id, quantity, avg_cost)
    VALUES (p_raw_material_id, p_branch_id, v_warehouse_id, v_qty, v_new_avg);
  ELSE
    v_before := v_inv.quantity;
    v_after := v_before + v_qty;
    v_new_avg := CASE WHEN v_after > 0
      THEN round((v_inv.quantity * v_inv.avg_cost + v_qty * v_cost) / v_after, 6)
      ELSE v_cost END;
    UPDATE public.raw_material_inventory
    SET quantity = v_after, avg_cost = v_new_avg, updated_at = now()
    WHERE id = v_inv.id;
  END IF;

  INSERT INTO public.raw_material_batches
    (raw_material_id, branch_id, warehouse_id, batch_number, quantity, unit_cost, production_date, expiry_date, source_type, source_id)
  VALUES
    (p_raw_material_id, p_branch_id, v_warehouse_id, v_batch_no, v_qty, v_cost,
     p_production_date, p_expiry_date, COALESCE(p_reference_type, p_entry_type), p_reference_id);

  INSERT INTO public.inventory_ledger
    (raw_material_id, branch_id, warehouse_id, batch_number, quantity, unit_cost, total_cost, before_qty, after_qty,
     entry_type, reference_type, reference_id, reference_number, created_by)
  VALUES
    (p_raw_material_id, p_branch_id, v_warehouse_id, v_batch_no, v_qty, v_cost,
     round(v_qty * v_cost, 2), v_before, v_after, p_entry_type,
     p_reference_type, p_reference_id, p_reference_number, p_created_by);

  INSERT INTO public.raw_material_movements
    (material_id, warehouse_id, movement_type, quantity, reference_id, notes, branch_id)
  VALUES
    (p_raw_material_id, v_warehouse_id, p_entry_type, v_qty, p_reference_id, NULL, p_branch_id);

  RETURN jsonb_build_object(
    'success', true,
    'before_qty', v_before,
    'after_qty', v_after,
    'added_qty', v_qty,
    'unit_cost', v_cost,
    'avg_cost', v_new_avg,
    'batch_number', v_batch_no,
    'warehouse_id', v_warehouse_id
  );
END;
$function$;

-- =============================================================================
-- 2. _raw_add_in_warehouse: warehouse-aware add with purchase UOM normalization.
--    Used by the purchase flows (process_purchase / receive_purchase_order) so raw
--    materials land in the explicitly selected warehouse while the invoice stays
--    unchanged and each partial receipt keeps its own normalized stock value.
-- =============================================================================
CREATE OR REPLACE FUNCTION public._raw_add_in_warehouse(p_raw_material_id uuid, p_branch_id uuid, p_quantity numeric, p_unit_cost numeric, p_movement_type text, p_reference_type text, p_reference_id uuid, p_reference_number text, p_notes text DEFAULT NULL::text, p_batch_number text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid, p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_qty numeric(14,4) := COALESCE(p_quantity, 0);
  v_cost numeric(14,4) := COALESCE(p_unit_cost, 0);
  v_warehouse_id uuid := p_warehouse_id;
  v_cur_qty numeric(14,4) := 0;
  v_cur_avg numeric(14,4) := 0;
  v_new_qty numeric(14,4);
  v_new_avg numeric(14,4);
  v_batch_id uuid;
  v_batch_no text;
  v_purchase_unit text;
  v_norm jsonb;
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

  -- Purchase UOM normalization: the receipt unit comes from the purchase_items line,
  -- the received quantity/cost from this call, so partial receipts stay proportional.
  IF COALESCE(p_movement_type, '') = 'purchase'
     AND p_reference_type IN ('purchase', 'purchase_receipt')
     AND p_reference_id IS NOT NULL THEN
    SELECT pi.unit_name INTO v_purchase_unit
    FROM public.purchase_items pi
    WHERE pi.purchase_id = p_reference_id
      AND pi.raw_material_id = p_raw_material_id
    ORDER BY pi.created_at DESC NULLS LAST, pi.id DESC
    LIMIT 1;

    IF FOUND THEN
      v_norm := public._normalize_raw_purchase_uom(p_raw_material_id, v_qty, v_cost, v_purchase_unit);
      IF COALESCE((v_norm->>'success')::boolean, false) IS NOT TRUE THEN
        RETURN v_norm;
      END IF;
      v_qty := (v_norm->>'stock_quantity')::numeric;
      v_cost := (v_norm->>'stock_unit_cost')::numeric;
      IF v_qty <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_NORMALIZED_QUANTITY');
      END IF;
    END IF;
  END IF;

  -- Lock and fetch existing balance for this warehouse
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

  v_batch_no := COALESCE(NULLIF(btrim(COALESCE(p_batch_number, '')), ''),
                         'B-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  -- Insert into batches with warehouse_id
  INSERT INTO public.raw_material_batches (
    raw_material_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, created_at
  ) VALUES (
    p_raw_material_id, p_branch_id, v_warehouse_id,
    v_batch_no, v_qty, ROUND(v_cost, 2), now()
  ) RETURNING id INTO v_batch_id;

  -- Record movement (live raw_material_movements columns only)
  INSERT INTO public.raw_material_movements (
    material_id, warehouse_id, movement_type,
    quantity, reference_id, notes, branch_id, created_at
  ) VALUES (
    p_raw_material_id, v_warehouse_id, p_movement_type,
    v_qty, p_reference_id, p_notes, p_branch_id, now()
  );

  -- Log to global inventory_ledger (raw-material row keeps the ledger CHECK valid)
  INSERT INTO public.inventory_ledger (
    raw_material_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, total_cost, before_qty, after_qty,
    entry_type, reference_type, reference_id, reference_number, created_by, created_at
  ) VALUES (
    p_raw_material_id, p_branch_id, v_warehouse_id, v_batch_no,
    v_qty, ROUND(v_cost, 2), ROUND(v_qty * v_cost, 2),
    v_cur_qty, v_new_qty,
    p_movement_type, p_reference_type, p_reference_id, p_reference_number, p_created_by, now()
  );

  RETURN jsonb_build_object(
    'success', true,
    'warehouse_id', v_warehouse_id,
    'new_quantity', v_new_qty,
    'new_avg_cost', v_new_avg,
    'batch_id', v_batch_id,
    'batch_number', v_batch_no
  );
END;
$function$;

-- =============================================================================
-- 3. Rewrite process_purchase to use _raw_add_in_warehouse (same body as
--    20260908150000, only the raw add target changes).
-- =============================================================================
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

      v_res := public._raw_add_in_warehouse(
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

-- =============================================================================
-- 4. Rewrite receive_purchase_order: use _raw_add_in_warehouse and log receipts
--    under reference_type='purchase_receipt' (supports partial-receipt accounting).
-- =============================================================================
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

-- =============================================================================
-- 5. Drop the ambiguous new _raw_add overload. Its only callers are the two
--    purchase flows rewritten above; the legacy 12-arg _raw_add remains canonical
--    and every legacy positional call now resolves uniquely.
-- =============================================================================
DROP FUNCTION public._raw_add(uuid, uuid, numeric, numeric, text, text, uuid, text, text, text, uuid, uuid);

-- =============================================================================
-- 6. Rewrite the 9-arg _raw_remove_fifo with the correct raw_material_movements
--    columns (the previous body INSERTed raw_material_id/unit_cost/balance_after/
--    reference_type/reference_number/created_by which do not exist). Signature,
--    warehouse resolution, FIFO logic and return keys are unchanged.
-- =============================================================================
CREATE OR REPLACE FUNCTION public._raw_remove_fifo(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_quantity numeric,
  p_movement_type text,
  p_reference_type text,
  p_reference_id uuid,
  p_reference_number text,
  p_created_by uuid DEFAULT NULL::uuid,
  p_warehouse_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- Record movement (live raw_material_movements columns only)
  INSERT INTO public.raw_material_movements (
    material_id, warehouse_id, movement_type,
    quantity, reference_id, notes, branch_id, created_at
  ) VALUES (
    p_raw_material_id, v_warehouse_id, p_movement_type,
    -(p_quantity - v_remaining), p_reference_id, p_reference_number, p_branch_id, now()
  );

  RETURN jsonb_build_object(
    'success', v_remaining = 0,
    'warehouse_id', v_warehouse_id,
    'deducted', p_quantity - v_remaining,
    'cogs', ROUND(v_total_cost, 2),
    'shortage', v_remaining
  );
END;
$function$;