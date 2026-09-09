-- Finish permission-first branch administration and preserve non-disclosing
-- cross-tenant error semantics.

CREATE OR REPLACE FUNCTION public.update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_name_en text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET
    name = COALESCE(p_name, name),
    name_en = COALESCE(p_name_en, name_en),
    address = COALESCE(p_address, address),
    phone = COALESCE(p_phone, phone),
    is_active = COALESCE(p_is_active, is_active)
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_UPDATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET is_active = false WHERE id = p_branch_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_user_branch uuid;
  v_org uuid;
  v_user_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_auth integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT branch_id
  INTO v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT organization_id
  INTO v_org
  FROM public.branches
  WHERE id = p_branch_id
  FOR UPDATE;

  IF v_org IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF v_user_branch IS NOT DISTINCT FROM p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'CANNOT_DELETE_CURRENT_BRANCH');
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[])
  INTO v_user_ids
  FROM public.users
  WHERE branch_id = p_branch_id;

  DELETE FROM public.journal_entries WHERE branch_id = p_branch_id;
  DELETE FROM public.branches WHERE id = p_branch_id;

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
$function$;

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;
