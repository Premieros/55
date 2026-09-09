-- Production acceptance exposed two gaps in the original branch hard delete:
-- 1) journal_entry_lines.account_id can block chart_of_accounts cascade ordering.
-- 2) deleting public.users does not remove their Supabase Auth identities.
-- Keep the operation explicit, protected and atomic.

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
  v_user_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_auth integer := 0;
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

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[])
    INTO v_user_ids
  FROM public.users
  WHERE branch_id = p_branch_id;

  -- Delete accounting roots first. Their lines cascade from journal_entries,
  -- preventing chart_of_accounts from being deleted while still referenced.
  DELETE FROM public.journal_entries WHERE branch_id = p_branch_id;

  -- Direct branch-owned rows use ON DELETE CASCADE (enforced by the previous
  -- hard-delete migration), including public.users.
  DELETE FROM public.branches WHERE id = p_branch_id;

  -- Public profile deletion alone must not leave login identities behind.
  IF COALESCE(array_length(v_user_ids, 1), 0) > 0 THEN
    DELETE FROM auth.sessions WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.identities WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.users WHERE id = ANY(v_user_ids);
    GET DIAGNOSTICS v_deleted_auth = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'organization_id', v_org,
    'deleted_auth_users', v_deleted_auth
  );
EXCEPTION WHEN foreign_key_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DELETE_BLOCKED', 'detail', SQLERRM);
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;
