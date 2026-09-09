CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_primary uuid;
  v_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  SELECT role, branch_id
  INTO v_target_role, v_target_primary
  FROM public.users
  WHERE id = p_user_id;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_target_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access');
    END IF;

    IF v_target_primary IS NOT NULL AND NOT public.user_may_access_branch(v_target_primary) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id
        AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED', 'branch_id', v_branch_id);
      END IF;
    END LOOP;
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, branch_id
  FROM unnest(p_branch_ids) AS branch_id
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    v_target_primary,
    'set_branch_access',
    'user_branch_access',
    p_user_id,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;
