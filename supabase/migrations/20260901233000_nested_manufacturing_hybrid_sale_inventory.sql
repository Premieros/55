-- Nested manufactured components + recipe-aware sale inventory.
--
-- Canonical inventory flow after this migration:
-- 1) Direct raw recipe items are purchased into raw_material_inventory and
--    consumed from raw-material FIFO at sale.
-- 2) Semi-finished/manufactured recipe items are inventory_units and are
--    consumed from inventory_unit_batches at sale or by another manufactured unit.
-- 3) Products with no recipe and no manufactured component links are treated
--    as ready/purchased products and use the existing product inventory FIFO.
-- This avoids duplicating raw materials into inventory_units only to satisfy a
-- technical link requirement.

CREATE TABLE IF NOT EXISTS public.inventory_unit_recipe_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  component_unit_id uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE RESTRICT,
  quantity numeric(14,6) NOT NULL CHECK (quantity > 0),
  wastage_percent numeric(8,4) NOT NULL DEFAULT 0 CHECK (wastage_percent >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_unit_recipe_units_no_self CHECK (unit_id <> component_unit_id),
  CONSTRAINT inventory_unit_recipe_units_unique UNIQUE (unit_id, component_unit_id)
);

ALTER TABLE public.inventory_unit_recipe_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS iuru_admin_all ON public.inventory_unit_recipe_units;
CREATE POLICY iuru_admin_all ON public.inventory_unit_recipe_units
FOR ALL USING (public.is_pos_admin()) WITH CHECK (public.is_pos_admin());

DROP POLICY IF EXISTS iuru_branch_read ON public.inventory_unit_recipe_units;
CREATE POLICY iuru_branch_read ON public.inventory_unit_recipe_units
FOR SELECT USING (
  unit_id IN (
    SELECT iu.id FROM public.inventory_units iu
    WHERE iu.branch_id = public.get_branch_id() OR iu.branch_id IS NULL
  )
);

REVOKE ALL ON public.inventory_unit_recipe_units FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_unit_recipe_units TO authenticated;
GRANT ALL ON public.inventory_unit_recipe_units TO service_role;

-- Convert imported "raw material" placeholders that are in fact another
-- manufactured product into explicit manufactured-unit recipe links.
-- quantity is stored as a fraction of one produced child batch.
WITH manufactured AS (
  SELECT p.id AS product_id, p.branch_id, p.name AS product_name,
         iu.id AS unit_id, iu.name AS unit_name
  FROM public.products p
  JOIN public.inventory_units iu
    ON iu.branch_id = p.branch_id
   AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
       regexp_replace(lower(btrim(p.name)), '[ .]+$', '', 'g')
   AND iu.unit_type = 'manufactured'
  WHERE p.product_type = 'manufactured'
), matches AS (
  SELECT parent.unit_id AS parent_unit_id,
         child.unit_id AS component_unit_id,
         iur.id AS raw_recipe_row_id,
         iur.quantity,
         COALESCE((
           SELECT SUM(x.quantity)
           FROM public.inventory_unit_recipes x
           WHERE x.unit_id = child.unit_id
         ), 0) AS child_batch_basis
  FROM manufactured parent
  JOIN public.inventory_unit_recipes iur ON iur.unit_id = parent.unit_id
  JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
  JOIN manufactured child
    ON child.branch_id = parent.branch_id
   AND regexp_replace(lower(btrim(child.product_name)), '[ .]+$', '', 'g') =
       regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
   AND child.unit_id <> parent.unit_id
), inserted AS (
  INSERT INTO public.inventory_unit_recipe_units(unit_id, component_unit_id, quantity)
  SELECT parent_unit_id, component_unit_id,
         quantity / NULLIF(child_batch_basis, 0)
  FROM matches
  WHERE child_batch_basis > 0
  ON CONFLICT (unit_id, component_unit_id) DO UPDATE
    SET quantity = EXCLUDED.quantity, updated_at = now()
  RETURNING unit_id, component_unit_id
)
DELETE FROM public.inventory_unit_recipes iur
USING matches m
WHERE iur.id = m.raw_recipe_row_id
  AND m.child_batch_basis > 0;

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
      auth.uid()
    );

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
$$;

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
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
  v_recipe_component_count integer;
  v_link_count integer;
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

  SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
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
      WHERE p.id = v_product_id AND p.branch_id = p_branch_id AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    -- Explicit manufactured/semi-finished unit components attached to product.
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
      VALUES (v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
      ON CONFLICT (unit_id) DO UPDATE
      SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
    END LOOP;

    -- Latest active recipe supplies direct raw-material consumption. Any raw
    -- placeholder matching an explicit linked manufactured unit is excluded to
    -- prevent double deduction.
    SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
      INTO v_recipe_id, v_yield
    FROM public.recipes r
    WHERE r.product_id = v_product_id
      AND r.branch_id = p_branch_id
      AND COALESCE(r.is_active, true) = true
    ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
    LIMIT 1;

    v_recipe_component_count := 0;
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
        VALUES (v_link.raw_material_id, v_link.raw_name, v_quantity * v_link.quantity_per_sale)
        ON CONFLICT (raw_material_id) DO UPDATE
        SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
      END LOOP;
    END IF;

    -- A genuinely ready/purchased product has no recipe consumption and no
    -- manufactured unit component links. Keep it on the established product
    -- inventory FIFO instead of fabricating a duplicate inventory_unit.
    IF v_link_count = 0 AND v_recipe_component_count = 0 THEN
      INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
      SELECT p.id, p.name, v_quantity FROM public.products p WHERE p.id = v_product_id
      ON CONFLICT (product_id) DO UPDATE
      SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
    END IF;

    v_recipe_id := NULL;
    v_yield := NULL;
  END LOOP;

  -- Preflight every stock source before any mutation.
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_UNIT_STOCK',
        'unit_id', v_link.unit_id, 'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_link.raw_material_id AND branch_id = p_branch_id;
    v_available := COALESCE(v_available, 0);
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
        'raw_material_id', v_link.raw_material_id,
        'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_batches
    WHERE product_id = v_link.product_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_PRODUCT_STOCK',
        'product_id', v_link.product_id,
        'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  -- Manufactured/semi-finished units.
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
      FOR UPDATE
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity = quantity - v_take WHERE id = v_batch.id;
      INSERT INTO public.inventory_unit_entries(
        unit_id, branch_id, warehouse_id, quantity, unit_cost,
        entry_type, reference_type, reference_id, reference_number,
        batch_number, created_by
      ) VALUES (
        v_link.unit_id, p_branch_id, p_warehouse_id, -v_take, v_batch.unit_cost,
        'sale', 'sale', p_reference_id, p_reference_number,
        v_batch.batch_number, auth.uid()
      );
      v_need := v_need - v_take;
      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
    END LOOP;
    v_units := v_units || jsonb_build_object(
      'unit_id', v_link.unit_id, 'unit_name', v_link.unit_name,
      'unit_type', v_link.unit_type, 'quantity', v_link.required_qty
    );
  END LOOP;

  -- Direct raw ingredients.
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id
  LOOP
    v_res := public._raw_remove_fifo(
      v_link.raw_material_id, p_branch_id, v_link.required_qty,
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

  -- Ready/purchased finished products.
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id
  LOOP
    v_res := public._product_inv_remove_fifo(
      v_link.product_id, p_warehouse_id, p_branch_id, v_link.required_qty,
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
  RETURN jsonb_build_object('success', false, 'error', 'SALE_INVENTORY_DEDUCTION_FAILED', 'detail', SQLERRM);
END;
$$;
