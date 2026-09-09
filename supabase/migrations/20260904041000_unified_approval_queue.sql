-- Unified, branch-safe queue for records that have real server-side approve/reject actions.

CREATE OR REPLACE FUNCTION public.get_operational_approval_queue(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE(
  source_type text,
  source_id uuid,
  branch_id uuid,
  title text,
  status text,
  requested_by uuid,
  requested_at timestamptz,
  required_permission text,
  payload jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT 'manager_approval', a.id, a.branch_id,
         a.action_type, a.status, a.requester_id, a.created_at,
         'approvals.review',
         jsonb_build_object('entity_type',a.entity_type,'entity_id',a.entity_id,'reason',a.reason,'payload',a.payload)
  FROM public.approval_requests a
  WHERE a.status='pending'
    AND (p_branch_id IS NULL OR a.branch_id=p_branch_id)
    AND public.user_may_access_branch(a.branch_id)

  UNION ALL
  SELECT 'waste', w.id, w.branch_id,
         'waste:'||w.waste_type, w.status, w.created_by, w.created_at,
         'production.waste',
         jsonb_build_object('product_id',w.product_id,'raw_material_id',w.raw_material_id,'inventory_unit_id',w.inventory_unit_id,
                            'quantity',w.quantity,'total_cost',w.total_cost,'reason',w.reason)
  FROM public.waste_entries w
  WHERE w.status='pending'
    AND (p_branch_id IS NULL OR w.branch_id=p_branch_id)
    AND public.user_may_access_branch(w.branch_id)

  UNION ALL
  SELECT 'stock_count', s.id, s.branch_id,
         'stock_count:'||COALESCE(s.count_number,s.id::text), s.status, s.submitted_by, COALESCE(s.submitted_at,s.created_at),
         'inventory.manage',
         jsonb_build_object('warehouse_id',s.warehouse_id,'count_type',s.count_type,'notes',s.notes)
  FROM public.stock_counts s
  WHERE s.status='submitted'
    AND (p_branch_id IS NULL OR s.branch_id=p_branch_id)
    AND public.user_may_access_branch(s.branch_id)

  UNION ALL
  SELECT 'warehouse_transfer', t.id, t.branch_id,
         'transfer:'||COALESCE(t.transfer_number,t.id::text), t.status, t.requested_by, COALESCE(t.requested_at,t.created_at),
         'inventory.transfers.approve',
         jsonb_build_object('from_warehouse_id',t.from_warehouse_id,'to_warehouse_id',t.to_warehouse_id,'reason',t.reason,'notes',t.notes)
  FROM public.warehouse_transfers t
  WHERE t.status IN ('pending','requested','submitted')
    AND (p_branch_id IS NULL OR t.branch_id=p_branch_id)
    AND public.user_may_access_branch(t.branch_id)

  ORDER BY 7 DESC;
$function$;

CREATE OR REPLACE FUNCTION public.decide_operational_approval(
  p_source_type text,
  p_source_id uuid,
  p_approve boolean,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;

  IF p_source_type='manager_approval' THEN
    IF NOT (public.is_pos_admin() OR public.can_permission('approvals.review')) THEN
      RETURN jsonb_build_object('success',false,'error','APPROVAL_REVIEW_DENIED');
    END IF;
    RETURN public.decide_manager_approval(p_source_id,p_approve,p_reason);
  ELSIF p_source_type='waste' THEN
    SELECT branch_id INTO v_branch FROM public.waste_entries WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('production.waste')) THEN
      RETURN jsonb_build_object('success',false,'error','WASTE_APPROVAL_DENIED');
    END IF;
    PERFORM public.approve_waste(p_source_id,p_approve,p_reason);
    RETURN jsonb_build_object('success',true,'source_type','waste','source_id',p_source_id,'status',CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END);
  ELSIF p_source_type='stock_count' THEN
    SELECT branch_id INTO v_branch FROM public.stock_counts WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
      RETURN jsonb_build_object('success',false,'error','STOCK_COUNT_APPROVAL_DENIED');
    END IF;
    IF p_approve THEN RETURN public.approve_stock_count(p_source_id); END IF;
    RETURN public.reject_stock_count(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  ELSIF p_source_type='warehouse_transfer' THEN
    SELECT branch_id INTO v_branch FROM public.warehouse_transfers WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
      RETURN jsonb_build_object('success',false,'error','TRANSFER_APPROVAL_DENIED');
    END IF;
    IF p_approve THEN RETURN public.approve_warehouse_transfer(p_source_id); END IF;
    RETURN public.reject_warehouse_transfer(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  END IF;
  RETURN jsonb_build_object('success',false,'error','UNSUPPORTED_APPROVAL_SOURCE');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_operational_approval_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) TO authenticated;
