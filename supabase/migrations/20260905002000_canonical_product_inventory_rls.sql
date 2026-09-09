-- Final canonical RLS for product and inventory mutations.
-- Removes the last runtime dependency on products.manage / inventory.manage.
--
-- Product rows remain editable directly by the frontend, but every mutation is
-- gated by its exact capability and branch access.
-- Inventory direct writes, when needed by an authorized administrative client,
-- use the single granular inventory.adjust capability plus branch access. The
-- normal application path remains the audited stock RPC/workflow boundary.

-- ---------------------------------------------------------------------------
-- Canonical default role templates.
-- Role names are only templates/labels; runtime authorization still resolves
-- explicit permissions from roles.permissions. Super Admin bypass is implicit.
-- ---------------------------------------------------------------------------
WITH grants(role, permissions) AS (
  VALUES
    ('owner', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb),
    ('branch_manager', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb),
    ('warehouse_manager', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb)
)
UPDATE public.roles r
SET permissions = COALESCE((
  SELECT jsonb_agg(permission ORDER BY permission)
  FROM (
    SELECT DISTINCT jsonb_array_elements_text(COALESCE(r.permissions, '[]'::jsonb)) AS permission
    UNION
    SELECT DISTINCT jsonb_array_elements_text(g.permissions) AS permission
  ) merged
), '[]'::jsonb),
updated_at = now()
FROM grants g
WHERE r.role = g.role;

-- ---------------------------------------------------------------------------
-- Products: exact permission per DML action + multi-branch access.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "auth_insert_products" ON public.products;
CREATE POLICY "auth_insert_products" ON public.products
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('products.create') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_update_products" ON public.products;
CREATE POLICY "auth_update_products" ON public.products
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_delete_products" ON public.products;
CREATE POLICY "auth_delete_products" ON public.products
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('products.delete') AND public.user_may_access_branch(branch_id))
);

-- product_units are part of editing a product, not a separate legacy manage
-- capability. They inherit branch authorization from their parent product.
DROP POLICY IF EXISTS "auth_insert_product_units" ON public.product_units;
CREATE POLICY "auth_insert_product_units" ON public.product_units
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

DROP POLICY IF EXISTS "auth_update_product_units" ON public.product_units;
CREATE POLICY "auth_update_product_units" ON public.product_units
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
)
WITH CHECK (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

DROP POLICY IF EXISTS "auth_delete_product_units" ON public.product_units;
CREATE POLICY "auth_delete_product_units" ON public.product_units
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

-- ---------------------------------------------------------------------------
-- Inventory: replace the legacy inventory.manage gate with one granular stock
-- adjustment permission. Normal UI writes still use adjust_stock / receiving /
-- kitchen / transfer / count RPCs; this RLS layer is the final branch boundary
-- for any authorized direct administrative DML.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "auth_insert_inventory" ON public.inventory;
CREATE POLICY "auth_insert_inventory" ON public.inventory
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_update_inventory" ON public.inventory;
CREATE POLICY "auth_update_inventory" ON public.inventory
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_delete_inventory" ON public.inventory;
CREATE POLICY "auth_delete_inventory" ON public.inventory
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "inventory_direct_insert_denied" ON public.inventory;
DROP POLICY IF EXISTS "inventory_direct_update_denied" ON public.inventory;
DROP POLICY IF EXISTS "inventory_direct_delete_denied" ON public.inventory;

COMMENT ON TABLE public.inventory IS
  'Authoritative stock balance. Application stock changes use audited inventory workflows; direct administrative DML requires inventory.adjust and branch access.';
