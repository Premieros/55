-- Preserve the established financial-visibility and audit-read contracts while
-- keeping the other Production acceptance fixes from 20260903083000.
--
-- Purchases are intentionally controlled in two layers:
--   1) branch isolation here;
--   2) the existing RESTRICTIVE financial_visibility_purchases policy, which
--      keeps recent history visible and applies the stable historical subset.
-- Adding purchases.view to the permissive branch policy would suppress that
-- established visibility model entirely for roles such as cashier.
DROP POLICY IF EXISTS auth_select_purchases ON public.purchases;
CREATE POLICY auth_select_purchases ON public.purchases
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

-- Direct audit rows remain branch-isolated as established by the RLS contract.
-- Privileged audit exploration is separately permission-gated by get_audit_trail.
DROP POLICY IF EXISTS auth_select_audit_log ON public.audit_log;
CREATE POLICY auth_select_audit_log ON public.audit_log
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));
