-- Harden SECURITY DEFINER execution without changing authenticated application RPC behavior.
-- Every function change is conditional because historical Production and a Fresh DB can
-- legitimately expose different overloads at this point in the migration chain.

DO $$
DECLARE
  fn regprocedure;
BEGIN
  -- Internal trigger functions must never be callable directly from API roles.
  fn := to_regprocedure('public._price_order_item_modifiers()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  fn := to_regprocedure('public.delete_unposted_purchase_on_cancel()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  fn := to_regprocedure('public.sync_kitchen_sent_quantity_after_void()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  -- send_to_kitchen is an authenticated operational RPC only. Harden every supported
  -- overload that exists in the target database without assuming schema history.
  fn := to_regprocedure('public.send_to_kitchen(uuid)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END IF;

  fn := to_regprocedure('public.send_to_kitchen(uuid,uuid)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END IF;

  -- Pre-auth login helpers intentionally remain available to anon.
  fn := to_regprocedure('public.get_login_email(text)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated, service_role', fn);
  END IF;

  fn := to_regprocedure('public.record_login_failure(text)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated, service_role', fn);
  END IF;
END
$$;

-- These tables were already deny-by-default because RLS was enabled with no policies.
-- Make that intent explicit for API roles when the tables exist, without changing
-- service/postgres access and without assuming historical schema drift.
DO $$
BEGIN
  IF to_regclass('public.sale_payments') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS sale_payments_api_deny_all ON public.sale_payments';
    EXECUTE 'CREATE POLICY sale_payments_api_deny_all ON public.sale_payments AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;

  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS schema_migrations_api_deny_all ON public.schema_migrations';
    EXECUTE 'CREATE POLICY schema_migrations_api_deny_all ON public.schema_migrations AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;
END
$$;
