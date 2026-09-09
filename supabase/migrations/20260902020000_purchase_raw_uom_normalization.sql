-- Normalize raw-material purchase units to each raw material's stock unit.
-- Purchase invoice lines remain in the user's entered unit/price; inventory is stored in the raw's canonical unit.

ALTER TABLE public.raw_material_inventory
  ALTER COLUMN avg_cost TYPE numeric(18,6) USING avg_cost::numeric(18,6);
ALTER TABLE public.raw_material_batches
  ALTER COLUMN unit_cost TYPE numeric(18,6) USING unit_cost::numeric(18,6);
ALTER TABLE public.inventory_ledger
  ALTER COLUMN unit_cost TYPE numeric(18,6) USING unit_cost::numeric(18,6);

CREATE OR REPLACE FUNCTION public._normalize_raw_purchase_uom(
  p_raw_material_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_purchase_unit text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_stock_label text;
  v_stock text;
  v_purchase text;
  v_factor numeric := 1;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 OR p_unit_cost IS NULL OR p_unit_cost < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PURCHASE_QUANTITY_OR_COST');
  END IF;

  SELECT lower(btrim(COALESCE(u.symbol, u.name, '')))
  INTO v_stock_label
  FROM public.raw_materials rm
  LEFT JOIN public.units u ON u.id = rm.unit_id
  WHERE rm.id = p_raw_material_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_FOUND');
  END IF;

  v_purchase := lower(btrim(COALESCE(NULLIF(p_purchase_unit, ''), v_stock_label)));

  v_stock := CASE
    WHEN v_stock_label IN ('g','gr','gm','gram','grams','جم','جرام') THEN 'g'
    WHEN v_stock_label IN ('kg','kgs','kilogram','kilograms','كجم','كغ','كيلو','ك') THEN 'kg'
    WHEN v_stock_label IN ('ml','mil','milliliter','milliliters','مل') THEN 'ml'
    WHEN v_stock_label IN ('l','lt','liter','litre','liters','litres','ل','لتر') THEN 'l'
    WHEN v_stock_label IN ('each','ea','pcs','pc','piece','pieces','قطعة','حبة') THEN 'each'
    WHEN v_stock_label IN ('packet','pack','bag','كيس','باكيت') THEN 'packet'
    ELSE v_stock_label
  END;

  v_purchase := CASE
    WHEN v_purchase IN ('g','gr','gm','gram','grams','جم','جرام') THEN 'g'
    WHEN v_purchase IN ('kg','kgs','kilogram','kilograms','كجم','كغ','كيلو','ك') THEN 'kg'
    WHEN v_purchase IN ('ml','mil','milliliter','milliliters','مل') THEN 'ml'
    WHEN v_purchase IN ('l','lt','liter','litre','liters','litres','ل','لتر') THEN 'l'
    WHEN v_purchase IN ('each','ea','pcs','pc','piece','pieces','قطعة','حبة') THEN 'each'
    WHEN v_purchase IN ('packet','pack','bag','كيس','باكيت') THEN 'packet'
    ELSE v_purchase
  END;

  IF v_stock = v_purchase THEN
    v_factor := 1;
  ELSIF v_stock = 'g' AND v_purchase = 'kg' THEN
    v_factor := 1000;
  ELSIF v_stock = 'kg' AND v_purchase = 'g' THEN
    v_factor := 0.001;
  ELSIF v_stock = 'ml' AND v_purchase = 'l' THEN
    v_factor := 1000;
  ELSIF v_stock = 'l' AND v_purchase = 'ml' THEN
    v_factor := 0.001;
  ELSE
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INCOMPATIBLE_PURCHASE_UNIT',
      'stock_unit', v_stock_label,
      'purchase_unit', p_purchase_unit
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'stock_unit', v_stock_label,
    'purchase_unit', p_purchase_unit,
    'factor', v_factor,
    'stock_quantity', round(p_quantity * v_factor, 6),
    'stock_unit_cost', round(p_unit_cost / v_factor, 6),
    'invoice_total', round(p_quantity * p_unit_cost, 2)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._raw_add(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_qty numeric,
  p_unit_cost numeric DEFAULT 0,
  p_batch_number text DEFAULT NULL,
  p_production_date date DEFAULT NULL,
  p_expiry_date date DEFAULT NULL,
  p_entry_type text DEFAULT 'purchase',
  p_reference_type text DEFAULT NULL,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL,
  p_created_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv record;
  v_new_avg numeric(18,6);
  v_before numeric(14,4) := 0;
  v_after numeric(14,4);
  v_batch_no text;
  v_qty numeric(18,6) := p_qty;
  v_cost numeric(18,6) := COALESCE(p_unit_cost, 0);
  v_purchase_unit text;
  v_invoice_qty numeric;
  v_invoice_cost numeric;
  v_norm jsonb;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PARAMS');
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
  WHERE raw_material_id = p_raw_material_id AND branch_id = p_branch_id
  FOR UPDATE;

  IF v_inv.id IS NULL THEN
    v_before := 0;
    v_after := v_qty;
    v_new_avg := v_cost;
    INSERT INTO public.raw_material_inventory (raw_material_id, branch_id, quantity, avg_cost)
    VALUES (p_raw_material_id, p_branch_id, v_qty, v_new_avg);
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
    (raw_material_id, branch_id, batch_number, quantity, unit_cost, production_date, expiry_date, source_type, source_id)
  VALUES
    (p_raw_material_id, p_branch_id, v_batch_no, v_qty, v_cost,
     p_production_date, p_expiry_date, COALESCE(p_reference_type, p_entry_type), p_reference_id);

  INSERT INTO public.inventory_ledger
    (raw_material_id, branch_id, batch_number, quantity, unit_cost, total_cost, before_qty, after_qty,
     entry_type, reference_type, reference_id, reference_number, created_by)
  VALUES
    (p_raw_material_id, p_branch_id, v_batch_no, v_qty, v_cost,
     round(v_qty * v_cost, 2), v_before, v_after, p_entry_type,
     p_reference_type, p_reference_id, p_reference_number, p_created_by);

  RETURN jsonb_build_object(
    'success', true,
    'before_qty', v_before,
    'after_qty', v_after,
    'added_qty', v_qty,
    'unit_cost', v_cost,
    'avg_cost', v_new_avg,
    'batch_number', v_batch_no
  );
END;
$$;

REVOKE ALL ON FUNCTION public._normalize_raw_purchase_uom(uuid,numeric,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._normalize_raw_purchase_uom(uuid,numeric,numeric,text) TO authenticated, service_role;
