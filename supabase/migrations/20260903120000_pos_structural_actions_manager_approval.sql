-- POS structural actions: split items/orders, merge orders and transfer tables.
-- These actions never deduct/restore inventory and never create kitchen sends.
-- Cashiers request manager approval; privileged managers execute directly.

ALTER TABLE public.approval_requests
  DROP CONSTRAINT IF EXISTS approval_requests_action_type_check;
ALTER TABLE public.approval_requests
  ADD CONSTRAINT approval_requests_action_type_check
  CHECK (action_type IN (
    'discount','reprint','void_order','cancel_sent_item','refund','open_drawer',
    'change_payment_method','force_close_shift','split_order','merge_order','transfer_order'
  ));

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_req_id uuid;
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF p_action_type NOT IN (
    'discount','reprint','void_order','cancel_sent_item','refund','open_drawer',
    'change_payment_method','force_close_shift','split_order','merge_order','transfer_order'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT id INTO v_req_id
  FROM public.approval_requests
  WHERE requester_id = auth.uid()
    AND branch_id = v_user.branch_id
    AND action_type = p_action_type
    AND entity_type = p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id
    AND payload = v_payload
    AND status = 'pending'
    AND expires_at > now()
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_req_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'request_id', v_req_id, 'status', 'pending', 'duplicate', true);
  END IF;

  INSERT INTO public.approval_requests(
    branch_id, requester_id, action_type, entity_type, entity_id, payload, reason
  ) VALUES (
    v_user.branch_id, auth.uid(), p_action_type, p_entity_type, p_entity_id, v_payload, trim(p_reason)
  ) RETURNING id INTO v_req_id;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'APPROVAL_REQUESTED', 'approval_request', v_req_id,
    jsonb_build_object(
      'action_type', p_action_type,
      'entity_type', p_entity_type,
      'target_id', p_entity_id,
      'reason', trim(p_reason),
      'payload', v_payload
    ),
    v_user.branch_id
  );

  RETURN jsonb_build_object('success', true, 'request_id', v_req_id, 'status', 'pending');
END;
$$;

CREATE OR REPLACE FUNCTION public._recalc_open_order_totals(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_subtotal numeric(14,4);
BEGIN
  SELECT COALESCE(sum(quantity * unit_price), 0)
    INTO v_subtotal
  FROM public.order_items
  WHERE order_id = p_order_id;

  UPDATE public.orders
  SET subtotal = v_subtotal,
      total = GREATEST(v_subtotal - COALESCE(discount_amount, 0) + COALESCE(tax_amount, 0), 0),
      updated_at = now()
  WHERE id = p_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._create_structural_target_order(
  p_source public.orders,
  p_target_kind text,
  p_target_table_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_id uuid;
  v_target public.dining_tables%ROWTYPE;
  v_number jsonb;
  v_order_number text;
BEGIN
  IF p_target_kind = 'table' THEN
    SELECT * INTO v_target
    FROM public.dining_tables
    WHERE id = p_target_table_id
      AND branch_id = p_source.branch_id
      AND is_active = true
    FOR UPDATE;

    IF v_target.id IS NULL THEN
      RAISE EXCEPTION 'TARGET_TABLE_NOT_FOUND';
    END IF;

    SELECT id INTO v_target_id
    FROM public.orders
    WHERE branch_id = p_source.branch_id
      AND table_id = p_target_table_id
      AND status IN ('open','held')
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_target_id IS NOT NULL THEN
      RETURN v_target_id;
    END IF;
  ELSIF p_target_kind <> 'quick' THEN
    RAISE EXCEPTION 'INVALID_TARGET_KIND';
  END IF;

  v_number := public.next_document_number('order');
  IF COALESCE((v_number->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'NUMBERING_FAILED: %', COALESCE(v_number->>'error', 'unknown');
  END IF;
  v_order_number := v_number->>'number';

  INSERT INTO public.orders(
    order_number, branch_id, order_type, status, table_id, customer_id,
    cashier_id, guest_count, notes, subtotal, discount_amount, discount_type,
    tax_amount, total
  ) VALUES (
    v_order_number,
    p_source.branch_id,
    CASE WHEN p_target_kind = 'table' THEN 'dine_in' ELSE 'takeaway' END,
    'open',
    CASE WHEN p_target_kind = 'table' THEN p_target_table_id ELSE NULL END,
    p_source.customer_id,
    COALESCE(p_source.cashier_id, auth.uid()),
    NULL,
    NULL,
    0, 0, 'amount', 0, 0
  ) RETURNING id INTO v_target_id;

  IF p_target_kind = 'table' THEN
    UPDATE public.dining_tables
    SET status = 'occupied', updated_at = now()
    WHERE id = p_target_table_id;
  END IF;

  RETURN v_target_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.perform_pos_order_action(
  p_action_type text,
  p_order_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_target_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_request public.approval_requests%ROWTYPE;
  v_request_result jsonb;
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_privileged boolean := false;
  v_target_id uuid;
  v_target_table_id uuid;
  v_target_kind text;
  v_item_id uuid;
  v_qty numeric(14,4);
  v_ratio numeric(18,8);
  v_moved_discount numeric(14,4);
  v_moved_bonus numeric(14,4);
  v_moved_total numeric(14,4);
  v_source_order_discount numeric(14,4);
  v_source_tax numeric(14,4);
  v_order_ratio numeric(18,8);
  v_old_subtotal numeric(14,4);
  v_remaining integer;
  v_source_table_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF p_action_type NOT IN ('split_order','merge_order','transfer_order') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;
  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND status IN ('open','held')
  FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  v_privileged := public.is_pos_admin() OR public.can_permission('approvals.review');

  IF NOT v_privileged THEN
    SELECT * INTO v_request
    FROM public.approval_requests ar
    WHERE ar.requester_id = auth.uid()
      AND ar.branch_id = v_order.branch_id
      AND ar.action_type = p_action_type
      AND ar.entity_type = 'order'
      AND ar.entity_id = p_order_id
      AND ar.payload = v_payload
      AND ar.status = 'approved'
      AND ar.expires_at > now()
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      v_request_result := public.request_manager_approval(
        p_action_type,
        'order',
        p_order_id,
        v_payload,
        trim(p_reason)
      );
      RETURN jsonb_build_object(
        'success', false,
        'error', 'MANAGER_APPROVAL_REQUIRED',
        'action', p_action_type,
        'request_id', v_request_result->>'request_id',
        'status', COALESCE(v_request_result->>'status', 'pending')
      );
    END IF;

    v_request_result := public.consume_manager_approval(v_request.id, p_action_type, p_order_id);
    IF COALESCE((v_request_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN COALESCE(v_request_result, jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED'));
    END IF;
  END IF;

  IF p_action_type = 'split_order' THEN
    BEGIN
      v_item_id := NULLIF(v_payload->>'order_item_id', '')::uuid;
      v_qty := NULLIF(v_payload->>'quantity', '')::numeric;
      v_target_kind := lower(COALESCE(v_payload->>'target_kind', ''));
      v_target_table_id := NULLIF(v_payload->>'target_table_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYLOAD');
    END;

    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty <= 0 OR v_target_kind NOT IN ('quick','table') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYLOAD');
    END IF;
    IF v_target_kind = 'table' AND v_target_table_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_REQUIRED');
    END IF;

    SELECT * INTO v_item
    FROM public.order_items
    WHERE id = v_item_id AND order_id = p_order_id
    FOR UPDATE;
    IF v_item.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEM_NOT_FOUND');
    END IF;
    IF v_qty > v_item.quantity THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_QUANTITY_EXCEEDS_LINE', 'available_quantity', v_item.quantity);
    END IF;

    -- Sent snapshots are immutable. Do not fake a KDS transfer.
    IF EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = v_item.id) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ITEM_ALREADY_SENT',
        'detail', 'Sent kitchen lines remain attached to their original order snapshot.'
      );
    END IF;

    v_target_id := public._create_structural_target_order(v_order, v_target_kind, v_target_table_id);
    IF v_target_id = p_order_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'SAME_ORDER');
    END IF;

    SELECT * INTO v_target_order FROM public.orders WHERE id = v_target_id FOR UPDATE;

    v_ratio := v_qty / NULLIF(v_item.quantity, 0);
    v_moved_discount := round(COALESCE(v_item.discount_amount, 0) * v_ratio, 4);
    v_moved_bonus := round(COALESCE(v_item.bonus_quantity, 0) * v_ratio, 4);
    v_moved_total := round(COALESCE(v_item.total, v_item.quantity * v_item.unit_price) * v_ratio, 4);

    v_old_subtotal := GREATEST(COALESCE(v_order.subtotal, 0), 0);
    v_order_ratio := CASE WHEN v_old_subtotal > 0
      THEN LEAST(1, GREATEST(0, (v_qty * v_item.unit_price) / v_old_subtotal))
      ELSE 0 END;
    v_source_order_discount := round(COALESCE(v_order.discount_amount, 0) * v_order_ratio, 4);
    v_source_tax := round(COALESCE(v_order.tax_amount, 0) * v_order_ratio, 4);

    IF v_qty = v_item.quantity THEN
      UPDATE public.order_items SET order_id = v_target_id WHERE id = v_item.id;
    ELSE
      UPDATE public.order_items
      SET quantity = quantity - v_qty,
          discount_amount = GREATEST(COALESCE(discount_amount,0) - v_moved_discount, 0),
          bonus_quantity = GREATEST(COALESCE(bonus_quantity,0) - v_moved_bonus, 0),
          total = GREATEST(COALESCE(total,0) - v_moved_total, 0)
      WHERE id = v_item.id;

      INSERT INTO public.order_items(
        order_id, product_id, unit_name, quantity, unit_price, discount_amount,
        bonus_quantity, total, modifier_option_ids, modifiers_snapshot, notes
      ) VALUES (
        v_target_id, v_item.product_id, v_item.unit_name, v_qty, v_item.unit_price,
        v_moved_discount, v_moved_bonus, v_moved_total,
        COALESCE(v_item.modifier_option_ids, '{}'::uuid[]),
        COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
        v_item.notes
      );
    END IF;

    UPDATE public.orders
    SET discount_amount = GREATEST(COALESCE(discount_amount,0) - v_source_order_discount, 0),
        tax_amount = GREATEST(COALESCE(tax_amount,0) - v_source_tax, 0)
    WHERE id = p_order_id;
    UPDATE public.orders
    SET discount_amount = COALESCE(discount_amount,0) + v_source_order_discount,
        tax_amount = COALESCE(tax_amount,0) + v_source_tax
    WHERE id = v_target_id;

    PERFORM public._recalc_open_order_totals(p_order_id);
    PERFORM public._recalc_open_order_totals(v_target_id);

    SELECT count(*) INTO v_remaining FROM public.order_items WHERE order_id = p_order_id;
    IF v_remaining = 0 THEN
      v_source_table_id := v_order.table_id;
      UPDATE public.orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
      IF v_source_table_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.orders
        WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
      ) THEN
        UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
      END IF;
    END IF;

    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(
      auth.uid(), v_user.email, 'POS_ORDER_SPLIT', 'order', p_order_id,
      jsonb_build_object(
        'order_item_id', v_item_id,
        'quantity', v_qty,
        'target_order_id', v_target_id,
        'target_kind', v_target_kind,
        'target_table_id', v_target_table_id,
        'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
        'inventory_changed', false,
        'kds_changed', false
      ),
      v_order.branch_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'action', 'split_order',
      'source_order_id', p_order_id,
      'target_order_id', v_target_id,
      'inventory_changed', false,
      'kds_changed', false,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
    );
  END IF;

  IF p_action_type = 'merge_order' THEN
    BEGIN
      v_target_id := NULLIF(v_payload->>'target_order_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MERGE_PAYLOAD');
    END;

    IF v_target_id IS NULL OR v_target_id = p_order_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MERGE_TARGET');
    END IF;

    SELECT * INTO v_target_order
    FROM public.orders
    WHERE id = v_target_id
      AND branch_id = v_order.branch_id
      AND status IN ('open','held')
    FOR UPDATE;
    IF v_target_order.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_ORDER_NOT_FOUND');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.order_kitchen_sends s
      JOIN public.order_items oi ON oi.id = s.order_item_id
      WHERE oi.order_id = p_order_id
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'SOURCE_HAS_SENT_ITEMS',
        'detail', 'Sent kitchen lines cannot be re-parented during merge.'
      );
    END IF;

    UPDATE public.order_items SET order_id = v_target_id WHERE order_id = p_order_id;
    UPDATE public.orders
    SET discount_amount = COALESCE(discount_amount,0) + COALESCE(v_order.discount_amount,0),
        tax_amount = COALESCE(tax_amount,0) + COALESCE(v_order.tax_amount,0)
    WHERE id = v_target_id;
    PERFORM public._recalc_open_order_totals(v_target_id);

    v_source_table_id := v_order.table_id;
    UPDATE public.orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
    IF v_source_table_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
    ) THEN
      UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
    END IF;

    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(
      auth.uid(), v_user.email, 'POS_ORDER_MERGED', 'order', p_order_id,
      jsonb_build_object(
        'target_order_id', v_target_id,
        'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
        'inventory_changed', false,
        'kds_changed', false
      ),
      v_order.branch_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'action', 'merge_order',
      'source_order_id', p_order_id,
      'target_order_id', v_target_id,
      'inventory_changed', false,
      'kds_changed', false,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
    );
  END IF;

  -- transfer_order: move the whole dine-in order to a vacant table. KDS remains on the same order id.
  BEGIN
    v_target_table_id := NULLIF(v_payload->>'target_table_id', '')::uuid;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TRANSFER_PAYLOAD');
  END;

  IF v_order.order_type <> 'dine_in' OR v_order.table_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SOURCE_NOT_DINE_IN');
  END IF;
  IF v_target_table_id IS NULL OR v_target_table_id = v_order.table_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TARGET_TABLE');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dining_tables
    WHERE id = v_target_table_id AND branch_id = v_order.branch_id AND is_active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_NOT_FOUND');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = v_target_table_id AND branch_id = v_order.branch_id
      AND status IN ('open','held') AND id <> p_order_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_OCCUPIED', 'detail', 'Use merge for an occupied target table.');
  END IF;

  v_source_table_id := v_order.table_id;
  UPDATE public.orders SET table_id = v_target_table_id, updated_at = now() WHERE id = p_order_id;
  UPDATE public.dining_tables SET status = 'occupied', updated_at = now() WHERE id = v_target_table_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
  ) THEN
    UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
  END IF;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'POS_ORDER_TRANSFERRED', 'order', p_order_id,
    jsonb_build_object(
      'from_table_id', v_source_table_id,
      'target_table_id', v_target_table_id,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
      'inventory_changed', false,
      'kds_changed', false
    ),
    v_order.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'action', 'transfer_order',
    'order_id', p_order_id,
    'from_table_id', v_source_table_id,
    'target_table_id', v_target_table_id,
    'inventory_changed', false,
    'kds_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public._recalc_open_order_totals(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._create_structural_target_order(public.orders,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._recalc_open_order_totals(uuid) TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._create_structural_target_order(public.orders,text,uuid) TO service_role, postgres;

REVOKE ALL ON FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated;
