-- Release-gate closure for permission-first authorization drift.
-- Keeps Super Admin as the only implicit bypass and removes operational role-label gates.

-- 1) Raw materials are branch-scoped master data: reads require view/manage,
-- writes require raw_materials.manage.
ALTER TABLE public.raw_materials ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS raw_materials_select_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_insert_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_update_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_delete_branch_isolated ON public.raw_materials;

CREATE POLICY raw_materials_select_branch_isolated
ON public.raw_materials FOR SELECT TO authenticated
USING (
  public.is_pos_admin()
  OR (
    public.user_may_access_branch(branch_id)
    AND (public.can_permission('raw_materials.view') OR public.can_permission('raw_materials.manage'))
  )
);

CREATE POLICY raw_materials_insert_branch_isolated
ON public.raw_materials FOR INSERT TO authenticated
WITH CHECK (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

CREATE POLICY raw_materials_update_branch_isolated
ON public.raw_materials FOR UPDATE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
)
WITH CHECK (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

CREATE POLICY raw_materials_delete_branch_isolated
ON public.raw_materials FOR DELETE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

-- 2) Recipe items inherit both branch scope and recipe-management permission
-- from their parent recipe. This prevents direct child DML from bypassing the
-- permission gate on recipes.
ALTER TABLE public.recipe_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS recipe_items_select_parent ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_insert_parent ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_update_parent ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_delete_parent ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_select_branch_isolated ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_insert_branch_isolated ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_update_branch_isolated ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_delete_branch_isolated ON public.recipe_items;

CREATE POLICY recipe_items_select_permission_first
ON public.recipe_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (
          public.user_may_access_branch(r.branch_id)
          AND (public.can_permission('recipes.view') OR public.can_permission('recipes.manage'))
        )
      )
  )
);

CREATE POLICY recipe_items_insert_permission_first
ON public.recipe_items FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
);

CREATE POLICY recipe_items_update_permission_first
ON public.recipe_items FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
);

CREATE POLICY recipe_items_delete_permission_first
ON public.recipe_items FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
);

-- Remove any older recipe_items policies left under different names so they
-- cannot combine permissively with the canonical policies above.
DO $policy_cleanup$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'recipe_items'
      AND policyname NOT IN (
        'recipe_items_select_permission_first',
        'recipe_items_insert_permission_first',
        'recipe_items_update_permission_first',
        'recipe_items_delete_permission_first'
      )
  LOOP
    EXECUTE format('DROP POLICY %I ON public.recipe_items', p.policyname);
  END LOOP;
END
$policy_cleanup$;

-- 3) Print queue policies use canonical branch access, never operational role labels.
ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view print jobs in their branch" ON public.print_jobs;
DROP POLICY IF EXISTS "Users can insert print jobs in their branch" ON public.print_jobs;
DROP POLICY IF EXISTS "Users can update print jobs in their branch" ON public.print_jobs;

CREATE POLICY "Users can view print jobs in their branch"
ON public.print_jobs FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

CREATE POLICY "Users can insert print jobs in their branch"
ON public.print_jobs FOR INSERT TO authenticated
WITH CHECK (public.user_may_access_branch(branch_id));

CREATE POLICY "Users can update print jobs in their branch"
ON public.print_jobs FOR UPDATE TO authenticated
USING (public.user_may_access_branch(branch_id))
WITH CHECK (public.user_may_access_branch(branch_id));

-- SECURITY DEFINER enqueueing must enforce the same branch boundary explicitly.
CREATE OR REPLACE FUNCTION public.enqueue_print_job(
  p_branch_id uuid,
  p_job_type text,
  p_station_code text,
  p_ticket_text text,
  p_ticket_html text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_sale_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_job_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED');
  END IF;

  INSERT INTO public.print_jobs (
    branch_id, job_type, station_code, ticket_text, ticket_html, title,
    order_id, sale_id, metadata, status, created_by
  ) VALUES (
    p_branch_id, p_job_type, COALESCE(p_station_code, 'main'), p_ticket_text,
    p_ticket_html, p_title, p_order_id, p_sale_id,
    COALESCE(p_metadata, '{}'::jsonb), 'pending', auth.uid()
  ) RETURNING id INTO v_job_id;

  RETURN jsonb_build_object('success', true, 'job_id', v_job_id);
END;
$function$;

-- 4) process_purchase: replace the retired fixed-role gate with purchases.manage
-- and canonical multi-branch access. Use the current function definition as the
-- base to avoid duplicating its inventory/accounting implementation.
DO $rewrite$
DECLARE
  v_sig regprocedure := 'public.process_purchase(text,uuid,uuid,uuid,numeric,numeric,numeric,numeric,numeric,text,text,text,jsonb)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old := $old$IF NOT is_pos_admin() AND get_user_role() NOT IN ('warehouse_manager','branch_manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;$old$;
  v_new := $new$IF NOT public.is_pos_admin() AND NOT public.can_permission('purchases.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;$new$;

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'process_purchase permission gate signature drifted; refusing unsafe rewrite';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := $old$IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND p_branch_id IS NOT NULL AND v_user_branch <> p_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;$old$;
  v_new := $new$IF NOT public.is_pos_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;$new$;

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'process_purchase branch gate signature drifted; refusing unsafe rewrite';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END
$rewrite$;
