CREATE OR REPLACE FUNCTION public.assign_user_to_branch(p_user_id uuid, p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    SELECT b.organization_id INTO v_target_org
    FROM public.branches b WHERE b.id = p_branch_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.user_id = v_caller_id
        AND om.organization_id = v_target_org
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  INSERT INTO public.user_branch_access (user_id, branch_id)
  VALUES (p_user_id, p_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    p_branch_id,
    'assign_branch',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_user_from_branch(p_user_id uuid, p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    SELECT b.organization_id INTO v_target_org
    FROM public.branches b WHERE b.id = p_branch_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.user_id = v_caller_id
        AND om.organization_id = v_target_org
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF (
    SELECT count(*) FROM public.user_branch_access WHERE user_id = p_user_id
  ) <= 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LAST_BRANCH');
  END IF;

  DELETE FROM public.user_branch_access
  WHERE user_id = p_user_id AND branch_id = p_branch_id;

  PERFORM public.log_audit_action(
    p_branch_id,
    'remove_branch',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
  v_branch_id uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      SELECT b.organization_id INTO v_target_org
      FROM public.branches b WHERE b.id = v_branch_id;

      IF NOT EXISTS (
        SELECT 1 FROM public.organization_members om
        WHERE om.user_id = v_caller_id
          AND om.organization_id = v_target_org
          AND om.membership_role IN ('owner', 'admin')
          AND om.is_active = true
      ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
      END IF;
    END LOOP;
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access (user_id, branch_id)
  SELECT p_user_id, unnest(p_branch_ids)
  ON CONFLICT DO NOTHING;

  PERFORM public.log_audit_action(
    NULL::uuid,
    'set_branch_access',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.toggle_organization_status(p_org_id uuid, p_is_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.organizations SET is_active = p_is_active WHERE id = p_org_id;

  PERFORM public.log_audit_action(
    NULL::uuid,
    CASE WHEN p_is_active THEN 'activate_organization' ELSE 'deactivate_organization' END,
    'organizations',
    p_org_id,
    jsonb_build_object('is_active', p_is_active)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;
