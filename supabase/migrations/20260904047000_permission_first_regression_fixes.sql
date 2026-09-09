-- Close permission-first regressions introduced by 20260904046000.
-- Super Admin remains the only implicit bypass. All tenant users require both
-- the relevant permission and explicit/primary branch scope.

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
  v_audit_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(p_branch_ids) AS requested(branch_id) WHERE requested.branch_id IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_BRANCH');
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
      RETURN jsonb_build_object(
        'success', false,
        'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access'
      );
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
        RETURN jsonb_build_object(
          'success', false,
          'error', 'BRANCH_ACCESS_DENIED',
          'branch_id', v_branch_id
        );
      END IF;
    END LOOP;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_branch_ids) AS requested(branch_id)
    LEFT JOIN public.branches b ON b.id = requested.branch_id
    WHERE b.id IS NULL
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, requested.branch_id
  FROM unnest(p_branch_ids) AS requested(branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  v_audit_branch := COALESCE(v_target_primary, p_branch_ids[1]);
  PERFORM public.log_audit_action(
    v_audit_branch,
    'set_branch_access',
    'user_branch_access',
    p_user_id,
    jsonb_build_object('branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;

-- The registration RPC deliberately enables this transaction-local flag.
-- Preserve the bypass for both later privilege checks in the canonical
-- create_user implementation, not only its first authorization block.
DO $block$
DECLARE
  v_oid regprocedure := to_regprocedure('public.create_user(text,text,text,text,uuid,boolean,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'PERMISSION_FIRST_FUNCTION_MISSING:create_user/7';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new := replace(
    v_def,
    'IF NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN',
    'IF COALESCE(current_setting(''app.register_branch'', true), '''') <> ''on'' AND NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN'
  );
  v_new := replace(
    v_new,
    E'IF NOT public.is_platform_admin() THEN\n    IF EXISTS (',
    E'IF COALESCE(current_setting(''app.register_branch'', true), '''') <> ''on'' AND NOT public.is_platform_admin() THEN\n    IF EXISTS ('
  );

  IF v_new = v_def
     OR position('app.register_branch' IN v_new) = 0
     OR v_new LIKE '%IF NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN%'
     OR v_new LIKE E'%IF NOT public.is_platform_admin() THEN\n    IF EXISTS (%' THEN
    RAISE EXCEPTION 'PERMISSION_FIRST_PATTERN_CHANGED:create_user/7';
  END IF;

  EXECUTE v_new;
END;
$block$;

CREATE OR REPLACE FUNCTION public.create_organization_branch(
  p_organization_id uuid,
  p_name text,
  p_name_en text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = p_organization_id AND is_active) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORGANIZATION_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.branches b
      WHERE b.organization_id = p_organization_id
        AND public.user_may_access_branch(b.id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
    END IF;

    IF NOT public.can_permission('branches.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF btrim(COALESCE(p_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_NAME');
  END IF;

  INSERT INTO public.branches (name, name_en, address, phone, is_active, organization_id)
  VALUES (p_name, p_name_en, p_address, p_phone, true, p_organization_id)
  RETURNING id INTO v_branch_id;

  INSERT INTO public.warehouses (name, branch_id, is_active)
  VALUES (p_name || ' - Main', v_branch_id, true)
  RETURNING id INTO v_warehouse_id;

  SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
  INTO v_global_tax, v_global_tax_enabled, v_global_currency
  FROM public.settings
  ORDER BY id
  LIMIT 1;

  INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
  VALUES (v_branch_id, v_global_tax, v_global_tax_enabled, v_global_currency, 10);

  INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
  VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

  -- The creator must be able to administer the branch they just created.
  INSERT INTO public.user_branch_access(user_id, branch_id)
  VALUES (auth.uid(), v_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    v_branch_id,
    'create_branch',
    'branches',
    v_branch_id,
    jsonb_build_object('organization_id', p_organization_id, 'name', p_name)
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', v_branch_id,
    'warehouse_id', v_warehouse_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_CREATE_FAILED', 'detail', SQLERRM);
END;
$function$;

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

  IF NOT public.is_platform_admin()
     AND (NOT public.can_permission('branches.manage') OR NOT public.user_may_access_branch(p_branch_id)) THEN
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

  IF NOT public.is_platform_admin()
     AND (NOT public.can_permission('branches.manage') OR NOT public.user_may_access_branch(p_branch_id)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET is_active = false WHERE id = p_branch_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_user_branch_access(uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_user_branch_access(uuid,uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_organization_branch(uuid,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_branch(uuid,text,text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_branch(uuid) TO authenticated;
