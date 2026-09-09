-- Permission-first authorization for Frontend V2.
-- Super Admin is the only platform-level bypass. All other users, including
-- owner-labelled users, are authorized by explicit role permissions and
-- explicit/legacy branch grants.

CREATE OR REPLACE FUNCTION public.can_permission(p_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT public.is_platform_admin() OR EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.roles r ON r.role = u.role
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND COALESCE(r.is_active, true) = true
      AND COALESCE(r.permissions, '[]'::jsonb) ? p_permission
  );
$function$;

CREATE OR REPLACE FUNCTION public.user_may_access_branch(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT
    public.is_platform_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = auth.uid()
        AND uba.branch_id = p_branch_id
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active = true
        AND u.branch_id = p_branch_id
    )
    OR (p_branch_id IS NULL AND public.is_platform_admin());
$function$;

CREATE OR REPLACE FUNCTION public.get_user_branch_access(p_user_id uuid)
RETURNS TABLE(
  branch_id uuid,
  branch_name text,
  branch_name_en text,
  organization_id uuid,
  is_active boolean,
  grant_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active, 'explicit'::text
  FROM public.user_branch_access uba
  JOIN public.branches b ON b.id = uba.branch_id
  WHERE uba.user_id = p_user_id
    AND (
      p_user_id = auth.uid()
      OR public.is_platform_admin()
      OR (public.can_permission('users.view') AND public.user_may_access_branch(b.id))
    )

  UNION

  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active, 'primary'::text
  FROM public.users u
  JOIN public.branches b ON b.id = u.branch_id
  WHERE u.id = p_user_id
    AND NOT EXISTS (
      SELECT 1 FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id AND uba.branch_id = b.id
    )
    AND (
      p_user_id = auth.uid()
      OR public.is_platform_admin()
      OR (public.can_permission('users.view') AND public.user_may_access_branch(b.id))
    )
  ORDER BY 2;
$function$;

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
    'set_branch_access', 'user_branch_access', NULL,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;

-- Branch visibility follows explicit access. Organization labels no longer imply
-- automatic access to every branch.
DROP POLICY IF EXISTS auth_select_branches ON public.branches;
CREATE POLICY auth_select_branches ON public.branches
FOR SELECT TO authenticated
USING (public.user_may_access_branch(id));

DROP POLICY IF EXISTS auth_update_branches ON public.branches;
CREATE POLICY auth_update_branches ON public.branches
FOR UPDATE TO authenticated
USING (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)))
WITH CHECK (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)));

DROP POLICY IF EXISTS auth_delete_branches ON public.branches;
CREATE POLICY auth_delete_branches ON public.branches
FOR DELETE TO authenticated
USING (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)));

-- Direct user_branch_access writes are permission-based as well. The RPC above
-- remains the preferred audited path.
DROP POLICY IF EXISTS auth_org_admin_manage_user_branch_access ON public.user_branch_access;
DROP POLICY IF EXISTS auth_platform_admin_user_branch_access ON public.user_branch_access;
DROP POLICY IF EXISTS auth_manage_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_manage_user_branch_access ON public.user_branch_access
FOR ALL TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
);

-- Role rows are templates/labels. Their permissions are the authority. Any role
-- with settings.manage may maintain role templates, but cannot grant a permission
-- that the caller does not already possess. Super Admin is the only exception.
DROP POLICY IF EXISTS auth_select_roles ON public.roles;
CREATE POLICY auth_select_roles ON public.roles
FOR SELECT TO authenticated
USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS auth_write_roles ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_del ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_upd ON public.roles;
CREATE POLICY auth_write_roles ON public.roles
FOR INSERT TO authenticated
WITH CHECK (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);
CREATE POLICY auth_write_roles_upd ON public.roles
FOR UPDATE TO authenticated
USING (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
)
WITH CHECK (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);
CREATE POLICY auth_write_roles_del ON public.roles
FOR DELETE TO authenticated
USING (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);

CREATE OR REPLACE FUNCTION public.guard_role_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_perm text;
BEGIN
  -- Migrations/DB owner fixtures are not interactive app users.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_platform_admin() THEN
    RETURN NEW;
  END IF;

  IF NOT public.can_permission('settings.manage') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: settings.manage required';
  END IF;

  IF NEW.role = 'super_admin' THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Super Admin role is platform-only';
  END IF;

  IF NEW.scope = 'branch' AND (NEW.branch_id IS NULL OR NOT public.user_may_access_branch(NEW.branch_id)) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: branch role outside caller access';
  END IF;

  FOR v_perm IN
    SELECT jsonb_array_elements_text(COALESCE(NEW.permissions, '[]'::jsonb))
  LOOP
    IF NOT public.can_permission(v_perm) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: cannot grant permission %', v_perm;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_user_role_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_caller_role text;
  v_bypass boolean;
  v_register boolean;
  v_perm text;
  v_role_scope text;
  v_role_branch uuid;
BEGIN
  SELECT role INTO v_caller_role FROM public.users WHERE id = auth.uid();

  v_bypass := COALESCE(current_setting('app.login_guard_bypass', true), '') = 'on';
  v_register := COALESCE(current_setting('app.register_branch', true), '') = 'on';

  IF v_register THEN RETURN NEW; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE role = NEW.role AND is_active = true) THEN
    RAISE EXCEPTION 'UNKNOWN_ROLE';
  END IF;

  SELECT scope, branch_id INTO v_role_scope, v_role_branch
  FROM public.roles WHERE role = NEW.role;

  IF v_caller_role IS NULL THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.id = auth.uid() AND NEW.role = 'cashier' AND NEW.branch_id IS NULL THEN RETURN NEW; END IF;
      RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.role IS DISTINCT FROM OLD.role
       OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
       OR NEW.is_active IS DISTINCT FROM OLD.is_active
       OR NEW.email IS DISTINCT FROM OLD.email
       OR NEW.username IS DISTINCT FROM OLD.username
       OR NEW.full_name IS DISTINCT FROM OLD.full_name
       OR NEW.phone IS DISTINCT FROM OLD.phone THEN
      RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;
    RETURN NEW;
  END IF;

  IF public.is_platform_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'UPDATE' AND NEW.id = auth.uid() THEN
    IF NEW.role IS DISTINCT FROM OLD.role
       OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
       OR NEW.is_active IS DISTINCT FROM OLD.is_active THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: users cannot change their own role/branch/status';
    END IF;
    IF NOT v_bypass AND (
      NEW.is_locked IS DISTINCT FROM OLD.is_locked
      OR NEW.failed_attempts IS DISTINCT FROM OLD.failed_attempts
      OR NEW.lock_until IS DISTINCT FROM OLD.lock_until
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: users cannot modify their own lock state';
    END IF;
    RETURN NEW;
  END IF;

  IF NOT public.can_permission('users.manage') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: users.manage required';
  END IF;

  IF NEW.role = 'super_admin' OR (TG_OP = 'UPDATE' AND OLD.role = 'super_admin') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Super Admin accounts are platform-only';
  END IF;

  IF NEW.branch_id IS NULL OR NOT public.user_may_access_branch(NEW.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: target branch outside caller access';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.branch_id IS NOT NULL AND NOT public.user_may_access_branch(OLD.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: target user outside caller access';
  END IF;

  IF v_role_scope = 'branch' AND v_role_branch IS DISTINCT FROM NEW.branch_id THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: role is not assignable in this branch';
  END IF;

  FOR v_perm IN
    SELECT jsonb_array_elements_text(COALESCE((SELECT permissions FROM public.roles WHERE role = NEW.role), '[]'::jsonb))
  LOOP
    IF NOT public.can_permission(v_perm) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: cannot assign role containing permission %', v_perm;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.protect_last_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_other_active_super_admins int;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.role = 'super_admin' AND OLD.is_active THEN
      SELECT count(*) INTO v_other_active_super_admins
      FROM public.users
      WHERE role = 'super_admin' AND is_active AND id <> OLD.id;
      IF v_other_active_super_admins = 0 THEN RAISE EXCEPTION 'LAST_ADMIN'; END IF;
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.role = 'super_admin' AND OLD.is_active
     AND (NEW.role <> 'super_admin' OR NOT NEW.is_active) THEN
    SELECT count(*) INTO v_other_active_super_admins
    FROM public.users
    WHERE role = 'super_admin' AND is_active AND id <> OLD.id;
    IF v_other_active_super_admins = 0 THEN RAISE EXCEPTION 'LAST_ADMIN'; END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- Canonical create_user overload: permission-based user management, with role
-- labels unrestricted except for Super Admin and branch scope.
CREATE OR REPLACE FUNCTION public.create_user(
  p_email text,
  p_password text,
  p_full_name text DEFAULT NULL::text,
  p_role text DEFAULT 'cashier'::text,
  p_branch_id uuid DEFAULT NULL::uuid,
  p_is_active boolean DEFAULT true,
  p_username text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_user_id uuid;
  v_role text;
  v_hash text;
  v_email text;
  v_username text;
  v_pgc_schema text;
  v_u_cols text;
  v_u_vals text;
  v_i_cols text;
  v_i_vals text;
BEGIN
  IF current_setting('app.register_branch', true) = 'on' THEN
    NULL;
  ELSIF public.is_platform_admin() THEN
    NULL;
  ELSIF public.can_permission('users.manage') THEN
    IF p_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Super Admin is platform-only');
    END IF;
    IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Target branch is not accessible');
    END IF;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  v_email := lower(btrim(p_email));
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) OR EXISTS (SELECT 1 FROM public.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMAIL_TAKEN');
  END IF;

  v_username := regexp_replace(
    regexp_replace(lower(btrim(coalesce(NULLIF(p_username, ''), split_part(v_email, '@', 1)))), '[^a-z0-9._-]', '_', 'g'),
    '^[._-]+', '', 'g'
  );
  IF v_username = '' THEN v_username := 'user' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE username = v_username) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USERNAME_TAKEN');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.role = p_role
      AND r.is_active = true
      AND (r.scope = 'global' OR r.branch_id = p_branch_id)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ROLE_NOT_ASSIGNABLE');
  END IF;

  IF NOT public.is_platform_admin() AND p_role = 'super_admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(COALESCE((SELECT permissions FROM public.roles WHERE role = p_role), '[]'::jsonb)) AS p(permission)
      WHERE NOT public.can_permission(p.permission)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Cannot assign a role with permissions the caller does not have');
    END IF;
  END IF;
  v_role := p_role;

  SELECT extnamespace::regnamespace::text INTO v_pgc_schema
  FROM pg_extension WHERE extname = 'pgcrypto';
  IF v_pgc_schema IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'pgcrypto extension is not enabled');
  END IF;

  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt($2, $3))', v_pgc_schema, v_pgc_schema)
    INTO v_hash USING p_password, 'bf', 10;

  v_user_id := gen_random_uuid();

  SELECT string_agg(c.col, ', ' ORDER BY c.ord), string_agg(c.val, ', ' ORDER BY c.ord)
  INTO v_u_cols, v_u_vals
  FROM (
    SELECT cols.ordinal_position AS ord, quote_ident(cols.column_name) AS col,
      CASE cols.column_name
        WHEN 'instance_id' THEN '''00000000-0000-0000-0000-000000000000'''
        WHEN 'id' THEN quote_literal(v_user_id)
        WHEN 'aud' THEN '''authenticated'''
        WHEN 'role' THEN '''authenticated'''
        WHEN 'email' THEN quote_literal(v_email)
        WHEN 'encrypted_password' THEN quote_literal(v_hash)
        WHEN 'email_confirmed_at' THEN 'now()'
        WHEN 'confirmation_token' THEN ''''''
        WHEN 'recovery_token' THEN ''''''
        WHEN 'email_change' THEN ''''''
        WHEN 'email_change_token_new' THEN ''''''
        WHEN 'email_change_token_current' THEN ''''''
        WHEN 'raw_app_meta_data' THEN format('jsonb_build_object(''provider'',''email'',''providers'',array[''email'']::text[],''email'',%L)', v_email)
        WHEN 'raw_user_meta_data' THEN format('jsonb_build_object(''full_name'',%L,''email'',%L,''email_verified'',true)', p_full_name, v_email)
        WHEN 'created_at' THEN 'now()'
        WHEN 'updated_at' THEN 'now()'
        WHEN 'is_anonymous' THEN 'false'
        WHEN 'is_sso_user' THEN 'false'
      END AS val
    FROM information_schema.columns cols
    WHERE cols.table_schema = 'auth' AND cols.table_name = 'users'
      AND cols.is_generated = 'NEVER'
      AND cols.column_name IN ('instance_id','id','aud','role','email','encrypted_password','email_confirmed_at','confirmation_token','recovery_token','email_change','email_change_token_new','email_change_token_current','raw_app_meta_data','raw_user_meta_data','created_at','updated_at','is_anonymous','is_sso_user')
  ) c;

  IF v_u_cols IS NULL OR v_u_vals IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'no insertable columns found for auth.users');
  END IF;
  EXECUTE 'INSERT INTO auth.users (' || v_u_cols || ') VALUES (' || v_u_vals || ')';

  SELECT string_agg(c.col, ', ' ORDER BY c.ord), string_agg(c.val, ', ' ORDER BY c.ord)
  INTO v_i_cols, v_i_vals
  FROM (
    SELECT cols.ordinal_position AS ord, quote_ident(cols.column_name) AS col,
      CASE cols.column_name
        WHEN 'id' THEN 'gen_random_uuid()'
        WHEN 'provider_id' THEN quote_literal(v_user_id::text)
        WHEN 'user_id' THEN quote_literal(v_user_id)
        WHEN 'identity_data' THEN format('jsonb_build_object(''sub'',%L,''email'',%L)', v_user_id::text, v_email)
        WHEN 'provider' THEN '''email'''
        WHEN 'last_sign_in_at' THEN 'now()'
        WHEN 'created_at' THEN 'now()'
        WHEN 'updated_at' THEN 'now()'
        WHEN 'email' THEN quote_literal(v_email)
      END AS val
    FROM information_schema.columns cols
    WHERE cols.table_schema = 'auth' AND cols.table_name = 'identities'
      AND cols.is_generated = 'NEVER'
      AND cols.column_name IN ('id','provider_id','user_id','identity_data','provider','last_sign_in_at','created_at','updated_at','email')
  ) c;

  IF v_i_cols IS NULL OR v_i_vals IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'no insertable columns found for auth.identities');
  END IF;
  EXECUTE 'INSERT INTO auth.identities (' || v_i_cols || ') VALUES (' || v_i_vals || ')';

  INSERT INTO public.users(id, email, username, full_name, role, branch_id, is_active)
  VALUES(v_user_id, v_email, v_username, p_full_name, v_role, p_branch_id, p_is_active);

  RETURN jsonb_build_object('success', true, 'user_id', v_user_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- Legacy overload delegates to the canonical function so both paths share the
-- same permission/branch rules.
CREATE OR REPLACE FUNCTION public.create_user(
  p_email text,
  p_password text,
  p_full_name text DEFAULT NULL::text,
  p_role text DEFAULT 'cashier'::text,
  p_branch_id uuid DEFAULT NULL::uuid,
  p_is_active boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  RETURN public.create_user(p_email, p_password, p_full_name, p_role, p_branch_id, p_is_active, NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_user(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_branch uuid;
BEGIN
  SELECT role, branch_id INTO v_target_role, v_target_branch FROM public.users WHERE id = p_user_id;
  IF v_target_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_role = 'super_admin' THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_branch IS NULL OR NOT public.user_may_access_branch(v_target_branch) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;
  END IF;

  DELETE FROM public.users WHERE id = p_user_id;
  DELETE FROM auth.users WHERE id = p_user_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM = 'LAST_ADMIN' THEN RETURN jsonb_build_object('success', false, 'error', 'LAST_ADMIN'); END IF;
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_user_password(p_user_id uuid, p_new_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_hash text;
  v_pgc_schema text;
  v_target_role text;
  v_target_branch uuid;
BEGIN
  SELECT role, branch_id INTO v_target_role, v_target_branch FROM public.users WHERE id = p_user_id;
  IF v_target_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_role = 'super_admin' THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_branch IS NULL OR NOT public.user_may_access_branch(v_target_branch) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF p_new_password IS NULL OR char_length(p_new_password) < 4 THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD');
  END IF;
  IF char_length(p_new_password) = 4 AND p_new_password !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  SELECT extnamespace::regnamespace::text INTO v_pgc_schema FROM pg_extension WHERE extname = 'pgcrypto';
  IF v_pgc_schema IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'pgcrypto extension is not enabled');
  END IF;
  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt($2, $3))', v_pgc_schema, v_pgc_schema)
    INTO v_hash USING p_new_password, 'bf', 10;
  UPDATE auth.users SET encrypted_password = v_hash, updated_at = now() WHERE id = p_user_id;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'sessions') THEN
    DELETE FROM auth.sessions WHERE user_id = p_user_id;
  END IF;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- V2-sensitive functions must use Super Admin as the only implicit bypass.
DO $block$
DECLARE
  v_sig text;
  v_oid regprocedure;
  v_def text;
  v_new text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.open_shift(uuid,numeric,text)',
    'public.decide_manager_approval(uuid,boolean,text)',
    'public.send_to_kitchen(uuid,uuid)',
    'public.close_shift(uuid,numeric,text)',
    'public.decide_operational_approval(text,uuid,boolean,text)',
    'public.approve_waste(uuid,boolean,text)',
    'public.approve_stock_count(uuid)',
    'public.reject_stock_count(uuid,text)',
    'public.approve_warehouse_transfer(uuid)',
    'public.reject_warehouse_transfer(uuid,text)'
  ] LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'PERMISSION_FIRST_FUNCTION_MISSING:%', v_sig; END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_def;
    v_new := replace(v_def, 'public.is_pos_admin()', 'public.is_platform_admin()');
    IF v_new = v_def THEN RAISE EXCEPTION 'PERMISSION_FIRST_PATTERN_CHANGED:%', v_sig; END IF;
    EXECUTE v_new;
  END LOOP;
END;
$block$;

REVOKE ALL ON FUNCTION public.get_user_branch_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_user_branch_access(uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_branch_access(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_user_branch_access(uuid,uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_user(text,text,text,text,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_user(text,text,text,text,uuid,boolean,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_user_password(uuid,text) TO authenticated, service_role;
