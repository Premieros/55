-- Move one exact, unsent order line between dine-in tables without touching KDS or inventory.
-- Sent lines are intentionally blocked: kitchen snapshots remain immutable and inventory is still sale-only.

CREATE OR REPLACE FUNCTION public.transfer_order_item_to_table(
  p_order_id uuid,
  p_order_item_id uuid,
  p_target_table_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_target public.dining_tables%ROWTYPE;
  v_target_order_id uuid;
  v_target_order_number text;
  v_number jsonb;
  v_new_item_id uuid;
  v_remaining integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND status IN ('open', 'held')
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF v_order.table_id IS NULL OR v_order.order_type <> 'dine_in' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SOURCE_NOT_DINE_IN');
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_order_item_id
    AND order_id = p_order_id
  FOR UPDATE;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEM_NOT_FOUND');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_kitchen_sends s
    WHERE s.order_item_id = p_order_item_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'ITEM_ALREADY_SENT',
      'detail', 'Sent kitchen lines cannot be transferred between orders.'
    );
  END IF;

  SELECT * INTO v_target
  FROM public.dining_tables
  WHERE id = p_target_table_id
    AND branch_id = v_order.branch_id
    AND is_active = true
  FOR UPDATE;

  IF v_target.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_NOT_FOUND');
  END IF;

  IF v_target.id = v_order.table_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'SAME_TABLE');
  END IF;

  SELECT id, order_number
    INTO v_target_order_id, v_target_order_number
  FROM public.orders
  WHERE table_id = p_target_table_id
    AND branch_id = v_order.branch_id
    AND status IN ('open', 'held')
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE;

  IF v_target_order_id IS NULL THEN
    v_number := public.next_document_number('order');
    IF COALESCE((v_number->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('success', false, 'error', 'NUMBERING_FAILED', 'detail', v_number->>'error');
    END IF;

    v_target_order_number := v_number->>'number';

    INSERT INTO public.orders (
      order_number, branch_id, order_type, status, table_id, customer_id,
      cashier_id, guest_count, notes, subtotal, discount_amount, discount_type,
      tax_amount, total
    )
    VALUES (
      v_target_order_number,
      v_order.branch_id,
      'dine_in',
      'open',
      p_target_table_id,
      v_order.customer_id,
      COALESCE(v_order.cashier_id, v_uid),
      NULL,
      NULL,
      0, 0, 'amount', 0, 0
    )
    RETURNING id INTO v_target_order_id;
  END IF;

  INSERT INTO public.order_items (
    order_id, product_id, unit_name, quantity, unit_price, discount_amount,
    bonus_quantity, total, modifier_option_ids, modifiers_snapshot, notes
  )
  VALUES (
    v_target_order_id,
    v_item.product_id,
    v_item.unit_name,
    v_item.quantity,
    v_item.unit_price,
    v_item.discount_amount,
    v_item.bonus_quantity,
    v_item.total,
    COALESCE(v_item.modifier_option_ids, '{}'::uuid[]),
    COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
    v_item.notes
  )
  RETURNING id INTO v_new_item_id;

  -- Deleting the unsent source line invokes the existing authoritative totals sync.
  DELETE FROM public.order_items WHERE id = p_order_item_id;

  UPDATE public.dining_tables
  SET status = 'occupied', updated_at = now()
  WHERE id = p_target_table_id;

  SELECT count(*) INTO v_remaining
  FROM public.order_items
  WHERE order_id = p_order_id;

  IF v_remaining = 0 THEN
    UPDATE public.orders
    SET status = 'cancelled', updated_at = now()
    WHERE id = p_order_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = v_order.table_id
        AND status IN ('open', 'held')
        AND id <> p_order_id
    ) THEN
      UPDATE public.dining_tables
      SET status = 'vacant', updated_at = now()
      WHERE id = v_order.table_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'source_order_id', p_order_id,
    'target_order_id', v_target_order_id,
    'target_order_number', v_target_order_number,
    'new_order_item_id', v_new_item_id,
    'source_order_empty', v_remaining = 0,
    'inventory_changed', false,
    'kds_changed', false
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_order_item_to_table(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_order_item_to_table(uuid, uuid, uuid) TO authenticated, service_role;
