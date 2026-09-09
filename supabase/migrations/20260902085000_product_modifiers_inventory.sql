-- Product modifiers / variants with server-authoritative pricing and inventory effects.
-- Examples: Single/Double, extra cheese, no onion. KDS remains snapshot-only;
-- inventory is still deducted exactly once at sale completion.

CREATE TABLE IF NOT EXISTS public.product_modifier_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_en text,
  min_selections integer NOT NULL DEFAULT 0 CHECK (min_selections >= 0),
  max_selections integer NOT NULL DEFAULT 1 CHECK (max_selections > 0),
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_modifier_groups_selection_bounds CHECK (max_selections >= min_selections)
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_groups_product
  ON public.product_modifier_groups(product_id, is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_product_modifier_groups_branch
  ON public.product_modifier_groups(branch_id);

CREATE TABLE IF NOT EXISTS public.product_modifier_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  group_id uuid NOT NULL REFERENCES public.product_modifier_groups(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_en text,
  price_delta numeric(14,2) NOT NULL DEFAULT 0,
  is_default boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_options_group
  ON public.product_modifier_options(group_id, is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_product_modifier_options_branch
  ON public.product_modifier_options(branch_id);

CREATE TABLE IF NOT EXISTS public.product_modifier_inventory_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  option_id uuid NOT NULL REFERENCES public.product_modifier_options(id) ON DELETE CASCADE,
  target_type text NOT NULL CHECK (target_type IN ('raw_material', 'inventory_unit')),
  raw_material_id uuid REFERENCES public.raw_materials(id) ON DELETE CASCADE,
  inventory_unit_id uuid REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  quantity_delta numeric(14,6) NOT NULL CHECK (quantity_delta <> 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_modifier_effect_target CHECK (
    (target_type = 'raw_material' AND raw_material_id IS NOT NULL AND inventory_unit_id IS NULL)
    OR
    (target_type = 'inventory_unit' AND inventory_unit_id IS NOT NULL AND raw_material_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_option
  ON public.product_modifier_inventory_effects(option_id);
CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_raw
  ON public.product_modifier_inventory_effects(raw_material_id) WHERE raw_material_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_unit
  ON public.product_modifier_inventory_effects(inventory_unit_id) WHERE inventory_unit_id IS NOT NULL;

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS modifier_option_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  ADD COLUMN IF NOT EXISTS modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.sale_items
  ADD COLUMN IF NOT EXISTS modifier_option_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  ADD COLUMN IF NOT EXISTS modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.product_modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_inventory_effects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_modifier_groups_branch_select ON public.product_modifier_groups;
CREATE POLICY product_modifier_groups_branch_select ON public.product_modifier_groups
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS product_modifier_options_branch_select ON public.product_modifier_options;
CREATE POLICY product_modifier_options_branch_select ON public.product_modifier_options
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS product_modifier_effects_branch_select ON public.product_modifier_inventory_effects;
CREATE POLICY product_modifier_effects_branch_select ON public.product_modifier_inventory_effects
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

REVOKE ALL ON public.product_modifier_groups FROM anon;
REVOKE ALL ON public.product_modifier_options FROM anon;
REVOKE ALL ON public.product_modifier_inventory_effects FROM anon;
GRANT SELECT ON public.product_modifier_groups TO authenticated;
GRANT SELECT ON public.product_modifier_options TO authenticated;
GRANT SELECT ON public.product_modifier_inventory_effects TO authenticated;
GRANT ALL ON public.product_modifier_groups TO service_role;
GRANT ALL ON public.product_modifier_options TO service_role;
GRANT ALL ON public.product_modifier_inventory_effects TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_product_modifiers(
  p_product_id uuid,
  p_branch_id uuid,
  p_option_ids jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group record;
  v_selected_count integer;
  v_input_count integer;
  v_distinct_count integer;
  v_price_delta numeric(14,2) := 0;
  v_snapshot jsonb := '[]'::jsonb;
  v_invalid uuid;
BEGIN
  IF p_option_ids IS NULL OR jsonb_typeof(p_option_ids) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_SELECTION');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = p_product_id AND p.branch_id = p_branch_id AND p.is_active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH');
  END IF;
  SELECT COUNT(*), COUNT(DISTINCT x.option_id)
    INTO v_input_count, v_distinct_count
  FROM (
    SELECT NULLIF(value, '')::uuid AS option_id
    FROM jsonb_array_elements_text(p_option_ids)
  ) x;
  IF v_input_count <> v_distinct_count THEN
    RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_MODIFIER_OPTION');
  END IF;
  SELECT x.option_id INTO v_invalid
  FROM (
    SELECT NULLIF(value, '')::uuid AS option_id
    FROM jsonb_array_elements_text(p_option_ids)
  ) x
  LEFT JOIN public.product_modifier_options o ON o.id = x.option_id AND o.is_active = true
  LEFT JOIN public.product_modifier_groups g ON g.id = o.group_id AND g.is_active = true
  WHERE o.id IS NULL OR g.id IS NULL OR g.product_id <> p_product_id
    OR g.branch_id <> p_branch_id OR o.branch_id <> p_branch_id
  LIMIT 1;
  IF v_invalid IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTION', 'option_id', v_invalid);
  END IF;
  FOR v_group IN
    SELECT g.id, g.name, g.name_en, g.min_selections, g.max_selections
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id
      AND g.branch_id = p_branch_id
      AND g.is_active = true
    ORDER BY g.sort_order, g.created_at
  LOOP
    SELECT COUNT(*) INTO v_selected_count
    FROM public.product_modifier_options o
    WHERE o.group_id = v_group.id
      AND o.is_active = true
      AND o.id IN (
        SELECT NULLIF(value, '')::uuid FROM jsonb_array_elements_text(p_option_ids)
      );
    IF v_selected_count < v_group.min_selections THEN
      RETURN jsonb_build_object(
        'success', false, 'error', 'MODIFIER_SELECTION_REQUIRED',
        'group_id', v_group.id, 'group_name', v_group.name,
        'min_selections', v_group.min_selections
      );
    END IF;
    IF v_selected_count > v_group.max_selections THEN
      RETURN jsonb_build_object(
        'success', false, 'error', 'TOO_MANY_MODIFIER_OPTIONS',
        'group_id', v_group.id, 'group_name', v_group.name,
        'max_selections', v_group.max_selections
      );
    END IF;
  END LOOP;
  SELECT COALESCE(SUM(o.price_delta), 0),
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'group_id', g.id,
             'group_name', g.name,
             'group_name_en', g.name_en,
             'option_id', o.id,
             'option_name', o.name,
             'option_name_en', o.name_en,
             'price_delta', o.price_delta
           ) ORDER BY g.sort_order, o.sort_order, o.created_at
         ), '[]'::jsonb)
    INTO v_price_delta, v_snapshot
  FROM public.product_modifier_options o
  JOIN public.product_modifier_groups g ON g.id = o.group_id
  WHERE o.id IN (
    SELECT NULLIF(value, '')::uuid FROM jsonb_array_elements_text(p_option_ids)
  );
  RETURN jsonb_build_object(
    'success', true,
    'price_delta', COALESCE(v_price_delta, 0),
    'snapshot', COALESCE(v_snapshot, '[]'::jsonb)
  );
EXCEPTION WHEN invalid_text_representation THEN
  RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTION_ID');
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_product_modifiers(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_groups jsonb;
BEGIN
  SELECT p.branch_id INTO v_branch_id FROM public.products p WHERE p.id = p_product_id AND p.is_active = true;
  IF v_branch_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_branch_id) THEN RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH'); END IF;
  SELECT COALESCE(jsonb_agg(group_row ORDER BY (group_row->>'sort_order')::integer), '[]'::jsonb)
    INTO v_groups
  FROM (
    SELECT jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'name_en', g.name_en,
      'min_selections', g.min_selections,
      'max_selections', g.max_selections,
      'sort_order', g.sort_order,
      'options', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', o.id,
          'name', o.name,
          'name_en', o.name_en,
          'price_delta', o.price_delta,
          'is_default', o.is_default,
          'sort_order', o.sort_order
        ) ORDER BY o.sort_order, o.created_at)
        FROM public.product_modifier_options o
        WHERE o.group_id = g.id AND o.is_active = true
      ), '[]'::jsonb)
    ) AS group_row
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id AND g.is_active = true
  ) q;
  RETURN jsonb_build_object('success', true, 'groups', COALESCE(v_groups, '[]'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_modifiers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_modifiers(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.save_product_modifiers(p_product_id uuid, p_groups jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_role text;
  v_group jsonb;
  v_option jsonb;
  v_effect jsonb;
  v_group_id uuid;
  v_option_id uuid;
  v_target_id uuid;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG');
  END IF;
  SELECT p.branch_id INTO v_branch_id FROM public.products p WHERE p.id = p_product_id;
  IF v_branch_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND'); END IF;
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager') OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;
  DELETE FROM public.product_modifier_groups WHERE product_id = p_product_id AND branch_id = v_branch_id;
  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    IF COALESCE(NULLIF(btrim(v_group->>'name'), ''), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_GROUP_NAME_REQUIRED');
    END IF;
    IF COALESCE((v_group->>'min_selections')::integer, 0) < 0
       OR COALESCE((v_group->>'max_selections')::integer, 1) < GREATEST(COALESCE((v_group->>'min_selections')::integer, 0), 1) THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;
    INSERT INTO public.product_modifier_groups(
      branch_id, product_id, name, name_en, min_selections, max_selections, sort_order, is_active
    ) VALUES (
      v_branch_id, p_product_id, btrim(v_group->>'name'), NULLIF(btrim(v_group->>'name_en'), ''),
      COALESCE((v_group->>'min_selections')::integer, 0),
      COALESCE((v_group->>'max_selections')::integer, 1),
      COALESCE((v_group->>'sort_order')::integer, 0), true
    ) RETURNING id INTO v_group_id;
    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      IF COALESCE(NULLIF(btrim(v_option->>'name'), ''), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_OPTION_NAME_REQUIRED');
      END IF;
      INSERT INTO public.product_modifier_options(
        branch_id, group_id, name, name_en, price_delta, is_default, sort_order, is_active
      ) VALUES (
        v_branch_id, v_group_id, btrim(v_option->>'name'), NULLIF(btrim(v_option->>'name_en'), ''),
        COALESCE((v_option->>'price_delta')::numeric, 0),
        COALESCE((v_option->>'is_default')::boolean, false),
        COALESCE((v_option->>'sort_order')::integer, 0), true
      ) RETURNING id INTO v_option_id;
      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        IF v_target_id IS NULL OR COALESCE((v_effect->>'quantity_delta')::numeric, 0) = 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;
        IF v_effect->>'target_type' = 'raw_material' THEN
          IF NOT EXISTS (SELECT 1 FROM public.raw_materials WHERE id = v_target_id AND branch_id = v_branch_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
          INSERT INTO public.product_modifier_inventory_effects(branch_id, option_id, target_type, raw_material_id, quantity_delta)
          VALUES (v_branch_id, v_option_id, 'raw_material', v_target_id, (v_effect->>'quantity_delta')::numeric);
        ELSIF v_effect->>'target_type' = 'inventory_unit' THEN
          IF NOT EXISTS (SELECT 1 FROM public.inventory_units WHERE id = v_target_id AND branch_id = v_branch_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVENTORY_UNIT_NOT_IN_BRANCH');
          END IF;
          INSERT INTO public.product_modifier_inventory_effects(branch_id, option_id, target_type, inventory_unit_id, quantity_delta)
          VALUES (v_branch_id, v_option_id, 'inventory_unit', v_target_id, (v_effect->>'quantity_delta')::numeric);
        ELSE
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_TARGET_TYPE');
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'SAVE_MODIFIERS_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_modifiers(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_modifiers(uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item jsonb; v_product_id uuid; v_quantity numeric(14,4); v_link record; v_effect record; v_batch record;
  v_need numeric(14,6); v_take numeric(14,6); v_available numeric(14,6);
  v_total_cost numeric(18,4):=0; v_units jsonb:='[]'::jsonb; v_raws jsonb:='[]'::jsonb; v_ready jsonb:='[]'::jsonb;
  v_user_branch uuid; v_recipe_id uuid; v_yield numeric(14,6); v_res jsonb; v_mod jsonb;
  v_recipe_component_count integer; v_link_count integer;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN
    RETURN jsonb_build_object('success',true,'units_deducted','[]'::jsonb,'raw_materials_deducted','[]'::jsonb,'ready_products_deducted','[]'::jsonb,'errors','[]'::jsonb);
  END IF;
  SELECT branch_id INTO v_user_branch FROM public.users WHERE id=auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch<>p_branch_id THEN
    RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH');
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(unit_id uuid PRIMARY KEY,unit_name text,unit_type text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(raw_material_id uuid PRIMARY KEY,raw_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(product_id uuid PRIMARY KEY,product_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need; TRUNCATE pg_temp.sale_raw_need; TRUNCATE pg_temp.sale_ready_need;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id:=(v_item->>'product_id')::uuid;
    v_quantity:=COALESCE((v_item->>'quantity')::numeric,0);
    IF v_quantity<=0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY','product_id',v_product_id); END IF;
    IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product_id AND p.branch_id=p_branch_id AND p.is_active=true) THEN
      RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id);
    END IF;
    v_mod := public.resolve_product_modifiers(v_product_id, p_branch_id, COALESCE(v_item->'modifier_option_ids','[]'::jsonb));
    IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;
    SELECT COUNT(*) INTO v_link_count
    FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
    WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true;
    FOR v_link IN
      SELECT pul.unit_id,pul.quantity,iu.name AS unit_name,iu.unit_type
      FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
      WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true
    LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty)
      VALUES(v_link.unit_id,v_link.unit_name,v_link.unit_type,v_quantity*v_link.quantity)
      ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
    END LOOP;
    SELECT r.id,COALESCE(NULLIF(r.yield_quantity,0),1) INTO v_recipe_id,v_yield
    FROM public.recipes r
    WHERE r.product_id=v_product_id AND r.branch_id=p_branch_id AND COALESCE(r.is_active,true)=true
    ORDER BY COALESCE(r.version,1) DESC,r.created_at DESC LIMIT 1;
    v_recipe_component_count:=0;
    IF v_recipe_id IS NOT NULL THEN
      FOR v_link IN
        SELECT ri.raw_material_id,rm.name AS raw_name,ri.quantity/v_yield AS quantity_per_sale
        FROM public.recipe_items ri JOIN public.raw_materials rm ON rm.id=ri.raw_material_id
        WHERE ri.recipe_id=v_recipe_id
          AND NOT EXISTS(
            SELECT 1 FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
            WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true
              AND regexp_replace(lower(btrim(iu.name)),'[ .]+$','','g')=regexp_replace(lower(btrim(rm.name)),'[ .]+$','','g')
          )
      LOOP
        v_recipe_component_count:=v_recipe_component_count+1;
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty)
        VALUES(v_link.raw_material_id,v_link.raw_name,v_quantity*v_link.quantity_per_sale)
        ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      END LOOP;
    END IF;
    IF v_link_count=0 AND v_recipe_component_count=0 THEN
      INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty)
      SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id
      ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty;
    END IF;
    FOR v_effect IN
      SELECT e.target_type,e.raw_material_id,e.inventory_unit_id,e.quantity_delta,
             rm.name AS raw_name,iu.name AS unit_name,iu.unit_type
      FROM public.product_modifier_inventory_effects e
      JOIN public.product_modifier_options o ON o.id=e.option_id AND o.is_active=true
      JOIN public.product_modifier_groups g ON g.id=o.group_id AND g.is_active=true
      LEFT JOIN public.raw_materials rm ON rm.id=e.raw_material_id
      LEFT JOIN public.inventory_units iu ON iu.id=e.inventory_unit_id
      WHERE g.product_id=v_product_id AND g.branch_id=p_branch_id
        AND o.id IN (SELECT NULLIF(value,'')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids','[]'::jsonb)))
    LOOP
      IF v_effect.target_type='raw_material' THEN
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty)
        VALUES(v_effect.raw_material_id,v_effect.raw_name,v_quantity*v_effect.quantity_delta)
        ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      ELSE
        INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty)
        VALUES(v_effect.inventory_unit_id,v_effect.unit_name,v_effect.unit_type,v_quantity*v_effect.quantity_delta)
        ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
      END IF;
    END LOOP;
    v_recipe_id:=NULL; v_yield:=NULL;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_temp.sale_unit_need WHERE required_qty < 0)
     OR EXISTS (SELECT 1 FROM pg_temp.sale_raw_need WHERE required_qty < 0) THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_MODIFIER_INVENTORY_EFFECT','detail','Modifier removal exceeds the base component quantity.');
  END IF;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 AND unit_type='manufactured' ORDER BY unit_id LOOP
    PERFORM public._ensure_inventory_unit_stock(v_link.unit_id, v_link.required_qty, p_warehouse_id, p_branch_id, 0);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 ORDER BY unit_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_unit_batches
    WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',v_link.unit_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty>0 ORDER BY raw_material_id LOOP
    SELECT COALESCE(quantity,0) INTO v_available FROM public.raw_material_inventory
    WHERE raw_material_id=v_link.raw_material_id AND branch_id=p_branch_id;
    v_available:=COALESCE(v_available,0);
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',v_link.raw_material_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty>0 ORDER BY product_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_batches
    WHERE product_id=v_link.product_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',v_link.product_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 ORDER BY unit_id LOOP
    v_need:=v_link.required_qty;
    FOR v_batch IN SELECT id,quantity,unit_cost,batch_number FROM public.inventory_unit_batches
      WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id AND quantity>0
      ORDER BY created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_need<=0; v_take:=LEAST(v_need,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,reference_type,reference_id,reference_number,batch_number,created_by)
      VALUES(v_link.unit_id,p_branch_id,p_warehouse_id,-v_take,v_batch.unit_cost,'sale','sale',p_reference_id,p_reference_number,v_batch.batch_number,auth.uid());
      v_need:=v_need-v_take; v_total_cost:=v_total_cost+(v_take*COALESCE(v_batch.unit_cost,0));
    END LOOP;
    v_units:=v_units||jsonb_build_object('unit_id',v_link.unit_id,'unit_name',v_link.unit_name,'unit_type',v_link.unit_type,'quantity',v_link.required_qty);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty>0 ORDER BY raw_material_id LOOP
    v_res:=public._raw_remove_fifo(v_link.raw_material_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',v_link.raw_material_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_raws:=v_raws||jsonb_build_object('raw_material_id',v_link.raw_material_id,'raw_name',v_link.raw_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty>0 ORDER BY product_id LOOP
    v_res:=public._product_inv_remove_fifo(v_link.product_id,p_warehouse_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',v_link.product_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_ready:=v_ready||jsonb_build_object('product_id',v_link.product_id,'product_name',v_link.product_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  RETURN jsonb_build_object('success',true,'units_deducted',v_units,'raw_materials_deducted',v_raws,'ready_products_deducted',v_ready,'total_cost',v_total_cost,'errors','[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','SALE_INVENTORY_DEDUCTION_FAILED','detail',SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) TO service_role, postgres;

CREATE OR REPLACE FUNCTION public._price_order_item_modifiers()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_base_price numeric(14,2);
  v_mod jsonb;
BEGIN
  SELECT o.branch_id INTO v_branch_id FROM public.orders o WHERE o.id=NEW.order_id;
  SELECT p.sale_price INTO v_base_price FROM public.products p
  WHERE p.id=NEW.product_id AND p.branch_id=v_branch_id AND p.is_active=true;
  IF v_base_price IS NULL THEN RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH'; END IF;
  v_mod:=public.resolve_product_modifiers(NEW.product_id,v_branch_id,to_jsonb(COALESCE(NEW.modifier_option_ids,'{}'::uuid[])));
  IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'MODIFIER_VALIDATION_FAILED: %',COALESCE(v_mod->>'error','unknown');
  END IF;
  NEW.modifiers_snapshot:=COALESCE(v_mod->'snapshot','[]'::jsonb);
  NEW.unit_price:=GREATEST(COALESCE(v_base_price,0)+COALESCE((v_mod->>'price_delta')::numeric,0),0);
  NEW.discount_amount:=LEAST(GREATEST(COALESCE(NEW.discount_amount,0),0),NEW.quantity*NEW.unit_price);
  NEW.total:=ROUND(NEW.quantity*NEW.unit_price-NEW.discount_amount,2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_item_modifier_price ON public.order_items;
CREATE TRIGGER trg_order_item_modifier_price
BEFORE INSERT OR UPDATE OF product_id, quantity, modifier_option_ids, discount_amount
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._price_order_item_modifiers();

DO $patch_orders$
DECLARE v_oid oid; v_def text;
BEGIN
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='create_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,uuid)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifier_option_ids' in v_def)=0 THEN
    v_def:=replace(v_def,
      'discount_amount, bonus_quantity, total, notes)',
      'discount_amount, bonus_quantity, total, modifier_option_ids, notes)');
    v_def:=replace(v_def,
      E'COALESCE((v_item->>''total'')::numeric, 0),\n        NULLIF(v_item->>''notes'', ''''))',
      E'COALESCE((v_item->>''total'')::numeric, 0),\n        ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb))),\n        NULLIF(v_item->>''notes'', ''''))');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='update_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,text)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifier_option_ids' in v_def)=0 THEN
    v_def:=replace(v_def,
      'AND oi.unit_price = COALESCE((v_item->>''unit_price'')::numeric, oi.unit_price)',
      'AND oi.modifier_option_ids = ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb)))');
    v_def:=replace(v_def,
      'discount_amount, bonus_quantity, total, notes)',
      'discount_amount, bonus_quantity, total, modifier_option_ids, notes)');
    v_def:=replace(v_def,
      E'COALESCE((v_item->>''total'')::numeric, 0),\n          NULLIF(v_item->>''notes'', ''''))',
      E'COALESCE((v_item->>''total'')::numeric, 0),\n          ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb))),\n          NULLIF(v_item->>''notes'', ''''))');
    EXECUTE v_def;
  END IF;
END
$patch_orders$;

DO $patch_sale$
DECLARE v_oid oid; v_def text;
BEGIN
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='process_sale'
    AND p.oid::regprocedure::text LIKE 'process_sale(text,uuid,%';
  v_def:=pg_get_functiondef(v_oid);
  IF position('resolve_product_modifiers' in v_def)=0 THEN
    v_def:=replace(v_def,'  v_price numeric;',E'  v_price numeric;\n  v_mod jsonb;');
    v_def:=replace(v_def,
      E'    v_price := COALESCE(v_price,0);\n    v_line_discount :=',
      E'    v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n    IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n    v_price := GREATEST(COALESCE(v_price,0)+COALESCE((v_mod->>''price_delta'')::numeric,0),0);\n    v_line_discount :=');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='_process_sale_core';
  v_def:=pg_get_functiondef(v_oid);
  IF position('deduct_sale_inventory_with_modifiers' in v_def)=0 THEN
    v_def:=replace(v_def,'  v_res jsonb;',E'  v_res jsonb;\n  v_mod jsonb;');
    v_def:=replace(v_def,
      E'      SELECT COALESCE(sale_price, 0) INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_discount_amount :=',
      E'      SELECT COALESCE(sale_price, 0) INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n      IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n      v_unit_price := GREATEST(v_unit_price+COALESCE((v_mod->>''price_delta'')::numeric,0),0);\n      v_discount_amount :=');
    v_def:=replace(v_def,
      E'      SELECT sale_price INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_unit_price := COALESCE(v_unit_price, 0);',
      E'      SELECT sale_price INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n      IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n      v_unit_price := GREATEST(COALESCE(v_unit_price,0)+COALESCE((v_mod->>''price_delta'')::numeric,0),0);');
    v_def:=replace(v_def,
      'INSERT INTO sale_items (sale_id, product_id, unit_name, quantity, unit_price, discount_amount, bonus_quantity, total)',
      'INSERT INTO sale_items (sale_id, product_id, unit_name, quantity, unit_price, discount_amount, bonus_quantity, total, modifier_option_ids, modifiers_snapshot)');
    v_def:=replace(v_def,
      'v_quantity, v_unit_price, v_discount_amount, v_bonus_quantity, v_item_total);',
      E'v_quantity, v_unit_price, v_discount_amount, v_bonus_quantity, v_item_total,\n        ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb))),\n        COALESCE(v_mod->''snapshot'',''[]''::jsonb));');
    v_def:=replace(v_def,'public.deduct_sale_unit_inventory(','public.deduct_sale_inventory_with_modifiers(');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='send_to_kitchen(uuid,uuid)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifiers_snapshot' in v_def)=0 THEN
    v_def:=replace(v_def,
      '''notes'', oi.notes',
      E'''notes'', oi.notes,\n        ''modifiers'', oi.modifiers_snapshot');
    EXECUTE v_def;
  END IF;
END
$patch_sale$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) TO service_role, postgres;