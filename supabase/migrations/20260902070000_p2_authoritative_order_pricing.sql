-- P2 closure: make order staging and sale approval server-authoritative.

CREATE OR REPLACE FUNCTION public._effective_branch_tax(p_branch_id uuid)
RETURNS TABLE(tax_enabled boolean, tax_rate numeric)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT
    COALESCE(
      (SELECT bs.tax_enabled FROM public.branch_settings bs WHERE bs.branch_id = p_branch_id),
      (SELECT s.tax_enabled FROM public.settings s ORDER BY s.created_at NULLS LAST LIMIT 1),
      false
    ),
    COALESCE(
      (SELECT bs.tax_rate FROM public.branch_settings bs WHERE bs.branch_id = p_branch_id),
      (SELECT s.tax_rate FROM public.settings s ORDER BY s.created_at NULLS LAST LIMIT 1),
      0
    );
$$;

CREATE OR REPLACE FUNCTION public._reprice_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_price numeric;
BEGIN
  SELECT branch_id INTO v_branch_id FROM public.orders WHERE id = NEW.order_id;
  IF v_branch_id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  SELECT sale_price INTO v_price
  FROM public.products
  WHERE id = NEW.product_id AND branch_id = v_branch_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH'; END IF;
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;

  NEW.unit_price := ROUND(COALESCE(v_price, 0), 2);
  NEW.discount_amount := ROUND(
    LEAST(GREATEST(COALESCE(NEW.discount_amount, 0), 0), NEW.quantity * NEW.unit_price), 2
  );
  NEW.bonus_quantity := GREATEST(COALESCE(NEW.bonus_quantity, 0), 0);
  NEW.total := ROUND(NEW.quantity * NEW.unit_price - NEW.discount_amount, 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_authoritative_price ON public.order_items;
CREATE TRIGGER trg_order_items_authoritative_price
BEFORE INSERT OR UPDATE OF product_id, quantity, unit_price, discount_amount, bonus_quantity, total
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._reprice_order_item();

CREATE OR REPLACE FUNCTION public._sync_order_totals_from_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_branch_id uuid;
  v_subtotal numeric(14,2);
  v_discount numeric(14,2);
  v_tax_enabled boolean;
  v_tax_rate numeric;
  v_tax numeric(14,2);
  v_total numeric(14,2);
BEGIN
  v_order_id := COALESCE(NEW.order_id, OLD.order_id);
  SELECT branch_id, GREATEST(COALESCE(discount_amount, 0), 0)
  INTO v_branch_id, v_discount
  FROM public.orders WHERE id = v_order_id;
  IF v_branch_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

  SELECT ROUND(COALESCE(SUM(total), 0), 2)
  INTO v_subtotal
  FROM public.order_items WHERE order_id = v_order_id;

  v_discount := LEAST(v_discount, v_subtotal);
  SELECT t.tax_enabled, t.tax_rate INTO v_tax_enabled, v_tax_rate
  FROM public._effective_branch_tax(v_branch_id) t;
  v_tax := CASE WHEN COALESCE(v_tax_enabled, false)
    THEN ROUND((v_subtotal - v_discount) * COALESCE(v_tax_rate, 0) / 100, 2)
    ELSE 0 END;
  v_total := ROUND(v_subtotal - v_discount + v_tax, 2);

  UPDATE public.orders
  SET subtotal = v_subtotal,
      discount_amount = v_discount,
      tax_amount = v_tax,
      total = v_total,
      updated_at = now()
  WHERE id = v_order_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_sync_totals ON public.order_items;
CREATE TRIGGER trg_order_items_sync_totals
AFTER INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._sync_order_totals_from_items();

DO $do$
DECLARE
  v_src text;
  v_old text := $old$    SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0) INTO v_tax_enabled, v_tax_rate
    FROM public.settings LIMIT 1;$old$;
  v_new text := $new$    SELECT t.tax_enabled, t.tax_rate INTO v_tax_enabled, v_tax_rate
    FROM public._effective_branch_tax(p_branch_id) t;$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='_process_sale_core'
    AND pg_get_function_identity_arguments(p.oid)=
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';
  IF v_src IS NULL THEN RAISE EXCEPTION '_process_sale_core target not found'; END IF;
  IF position(v_new IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION '_process_sale_core tax block changed unexpectedly'; END IF;
    EXECUTE replace(v_src,v_old,v_new);
  END IF;
END
$do$;

CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,p_branch_id uuid,p_warehouse_id uuid,p_customer_id uuid,p_salesperson_id uuid,
  p_subtotal numeric,p_discount_amount numeric,p_discount_type text,p_tax_amount numeric,p_bonus_amount numeric,
  p_total numeric,p_paid_amount numeric,p_payment_method text,p_status text,p_items jsonb,p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',p_table_id uuid DEFAULT NULL,p_order_id uuid DEFAULT NULL,p_guest_count integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_req_id uuid;
  v_result jsonb;
  v_email text;
  v_item jsonb;
  v_product_id uuid;
  v_qty numeric;
  v_price numeric;
  v_line_discount numeric;
  v_server_subtotal numeric(14,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',false,'error','EMPTY_CART'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := NULLIF(v_item->>'product_id','')::uuid;
    v_qty := COALESCE((v_item->>'quantity')::numeric,0);
    IF v_product_id IS NULL OR v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT'); END IF;
    SELECT sale_price INTO v_price FROM public.products
    WHERE id=v_product_id AND branch_id=p_branch_id AND is_active=true;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;
    v_price := COALESCE(v_price,0);
    v_line_discount := ROUND(LEAST(GREATEST(COALESCE((v_item->>'discount_amount')::numeric,0),0),v_qty*v_price),2);
    IF v_line_discount > 0 AND NOT can_permission('pos.discount') THEN
      RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount','scope','line');
    END IF;
    v_server_subtotal := v_server_subtotal + ROUND(v_qty*v_price-v_line_discount,2);
  END LOOP;
  v_server_subtotal := ROUND(v_server_subtotal,2);

  IF COALESCE(p_discount_amount,0)>0 AND NOT can_permission('pos.discount') THEN
    SELECT id INTO v_req_id FROM public.approval_requests
    WHERE requester_id=auth.uid() AND branch_id=p_branch_id AND action_type='discount'
      AND status='approved' AND expires_at>now()
      AND (entity_id IS NULL OR entity_id IS NOT DISTINCT FROM p_order_id)
      AND COALESCE(payload->>'discount_type','amount')=COALESCE(p_discount_type,'amount')
      AND abs(COALESCE((payload->>'discount_amount')::numeric,-1)-p_discount_amount)<0.0001
      AND abs(COALESCE((payload->>'subtotal')::numeric,-1)-v_server_subtotal)<0.0001
    ORDER BY decided_at DESC NULLS LAST,created_at DESC LIMIT 1 FOR UPDATE;
    IF v_req_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req_id;
    SELECT email INTO v_email FROM public.users WHERE id=auth.uid();
    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),v_email,'APPROVAL_CONSUMED','approval_request',v_req_id,
      jsonb_build_object('action_type','discount','discount_amount',p_discount_amount,'discount_type',p_discount_type,
        'server_subtotal',v_server_subtotal,'order_id',p_order_id),p_branch_id);
  END IF;

  v_result:=public._process_sale_core(
    p_invoice_number,p_branch_id,p_warehouse_id,p_customer_id,p_salesperson_id,
    v_server_subtotal,p_discount_amount,p_discount_type,0,p_bonus_amount,0,p_paid_amount,
    p_payment_method,p_status,p_items,p_shift_id,p_order_type,p_table_id,p_order_id,p_guest_count);
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public._reprice_order_item() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._sync_order_totals_from_items() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._effective_branch_tax(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public._effective_branch_tax(uuid) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated,service_role;

NOTIFY pgrst, 'reload schema';
