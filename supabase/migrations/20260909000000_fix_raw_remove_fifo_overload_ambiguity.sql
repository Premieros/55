-- Fix: route all remaining 8-argument _raw_remove_fifo call sites to the
-- warehouse-aware 9-argument overload (added by 20260908150000). The old
-- 8-arg overload is branch-scoped while raw balance + batches are now strictly
-- warehouse-scoped; both share a matching prefix so every 8-arg positional
-- call is ambiguous at runtime ("function is not unique"). Forwarding the
-- warehouse restores unambiguous resolution AND keeps deductions strictly in
-- the caller's warehouse (identical semantics to the named 9-arg call already
-- used by the unit-sale path).

BEGIN;

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(p_unit_id uuid, p_quantity numeric, p_warehouse_id uuid, p_branch_id uuid DEFAULT get_branch_id(), p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_component record;
  v_rm_qty numeric;
  v_batch_number text;
  v_unit_cost numeric := 0;
  v_unit_name text;
  v_res jsonb;
  v_need numeric;
  v_available numeric;
  v_batch record;
  v_take numeric;
BEGIN
  SELECT name INTO v_unit_name
  FROM public.inventory_units
  WHERE id = p_unit_id
    AND unit_type = 'manufactured'
    AND is_active = true
    AND (branch_id = p_branch_id OR branch_id IS NULL);

  IF v_unit_name IS NULL THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit in branch %', p_unit_id, p_branch_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  -- Preflight manufactured child stock before mutating raw stock.
  FOR v_component IN
    SELECT iuru.component_unit_id, iuru.quantity, iuru.wastage_percent
    FROM public.inventory_unit_recipe_units iuru
    WHERE iuru.unit_id = p_unit_id
  LOOP
    v_need := p_quantity * v_component.quantity * (1 + v_component.wastage_percent / 100.0);
    SELECT COALESCE(SUM(iub.quantity), 0)
      INTO v_available
    FROM public.inventory_unit_batches iub
    WHERE iub.unit_id = v_component.component_unit_id
      AND iub.branch_id = p_branch_id
      AND iub.warehouse_id = p_warehouse_id
      AND iub.quantity > 0;

    IF v_available < v_need THEN
      RAISE EXCEPTION 'INSUFFICIENT_COMPONENT_UNIT_STOCK unit=% required=% available=%',
        v_component.component_unit_id, v_need, v_available;
    END IF;
  END LOOP;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-MS');

  -- Consume direct raw-material ingredients using purchase-derived FIFO cost.
  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent
    FROM public.inventory_unit_recipes iur
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100.0);

    v_res := public._raw_remove_fifo(
      v_recipe.raw_material_id,
      p_branch_id,
      v_rm_qty,
      'production',
      'production',
      v_production_id,
      v_batch_number,
      auth.uid(),
    p_warehouse_id);

    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% shortage=%',
        v_recipe.raw_material_id, v_rm_qty, v_res->>'shortage';
    END IF;

    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
  END LOOP;

  -- Consume nested/semi-finished manufactured units FIFO.
  FOR v_component IN
    SELECT iuru.component_unit_id, iuru.quantity, iuru.wastage_percent
    FROM public.inventory_unit_recipe_units iuru
    WHERE iuru.unit_id = p_unit_id
    ORDER BY iuru.component_unit_id
  LOOP
    v_need := p_quantity * v_component.quantity * (1 + v_component.wastage_percent / 100.0);

    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_component.component_unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
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
      ) VALUES (
        v_component.component_unit_id, p_branch_id, p_warehouse_id,
        -v_take, v_batch.unit_cost,
        'production_consumption', 'production', v_production_id, v_batch_number,
        v_batch.batch_number, auth.uid()
      );

      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
      v_need := v_need - v_take;
    END LOOP;
  END LOOP;

  v_unit_cost := CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END;

  INSERT INTO public.inventory_unit_batches(
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity, v_unit_cost, CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries(
    unit_id, branch_id, warehouse_id, quantity, unit_cost,
    entry_type, reference_type, reference_id, batch_number, created_by
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity, v_unit_cost,
    'production', 'production', v_production_id, v_batch_number, auth.uid()
  );

  INSERT INTO public.inventory_unit_productions(
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  UPDATE public.inventory_units
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE id = p_unit_id;

  UPDATE public.products
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE branch_id = p_branch_id
    AND product_type = 'manufactured'
    AND regexp_replace(lower(btrim(name)), '[ .]+$', '', 'g') =
        regexp_replace(lower(btrim(v_unit_name)), '[ .]+$', '', 'g');

  RETURN v_production_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_raw_material_inventory(p_raw_material_id uuid, p_quantity numeric, p_branch_id uuid, p_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Raw-material inventory is branch-scoped; warehouse_id is accepted for
  -- compatibility with the production RPC but the canonical FIFO helper
  -- operates across the branch's raw-material batches.
  RETURN public._raw_remove_fifo(
    p_raw_material_id,
    p_branch_id,
    p_quantity,
    'production',
    'production',
    NULL,
    NULL,
    auth.uid(),
  p_warehouse_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(p_branch_id uuid, p_warehouse_id uuid, p_items jsonb, p_reference_id uuid DEFAULT NULL::uuid, p_reference_number text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_item jsonb; v_product_id uuid; v_quantity numeric(14,4); v_link record; v_batch record; v_need numeric(14,6); v_take numeric(14,6); v_available numeric(14,6);
  v_total_cost numeric(18,4):=0; v_units jsonb:='[]'::jsonb; v_raws jsonb:='[]'::jsonb; v_ready jsonb:='[]'::jsonb; v_user_branch uuid; v_recipe_id uuid; v_yield numeric(14,6); v_res jsonb; v_recipe_component_count integer; v_link_count integer;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',true,'units_deducted','[]'::jsonb,'raw_materials_deducted','[]'::jsonb,'ready_products_deducted','[]'::jsonb,'errors','[]'::jsonb); END IF;
  SELECT branch_id INTO v_user_branch FROM public.users WHERE id=auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch<>p_branch_id THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(unit_id uuid PRIMARY KEY,unit_name text,unit_type text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(raw_material_id uuid PRIMARY KEY,raw_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(product_id uuid PRIMARY KEY,product_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need; TRUNCATE pg_temp.sale_raw_need; TRUNCATE pg_temp.sale_ready_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id:=(v_item->>'product_id')::uuid; v_quantity:=COALESCE((v_item->>'quantity')::numeric,0);
    IF v_quantity<=0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY','product_id',v_product_id); END IF;
    IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product_id AND p.branch_id=p_branch_id AND p.is_active=true) THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;

    v_res := public.check_product_availability(v_product_id, p_branch_id, p_warehouse_id, v_quantity);
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN RETURN v_res; END IF;

    IF COALESCE(v_res->>'mode', '') = 'ready_product' THEN
      INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty)
      SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id
      ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty;
      CONTINUE;
    END IF;

    SELECT COUNT(*) INTO v_link_count FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true;
    FOR v_link IN SELECT pul.unit_id,pul.quantity,iu.name AS unit_name,iu.unit_type FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty) VALUES(v_link.unit_id,v_link.unit_name,v_link.unit_type,v_quantity*v_link.quantity) ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
    END LOOP;
    SELECT r.id,COALESCE(NULLIF(r.yield_quantity,0),1) INTO v_recipe_id,v_yield FROM public.recipes r WHERE r.product_id=v_product_id AND r.branch_id=p_branch_id AND COALESCE(r.is_active,true)=true ORDER BY COALESCE(r.version,1) DESC,r.created_at DESC LIMIT 1;
    v_recipe_component_count:=0;
    IF v_recipe_id IS NOT NULL THEN
      FOR v_link IN SELECT ri.raw_material_id,rm.name AS raw_name,ri.quantity/v_yield AS quantity_per_sale FROM public.recipe_items ri JOIN public.raw_materials rm ON rm.id=ri.raw_material_id WHERE ri.recipe_id=v_recipe_id AND NOT EXISTS(SELECT 1 FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true AND regexp_replace(lower(btrim(iu.name)),'[ .]+$','','g')=regexp_replace(lower(btrim(rm.name)),'[ .]+$','','g')) LOOP
        v_recipe_component_count:=v_recipe_component_count+1;
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty) VALUES(v_link.raw_material_id,v_link.raw_name,v_quantity*v_link.quantity_per_sale) ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      END LOOP;
    END IF;
    IF v_link_count=0 AND v_recipe_component_count=0 THEN INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty) SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty; END IF;
    v_recipe_id:=NULL; v_yield:=NULL;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE unit_type='manufactured' ORDER BY unit_id LOOP
    PERFORM public._ensure_inventory_unit_stock(v_link.unit_id, v_link.required_qty, p_warehouse_id, p_branch_id, 0);
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_unit_batches WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',v_link.unit_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id LOOP
    SELECT COALESCE(quantity,0) INTO v_available FROM public.raw_material_inventory WHERE raw_material_id=v_link.raw_material_id AND branch_id=p_branch_id; v_available:=COALESCE(v_available,0);
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',v_link.raw_material_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_batches WHERE product_id=v_link.product_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',v_link.product_id,v_link.required_qty,v_available; END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id LOOP
    v_need:=v_link.required_qty;
    FOR v_batch IN SELECT id,quantity,unit_cost,batch_number FROM public.inventory_unit_batches WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id AND quantity>0 ORDER BY created_at,id FOR UPDATE LOOP
      EXIT WHEN v_need<=0; v_take:=LEAST(v_need,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,reference_type,reference_id,reference_number,batch_number,created_by) VALUES(v_link.unit_id,p_branch_id,p_warehouse_id,-v_take,v_batch.unit_cost,'sale','sale',p_reference_id,p_reference_number,v_batch.batch_number,auth.uid());
      v_need:=v_need-v_take; v_total_cost:=v_total_cost+(v_take*COALESCE(v_batch.unit_cost,0));
    END LOOP;
    v_units:=v_units||jsonb_build_object('unit_id',v_link.unit_id,'unit_name',v_link.unit_name,'unit_type',v_link.unit_type,'quantity',v_link.required_qty);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id LOOP
    v_res:=public._raw_remove_fifo(v_link.raw_material_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid(),
    p_warehouse_id);
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',v_link.raw_material_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_raws:=v_raws||jsonb_build_object('raw_material_id',v_link.raw_material_id,'raw_name',v_link.raw_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id LOOP
    v_res:=public._product_inv_remove_fifo(v_link.product_id,p_warehouse_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',v_link.product_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_ready:=v_ready||jsonb_build_object('product_id',v_link.product_id,'product_name',v_link.product_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  RETURN jsonb_build_object('success',true,'units_deducted',v_units,'raw_materials_deducted',v_raws,'ready_products_deducted',v_ready,'total_cost',v_total_cost,'errors','[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','SALE_INVENTORY_DEDUCTION_FAILED','detail',SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public._deduct_sale_inventory_with_modifiers_core(p_branch_id uuid, p_warehouse_id uuid, p_items jsonb, p_reference_id uuid DEFAULT NULL::uuid, p_reference_number text DEFAULT NULL::text)
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
      'sale', 'sale', p_reference_id, p_reference_number, auth.uid(),
    p_warehouse_id);
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

CREATE OR REPLACE FUNCTION public.adjust_raw_stock(p_raw_material_id uuid, p_branch_id uuid, p_new_quantity numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cur numeric(14,4);
  v_delta numeric(14,4);
  v_user_branch uuid;
  v_res jsonb;
  v_cost numeric(12,2);
  v_value numeric(14,2);
  v_lines jsonb := '[]'::jsonb;
BEGIN
  BEGIN
    IF NOT public.can_permission('inventory.adjust') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Raw material adjustments require the warehouse manager or branch manager role.');
    END IF;

    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND p_branch_id <> v_user_branch THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    SELECT COALESCE(quantity, 0), COALESCE(avg_cost, 0)
    INTO v_cur, v_cost
    FROM public.raw_material_inventory
    WHERE raw_material_id = p_raw_material_id AND branch_id = p_branch_id;
    IF v_cur IS NULL THEN v_cur := 0; END IF;

    v_delta := p_new_quantity - v_cur;
    IF v_delta = 0 THEN
      RETURN jsonb_build_object('success', true, 'raw_material_id', p_raw_material_id, 'no_change', true);
    END IF;

    IF v_delta > 0 THEN
      v_res := public._raw_add(p_raw_material_id, p_branch_id, v_delta, v_cost,
        'ADJ', NULL, NULL, 'adjustment', 'adjustment', NULL, p_reason, auth.uid());
      v_value := round(v_delta * COALESCE(v_cost, 0), 2);
    ELSE
      v_res := public._raw_remove_fifo(p_raw_material_id, p_branch_id, -v_delta,
        'adjustment', 'adjustment', NULL, p_reason, auth.uid(), NULL::uuid); -- branch-wide adjustment: resolve default warehouse
      v_value := round(COALESCE((v_res->>'total_cost')::numeric, 0), 2);
    END IF;

    IF NOT (v_res->>'success')::boolean THEN
      RETURN v_res;
    END IF;

    -- ===== LEDGER POSTING =====
    IF v_value > 0 THEN
      IF v_delta > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_value, 'credit', 0, 'note', COALESCE(p_reason, 'جرد'));
        v_lines := v_lines || jsonb_build_object('account_key', 'stock_variance', 'debit', 0, 'credit', v_value, 'note', COALESCE(p_reason, 'جرد'));
      ELSE
        v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', 0, 'credit', v_value, 'note', COALESCE(p_reason, 'جرد'));
        v_lines := v_lines || jsonb_build_object('account_key', 'stock_variance', 'debit', v_value, 'credit', 0, 'note', COALESCE(p_reason, 'جرد'));
      END IF;
      PERFORM public._post_journal_entry(p_branch_id, 'adjustment', NULL, NULL,
        'تسوية خامات ' || COALESCE(p_reason, ''), v_lines);
    END IF;

    RETURN jsonb_build_object('success', true, 'raw_material_id', p_raw_material_id, 'quantity', p_new_quantity);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_production_order(p_order_id uuid, p_waste jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order record;
  v_recipe_id uuid;
  v_recipe_yield numeric(14,4);
  v_factor numeric(14,4);
  v_item record;
  v_waste_item jsonb;
  v_req numeric(14,4);
  v_res jsonb;
  v_short numeric(14,4);
  v_cost numeric(14,2) := 0;
  v_unit_cost numeric(12,2) := 0;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('production.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;

    SELECT * INTO v_order FROM public.production_orders WHERE id = p_order_id FOR UPDATE;
    IF v_order.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF v_order.status NOT IN ('planned', 'in_progress') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_order.status);
    END IF;
    IF v_order.warehouse_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED',
        'detail', 'Assign an output warehouse to the production order before completing it.');
    END IF;

    SELECT id, yield_quantity INTO v_recipe_id, v_recipe_yield
    FROM public.recipes
    WHERE product_id = v_order.product_id AND branch_id = v_order.branch_id AND is_active
    ORDER BY updated_at DESC LIMIT 1;
    IF v_recipe_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'NO_RECIPE', 'product_id', v_order.product_id);
    END IF;

    v_recipe_yield := COALESCE(v_recipe_yield, 1);
    v_factor := v_order.quantity / v_recipe_yield;

    -- Consume raw materials (FIFO by nearest expiry)
    FOR v_item IN SELECT * FROM public.recipe_items WHERE recipe_id = v_recipe_id
    LOOP
      v_req := COALESCE(v_item.quantity, 0) * v_factor;
      IF v_req <= 0 THEN CONTINUE; END IF;

      v_res := public._raw_remove_fifo(v_item.raw_material_id, v_order.branch_id, v_req,
        'production', 'production_order', v_order.id, v_order.order_number, auth.uid(),
    v_order.warehouse_id);
      v_short := (v_res->>'shortage')::numeric;
      IF v_short > 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_RAW',
          'raw_material_id', v_item.raw_material_id, 'required', v_req,
          'available', v_req - v_short,
          'detail', 'Not enough raw material to complete production. The order was not completed.');
      END IF;
      v_cost := v_cost + (v_res->>'total_cost')::numeric;
    END LOOP;

    -- Record waste (extra raw material consumed beyond the recipe)
    IF p_waste IS NOT NULL AND jsonb_array_length(p_waste) > 0 THEN
      FOR v_waste_item IN SELECT * FROM jsonb_array_elements(p_waste)
      LOOP
        v_req := COALESCE((v_waste_item->>'quantity')::numeric, 0);
        IF v_req <= 0 THEN CONTINUE; END IF;
        v_res := public._raw_remove_fifo((v_waste_item->>'raw_material_id')::uuid, v_order.branch_id, v_req,
          'waste', 'production_order', v_order.id, v_order.order_number, auth.uid(),
    v_order.warehouse_id);
        v_cost := v_cost + (v_res->>'total_cost')::numeric;
        INSERT INTO public.production_waste (order_id, branch_id, raw_material_id, quantity, reason)
        VALUES (v_order.id, v_order.branch_id, (v_waste_item->>'raw_material_id')::uuid, v_req,
                COALESCE(v_waste_item->>'reason', 'إنتاج'));
      END LOOP;
    END IF;

    -- Produce output as a new batch
    v_unit_cost := CASE WHEN v_order.quantity > 0 THEN round(v_cost / v_order.quantity, 2) ELSE 0 END;
    v_res := public._product_inv_add(v_order.product_id, v_order.warehouse_id, v_order.branch_id,
      v_order.quantity, v_unit_cost, v_order.batch_number, CURRENT_DATE, NULL,
      'production', 'production_order', v_order.id, v_order.order_number, auth.uid());
    IF NOT (v_res->>'success')::boolean THEN
      RETURN v_res;
    END IF;

    UPDATE public.production_orders
    SET status = 'completed', total_cost = v_cost, completed_at = now()
    WHERE id = v_order.id;

    -- ===== LEDGER POSTING: raw consumed into WIP, output to finished goods =====
    IF v_cost > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'wip', 'debit', v_cost, 'credit', 0, 'note', v_order.order_number);
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', 0, 'credit', v_cost, 'note', v_order.order_number);
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_cost, 'credit', 0, 'note', v_order.order_number);
      v_lines := v_lines || jsonb_build_object('account_key', 'wip', 'debit', 0, 'credit', v_cost, 'note', v_order.order_number);
      PERFORM public._post_journal_entry(v_order.branch_id, 'production', v_order.id, v_order.order_number,
        'إنتاج ' || v_order.order_number, v_lines);
    END IF;

    RETURN jsonb_build_object('success', true, 'order_id', v_order.id, 'order_number', v_order.order_number,
      'total_cost', v_cost, 'unit_cost', v_unit_cost);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_purchase_return(p_purchase_id uuid, p_items jsonb DEFAULT NULL::jsonb, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase record;
  v_user_branch uuid;
  v_return_total numeric(14,2) := 0;
  v_item record;
  v_req jsonb;
  v_item_id uuid;
  v_req_qty numeric(14,4);
  v_already numeric(14,4);
  v_ret_qty numeric(14,4);
  v_item_line_total numeric(14,2);
  v_item_ret_amt numeric(14,2);
  v_all_returned boolean := true;
  v_remaining numeric(14,4);
  v_res jsonb;
  v_purchase_entry uuid;
  v_fg numeric(14,2);
  v_rm numeric(14,2);
  v_vat numeric(14,2);
  v_discount numeric(14,2);
  v_paid_cash numeric(14,2);
  v_paid_bank numeric(14,2);
  v_ap numeric(14,2);
  v_ratio numeric(14,6);
  v_fg_r numeric(14,2);
  v_rm_r numeric(14,2);
  v_vat_r numeric(14,2);
  v_discount_r numeric(14,2);
  v_paid_r numeric(14,2);
  v_ap_r numeric(14,2);
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_credit_key text;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  BEGIN
    IF p_purchase_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_PURCHASE');
    END IF;

    SELECT id, branch_id, warehouse_id, status, total, paid_amount, supplier_id, invoice_number
      INTO v_purchase FROM public.purchases WHERE id = p_purchase_id;
    IF v_purchase.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
    END IF;

    IF v_purchase.status = 'returned' THEN
      RETURN jsonb_build_object('success', false, 'error', 'ALREADY_RETURNED');
    END IF;
    IF v_purchase.status <> 'completed' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS',
        'status', v_purchase.status, 'detail', 'Only completed purchases can be returned.');
    END IF;

    IF NOT public.can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Purchase returns require the purchases.manage permission.');
    END IF;

    SELECT branch_id INTO v_user_branch FROM users WHERE id = auth.uid();
    IF NOT is_pos_admin() AND v_user_branch IS NOT NULL
       AND v_purchase.branch_id IS NOT NULL AND v_user_branch <> v_purchase.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    -- ===== VALIDATION PHASE =====
    IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_req IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        v_item_id := (v_req->>'purchase_item_id')::uuid;
        v_req_qty := COALESCE((v_req->>'quantity')::numeric, 0);
        IF v_req_qty <= 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'purchase_item_id', v_item_id);
        END IF;
        SELECT id, quantity, returned_quantity INTO v_item
          FROM purchase_items WHERE id = v_item_id AND purchase_id = p_purchase_id;
        IF v_item.id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND', 'purchase_item_id', v_item_id);
        END IF;
        v_already := COALESCE(v_item.returned_quantity, 0);
        IF v_req_qty > v_item.quantity - v_already THEN
          RETURN jsonb_build_object('success', false, 'error', 'RETURN_EXCEEDS_QUANTITY',
            'purchase_item_id', v_item_id, 'max', v_item.quantity - v_already);
        END IF;
      END LOOP;
    END IF;

    -- ===== RETURN + RESTOCK-OUT PHASE =====
    FOR v_item IN SELECT id, product_id, raw_material_id, quantity, unit_cost, returned_quantity
                  FROM purchase_items WHERE purchase_id = p_purchase_id
    LOOP
      IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
        v_req_qty := 0;
        SELECT (req->>'quantity')::numeric INTO v_req_qty
        FROM jsonb_array_elements(p_items) req
        WHERE (req->>'purchase_item_id')::uuid = v_item.id;
        v_req_qty := COALESCE(v_req_qty, 0);
      ELSE
        v_req_qty := v_item.quantity - COALESCE(v_item.returned_quantity, 0);
      END IF;
      IF v_req_qty <= 0 THEN CONTINUE; END IF;

      v_item_line_total := v_item.quantity * v_item.unit_cost;
      IF v_item.quantity > 0 THEN
        v_item_ret_amt := ROUND(v_item_line_total * v_req_qty / v_item.quantity, 2);
      ELSE
        v_item_ret_amt := 0;
      END IF;
      v_return_total := v_return_total + v_item_ret_amt;

      UPDATE purchase_items
        SET returned_quantity = COALESCE(returned_quantity, 0) + v_req_qty,
            returned_amount = COALESCE(returned_amount, 0) + v_item_ret_amt
        WHERE id = v_item.id;

      -- Return the goods to the supplier (remove from the receiving warehouse)
      v_remaining := v_req_qty;
      IF v_item.product_id IS NOT NULL THEN
        v_res := public._product_inv_remove_fifo(v_item.product_id, v_purchase.warehouse_id,
          v_purchase.branch_id, v_remaining, 'purchase_return', 'purchase_return',
          p_purchase_id, v_purchase.invoice_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
      ELSIF v_item.raw_material_id IS NOT NULL THEN
        v_res := public._raw_remove_fifo(v_item.raw_material_id, v_purchase.branch_id,
          v_remaining, 'purchase_return', 'purchase_return', p_purchase_id,
          v_purchase.invoice_number, auth.uid(),
    v_purchase.warehouse_id);
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
      END IF;
    END LOOP;

    -- Update header: full return flips the status, otherwise accumulate returned_amount
    SELECT bool_and(quantity = returned_quantity) INTO v_all_returned
      FROM purchase_items WHERE purchase_id = p_purchase_id;
    UPDATE purchases SET
      returned_amount = COALESCE(returned_amount, 0) + v_return_total,
      status = CASE WHEN v_all_returned THEN 'returned' ELSE status END,
      notes = CASE WHEN p_reason IS NOT NULL THEN COALESCE(notes, '') || E'\n' || p_reason ELSE notes END
      WHERE id = p_purchase_id;

    -- ===== LEDGER POSTING: prorated reversal of the purchase entry =====
    IF v_return_total > 0 THEN
      SELECT id INTO v_purchase_entry
      FROM public.journal_entries
      WHERE branch_id = v_purchase.branch_id AND reference_type = 'purchase' AND reference_id = p_purchase_id;

      IF v_purchase_entry IS NOT NULL THEN
        SELECT
          round(COALESCE(SUM(CASE WHEN a.id = m.fg_id THEN l.debit - l.credit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.rm_id THEN l.debit - l.credit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.vat_id THEN l.debit - l.credit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.disc_id THEN l.credit - l.debit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.cash_id THEN l.credit - l.debit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.bank_id THEN l.credit - l.debit ELSE 0 END), 0), 2),
          round(COALESCE(SUM(CASE WHEN a.id = m.ap_id THEN l.credit - l.debit ELSE 0 END), 0), 2)
        INTO v_fg, v_rm, v_vat, v_discount, v_paid_cash, v_paid_bank, v_ap
        FROM public.journal_entry_lines l
        JOIN public.chart_of_accounts a ON a.id = l.account_id
        CROSS JOIN (
          SELECT
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'inventory_fg')) AS fg_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'inventory_rm')) AS rm_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'vat_receivable')) AS vat_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'discount_received')) AS disc_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'cash')) AS cash_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'bank')) AS bank_id,
            (SELECT public.resolve_account_key(v_purchase.branch_id, 'ap')) AS ap_id
        ) m
        WHERE l.journal_entry_id = v_purchase_entry;

        v_ratio := round(v_return_total / GREATEST(COALESCE(v_purchase.total, 0), 1), 6);
        v_fg_r := round(COALESCE(v_fg, 0) * v_ratio, 2);
        v_rm_r := round(COALESCE(v_rm, 0) * v_ratio, 2);
        v_vat_r := round(COALESCE(v_vat, 0) * v_ratio, 2);
        v_discount_r := round(COALESCE(v_discount, 0) * v_ratio, 2);
        v_paid_r := round((COALESCE(v_paid_cash, 0) + COALESCE(v_paid_bank, 0)) * v_ratio, 2);
        v_ap_r := round(COALESCE(v_ap, 0) * v_ratio, 2);

        v_credit_key := CASE WHEN COALESCE(v_paid_cash, 0) >= COALESCE(v_paid_bank, 0) THEN 'cash' ELSE 'bank' END;

        IF v_fg_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', 0, 'credit', v_fg_r);
          v_cr := v_cr + v_fg_r;
        END IF;
        IF v_rm_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', 0, 'credit', v_rm_r);
          v_cr := v_cr + v_rm_r;
        END IF;
        IF v_vat_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'vat_receivable', 'debit', 0, 'credit', v_vat_r);
          v_cr := v_cr + v_vat_r;
        END IF;
        IF v_discount_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', v_discount_r, 'credit', 0);
          v_dr := v_dr + v_discount_r;
        END IF;
        IF v_paid_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', v_credit_key, 'debit', v_paid_r, 'credit', 0,
            'note', 'مرتجع ' || v_purchase.invoice_number);
          v_dr := v_dr + v_paid_r;
        END IF;
        IF v_ap_r > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'ap', 'debit', v_ap_r, 'credit', 0,
            'supplier_id', v_purchase.supplier_id, 'note', 'مرتجع ' || v_purchase.invoice_number);
          v_dr := v_dr + v_ap_r;
        END IF;

        v_diff := round(v_dr - v_cr, 2);
        IF v_diff <> 0 THEN
          IF v_diff > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', 0, 'credit', v_diff);
          ELSE
            v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', -v_diff, 'credit', 0);
          END IF;
        END IF;

        PERFORM public._post_journal_entry(v_purchase.branch_id, 'purchase_return', NULL, v_purchase.invoice_number,
          'مرتجع فاتورة شراء ' || v_purchase.invoice_number, v_lines);
      END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id,
      'returned_amount', v_return_total, 'fully_returned', v_all_returned);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
