-- Recipe item rows are operational recipe detail data. Reading follows the
-- parent recipe's branch/tenant visibility; mutation remains permission-gated
-- by recipes.manage from the previous release-closure migration.

DROP POLICY IF EXISTS recipe_items_select_permission_first ON public.recipe_items;

CREATE POLICY recipe_items_select_permission_first
ON public.recipe_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.recipes r
    WHERE r.id = recipe_items.recipe_id
      AND (
        public.is_pos_admin()
        OR public.user_may_access_branch(r.branch_id)
      )
  )
);
