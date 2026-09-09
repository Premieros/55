-- Final audit CI/admin alignment: database administrators may execute internal
-- setup helpers, while client roles remain denied. PostgreSQL admin access is
-- not an application surface.
GRANT EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.seed_account_mappings(uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) TO postgres;

REVOKE EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_account_mappings(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
