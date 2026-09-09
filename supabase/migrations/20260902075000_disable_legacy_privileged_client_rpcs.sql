-- Final release audit: privileged bootstrap/registration and legacy KDS inventory
-- mutations must never be callable by ordinary authenticated clients.

REVOKE EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.register_branch(text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_branch(text,text,text,text,text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.register_tenant(text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_tenant(text,text,text,text,text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.consume_order_kitchen_inventory(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_order_kitchen_inventory(uuid,uuid) TO service_role;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='reverse_order_kitchen_inventory'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated',r.nspname,r.proname,r.args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO service_role',r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

NOTIFY pgrst, 'reload schema';
