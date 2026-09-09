-- Provision a clean baseline of 50 dining tables for every branch.
-- Existing custom tables are preserved, and users may add more than 50.

CREATE OR REPLACE FUNCTION private.ensure_default_dining_tables(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_area_id uuid;
  v_i integer;
  v_name text;
  v_layout jsonb;
BEGIN
  IF p_branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN;
  END IF;

  SELECT id INTO v_area_id
  FROM public.dining_areas
  WHERE branch_id = p_branch_id
  ORDER BY sort_order, created_at, id
  LIMIT 1;

  IF v_area_id IS NULL THEN
    INSERT INTO public.dining_areas (branch_id, name, sort_order, is_demo)
    VALUES (p_branch_id, 'الصالة الرئيسية', 0, false)
    RETURNING id INTO v_area_id;
  END IF;

  FOR v_i IN 1..50 LOOP
    v_name := 'طاولة ' || lpad(v_i::text, 2, '0');
    v_layout := jsonb_build_object(
      'x', 20 + ((v_i - 1) % 10) * 130,
      'y', 20 + ((v_i - 1) / 10) * 100,
      'w', 110,
      'h', 70
    );

    IF EXISTS (
      SELECT 1
      FROM public.dining_tables
      WHERE branch_id = p_branch_id
        AND name = v_name
    ) THEN
      UPDATE public.dining_tables
      SET is_active = true,
          area_id = COALESCE(area_id, v_area_id),
          updated_at = now()
      WHERE branch_id = p_branch_id
        AND name = v_name;
    ELSE
      INSERT INTO public.dining_tables (
        branch_id,
        area_id,
        name,
        capacity,
        status,
        shape,
        layout,
        is_active,
        is_demo
      ) VALUES (
        p_branch_id,
        v_area_id,
        v_name,
        4,
        'vacant',
        'rect',
        v_layout,
        true,
        false
      );
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION private.provision_default_dining_tables_on_branch_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM private.ensure_default_dining_tables(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provision_default_dining_tables ON public.branches;
CREATE TRIGGER trg_provision_default_dining_tables
AFTER INSERT ON public.branches
FOR EACH ROW
EXECUTE FUNCTION private.provision_default_dining_tables_on_branch_insert();

-- Backfill the baseline for all existing active branches without touching
-- custom tables beyond the numbered default set.
DO $$
DECLARE
  v_branch record;
BEGIN
  FOR v_branch IN SELECT id FROM public.branches WHERE is_active = true LOOP
    PERFORM private.ensure_default_dining_tables(v_branch.id);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_default_dining_tables(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.provision_default_dining_tables_on_branch_insert() FROM PUBLIC, anon, authenticated;
