-- Product photos are stored in a dedicated public-read bucket.
-- Object mutation remains authenticated, permission-aware, and branch-scoped.
-- The storage schema exists on Supabase but not in the lightweight CI Postgres image,
-- so the migration intentionally no-ops there while application tests still compile/run.

DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage schema unavailable; skipping product image bucket setup';
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES (
    'product-images',
    'product-images',
    true,
    5242880,
    ARRAY['image/jpeg','image/png','image/webp','image/gif','image/avif']::text[]
  )
  ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_manage ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY product_images_insert_manage
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_update_manage
    ON storage.objects
    FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_delete_manage
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;
END
$$;
