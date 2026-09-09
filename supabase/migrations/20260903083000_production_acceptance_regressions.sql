-- Fix regressions proven by the real Production acceptance branch on 2026-09-03.

-- 1) Floor-plan managers must be able to manage dining areas in their branch.
DROP POLICY IF EXISTS auth_insert_dining_areas ON public.dining_areas;
CREATE POLICY auth_insert_dining_areas ON public.dining_areas
FOR INSERT TO authenticated
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_update_dining_areas ON public.dining_areas;
CREATE POLICY auth_update_dining_areas ON public.dining_areas
FOR UPDATE TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
);

-- 2) Direct table reads must honor the same permission model as navigation/UI.
DROP POLICY IF EXISTS auth_select_products ON public.products;
CREATE POLICY auth_select_products ON public.products
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('products.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_purchases ON public.purchases;
CREATE POLICY auth_select_purchases ON public.purchases
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('purchases.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_sales ON public.sales;
CREATE POLICY auth_select_sales ON public.sales
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('sales.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_users ON public.users;
CREATE POLICY auth_select_users ON public.users
FOR SELECT TO authenticated
USING (
  id = auth.uid()
  OR public.is_platform_admin()
  OR (public.can_permission('users.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_audit_log ON public.audit_log;
CREATE POLICY auth_select_audit_log ON public.audit_log
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('audit.view') AND public.user_may_access_branch(branch_id))
);

-- 3) The paid state of a linked order must follow the authoritative sale row.
-- Keep the existing process_sale validation/pricing flow and only synchronize
-- the linked order after the core transaction succeeds.
CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_customer_id uuid,
  p_salesperson_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_discount_type text,
  p_tax_amount numeric,
  p_bonus_amount numeric,
  p_total numeric,
  p_paid_amount numeric,
  p_payment_method text,
  p_status text,
  p_items jsonb,
  p_shift_id uuid DEFAULT NULL::uuid,
  p_order_type text DEFAULT 'takeaway'::text,
  p_table_id uuid DEFAULT NULL::uuid,
  p_order_id uuid DEFAULT NULL::uuid,
  p_guest_count integer DEFAULT NULL::integer
)
RETURNS jsonb
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
  v_mod jsonb;
  v_line_discount numeric;
  v_server_subtotal numeric(14,2) := 0;
  v_sale_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',false,'error','EMPTY_CART'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := NULLIF(v_item->>'product_id','')::uuid;
    v_qty := COALESCE((v_item->>'quantity')::numeric,0);
    IF v_product_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','INVALID_PRODUCT'); END IF;
    IF v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY'); END IF;
    SELECT sale_price INTO v_price FROM public.products
    WHERE id=v_product_id AND branch_id=p_branch_id AND is_active=true;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;
    v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->'modifier_option_ids','[]'::jsonb));
    IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;
    v_price := GREATEST(COALESCE(v_price,0)+COALESCE((v_mod->>'price_delta')::numeric,0),0);
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

  IF p_order_id IS NOT NULL AND COALESCE((v_result->>'success')::boolean,false) IS TRUE THEN
    v_sale_id := NULLIF(v_result->>'sale_id','')::uuid;
    UPDATE public.orders o
    SET payment_status = CASE
          WHEN s.total > 0 AND s.paid_amount >= s.total THEN 'paid'
          WHEN s.paid_amount > 0 THEN 'partial'
          ELSE 'unpaid'
        END,
        payment_at = CASE WHEN s.paid_amount > 0 THEN now() ELSE NULL END,
        updated_at = now()
    FROM public.sales s
    WHERE o.id = p_order_id
      AND o.branch_id = p_branch_id
      AND s.id = v_sale_id;
  END IF;

  RETURN v_result;
END;
$$;
