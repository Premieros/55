-- Enforce branch consistency for modifier definitions at the database layer.
-- RPC validation remains the normal write path, but these triggers prevent
-- cross-branch configuration even if a future privileged writer bypasses it.

CREATE OR REPLACE FUNCTION public._enforce_modifier_group_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product_branch uuid;
BEGIN
  SELECT branch_id INTO v_product_branch
  FROM public.products
  WHERE id = NEW.product_id;

  IF v_product_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_PRODUCT_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_product_branch THEN
    RAISE EXCEPTION 'MODIFIER_GROUP_BRANCH_MISMATCH';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._enforce_modifier_option_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group_branch uuid;
BEGIN
  SELECT branch_id INTO v_group_branch
  FROM public.product_modifier_groups
  WHERE id = NEW.group_id;

  IF v_group_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_GROUP_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_group_branch THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_BRANCH_MISMATCH';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._enforce_modifier_effect_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_option_branch uuid;
  v_target_branch uuid;
BEGIN
  SELECT branch_id INTO v_option_branch
  FROM public.product_modifier_options
  WHERE id = NEW.option_id;

  IF v_option_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_option_branch THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_BRANCH_MISMATCH';
  END IF;

  IF NEW.target_type = 'raw_material' THEN
    SELECT branch_id INTO v_target_branch
    FROM public.raw_materials
    WHERE id = NEW.raw_material_id;
  ELSIF NEW.target_type = 'inventory_unit' THEN
    SELECT branch_id INTO v_target_branch
    FROM public.inventory_units
    WHERE id = NEW.inventory_unit_id;
  ELSE
    RAISE EXCEPTION 'INVALID_MODIFIER_TARGET_TYPE';
  END IF;

  IF v_target_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_TARGET_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_target_branch THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_TARGET_BRANCH_MISMATCH';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_modifier_group_branch_consistency ON public.product_modifier_groups;
CREATE TRIGGER trg_modifier_group_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, product_id
ON public.product_modifier_groups
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_group_branch();

DROP TRIGGER IF EXISTS trg_modifier_option_branch_consistency ON public.product_modifier_options;
CREATE TRIGGER trg_modifier_option_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, group_id
ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_option_branch();

DROP TRIGGER IF EXISTS trg_modifier_effect_branch_consistency ON public.product_modifier_inventory_effects;
CREATE TRIGGER trg_modifier_effect_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, option_id, target_type, raw_material_id, inventory_unit_id
ON public.product_modifier_inventory_effects
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_effect_branch();

-- Validate any existing rows before considering the migration successful.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_groups g
    JOIN public.products p ON p.id = g.product_id
    WHERE g.branch_id <> p.branch_id
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_GROUP_BRANCH_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_options o
    JOIN public.product_modifier_groups g ON g.id = o.group_id
    WHERE o.branch_id <> g.branch_id
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_OPTION_BRANCH_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_inventory_effects e
    JOIN public.product_modifier_options o ON o.id = e.option_id
    LEFT JOIN public.raw_materials rm ON rm.id = e.raw_material_id
    LEFT JOIN public.inventory_units iu ON iu.id = e.inventory_unit_id
    WHERE e.branch_id <> o.branch_id
       OR (e.target_type = 'raw_material' AND (rm.id IS NULL OR rm.branch_id <> e.branch_id))
       OR (e.target_type = 'inventory_unit' AND (iu.id IS NULL OR iu.branch_id <> e.branch_id))
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_EFFECT_BRANCH_MISMATCH';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._enforce_modifier_group_branch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_modifier_option_branch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_modifier_effect_branch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_group_branch() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_option_branch() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_effect_branch() TO service_role, postgres;
