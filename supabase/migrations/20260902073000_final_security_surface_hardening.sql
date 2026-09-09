-- Final release audit security hardening.

ALTER VIEW public.units SET (security_invoker = true);

ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.schema_migrations FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.protect_system_accounts() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_updated_at() SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_move(uuid,uuid,uuid,uuid,numeric,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_add(uuid,uuid,uuid,numeric,numeric,text,date,date,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_remove_fifo(uuid,uuid,uuid,numeric,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._raw_remove_fifo(uuid,uuid,numeric,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.guard_table_delete() SET search_path = public, pg_temp;
ALTER FUNCTION public.touch_system_settings() SET search_path = public, pg_temp;
ALTER FUNCTION public._product_wavg_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._raw_wavg_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_bom_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_recipe_cost(uuid,uuid) SET search_path = public, pg_temp;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon', r.nspname,r.proname,r.args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated', r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

GRANT EXECUTE ON FUNCTION public.get_login_email(text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
      AND (
        p.proname LIKE '\_%' ESCAPE '\'
        OR p.proname IN (
          'assert_branch_active','guard_branch_org_immutable','guard_order_subscription',
          'guard_role_permissions','guard_sale_discount','guard_user_role_changes',
          'guard_table_delete','protect_last_admin','protect_system_accounts',
          'seed_chart_for_new_branch','seed_mappings_for_new_branch',
          'track_product_cost_history','validate_recipe_item_branch_match',
          'touch_system_settings'
        )
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM authenticated', r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

NOTIFY pgrst, 'reload schema';
