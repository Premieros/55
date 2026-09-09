-- Final release audit: anonymous access is deny-by-default.
-- Public sign-up is disabled; pre-auth only needs username/email resolution
-- and login-failure throttling RPCs.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon',r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

GRANT EXECUTE ON FUNCTION public.get_login_email(text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

NOTIFY pgrst, 'reload schema';
