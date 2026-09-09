-- Canonicalize product image mutation authorization.
-- Historical migrations used products.manage; the active model uses products.edit.
-- The storage schema is absent from lightweight CI Postgres, so this no-ops there.

DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage schema unavailable; skipping product image policy canonicalization';
    RETURN;
  END IF;

  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_edit ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_edit ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_edit ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY product_images_insert_edit
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_update_edit
    ON storage.objects
    FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_delete_edit
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;
END
$$;

-- Remove deprecated permission names from persisted role templates so future
-- assignments cannot silently revive the legacy model. Super Admin bypass is
-- implicit and does not depend on this array.
UPDATE public.roles r
SET permissions = COALESCE((
  SELECT jsonb_agg(p.value ORDER BY p.ordinality)
  FROM jsonb_array_elements(COALESCE(r.permissions, '[]'::jsonb)) WITH ORDINALITY AS p(value, ordinality)
  WHERE p.value #>> '{}' NOT IN (
    'pos.sell',
    'pos.pay',
    'pos.transfer_order',
    'pos.split_order',
    'products.manage',
    'inventory.manage',
    'inventory.transfers',
    'inventory.transfers.approve',
    'catalog.view',
    'procurement.view',
    'accounting.view',
    'admin.view'
  )
), '[]'::jsonb)
WHERE EXISTS (
  SELECT 1
  FROM jsonb_array_elements_text(COALESCE(r.permissions, '[]'::jsonb)) AS p(permission)
  WHERE p.permission IN (
    'pos.sell',
    'pos.pay',
    'pos.transfer_order',
    'pos.split_order',
    'products.manage',
    'inventory.manage',
    'inventory.transfers',
    'inventory.transfers.approve',
    'catalog.view',
    'procurement.view',
    'accounting.view',
    'admin.view'
  )
);
