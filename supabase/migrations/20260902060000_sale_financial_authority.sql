-- P2: keep the complete financial sale lifecycle behind process_sale.
-- Direct authenticated DML cannot provide the same pricing, inventory,
-- approval, accounting, and transaction guarantees.

DROP POLICY IF EXISTS auth_insert_sales ON public.sales;
CREATE POLICY auth_insert_sales ON public.sales
  FOR INSERT TO authenticated
  WITH CHECK (false);

DROP POLICY IF EXISTS auth_insert_sale_items ON public.sale_items;
CREATE POLICY auth_insert_sale_items ON public.sale_items
  FOR INSERT TO authenticated
  WITH CHECK (false);

-- The catalog-derived total is authoritative. paid_amount records the amount
-- applied to the invoice, not cash tendered by the customer, so it must never
-- exceed the server-computed total.
DO $do$
DECLARE
  v_src text;
  v_old text := 'v_paid := ROUND(GREATEST(COALESCE(p_paid_amount, 0), 0), 2);';
  v_new text := 'v_paid := ROUND(LEAST(GREATEST(COALESCE(p_paid_amount, 0), 0), v_total), 2);';
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = '_process_sale_core'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION '_process_sale_core target signature not found';
  END IF;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN
      RAISE EXCEPTION '_process_sale_core paid amount assignment changed unexpectedly';
    END IF;
    v_src := replace(v_src, v_old, v_new);
    EXECUTE v_src;
  END IF;
END
$do$;

REVOKE ALL ON FUNCTION public._process_sale_core(
  text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,
  text,text,jsonb,uuid,text,uuid,uuid,integer
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._process_sale_core(
  text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,
  text,text,jsonb,uuid,text,uuid,uuid,integer
) TO service_role;

NOTIFY pgrst, 'reload schema';
