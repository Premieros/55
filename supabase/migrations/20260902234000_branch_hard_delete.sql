-- Hard-delete a branch and every public row directly linked to it.
-- Branch deletion is an explicit destructive admin operation; do not use for soft disable.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT tc.table_schema, tc.table_name, tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.constraint_schema = kcu.constraint_schema
    JOIN information_schema.referential_constraints rc
      ON rc.constraint_name = tc.constraint_name
     AND rc.constraint_schema = tc.constraint_schema
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name
     AND ccu.constraint_schema = tc.constraint_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = 'public'
      AND ccu.table_schema = 'public'
      AND ccu.table_name = 'branches'
      AND kcu.column_name = 'branch_id'
      AND rc.delete_rule <> 'CASCADE'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', r.table_schema, r.table_name, r.constraint_name);
    EXECUTE format(
      'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE',
      r.table_schema, r.table_name, r.constraint_name
    );
  END LOOP;
END $$;

-- Preserve the normal safety guards, but do not let them block rows that are
-- being removed only because their parent branch itself is being deleted.
CREATE OR REPLACE FUNCTION public.protect_system_accounts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.is_system THEN
    IF OLD.branch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED: % (%)', OLD.code, OLD.name;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.is_system THEN
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.account_type IS DISTINCT FROM OLD.account_type THEN
      RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED: % (%)', OLD.code, OLD.name;
    END IF;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    NEW.name := btrim(NEW.name);
    IF NEW.name = '' THEN RAISE EXCEPTION 'ACCOUNT_NAME_REQUIRED'; END IF;
    NEW.code := upper(btrim(NEW.code));
    IF NEW.code = '' THEN RAISE EXCEPTION 'ACCOUNT_CODE_REQUIRED'; END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_table_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.branch_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
    RETURN OLD;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = OLD.id AND status IN ('open', 'held')
  ) THEN
    RAISE EXCEPTION 'Cannot delete a table with open orders.';
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.branch_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
    RETURN OLD;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.status IN ('open', 'held')
      AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
  ) THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_user_branch uuid;
  v_org uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT role, branch_id
    INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF v_role NOT IN ('super_admin', 'owner') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT organization_id INTO v_org
  FROM public.branches
  WHERE id = p_branch_id
  FOR UPDATE;

  IF v_org IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF v_user_branch IS NOT DISTINCT FROM p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'CANNOT_DELETE_CURRENT_BRANCH');
  END IF;

  IF v_role = 'owner' AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  DELETE FROM public.branches WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'organization_id', v_org);
EXCEPTION WHEN foreign_key_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DELETE_BLOCKED', 'detail', SQLERRM);
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;
