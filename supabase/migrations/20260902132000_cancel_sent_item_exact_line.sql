-- Cancel an exact sent order-item line. This removes the product-id ambiguity
-- when the same product appears more than once with different modifiers.
-- KDS remains state-only: this function never mutates inventory.

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item_exact(
  p_order_id uuid,
  p_order_item_id uuid,
  p_quantity numeric,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_product_name text;
  v_request public.approval_requests%ROWTYPE;
  v_request_result jsonb;
  v_new_qty numeric(14,4);
  v_new_discount numeric(14,4);
  v_new_total numeric(14,4);
  v_subtotal numeric(14,4);
  v_total numeric(14,4);
  v_note text;
  v_privileged boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
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
  WHERE id = p_order_id
  FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.status NOT IN ('open', 'held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;
  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT oi.* INTO v_item
  FROM public.order_items oi
  WHERE oi.id = p_order_item_id
    AND oi.order_id = p_order_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    )
  FOR UPDATE;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;

  IF p_quantity > v_item.quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'VOID_QUANTITY_EXCEEDS_SENT',
      'available_quantity', v_item.quantity
    );
  END IF;

  SELECT name INTO v_product_name FROM public.products WHERE id = v_item.product_id;
  v_product_name := COALESCE(v_product_name, 'Unknown product');
  v_privileged := public.is_pos_admin() OR public.can_permission('approvals.review');

  IF NOT v_privileged THEN
    SELECT * INTO v_request
    FROM public.approval_requests ar
    WHERE ar.requester_id = auth.uid()
      AND ar.branch_id = v_order.branch_id
      AND ar.action_type = 'cancel_sent_item'
      AND ar.entity_type = 'order_item'
      AND ar.entity_id = v_item.id
      AND ar.status = 'approved'
      AND ar.expires_at > now()
      AND ar.payload->>'order_id' = p_order_id::text
      AND ar.payload->>'order_item_id' = v_item.id::text
      AND abs(COALESCE((ar.payload->>'quantity')::numeric, -1) - p_quantity) < 0.0001
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      v_request_result := public.request_manager_approval(
        'cancel_sent_item',
        'order_item',
        v_item.id,
        jsonb_build_object(
          'order_id', p_order_id,
          'order_item_id', v_item.id,
          'product_id', v_item.product_id,
          'product_name', v_product_name,
          'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
          'modifiers_snapshot', COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
          'quantity', p_quantity
        ),
        trim(p_reason)
      );

      RETURN jsonb_build_object(
        'success', false,
        'error', 'MANAGER_APPROVAL_REQUIRED',
        'action', 'cancel_sent_item',
        'request_id', v_request_result->>'request_id',
        'status', COALESCE(v_request_result->>'status', 'pending')
      );
    END IF;

    v_request_result := public.consume_manager_approval(
      v_request.id,
      'cancel_sent_item',
      v_item.id
    );
    IF COALESCE((v_request_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN COALESCE(v_request_result, jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED'));
    END IF;
  END IF;

  PERFORM set_config('app.approved_sent_item_void', '1', true);
  v_new_qty := v_item.quantity - p_quantity;

  IF v_new_qty <= 0 THEN
    DELETE FROM public.order_items WHERE id = v_item.id;
  ELSE
    v_new_discount := CASE
      WHEN v_item.quantity > 0 THEN round((v_item.discount_amount * v_new_qty / v_item.quantity)::numeric, 4)
      ELSE 0
    END;
    v_new_total := round((v_new_qty * v_item.unit_price - v_new_discount)::numeric, 4);
    UPDATE public.order_items
    SET quantity = v_new_qty,
        discount_amount = v_new_discount,
        total = GREATEST(v_new_total, 0)
    WHERE id = v_item.id;
  END IF;

  SELECT COALESCE(sum(quantity * unit_price), 0)
  INTO v_subtotal
  FROM public.order_items
  WHERE order_id = p_order_id;

  v_total := GREATEST(
    v_subtotal - COALESCE(v_order.discount_amount, 0) + COALESCE(v_order.tax_amount, 0),
    0
  );

  v_note := format(
    '[Kitchen void: %s x %s - %s]',
    trim(to_char(p_quantity, 'FM999999990.####')),
    v_product_name,
    trim(p_reason)
  );

  UPDATE public.orders
  SET subtotal = v_subtotal,
      total = v_total,
      notes = concat_ws(E'\n', NULLIF(notes, ''), v_note),
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.order_kitchen_voids(
    branch_id, order_id, order_item_id, product_id, product_name, unit_name,
    quantity, reason, voided_by, approval_request_id
  ) VALUES (
    v_order.branch_id, p_order_id, v_item.id, v_item.product_id,
    v_product_name, COALESCE(v_item.unit_name, 'piece'), p_quantity,
    trim(p_reason), auth.uid(), CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'SENT_ITEM_VOIDED', 'order_item', v_item.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'order_item_id', v_item.id,
      'product_id', v_item.product_id,
      'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
      'quantity', p_quantity,
      'reason', trim(p_reason),
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
      'inventory_changed', false
    ),
    v_order.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'order_item_id', v_item.id,
    'product_id', v_item.product_id,
    'voided_quantity', p_quantity,
    'remaining_quantity', GREATEST(v_new_qty, 0),
    'inventory_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item_exact(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item_exact(uuid,uuid,numeric,text) TO authenticated, service_role;

-- Keep the legacy product-targeted RPC executable during the UI cutover so
-- existing deployed clients do not break. New code must use the exact-line RPC.
REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;
