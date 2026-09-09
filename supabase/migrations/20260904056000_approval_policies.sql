-- Branch-aware approval policy registry. Absence of a matching policy keeps
-- the existing permission contract, so rollout cannot lock current approvers.

UPDATE public.roles SET permissions=permissions||'["approvals.policy.manage"]'::jsonb,updated_at=now()
WHERE permissions ? 'settings.manage' AND NOT permissions ? 'approvals.policy.manage';

CREATE TABLE public.approval_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope text NOT NULL,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  min_amount numeric(14,2) CHECK (min_amount IS NULL OR min_amount>=0),
  max_amount numeric(14,2) CHECK (max_amount IS NULL OR max_amount>=0),
  approver_mode text NOT NULL DEFAULT 'permission' CHECK (approver_mode IN ('permission','user','both')),
  approver_permission text,
  approver_user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  priority integer NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (max_amount IS NULL OR min_amount IS NULL OR max_amount>=min_amount),
  CHECK (approver_mode='user' OR approver_permission IS NOT NULL),
  CHECK (approver_mode='permission' OR approver_user_id IS NOT NULL)
);

CREATE INDEX approval_policies_match_idx ON public.approval_policies(scope,branch_id,is_active,priority);
CREATE TRIGGER approval_policies_updated_at BEFORE UPDATE ON public.approval_policies
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.approval_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY approval_policies_select ON public.approval_policies FOR SELECT TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));
CREATE POLICY approval_policies_insert ON public.approval_policies FOR INSERT TO authenticated
WITH CHECK (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)) AND created_by=auth.uid());
CREATE POLICY approval_policies_update ON public.approval_policies FOR UPDATE TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)))
WITH CHECK (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));
CREATE POLICY approval_policies_delete ON public.approval_policies FOR DELETE TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));

REVOKE ALL ON public.approval_policies FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.approval_policies TO authenticated;
GRANT ALL ON public.approval_policies TO service_role,postgres;

CREATE OR REPLACE FUNCTION public.can_approve_by_policy(
  p_scope text,p_branch_id uuid,p_amount numeric,p_fallback_permission text
) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_has_policy boolean; v_allowed boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN RETURN false; END IF;
  SELECT EXISTS(
    SELECT 1 FROM public.approval_policies ap
    WHERE ap.is_active AND ap.scope=p_scope AND (ap.branch_id IS NULL OR ap.branch_id=p_branch_id)
  ) INTO v_has_policy;
  IF NOT v_has_policy THEN RETURN public.can_permission(p_fallback_permission); END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.approval_policies ap
    WHERE ap.is_active AND ap.scope=p_scope AND (ap.branch_id IS NULL OR ap.branch_id=p_branch_id)
      AND (ap.min_amount IS NULL OR COALESCE(p_amount,0)>=ap.min_amount)
      AND (ap.max_amount IS NULL OR COALESCE(p_amount,0)<=ap.max_amount)
      AND (ap.approver_mode='permission' AND public.can_permission(ap.approver_permission)
        OR ap.approver_mode='user' AND ap.approver_user_id=auth.uid()
        OR ap.approver_mode='both' AND ap.approver_user_id=auth.uid() AND public.can_permission(ap.approver_permission))
  ) INTO v_allowed;
  RETURN v_allowed;
END;
$$;

REVOKE ALL ON FUNCTION public.can_approve_by_policy(text,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_approve_by_policy(text,uuid,numeric,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,p_entity_type text,p_entity_id uuid,p_payload jsonb DEFAULT '{}'::jsonb,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_user public.users%ROWTYPE; v_req_id uuid; v_payload jsonb:=COALESCE(p_payload,'{}'::jsonb); v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  IF p_action_type NOT IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift','split_order','merge_order','transfer_order') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_ACTION'); END IF;
  IF p_reason IS NULL OR length(trim(p_reason))<3 THEN RETURN jsonb_build_object('success',false,'error','REASON_REQUIRED'); END IF;

  IF p_entity_type='order' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.orders WHERE id=p_entity_id;
  ELSIF p_entity_type='sale' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.sales WHERE id=p_entity_id;
  ELSIF p_entity_type='shift' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.shifts WHERE id=p_entity_id;
  ELSE
    BEGIN v_branch:=NULLIF(v_payload->>'branch_id','')::uuid; EXCEPTION WHEN OTHERS THEN v_branch:=NULL; END;
  END IF;
  v_branch:=COALESCE(v_branch,v_user.branch_id);
  IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;

  SELECT id INTO v_req_id FROM public.approval_requests
  WHERE requester_id=auth.uid() AND branch_id=v_branch AND action_type=p_action_type AND entity_type=p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id AND payload=v_payload AND status='pending' AND expires_at>now()
  ORDER BY created_at DESC LIMIT 1;
  IF v_req_id IS NOT NULL THEN RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending','duplicate',true); END IF;

  INSERT INTO public.approval_requests(branch_id,requester_id,action_type,entity_type,entity_id,payload,reason)
  VALUES(v_branch,auth.uid(),p_action_type,p_entity_type,p_entity_id,v_payload,trim(p_reason)) RETURNING id INTO v_req_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,'APPROVAL_REQUESTED','approval_request',v_req_id,
    jsonb_build_object('action_type',p_action_type,'entity_type',p_entity_type,'target_id',p_entity_id,'reason',trim(p_reason),'payload',v_payload),v_branch);
  RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending');
END $$;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.decide_manager_approval(p_request_id uuid,p_approve boolean,p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_req public.approval_requests%ROWTYPE; v_user public.users%ROWTYPE; v_status text; v_amount numeric; v_self_override boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  v_amount:=COALESCE(
    CASE WHEN COALESCE(v_req.payload->>'total','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'total')::numeric END,
    CASE WHEN COALESCE(v_req.payload->>'amount','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'amount')::numeric END,
    CASE WHEN COALESCE(v_req.payload->>'discount_amount','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'discount_amount')::numeric END,
    0
  );
  IF NOT public.can_approve_by_policy('manager:'||v_req.action_type,v_req.branch_id,v_amount,'approvals.review') THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED','reason','NOT_AUTHORIZED_BY_POLICY'); END IF;
  IF v_req.requester_id=auth.uid() AND NOT public.can_permission('approvals.override') THEN RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN'); END IF;
  v_self_override:=v_req.requester_id=auth.uid();
  IF v_req.status<>'pending' THEN RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now() WHERE id=v_req.id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,'target_id',v_req.entity_id,'note',p_note),v_req.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status,'self_override',v_self_override);
END $$;

CREATE OR REPLACE FUNCTION public.enforce_approval_policy_transition()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_scope text; v_fallback text; v_amount numeric:=0;
BEGIN
  IF auth.uid() IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('approved','rejected') THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='waste_entries' THEN v_scope:='waste'; v_fallback:='waste.approve'; v_amount:=COALESCE(NEW.total_cost,0);
  ELSIF TG_TABLE_NAME='stock_counts' THEN v_scope:='stock_count'; v_fallback:='inventory.manage';
  ELSIF TG_TABLE_NAME='warehouse_transfers' THEN v_scope:='warehouse_transfer'; v_fallback:='inventory.transfers.approve';
  ELSE RETURN NEW; END IF;
  IF NOT public.can_approve_by_policy(v_scope,NEW.branch_id,v_amount,v_fallback) THEN RAISE EXCEPTION 'APPROVAL_POLICY_DENIED:%',v_scope; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_waste_approval_policy ON public.waste_entries;
CREATE TRIGGER enforce_waste_approval_policy BEFORE UPDATE ON public.waste_entries
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();
DROP TRIGGER IF EXISTS enforce_stock_count_approval_policy ON public.stock_counts;
CREATE TRIGGER enforce_stock_count_approval_policy BEFORE UPDATE ON public.stock_counts
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();
DROP TRIGGER IF EXISTS enforce_transfer_approval_policy ON public.warehouse_transfers;
CREATE TRIGGER enforce_transfer_approval_policy BEFORE UPDATE ON public.warehouse_transfers
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();

REVOKE ALL ON FUNCTION public.enforce_approval_policy_transition() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_approval_policy_transition() TO service_role;
