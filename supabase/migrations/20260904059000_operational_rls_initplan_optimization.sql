-- Preserve RLS semantics while evaluating auth.uid() once per statement.
-- Historical Production and Fresh DB can have different policy sets. Optimize only
-- policies that already exist; never create a new access path as a performance fix.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_requests' AND policyname='approval_requests_insert') THEN
    EXECUTE $policy$
      ALTER POLICY approval_requests_insert ON public.approval_requests
      WITH CHECK ((requester_id = (SELECT auth.uid())) AND user_may_access_branch(branch_id))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_requests' AND policyname='approval_requests_select') THEN
    EXECUTE $policy$
      ALTER POLICY approval_requests_select ON public.approval_requests
      USING ((requester_id = (SELECT auth.uid())) OR (user_may_access_branch(branch_id) AND (is_pos_admin() OR can_permission('approvals.review'::text))))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_policies' AND policyname='approval_policies_insert') THEN
    EXECUTE $policy$
      ALTER POLICY approval_policies_insert ON public.approval_policies
      WITH CHECK (can_permission('approvals.policy.manage'::text)
        AND (((branch_id IS NULL) AND is_platform_admin()) OR user_may_access_branch(branch_id))
        AND (created_by = (SELECT auth.uid())))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_insert_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_insert_users ON public.users
      WITH CHECK (is_platform_admin() OR ((id = (SELECT auth.uid())) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_select_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_select_users ON public.users
      USING ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.view'::text) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_update_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_update_users ON public.users
      USING ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.manage'::text) AND user_may_access_branch(branch_id)))
      WITH CHECK ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.manage'::text) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_branch_access' AND policyname='auth_select_own_user_branch_access') THEN
    EXECUTE $policy$
      ALTER POLICY auth_select_own_user_branch_access ON public.user_branch_access
      USING (user_id = (SELECT auth.uid()))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_branch_access' AND policyname='auth_org_admin_manage_user_branch_access') THEN
    EXECUTE $policy$
      ALTER POLICY auth_org_admin_manage_user_branch_access ON public.user_branch_access
      USING (is_platform_admin() OR (EXISTS (
        SELECT 1 FROM public.branches b
        WHERE b.id = user_branch_access.branch_id
          AND b.organization_id IN (SELECT user_organization_ids())
          AND EXISTS (
            SELECT 1 FROM public.organization_members om
            WHERE om.user_id = (SELECT auth.uid())
              AND om.organization_id = b.organization_id
              AND om.membership_role = ANY (ARRAY['owner'::text,'admin'::text])
              AND om.is_active = true
          )
      )))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_kitchen_station_assignments' AND policyname='user_kitchen_station_select') THEN
    EXECUTE $policy$
      ALTER POLICY user_kitchen_station_select ON public.user_kitchen_station_assignments
      USING ((user_id = (SELECT auth.uid())) OR (user_may_access_branch(branch_id) AND EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = (SELECT auth.uid())
          AND u.role = ANY (ARRAY['super_admin'::text,'owner'::text,'branch_manager'::text])
      )))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='kitchen_stations' AND policyname='ks_manage_by_permission') THEN
    EXECUTE $policy$
      ALTER POLICY ks_manage_by_permission ON public.kitchen_stations
      USING (can_permission('settings.manage'::text) AND EXISTS (
        SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_active = true
      ))
      WITH CHECK (can_permission('settings.manage'::text) AND EXISTS (
        SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_active = true
      ))
    $policy$;
  END IF;
END
$$;
