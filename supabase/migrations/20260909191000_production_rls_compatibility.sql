-- Production RLS compatibility closure for current scpovyrqmsbiduanykod drift.
-- Remove permissive/legacy policies and enforce canonical permission-first + branch isolation.

-- Raw materials: branch-scoped reads; mutation requires raw_materials.manage.
ALTER TABLE public.raw_materials ENABLE ROW LEVEL SECURITY;

DO $cleanup_raw$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'raw_materials'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.raw_materials', p.policyname);
  END LOOP;
END
$cleanup_raw$;

CREATE POLICY raw_materials_select_permission_first
ON public.raw_materials FOR SELECT TO authenticated
USING (
  public.is_pos_admin()
  OR (
    public.user_may_access_branch(branch_id)
    AND (public.can_permission('raw_materials.view') OR public.can_permission('raw_materials.manage'))
  )
);

CREATE POLICY raw_materials_insert_permission_first
ON public.raw_materials FOR INSERT TO authenticated
WITH CHECK (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

CREATE POLICY raw_materials_update_permission_first
ON public.raw_materials FOR UPDATE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
)
WITH CHECK (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

CREATE POLICY raw_materials_delete_permission_first
ON public.raw_materials FOR DELETE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.user_may_access_branch(branch_id) AND public.can_permission('raw_materials.manage'))
);

-- Recipe items: branch-visible read; all mutation requires recipes.manage.
ALTER TABLE public.recipe_items ENABLE ROW LEVEL SECURITY;

DO $cleanup_recipe_items$
DECLARE p record;
BEGIN
  FOR p IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'recipe_items'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.recipe_items', p.policyname);
  END LOOP;
END
$cleanup_recipe_items$;

CREATE POLICY recipe_items_select_permission_first
ON public.recipe_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (public.is_pos_admin() OR public.user_may_access_branch(r.branch_id))
  )
);

CREATE POLICY recipe_items_insert_permission_first
ON public.recipe_items FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.recipes r
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
    SELECT 1
    FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.recipes r
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
    SELECT 1
    FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR (public.user_may_access_branch(r.branch_id) AND public.can_permission('recipes.manage'))
      )
  )
);
