-- Operations / approvals / reporting hardening requested for multi-branch users.
-- Reuse user_branch_access as the canonical multi-branch grant; do not weaken branch RLS.

-- Every active operational role may enter POS and create an order. Sensitive POS actions
-- remain separately permission-gated.
UPDATE public.roles
SET permissions = CASE
  WHEN permissions ? 'pos.sell' THEN permissions
  ELSE permissions || '["pos.sell"]'::jsonb
END,
updated_at = now()
WHERE is_active = true;

-- Managers may review approvals. Override is explicit and is not a global-admin shortcut.
UPDATE public.roles
SET permissions = permissions || '["approvals.review","approvals.override","shifts.open","shifts.close","shifts.view"]'::jsonb,
    updated_at = now()
WHERE role = 'branch_manager' AND is_active = true;

-- Opening a shift is permission-based and branch-access based, not hard-coded to cashier.
CREATE OR REPLACE FUNCTION public.open_shift(
  p_branch_id uuid,
  p_opening_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id=v_uid AND is_active=true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('shifts.open')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_ALLOWED');
  END IF;
  IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  -- One normal open shift per user. A multi-branch user selects which authorized branch
  -- the shift belongs to; financial ownership stays branch-safe.
  IF EXISTS (SELECT 1 FROM public.shifts WHERE cashier_id=v_uid AND status='open') THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_ALREADY_OPEN');
  END IF;

  INSERT INTO public.shifts(branch_id,cashier_id,opening_amount,notes)
  VALUES(p_branch_id,v_uid,COALESCE(p_opening_amount,0),p_notes)
  RETURNING id INTO v_shift_id;

  INSERT INTO public.shift_operations(shift_id,operation_type,amount,payment_method,reference_type,created_by)
  VALUES(v_shift_id,'opening',COALESCE(p_opening_amount,0),'cash','shift_opening',v_uid);

  RETURN jsonb_build_object('success',true,'shift_id',v_shift_id,'branch_id',p_branch_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','UNKNOWN_ERROR','detail',SQLERRM);
END;
$function$;

-- Explicitly-authorized approvers may approve their own action request. This implements
-- manager self-bypass without turning branch_manager into global admin.
CREATE OR REPLACE FUNCTION public.decide_manager_approval(
  p_request_id uuid,
  p_approve boolean,
  p_note text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_req public.approval_requests%ROWTYPE;
  v_user public.users%ROWTYPE;
  v_status text;
  v_self_override boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;

  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_req.branch_id)
     OR NOT (public.is_pos_admin() OR public.can_permission('approvals.review')) THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED');
  END IF;
  v_self_override := v_req.requester_id=auth.uid() AND (public.is_pos_admin() OR public.can_permission('approvals.override'));
  IF v_req.requester_id=auth.uid() AND NOT v_self_override THEN
    RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN');
  END IF;
  IF v_req.status<>'pending' THEN
    RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status);
  END IF;
  IF v_req.expires_at<=now() THEN
    UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id;
    RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED');
  END IF;

  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests
  SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now()
  WHERE id=v_req.id;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,
    'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,
      'entity_type',v_req.entity_type,'target_id',v_req.entity_id,'note',p_note,'self_override',v_self_override),
    v_req.branch_id);

  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status,'self_override',v_self_override);
END;
$function$;

-- One user closing report, independent of the shift summary.
CREATE OR REPLACE FUNCTION public.get_user_closing_report(
  p_user_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF p_user_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'INVALID_REPORT_RANGE';
  END IF;
  IF p_branch_id IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  SELECT jsonb_build_object(
    'user_id',p_user_id,
    'from',p_from,'to',p_to,
    'invoice_count',COUNT(*),
    'gross_sales',COALESCE(SUM(s.subtotal),0),
    'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),
    'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0),
    'branches',COALESCE(jsonb_agg(DISTINCT s.branch_id) FILTER (WHERE s.branch_id IS NOT NULL),'[]'::jsonb)
  ) INTO v_result
  FROM public.sales s
  WHERE (s.cashier_id=p_user_id OR s.salesperson_id=p_user_id)
    AND s.created_at>=p_from AND s.created_at<p_to
    AND (p_branch_id IS NULL OR s.branch_id=p_branch_id)
    AND public.user_may_access_branch(s.branch_id);
  RETURN COALESCE(v_result,'{}'::jsonb);
END;
$function$;

-- Shift financial report derives sales by branch+cashier+time window because sales has no shift_id.
CREATE OR REPLACE FUNCTION public.get_shift_closing_report(p_shift_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_shift public.shifts%ROWTYPE; v_result jsonb;
BEGIN
  SELECT * INTO v_shift FROM public.shifts WHERE id=p_shift_id;
  IF v_shift.id IS NULL THEN RAISE EXCEPTION 'SHIFT_NOT_FOUND'; END IF;
  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;

  SELECT jsonb_build_object(
    'shift_id',v_shift.id,'branch_id',v_shift.branch_id,'cashier_id',v_shift.cashier_id,
    'opened_at',v_shift.opened_at,'closed_at',v_shift.closed_at,
    'opening_amount',v_shift.opening_amount,'expected_amount',v_shift.expected_amount,
    'actual_amount',v_shift.actual_amount,'difference',v_shift.difference,
    'invoice_count',COUNT(s.id),
    'gross_sales',COALESCE(SUM(s.subtotal),0),'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0)
  ) INTO v_result
  FROM public.sales s
  WHERE s.branch_id=v_shift.branch_id
    AND s.cashier_id=v_shift.cashier_id
    AND s.created_at>=v_shift.opened_at
    AND s.created_at<COALESCE(v_shift.closed_at,now());
  RETURN v_result;
END;
$function$;

-- End-of-day summary includes every shift overlapping that business day, not only the active shift.
CREATE OR REPLACE FUNCTION public.get_day_closing_report(p_branch_id uuid,p_day date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_start timestamptz:=p_day::timestamptz; v_finish timestamptz:=(p_day+1)::timestamptz; v_result jsonb;
BEGIN
  IF NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  SELECT jsonb_build_object(
    'branch_id',p_branch_id,'day',p_day,
    'shift_count',(SELECT COUNT(*) FROM public.shifts sh WHERE sh.branch_id=p_branch_id AND sh.opened_at<v_finish AND COALESCE(sh.closed_at,now())>=v_start),
    'closed_shift_count',(SELECT COUNT(*) FROM public.shifts sh WHERE sh.branch_id=p_branch_id AND sh.status='closed' AND sh.opened_at<v_finish AND COALESCE(sh.closed_at,now())>=v_start),
    'user_count',COUNT(DISTINCT s.cashier_id),
    'invoice_count',COUNT(s.id),
    'gross_sales',COALESCE(SUM(s.subtotal),0),'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0)
  ) INTO v_result
  FROM public.sales s
  WHERE s.branch_id=p_branch_id AND s.created_at>=v_start AND s.created_at<v_finish;
  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_user_closing_report(uuid,timestamptz,timestamptz,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_shift_closing_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_day_closing_report(uuid,date) TO authenticated;
