-- Keep sale deduction consistent with POS availability: if finished-product stock
-- covers the sale, consume that finished stock even when a legacy recipe exists.
-- Modifier inventory effects are still evaluated separately.
CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL::uuid,
  p_reference_number text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
  v_effect record;
  v_batch record;
  v_need numeric(14,6);
  v_take numeric(14,6);
  v_available numeric(14,6);
  v_total_cost numeric(18,4) := 0;
  v_units jsonb := '[]'::jsonb;
  v_raws jsonb := '[]'::jsonb;
  v_ready jsonb := '[]'::jsonb;
  v_user_branch uuid;
  v_recipe_id uuid;
  v_yield numeric(14,6);
  v_res jsonb;
  v_mod jsonb;
  v_recipe_component_count integer;
  v_link_count integer;
  v_base_ready boolean;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object(
      'success', true,
      'units_deducted', '[]'::jsonb,
      'raw_materials_deducted', '[]'::jsonb,
      'ready_products_deducted', '[]'::jsonb,
      'errors', '[]'::jsonb
    );
  END IF;

  SELECT branch_id INTO v_user_branch
  FROM public.users
  WHERE id = auth.uid();

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(
    unit_id uuid PRIMARY KEY,
    unit_name text,
    unit_type text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(
    raw_material_id uuid PRIMARY KEY,
    raw_name text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(
    product_id uuid PRIMARY KEY,
    product_name text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE pg_temp.sale_unit_need;
  TRUNCATE pg_temp.sale_raw_need;
  TRUNCATE pg_temp.sale_ready_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);

    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = v_product_id
        AND p.branch_id = p_branch_id
        AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    v_mod := public.resolve_product_modifiers(
      v_product_id,
      p_branch_id,
      COALESCE(v_item->'modifier_option_ids', '[]'::jsonb)
    );
    IF COALESCE((v_mod->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_mod;
    END IF;

    -- Use the same authoritative base-stock decision as POS availability.
    v_res := public.check_product_availability(
      v_product_id,
      p_branch_id,
      p_warehouse_id,
      v_quantity
    );
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_res;
    END IF;

    v_base_ready := COALESCE(v_res->>'mode', '') = 'ready_product';
    v_link_count := 0;
    v_recipe_component_count := 0;

    IF v_base_ready THEN
      INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
      SELECT p.id, p.name, v_quantity
      FROM public.products p
      WHERE p.id = v_product_id
      ON CONFLICT(product_id) DO UPDATE
      SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
    ELSE
      SELECT COUNT(*) INTO v_link_count
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = v_product_id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true;

      FOR v_link IN
        SELECT pul.unit_id, pul.quantity, iu.name AS unit_name, iu.unit_type
        FROM public.product_unit_links pul
        JOIN public.inventory_units iu ON iu.id = pul.unit_id
        WHERE pul.product_id = v_product_id
          AND iu.branch_id = p_branch_id
          AND iu.is_active = true
      LOOP
        INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
        VALUES(v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
        ON CONFLICT(unit_id) DO UPDATE
        SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
      END LOOP;

      SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
      INTO v_recipe_id, v_yield
      FROM public.recipes r
      WHERE r.product_id = v_product_id
        AND r.branch_id = p_branch_id
        AND COALESCE(r.is_active, true) = true
      ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
      LIMIT 1;

      IF v_recipe_id IS NOT NULL THEN
        FOR v_link IN
          SELECT ri.raw_material_id,
                 rm.name AS raw_name,
                 ri.quantity / v_yield AS quantity_per_sale
          FROM public.recipe_items ri
          JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
          WHERE ri.recipe_id = v_recipe_id
            AND NOT EXISTS (
              SELECT 1
              FROM public.product_unit_links pul
              JOIN public.inventory_units iu ON iu.id = pul.unit_id
              WHERE pul.product_id = v_product_id
                AND iu.branch_id = p_branch_id
                AND iu.is_active = true
                AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
                    regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
            )
        LOOP
          v_recipe_component_count := v_recipe_component_count + 1;
          INSERT INTO pg_temp.sale_raw_need(raw_material_id, raw_name, required_qty)
          VALUES(v_link.raw_material_id, v_link.raw_name, v_quantity * v_link.quantity_per_sale)
          ON CONFLICT(raw_material_id) DO UPDATE
          SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
        END LOOP;
      END IF;

      IF v_link_count = 0 AND v_recipe_component_count = 0 THEN
        INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
        SELECT p.id, p.name, v_quantity
        FROM public.products p
        WHERE p.id = v_product_id
        ON CONFLICT(product_id) DO UPDATE
        SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
      END IF;
    END IF;

    -- Selected modifier effects remain independent from the base-stock source.
    FOR v_effect IN
      SELECT e.target_type,
             e.raw_material_id,
             e.inventory_unit_id,
             e.quantity_delta,
             rm.name AS raw_name,
             iu.name AS unit_name,
             iu.unit_type
      FROM public.product_modifier_inventory_effects e
      JOIN public.product_modifier_options o ON o.id = e.option_id AND o.is_active = true
      JOIN public.product_modifier_groups g ON g.id = o.group_id AND g.is_active = true
      LEFT JOIN public.raw_materials rm ON rm.id = e.raw_material_id
      LEFT JOIN public.inventory_units iu ON iu.id = e.inventory_unit_id
      WHERE g.product_id = v_product_id
        AND g.branch_id = p_branch_id
        AND o.id IN (
          SELECT NULLIF(value, '')::uuid
          FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids', '[]'::jsonb))
        )
    LOOP
      IF v_effect.target_type = 'raw_material' THEN
        INSERT INTO pg_temp.sale_raw_need(raw_material_id, raw_name, required_qty)
        VALUES(v_effect.raw_material_id, v_effect.raw_name, v_quantity * v_effect.quantity_delta)
        ON CONFLICT(raw_material_id) DO UPDATE
        SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
      ELSE
        INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
        VALUES(v_effect.inventory_unit_id, v_effect.unit_name, v_effect.unit_type, v_quantity * v_effect.quantity_delta)
        ON CONFLICT(unit_id) DO UPDATE
        SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
      END IF;
    END LOOP;

    v_recipe_id := NULL;
    v_yield := NULL;
  END LOOP;

  IF EXISTS(SELECT 1 FROM pg_temp.sale_unit_need WHERE required_qty < 0)
     OR EXISTS(SELECT 1 FROM pg_temp.sale_raw_need WHERE required_qty < 0) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_MODIFIER_INVENTORY_EFFECT',
      'detail', 'Modifier removal exceeds the base component quantity.'
    );
  END IF;

  FOR v_link IN
    SELECT * FROM pg_temp.sale_unit_need
    WHERE required_qty > 0 AND unit_type = 'manufactured'
    ORDER BY unit_id
  LOOP
    PERFORM public._ensure_inventory_unit_stock(
      v_link.unit_id,
      v_link.required_qty,
      p_warehouse_id,
      p_branch_id,
      0
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty > 0 ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',
        v_link.unit_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty > 0 ORDER BY raw_material_id
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_link.raw_material_id
      AND branch_id = p_branch_id;
    v_available := COALESCE(v_available, 0);
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',
        v_link.raw_material_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty > 0 ORDER BY product_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_batches
    WHERE product_id = v_link.product_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',
        v_link.product_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty > 0 ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at, id
      FOR UPDATE
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, v_batch.quantity);
      UPDATE public.inventory_unit_batches
      SET quantity = quantity - v_take
      WHERE id = v_batch.id;
      INSERT INTO public.inventory_unit_entries(
        unit_id, branch_id, warehouse_id, quantity, unit_cost,
        entry_type, reference_type, reference_id, reference_number,
        batch_number, created_by
      ) VALUES(
        v_link.unit_id, p_branch_id, p_warehouse_id, -v_take, v_batch.unit_cost,
        'sale', 'sale', p_reference_id, p_reference_number,
        v_batch.batch_number, auth.uid()
      );
      v_need := v_need - v_take;
      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
    END LOOP;
    v_units := v_units || jsonb_build_object(
      'unit_id', v_link.unit_id,
      'unit_name', v_link.unit_name,
      'unit_type', v_link.unit_type,
      'quantity', v_link.required_qty
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty > 0 ORDER BY raw_material_id
  LOOP
    v_res := public._raw_remove_fifo(
      v_link.raw_material_id,
      p_branch_id,
      v_link.required_qty,
      'sale', 'sale', p_reference_id, p_reference_number, auth.uid()
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',
        v_link.raw_material_id, v_res->>'shortage';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
    v_raws := v_raws || jsonb_build_object(
      'raw_material_id', v_link.raw_material_id,
      'raw_name', v_link.raw_name,
      'quantity', v_link.required_qty,
      'total_cost', COALESCE((v_res->>'total_cost')::numeric, 0)
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty > 0 ORDER BY product_id
  LOOP
    v_res := public._product_inv_remove_fifo(
      v_link.product_id,
      p_warehouse_id,
      p_branch_id,
      v_link.required_qty,
      'sale', 'sale', p_reference_id, p_reference_number, auth.uid()
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',
        v_link.product_id, v_res->>'shortage';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
    v_ready := v_ready || jsonb_build_object(
      'product_id', v_link.product_id,
      'product_name', v_link.product_name,
      'quantity', v_link.required_qty,
      'total_cost', COALESCE((v_res->>'total_cost')::numeric, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', v_raws,
    'ready_products_deducted', v_ready,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', 'SALE_INVENTORY_DEDUCTION_FAILED',
    'detail', SQLERRM
  );
END;
$function$;
