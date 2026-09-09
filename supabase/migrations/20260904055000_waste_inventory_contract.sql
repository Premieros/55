-- Waste contract: exact target + exact warehouse + approval-time deduction.

UPDATE public.roles
SET permissions = permissions || '["waste.view","waste.create","waste.approve","waste.report"]'::jsonb,
    updated_at = now()
WHERE permissions ? 'production.waste';

UPDATE public.roles r
SET permissions = (
  SELECT jsonb_agg(value ORDER BY value)
  FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(r.permissions)) p
), updated_at = now();

DROP POLICY IF EXISTS we_admin_all ON public.waste_entries;
DROP POLICY IF EXISTS we_branch_read ON public.waste_entries;
DROP POLICY IF EXISTS waste_entries_select ON public.waste_entries;
CREATE POLICY waste_entries_select ON public.waste_entries
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id) AND public.can_permission('waste.view'));

REVOKE INSERT, UPDATE, DELETE ON public.waste_entries FROM authenticated;
GRANT ALL ON public.waste_entries TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.create_waste_entry(
  p_branch_id uuid,
  p_waste_category_id uuid,
  p_waste_type text,
  p_quantity numeric,
  p_unit_cost numeric,
  p_reason text DEFAULT NULL,
  p_raw_material_id uuid DEFAULT NULL,
  p_inventory_unit_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
  v_target_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.create') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.create'; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  IF p_waste_type NOT IN ('raw_material','finished_good','production','expired','damaged') THEN RAISE EXCEPTION 'INVALID_WASTE_TYPE'; END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_WASTE_QUANTITY'; END IF;
  IF p_warehouse_id IS NULL THEN RAISE EXCEPTION 'WAREHOUSE_REQUIRED'; END IF;
  IF p_raw_material_id IS NOT NULL THEN RAISE EXCEPTION 'RAW_MATERIAL_TARGET_DEPRECATED:use_inventory_unit'; END IF;
  IF (p_product_id IS NULL) = (p_inventory_unit_id IS NULL) THEN RAISE EXCEPTION 'EXACTLY_ONE_WASTE_TARGET_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id=p_warehouse_id AND w.branch_id=p_branch_id AND w.is_active=true) THEN
    RAISE EXCEPTION 'WAREHOUSE_BRANCH_MISMATCH';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.waste_categories c WHERE c.id=p_waste_category_id AND c.is_active=true) THEN
    RAISE EXCEPTION 'WASTE_CATEGORY_NOT_FOUND';
  END IF;

  IF p_product_id IS NOT NULL THEN
    SELECT branch_id INTO v_target_branch FROM public.products WHERE id=p_product_id AND is_active=true;
  ELSE
    SELECT branch_id INTO v_target_branch FROM public.inventory_units WHERE id=p_inventory_unit_id AND is_active=true;
  END IF;
  IF NOT FOUND OR (v_target_branch IS NOT NULL AND v_target_branch<>p_branch_id) THEN RAISE EXCEPTION 'WASTE_TARGET_BRANCH_MISMATCH'; END IF;

  INSERT INTO public.waste_entries(
    id,branch_id,waste_category_id,waste_type,inventory_unit_id,product_id,
    quantity,unit_cost,reason,warehouse_id,employee_id,created_by,status
  ) VALUES (
    v_id,p_branch_id,p_waste_category_id,p_waste_type,p_inventory_unit_id,p_product_id,
    p_quantity,GREATEST(COALESCE(p_unit_cost,0),0),NULLIF(trim(p_reason),''),p_warehouse_id,
    p_employee_id,auth.uid(),'pending'
  );

  INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),'create','waste_entry',v_id,
    jsonb_build_object('waste_type',p_waste_type,'quantity',p_quantity,'warehouse_id',p_warehouse_id,
      'product_id',p_product_id,'inventory_unit_id',p_inventory_unit_id),p_branch_id);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_waste(
  p_waste_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_entry public.waste_entries%ROWTYPE;
  v_inventory public.inventory%ROWTYPE;
  v_available numeric(14,4);
  v_remaining numeric(14,4);
  v_take numeric(14,4);
  v_batch record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.approve') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.approve'; END IF;

  SELECT * INTO v_entry FROM public.waste_entries WHERE id=p_waste_id FOR UPDATE;
  IF v_entry.id IS NULL THEN RAISE EXCEPTION 'WASTE_NOT_FOUND'; END IF;
  IF NOT public.user_may_access_branch(v_entry.branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  IF v_entry.status<>'pending' THEN RAISE EXCEPTION 'WASTE_NOT_PENDING'; END IF;
  IF v_entry.warehouse_id IS NULL THEN RAISE EXCEPTION 'WAREHOUSE_REQUIRED'; END IF;
  IF (v_entry.product_id IS NULL)=(v_entry.inventory_unit_id IS NULL) THEN RAISE EXCEPTION 'INVALID_WASTE_TARGET'; END IF;

  IF NOT p_approve THEN
    UPDATE public.waste_entries SET status='rejected',rejection_reason=p_rejection_reason,
      approved_by=auth.uid(),approved_at=now(),updated_at=now() WHERE id=p_waste_id;
    INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),'reject','waste_entry',p_waste_id,jsonb_build_object('status','rejected','reason',p_rejection_reason),v_entry.branch_id);
    RETURN;
  END IF;

  IF v_entry.product_id IS NOT NULL THEN
    SELECT * INTO v_inventory FROM public.inventory
    WHERE product_id=v_entry.product_id AND warehouse_id=v_entry.warehouse_id FOR UPDATE;
    IF v_inventory.id IS NULL OR v_inventory.quantity<v_entry.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK:product:%:available:%:required:%',v_entry.product_id,COALESCE(v_inventory.quantity,0),v_entry.quantity;
    END IF;
    v_available:=v_inventory.quantity;
    UPDATE public.inventory SET quantity=quantity-v_entry.quantity,updated_at=now() WHERE id=v_inventory.id;

    v_remaining:=v_entry.quantity;
    FOR v_batch IN SELECT id,quantity FROM public.inventory_batches
      WHERE product_id=v_entry.product_id AND warehouse_id=v_entry.warehouse_id AND quantity>0
      ORDER BY expiry_date NULLS LAST,created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.quantity);
      UPDATE public.inventory_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      v_remaining:=v_remaining-v_take;
    END LOOP;

    INSERT INTO public.inventory_ledger(product_id,branch_id,warehouse_id,quantity,unit_cost,total_cost,
      before_qty,after_qty,entry_type,reference_type,reference_id,reference_number,created_by)
    VALUES(v_entry.product_id,v_entry.branch_id,v_entry.warehouse_id,-v_entry.quantity,v_entry.unit_cost,
      -(v_entry.quantity*v_entry.unit_cost),v_available,v_available-v_entry.quantity,'waste','waste',p_waste_id,
      'WASTE-'||left(p_waste_id::text,8),auth.uid());
    INSERT INTO public.inventory_movements(product_id,warehouse_id,movement_type,quantity,reference_id,notes,branch_id)
    VALUES(v_entry.product_id,v_entry.warehouse_id,'waste',-v_entry.quantity,p_waste_id,v_entry.reason,v_entry.branch_id);
  ELSE
    PERFORM 1 FROM public.inventory_unit_batches
    WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id FOR UPDATE;
    SELECT COALESCE(sum(quantity),0) INTO v_available FROM public.inventory_unit_batches
    WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id;
    IF v_available<v_entry.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK:inventory_unit:%:available:%:required:%',v_entry.inventory_unit_id,v_available,v_entry.quantity;
    END IF;
    v_remaining:=v_entry.quantity;
    FOR v_batch IN SELECT id,quantity FROM public.inventory_unit_batches
      WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id AND quantity>0
      ORDER BY expiry_date NULLS LAST,created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      v_remaining:=v_remaining-v_take;
    END LOOP;
    INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,
      reference_type,reference_id,reference_number,created_by)
    VALUES(v_entry.inventory_unit_id,v_entry.branch_id,v_entry.warehouse_id,-v_entry.quantity,v_entry.unit_cost,
      'waste','waste',p_waste_id,'WASTE-'||left(p_waste_id::text,8),auth.uid());
  END IF;

  UPDATE public.waste_entries SET status='approved',approved_by=auth.uid(),approved_at=now(),
    updated_at=now(),rejection_reason=NULL WHERE id=p_waste_id;
  INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),'approve','waste_entry',p_waste_id,
    jsonb_build_object('status','approved','warehouse_id',v_entry.warehouse_id,'quantity_deducted',v_entry.quantity,
      'product_id',v_entry.product_id,'inventory_unit_id',v_entry.inventory_unit_id),v_entry.branch_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_waste_report(
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_from_date date DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_to_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE(waste_category text,waste_type text,total_quantity numeric,total_cost numeric,entry_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.report') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.report'; END IF;
  IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  RETURN QUERY SELECT wc.name,we.waste_type,sum(we.quantity),sum(we.total_cost),count(*)::bigint
  FROM public.waste_entries we JOIN public.waste_categories wc ON wc.id=we.waste_category_id
  WHERE we.branch_id=p_branch_id AND we.status='approved' AND we.created_at>=p_from_date
    AND we.created_at<(p_to_date+INTERVAL '1 day') GROUP BY wc.name,we.waste_type ORDER BY sum(we.total_cost) DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_waste_entry(uuid,uuid,text,numeric,numeric,text,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_waste_report(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_waste_entry(uuid,uuid,text,numeric,numeric,text,uuid,uuid,uuid,uuid,uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_waste_report(uuid,date,date) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_operational_approval_queue(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE(source_type text,source_id uuid,branch_id uuid,title text,status text,requested_by uuid,requested_at timestamptz,required_permission text,payload jsonb)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
  SELECT 'manager_approval',a.id,a.branch_id,a.action_type,a.status,a.requester_id,a.created_at,'approvals.review',
    jsonb_build_object('entity_type',a.entity_type,'entity_id',a.entity_id,'reason',a.reason,'payload',a.payload)
  FROM public.approval_requests a WHERE a.status='pending' AND (p_branch_id IS NULL OR a.branch_id=p_branch_id) AND public.user_may_access_branch(a.branch_id)
  UNION ALL
  SELECT 'waste',w.id,w.branch_id,'waste:'||w.waste_type,w.status,w.created_by,w.created_at,'waste.approve',
    jsonb_build_object('product_id',w.product_id,'inventory_unit_id',w.inventory_unit_id,'warehouse_id',w.warehouse_id,'quantity',w.quantity,'total_cost',w.total_cost,'reason',w.reason)
  FROM public.waste_entries w WHERE w.status='pending' AND (p_branch_id IS NULL OR w.branch_id=p_branch_id) AND public.user_may_access_branch(w.branch_id)
  UNION ALL
  SELECT 'stock_count',s.id,s.branch_id,'stock_count:'||COALESCE(s.count_number,s.id::text),s.status,s.submitted_by,COALESCE(s.submitted_at,s.created_at),'inventory.manage',
    jsonb_build_object('warehouse_id',s.warehouse_id,'count_type',s.count_type,'notes',s.notes)
  FROM public.stock_counts s WHERE s.status='submitted' AND (p_branch_id IS NULL OR s.branch_id=p_branch_id) AND public.user_may_access_branch(s.branch_id)
  UNION ALL
  SELECT 'warehouse_transfer',t.id,t.branch_id,'transfer:'||COALESCE(t.transfer_number,t.id::text),t.status,t.requested_by,COALESCE(t.requested_at,t.created_at),'inventory.transfers.approve',
    jsonb_build_object('from_warehouse_id',t.from_warehouse_id,'to_warehouse_id',t.to_warehouse_id,'reason',t.reason,'notes',t.notes)
  FROM public.warehouse_transfers t WHERE t.status IN ('pending','requested','submitted') AND (p_branch_id IS NULL OR t.branch_id=p_branch_id) AND public.user_may_access_branch(t.branch_id)
  ORDER BY 7 DESC;
$$;

CREATE OR REPLACE FUNCTION public.decide_operational_approval(p_source_type text,p_source_id uuid,p_approve boolean,p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_source_type='manager_approval' THEN
    IF NOT public.can_permission('approvals.review') THEN RETURN jsonb_build_object('success',false,'error','APPROVAL_REVIEW_DENIED'); END IF;
    RETURN public.decide_manager_approval(p_source_id,p_approve,p_reason);
  ELSIF p_source_type='waste' THEN
    SELECT branch_id INTO v_branch FROM public.waste_entries WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('waste.approve') THEN
      RETURN jsonb_build_object('success',false,'error','WASTE_APPROVAL_DENIED'); END IF;
    PERFORM public.approve_waste(p_source_id,p_approve,p_reason);
    RETURN jsonb_build_object('success',true,'source_type','waste','source_id',p_source_id,'status',CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END);
  ELSIF p_source_type='stock_count' THEN
    SELECT branch_id INTO v_branch FROM public.stock_counts WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('inventory.manage') THEN RETURN jsonb_build_object('success',false,'error','STOCK_COUNT_APPROVAL_DENIED'); END IF;
    IF p_approve THEN RETURN public.approve_stock_count(p_source_id); END IF;
    RETURN public.reject_stock_count(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  ELSIF p_source_type='warehouse_transfer' THEN
    SELECT branch_id INTO v_branch FROM public.warehouse_transfers WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('inventory.transfers.approve') THEN RETURN jsonb_build_object('success',false,'error','TRANSFER_APPROVAL_DENIED'); END IF;
    IF p_approve THEN RETURN public.approve_warehouse_transfer(p_source_id); END IF;
    RETURN public.reject_warehouse_transfer(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  END IF;
  RETURN jsonb_build_object('success',false,'error','UNSUPPORTED_APPROVAL_SOURCE');
END;
$$;

REVOKE ALL ON FUNCTION public.get_operational_approval_queue(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_operational_approval_queue(uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) TO authenticated,service_role;
