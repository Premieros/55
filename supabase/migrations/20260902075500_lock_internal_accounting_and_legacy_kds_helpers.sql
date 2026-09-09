-- Internal setup helpers and legacy KDS reversal are service-only.
REVOKE EXECUTE ON FUNCTION public.reverse_order_kitchen_consumption(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_order_kitchen_consumption(uuid,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.seed_account_mappings(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_account_mappings(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
