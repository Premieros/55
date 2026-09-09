-- Manufactured unit costing must follow real purchase-derived raw-material cost.
-- The raw-material weighted average is maintained by purchase receipts in
-- raw_material_inventory/raw_material_batches. Do not rely on default_cost.

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_rm_qty numeric;
  v_rm_cost numeric;
  v_batch_number text;
  v_unit_cost numeric := 0;
  v_unit_name text;
BEGIN
  SELECT name INTO v_unit_name
  FROM public.inventory_units
  WHERE id = p_unit_id
    AND unit_type = 'manufactured'
    AND is_active = true;

  IF v_unit_name IS NULL THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit', p_unit_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(now(), 'YYYYMMDD-HH24MISS');

  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent
    FROM public.inventory_unit_recipes iur
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100.0);

    -- Purchase-derived weighted average, with default_cost only as the helper's
    -- last-resort fallback when no received stock has ever existed.
    v_rm_cost := public._raw_wavg_cost(v_recipe.raw_material_id, p_branch_id);
    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, batch_number,
      quantity, unit_cost, expiry_date, source_type, source_id
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, v_batch_number,
      0, COALESCE(v_rm_cost, 0), NULL, 'production_consumption', v_production_id
    );
  END LOOP;

  v_unit_cost := CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END;

  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity, v_unit_cost, CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    v_unit_cost, 'production', 'production', v_production_id, v_batch_number
  );

  INSERT INTO public.inventory_unit_productions (
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  -- Keep master cost visible in inventory and on the matching manufactured
  -- product placeholder used by costing/BOM screens.
  UPDATE public.inventory_units
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE id = p_unit_id;

  UPDATE public.products
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE branch_id = p_branch_id
    AND product_type = 'manufactured'
    AND lower(btrim(name)) = lower(btrim(v_unit_name));

  RETURN v_production_id;
END;
$$;

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;
