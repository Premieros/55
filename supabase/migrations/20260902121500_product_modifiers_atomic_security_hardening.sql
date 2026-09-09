-- Harden modifier administration before production rollout.
-- 1) Validate the complete configuration before deleting/replacing anything.
-- 2) Keep modifier inventory effects server-internal; POS clients only need the
--    public modifier catalog returned by get_product_modifiers().

REVOKE SELECT ON public.product_modifier_inventory_effects FROM authenticated;

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
  v_min integer;
  v_max integer;
  v_option_count integer;
  v_default_count integer;
  v_delta numeric;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG');
  END IF;

  SELECT p.branch_id
    INTO v_branch_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- Validation pass. No persistent mutation is allowed before this pass ends.
  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    IF jsonb_typeof(v_group) <> 'object'
       OR COALESCE(NULLIF(btrim(v_group->>'name'), ''), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_GROUP_NAME_REQUIRED');
    END IF;

    v_min := COALESCE((v_group->>'min_selections')::integer, 0);
    v_max := COALESCE((v_group->>'max_selections')::integer, 1);

    IF v_min < 0 OR v_max < 1 OR v_max < v_min THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;

    IF v_group ? 'options' AND jsonb_typeof(v_group->'options') <> 'array' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTIONS');
    END IF;

    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE COALESCE((opt->>'is_default')::boolean, false))
      INTO v_option_count, v_default_count
    FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb)) AS options(opt);

    IF v_min > v_option_count OR v_max > GREATEST(v_option_count, 1) THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;

    IF v_default_count > v_max THEN
      RETURN jsonb_build_object('success', false, 'error', 'TOO_MANY_DEFAULT_MODIFIER_OPTIONS');
    END IF;

    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_option) <> 'object'
         OR COALESCE(NULLIF(btrim(v_option->>'name'), ''), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_OPTION_NAME_REQUIRED');
      END IF;

      -- Force numeric/boolean validation before any DELETE/INSERT below.
      PERFORM COALESCE((v_option->>'price_delta')::numeric, 0);
      PERFORM COALESCE((v_option->>'is_default')::boolean, false);
      PERFORM COALESCE((v_option->>'sort_order')::integer, 0);

      IF v_option ? 'inventory_effects'
         AND jsonb_typeof(v_option->'inventory_effects') <> 'array' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
      END IF;

      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        IF jsonb_typeof(v_effect) <> 'object' THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;

        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        v_delta := COALESCE((v_effect->>'quantity_delta')::numeric, 0);

        IF v_target_id IS NULL OR v_delta = 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;

        IF v_effect->>'target_type' = 'raw_material' THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.raw_materials
            WHERE id = v_target_id AND branch_id = v_branch_id
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
        ELSIF v_effect->>'target_type' = 'inventory_unit' THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.inventory_units
            WHERE id = v_target_id AND branch_id = v_branch_id
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVENTORY_UNIT_NOT_IN_BRANCH');
          END IF;
        ELSE
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_TARGET_TYPE');
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- Mutation pass starts only after the entire payload is known-valid.
  DELETE FROM public.product_modifier_groups
  WHERE product_id = p_product_id AND branch_id = v_branch_id;

  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    INSERT INTO public.product_modifier_groups(
      branch_id, product_id, name, name_en,
      min_selections, max_selections, sort_order, is_active
    ) VALUES (
      v_branch_id,
      p_product_id,
      btrim(v_group->>'name'),
      NULLIF(btrim(v_group->>'name_en'), ''),
      COALESCE((v_group->>'min_selections')::integer, 0),
      COALESCE((v_group->>'max_selections')::integer, 1),
      COALESCE((v_group->>'sort_order')::integer, 0),
      true
    ) RETURNING id INTO v_group_id;

    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      INSERT INTO public.product_modifier_options(
        branch_id, group_id, name, name_en,
        price_delta, is_default, sort_order, is_active
      ) VALUES (
        v_branch_id,
        v_group_id,
        btrim(v_option->>'name'),
        NULLIF(btrim(v_option->>'name_en'), ''),
        COALESCE((v_option->>'price_delta')::numeric, 0),
        COALESCE((v_option->>'is_default')::boolean, false),
        COALESCE((v_option->>'sort_order')::integer, 0),
        true
      ) RETURNING id INTO v_option_id;

      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        v_delta := (v_effect->>'quantity_delta')::numeric;

        IF v_effect->>'target_type' = 'raw_material' THEN
          INSERT INTO public.product_modifier_inventory_effects(
            branch_id, option_id, target_type, raw_material_id, quantity_delta
          ) VALUES (
            v_branch_id, v_option_id, 'raw_material', v_target_id, v_delta
          );
        ELSE
          INSERT INTO public.product_modifier_inventory_effects(
            branch_id, option_id, target_type, inventory_unit_id, quantity_delta
          ) VALUES (
            v_branch_id, v_option_id, 'inventory_unit', v_target_id, v_delta
          );
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG_VALUE');
  WHEN OTHERS THEN
    -- Because this block has an EXCEPTION handler, PostgreSQL rolls back all
    -- persistent statements executed inside the block before entering here.
    RETURN jsonb_build_object('success', false, 'error', 'SAVE_MODIFIERS_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_modifiers(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_modifiers(uuid, jsonb) TO authenticated, service_role;
