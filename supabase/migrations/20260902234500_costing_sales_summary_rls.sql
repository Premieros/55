-- Costing sales reads must obey the same row visibility policy as sales/history.

ALTER FUNCTION public.get_order_margin(uuid, date, date) SECURITY INVOKER;
ALTER FUNCTION public.get_order_margin(uuid, date, date) SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION public.get_order_margin(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_order_margin(uuid, date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_order_margin(uuid, date, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_costing_sales_summary(
  p_branch_id uuid DEFAULT NULL,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
WITH scoped_sales AS (
  SELECT
    s.id,
    GREATEST(COALESCE(s.total, 0) - COALESCE(s.tax_amount, 0), 0)::numeric AS net_sales
  FROM public.sales s
  WHERE (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (p_from IS NULL OR s.created_at::date >= p_from)
    AND (p_to IS NULL OR s.created_at::date <= p_to)
    AND COALESCE(s.status, '') NOT IN ('returned', 'cancelled')
), sale_costs AS (
  SELECT
    il.reference_id AS sale_id,
    GREATEST(COALESCE(-SUM(il.total_cost), 0), 0)::numeric AS cogs
  FROM public.inventory_ledger il
  JOIN scoped_sales ss ON ss.id = il.reference_id
  WHERE il.entry_type = 'sale'
    AND il.reference_type = 'sale'
  GROUP BY il.reference_id
), totals AS (
  SELECT
    COUNT(*)::integer AS sales_count,
    ROUND(COALESCE(SUM(ss.net_sales), 0), 2) AS net_sales,
    ROUND(COALESCE(SUM(sc.cogs), 0), 2) AS cogs
  FROM scoped_sales ss
  LEFT JOIN sale_costs sc ON sc.sale_id = ss.id
)
SELECT jsonb_build_object(
  'sales_count', sales_count,
  'net_sales', net_sales,
  'cogs', cogs,
  'ratio', CASE WHEN net_sales > 0 THEN ROUND(cogs * 100.0 / net_sales, 2) ELSE 0 END
)
FROM totals;
$$;

REVOKE ALL ON FUNCTION public.get_costing_sales_summary(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_costing_sales_summary(uuid, date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_costing_sales_summary(uuid, date, date) TO authenticated;
