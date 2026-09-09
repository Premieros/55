-- Final release audit: remove only byte-for-byte duplicate indexes verified on production.
DROP INDEX IF EXISTS public.idx_audit_log_branch_date;
DROP INDEX IF EXISTS public.idx_customers_branch;
DROP INDEX IF EXISTS public.idx_inventory_ledger_branch;
DROP INDEX IF EXISTS public.idx_journal_branch_date;
DROP INDEX IF EXISTS public.idx_purchase_items_purchase;
DROP INDEX IF EXISTS public.idx_sale_items_product;
DROP INDEX IF EXISTS public.idx_sale_items_sale;
DROP INDEX IF EXISTS public.idx_sales_branch_created;
DROP INDEX IF EXISTS public.idx_suppliers_branch;
DROP INDEX IF EXISTS public.idx_users_branch;
