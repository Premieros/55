-- Remove the legacy permissive waste SELECT policy.
-- waste_entries_select is the canonical read path and requires both branch access
-- and the explicit waste.view permission. Keeping the legacy branch-only policy
-- would bypass that granular permission because PostgreSQL permissive policies OR together.
DROP POLICY IF EXISTS auth_select_waste_entries ON public.waste_entries;
