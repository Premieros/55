-- Cashier hardening + manager approval control center.
-- Mirrors the production hardening already applied on 2026-09-01.

CREATE TABLE IF NOT EXISTS public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  requester_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  action_type text NOT NULL CHECK (action_type IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift')),
  entity_type text NOT NULL,
  entity_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text NOT NULL CHECK (length(trim(reason)) >= 3),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired','consumed')),
  approver_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '10 minutes'),
  consumed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_approval_requests_branch_status_created ON public.approval_requests(branch_id,status,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_approval_requests_requester_status ON public.approval_requests(requester_id,status,created_at DESC);
ALTER TABLE public.approval_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS approval_requests_select ON public.approval_requests;
CREATE POLICY approval_requests_select ON public.approval_requests FOR SELECT TO authenticated
USING (requester_id = auth.uid() OR (user_may_access_branch(branch_id) AND (is_pos_admin() OR can_permission('approvals.review'))));
DROP POLICY IF EXISTS approval_requests_insert ON public.approval_requests;
CREATE POLICY approval_requests_insert ON public.approval_requests FOR INSERT TO authenticated
WITH CHECK (requester_id=auth.uid() AND user_may_access_branch(branch_id));
DROP POLICY IF EXISTS approval_requests_no_direct_update ON public.approval_requests;
CREATE POLICY approval_requests_no_direct_update ON public.approval_requests FOR UPDATE TO authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS approval_requests_no_delete ON public.approval_requests;
CREATE POLICY approval_requests_no_delete ON public.approval_requests FOR DELETE TO authenticated USING(false);

UPDATE public.roles SET permissions=COALESCE(permissions,'[]'::jsonb)-'pos.reprint',updated_at=now() WHERE role='cashier';
UPDATE public.roles SET permissions=CASE WHEN COALESCE(permissions,'[]'::jsonb)?'approvals.review' THEN permissions ELSE COALESCE(permissions,'[]'::jsonb)||'["approvals.review"]'::jsonb END,updated_at=now()
WHERE role IN ('branch_manager','owner','super_admin');

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,p_entity_type text,p_entity_id uuid,p_payload jsonb DEFAULT '{}'::jsonb,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_user public.users%ROWTYPE; v_req_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  IF p_action_type NOT IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift') THEN RETURN jsonb_build_object('success',false,'error','INVALID_ACTION'); END IF;
  IF p_reason IS NULL OR length(trim(p_reason))<3 THEN RETURN jsonb_build_object('success',false,'error','REASON_REQUIRED'); END IF;
  SELECT id INTO v_req_id FROM public.approval_requests
  WHERE requester_id=auth.uid() AND branch_id=v_user.branch_id AND action_type=p_action_type AND entity_type=p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id AND status='pending' AND expires_at>now()
  ORDER BY created_at DESC LIMIT 1;
  IF v_req_id IS NOT NULL THEN RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending','duplicate',true); END IF;
  INSERT INTO public.approval_requests(branch_id,requester_id,action_type,entity_type,entity_id,payload,reason)
  VALUES(v_user.branch_id,auth.uid(),p_action_type,p_entity_type,p_entity_id,COALESCE(p_payload,'{}'::jsonb),trim(p_reason))
  RETURNING id INTO v_req_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,'APPROVAL_REQUESTED','approval_request',v_req_id,
    jsonb_build_object('action_type',p_action_type,'entity_type',p_entity_type,'target_id',p_entity_id,'reason',trim(p_reason),'payload',COALESCE(p_payload,'{}'::jsonb)),v_user.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending');
END $$;

CREATE OR REPLACE FUNCTION public.decide_manager_approval(p_request_id uuid,p_approve boolean,p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req public.approval_requests%ROWTYPE; v_user public.users%ROWTYPE; v_status text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF NOT user_may_access_branch(v_req.branch_id) OR NOT (is_pos_admin() OR can_permission('approvals.review')) THEN RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED'); END IF;
  IF v_req.requester_id=auth.uid() THEN RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN'); END IF;
  IF v_req.status<>'pending' THEN RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now() WHERE id=v_req.id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,'target_id',v_req.entity_id,'note',p_note),v_req.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status);
END $$;

CREATE OR REPLACE FUNCTION public.consume_manager_approval(p_request_id uuid,p_action_type text,p_entity_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req public.approval_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF v_req.requester_id<>auth.uid() THEN RETURN jsonb_build_object('success',false,'error','REQUESTER_MISMATCH'); END IF;
  IF v_req.action_type<>p_action_type OR v_req.entity_id IS DISTINCT FROM p_entity_id THEN RETURN jsonb_build_object('success',false,'error','REQUEST_SCOPE_MISMATCH'); END IF;
  IF v_req.status<>'approved' THEN RETURN jsonb_build_object('success',false,'error','APPROVAL_REQUIRED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=COALESCE(decided_at,now()) WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req.id;
  RETURN jsonb_build_object('success',true,'payload',v_req.payload,'approver_id',v_req.approver_id);
END $$;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_manager_approval(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.decide_manager_approval(uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.consume_manager_approval(uuid,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.consume_manager_approval(uuid,text,uuid) TO authenticated;

DROP POLICY IF EXISTS auth_update_sales ON public.sales;
CREATE POLICY auth_update_sales ON public.sales FOR UPDATE TO authenticated
USING((is_pos_admin() OR can_permission('sales.manage')) AND user_may_access_branch(branch_id))
WITH CHECK((is_pos_admin() OR can_permission('sales.manage')) AND user_may_access_branch(branch_id));
DROP POLICY IF EXISTS auth_delete_sale_items ON public.sale_items;
CREATE POLICY auth_delete_sale_items ON public.sale_items FOR DELETE TO authenticated USING(false);
DROP POLICY IF EXISTS auth_update_sale_items ON public.sale_items;
CREATE POLICY auth_update_sale_items ON public.sale_items FOR UPDATE TO authenticated USING(false) WITH CHECK(false);

DO $$
BEGIN
  IF to_regprocedure('public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)') IS NULL
     AND to_regprocedure('public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)') IS NOT NULL THEN
    ALTER FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) RENAME TO _process_sale_core;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,p_branch_id uuid,p_warehouse_id uuid,p_customer_id uuid,p_salesperson_id uuid,
  p_subtotal numeric,p_discount_amount numeric,p_discount_type text,p_tax_amount numeric,p_bonus_amount numeric,
  p_total numeric,p_paid_amount numeric,p_payment_method text,p_status text,p_items jsonb,p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',p_table_id uuid DEFAULT NULL,p_order_id uuid DEFAULT NULL,p_guest_count integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req_id uuid; v_result jsonb; v_email text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF COALESCE(p_discount_amount,0)>0 AND NOT can_permission('pos.discount') THEN
    SELECT id INTO v_req_id FROM public.approval_requests
    WHERE requester_id=auth.uid() AND branch_id=p_branch_id AND action_type='discount' AND status='approved' AND expires_at>now()
      AND (entity_id IS NULL OR entity_id IS NOT DISTINCT FROM p_order_id)
      AND COALESCE(payload->>'discount_type','amount')=COALESCE(p_discount_type,'amount')
      AND abs(COALESCE((payload->>'discount_amount')::numeric,-1)-p_discount_amount)<0.0001
      AND abs(COALESCE((payload->>'subtotal')::numeric,-1)-p_subtotal)<0.0001
    ORDER BY decided_at DESC NULLS LAST,created_at DESC LIMIT 1 FOR UPDATE;
    IF v_req_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req_id;
    SELECT email INTO v_email FROM public.users WHERE id=auth.uid();
    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),v_email,'APPROVAL_CONSUMED','approval_request',v_req_id,
      jsonb_build_object('action_type','discount','discount_amount',p_discount_amount,'discount_type',p_discount_type,'subtotal',p_subtotal,'order_id',p_order_id),p_branch_id);
  END IF;
  v_result:=public._process_sale_core(p_invoice_number,p_branch_id,p_warehouse_id,p_customer_id,p_salesperson_id,p_subtotal,p_discount_amount,p_discount_type,p_tax_amount,p_bonus_amount,p_total,p_paid_amount,p_payment_method,p_status,p_items,p_shift_id,p_order_type,p_table_id,p_order_id,p_guest_count);
  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated,service_role;

CREATE TABLE IF NOT EXISTS public.sale_print_events(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  print_number integer NOT NULL CHECK(print_number>0),
  approval_request_id uuid REFERENCES public.approval_requests(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(sale_id,print_number)
);
ALTER TABLE public.sale_print_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sale_print_events_select ON public.sale_print_events;
CREATE POLICY sale_print_events_select ON public.sale_print_events FOR SELECT TO authenticated USING(user_may_access_branch(branch_id));
DROP POLICY IF EXISTS sale_print_events_no_direct_insert ON public.sale_print_events;
CREATE POLICY sale_print_events_no_direct_insert ON public.sale_print_events FOR INSERT TO authenticated WITH CHECK(false);
DROP POLICY IF EXISTS sale_print_events_no_update ON public.sale_print_events;
CREATE POLICY sale_print_events_no_update ON public.sale_print_events FOR UPDATE TO authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS sale_print_events_no_delete ON public.sale_print_events;
CREATE POLICY sale_print_events_no_delete ON public.sale_print_events FOR DELETE TO authenticated USING(false);

CREATE OR REPLACE FUNCTION public.authorize_sale_print(p_sale_id uuid,p_approval_request_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_sale public.sales%ROWTYPE; v_user public.users%ROWTYPE; v_count integer; v_req public.approval_requests%ROWTYPE; v_event_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_sale FROM public.sales WHERE id=p_sale_id;
  IF v_sale.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','SALE_NOT_FOUND'); END IF;
  IF NOT user_may_access_branch(v_sale.branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
  SELECT count(*)::int INTO v_count FROM public.sale_print_events WHERE sale_id=p_sale_id;
  IF v_count>0 AND NOT can_permission('pos.reprint') THEN
    IF p_approval_request_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','reprint'); END IF;
    SELECT * INTO v_req FROM public.approval_requests WHERE id=p_approval_request_id FOR UPDATE;
    IF v_req.id IS NULL OR v_req.requester_id<>auth.uid() OR v_req.branch_id<>v_sale.branch_id OR v_req.action_type<>'reprint' OR v_req.entity_id IS DISTINCT FROM p_sale_id OR v_req.status<>'approved' OR v_req.expires_at<=now() THEN RETURN jsonb_build_object('success',false,'error','INVALID_APPROVAL'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req.id;
  END IF;
  INSERT INTO public.sale_print_events(sale_id,branch_id,user_id,print_number,approval_request_id)
  VALUES(p_sale_id,v_sale.branch_id,auth.uid(),v_count+1,CASE WHEN v_count>0 THEN p_approval_request_id ELSE NULL END)
  RETURNING id INTO v_event_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN v_count=0 THEN 'SALE_PRINTED' ELSE 'SALE_REPRINTED' END,'sale',p_sale_id,
    jsonb_build_object('print_number',v_count+1,'approval_request_id',p_approval_request_id),v_sale.branch_id);
  RETURN jsonb_build_object('success',true,'event_id',v_event_id,'print_number',v_count+1,'is_reprint',(v_count>0));
END $$;

REVOKE ALL ON FUNCTION public.authorize_sale_print(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.authorize_sale_print(uuid,uuid) TO authenticated,service_role;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.approval_requests;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_object THEN NULL; END $$;
