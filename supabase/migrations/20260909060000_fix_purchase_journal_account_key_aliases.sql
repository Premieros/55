-- Canonicalize purchase journal account keys.
-- The warehouse-unification era regenerated process_purchase / receive_purchase_order
-- with 'accounts_payable' and 'vat_input' semantic keys, but account_mappings only
-- seeds 'ap' and 'vat_receivable'. This adds both as first-class alias keys (seeded for
-- every branch, including new ones) so purchase posting resolves instead of failing
-- with ACCOUNT_NOT_FOUND.

CREATE OR REPLACE FUNCTION public.seed_account_mappings(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.ensure_chart_of_accounts(p_branch_id);

  INSERT INTO public.account_mappings (branch_id, semantic_key, account_id)
  SELECT p_branch_id, m.semantic_key, a.id
  FROM (VALUES
    ('cash','1000'),('bank','1010'),('ar','1100'),('ap','2000'),
    ('accounts_payable','2000'),
    ('inventory_fg','1200'),('inventory_rm','1210'),('wip','1300'),
    ('fixed_assets','1500'),('accumulated_depreciation','1520'),
    ('vat_payable','2100'),('vat_receivable','2110'),('vat_input','2110'),
    ('capital','3000'),('retained','3100'),
    ('revenue','4000'),('discount_given','4100'),('discount_received','4110'),
    ('other_income','4200'),
    ('cogs','5000'),('expense_default','5100'),('expense_operating','5100'),
    ('stock_variance','5500'),('depreciation_expense','5600'),('bank_charges','5700')
  ) AS m(semantic_key, code)
  JOIN public.chart_of_accounts a ON a.branch_id = p_branch_id AND a.code = m.code
  ON CONFLICT (branch_id, semantic_key) DO UPDATE SET
    account_id = EXCLUDED.account_id,
    updated_at = now();
END;
$function$;

SELECT public.seed_account_mappings(id) FROM public.branches;