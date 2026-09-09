-- Keep the sent-order-item mutation guard internal.
-- Public clients must use cancel_sent_order_item / cancel_sent_order_item_exact,
-- which enforce branch access, approval rules, audit logging, and exact-line targeting.

REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;
