-- Financial Visibility Policy — phase 3
--
-- Read/report RPCs must execute with caller privileges so the restrictive RLS
-- policies added by the previous phases are effective inside reports as well.
-- This allowlist intentionally excludes every operational/posting/mutation RPC.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'get_journals',
        'get_general_ledger',
        'get_trial_balance',
        'get_trial_balance_summary',
        'get_income_statement',
        'get_balance_sheet',
        'get_ar_aging',
        'get_ap_aging',
        'get_aging_summary',
        'get_cash_flow',
        'get_party_statement',
        'get_treasury_balances',
        'get_bank_reconciliation'
      ]::text[])
  LOOP
    EXECUTE format('ALTER FUNCTION %s SECURITY INVOKER', r.fn);
  END LOOP;
END
$$;

-- Keep the report surface executable only by the roles it already serves.
-- Changing SECURITY mode does not change grants; this block merely ensures
-- PUBLIC/anon cannot gain access through an old broad grant while authenticated
-- callers keep the existing application contract.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'get_journals',
        'get_general_ledger',
        'get_trial_balance',
        'get_trial_balance_summary',
        'get_income_statement',
        'get_balance_sheet',
        'get_ar_aging',
        'get_ap_aging',
        'get_aging_summary',
        'get_cash_flow',
        'get_party_statement',
        'get_treasury_balances',
        'get_bank_reconciliation'
      ]::text[])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.fn);
  END LOOP;
END
$$;

COMMENT ON SCHEMA private IS
  'Internal helpers. Financial visibility helpers are read-side predicates and are not public RPC APIs.';
