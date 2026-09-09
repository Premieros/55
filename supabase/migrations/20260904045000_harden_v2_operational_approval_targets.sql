-- V2 unified approvals must remain safe even if a client calls the target RPC
-- directly instead of going through decide_operational_approval().
-- Keep existing business logic; replace legacy branch checks with the canonical
-- user_may_access_branch() primitive and require the matching permission.

CREATE OR REPLACE FUNCTION public.approve_waste(
  p_waste_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_entry public.waste_entries%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT * INTO v_entry
  FROM public.waste_entries
  WHERE id = p_waste_id
  FOR UPDATE;

  IF v_entry.id IS NULL THEN
    RAISE EXCEPTION 'WASTE_NOT_FOUND';
  END IF;

  IF NOT public.user_may_access_branch(v_entry.branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF NOT (public.is_pos_admin() OR public.can_permission('production.waste')) THEN
    RAISE EXCEPTION 'WASTE_APPROVAL_DENIED';
  END IF;

  IF v_entry.status <> 'pending' THEN
    RAISE EXCEPTION 'WASTE_NOT_PENDING';
  END IF;

  IF p_approve THEN
    UPDATE public.waste_entries
    SET status = 'approved',
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now(),
        rejection_reason = NULL
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (auth.uid(), 'approve', 'waste_entry', p_waste_id,
      jsonb_build_object('status', 'approved'), v_entry.branch_id);
  ELSE
    UPDATE public.waste_entries
    SET status = 'rejected',
        rejection_reason = p_rejection_reason,
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now()
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (auth.uid(), 'reject', 'waste_entry', p_waste_id,
      jsonb_build_object('status', 'rejected', 'reason', p_rejection_reason), v_entry.branch_id);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count public.stock_counts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
      'detail', 'Approving stock counts requires inventory.manage.');
  END IF;

  SELECT * INTO v_count
  FROM public.stock_counts
  WHERE id = p_stock_count_id
  FOR UPDATE;

  IF v_count.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_count.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_count.status <> 'submitted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
  END IF;

  UPDATE public.stock_counts
  SET status = 'approved', approved_by = auth.uid(), approved_at = now(), rejection_reason = NULL
  WHERE id = p_stock_count_id;

  RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_stock_count(
  p_stock_count_id uuid,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count public.stock_counts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_count
  FROM public.stock_counts
  WHERE id = p_stock_count_id
  FOR UPDATE;

  IF v_count.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_count.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_count.status <> 'submitted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
  END IF;

  UPDATE public.stock_counts
  SET status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_reason
  WHERE id = p_stock_count_id;

  RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_warehouse_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_transfer public.warehouse_transfers%ROWTYPE;
  v_item record;
  v_avail numeric(14,4);
  v_res jsonb;
  v_short numeric(14,4);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
      'detail', 'Approving transfers requires inventory.transfers.approve.');
  END IF;

  SELECT * INTO v_transfer
  FROM public.warehouse_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;

  IF v_transfer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSFER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_transfer.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_transfer.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_transfer.status);
  END IF;

  FOR v_item IN
    SELECT * FROM public.warehouse_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_avail
    FROM public.inventory_batches
    WHERE product_id = v_item.product_id
      AND warehouse_id = v_transfer.from_warehouse_id;

    IF v_avail < v_item.quantity THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
        'product_id', v_item.product_id, 'required', v_item.quantity, 'available', v_avail);
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT * FROM public.warehouse_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    v_res := public._product_inv_move(
      v_item.product_id,
      v_transfer.from_warehouse_id,
      v_transfer.to_warehouse_id,
      v_transfer.branch_id,
      v_item.quantity,
      'warehouse_transfer',
      v_transfer.id,
      v_transfer.transfer_number,
      auth.uid()
    );
    v_short := (v_res->>'shortage')::numeric;
    IF v_short > 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
        'product_id', v_item.product_id, 'shortage', v_short);
    END IF;
  END LOOP;

  UPDATE public.warehouse_transfers
  SET status = 'approved', approved_by = auth.uid(), approved_at = now()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true, 'transfer_id', p_transfer_id, 'transfer_number', v_transfer.transfer_number);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_warehouse_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_transfer public.warehouse_transfers%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_transfer
  FROM public.warehouse_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;

  IF v_transfer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSFER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_transfer.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_transfer.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_transfer.status);
  END IF;

  UPDATE public.warehouse_transfers
  SET status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_reason
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true, 'transfer_id', p_transfer_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO service_role;

REVOKE ALL ON FUNCTION public.approve_stock_count(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_stock_count(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_warehouse_transfer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_warehouse_transfer(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_stock_count(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_stock_count(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_warehouse_transfer(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_warehouse_transfer(uuid,text) TO authenticated, service_role;
