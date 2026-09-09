-- P1: secure cancellation of items already sent to the kitchen.
-- KDS is state-only: sending does NOT deduct inventory. Therefore cancelling a
-- sent line must never restore/increase stock. Inventory remains owned by the
-- final sale settlement path.

CREATE TABLE IF NOT EXISTS public.order_kitchen_voids (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name text NOT NULL,
  unit_name text NOT NULL DEFAULT 'piece',
  quantity numeric(14,4) NOT NULL CHECK (quantity > 0),
  reason text NOT NULL CHECK (length(trim(reason)) >= 3),
  voided_by uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  approval_request_id uuid REFERENCES public.approval_requests(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_order_created
  ON public.order_kitchen_voids(order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_branch_created
  ON public.order_kitchen_voids(branch_id, created_at DESC);

ALTER TABLE public.order_kitchen_voids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_kitchen_voids_select ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_select ON public.order_kitchen_voids
FOR SELECT TO authenticated
USING (user_may_access_branch(branch_id));

DROP POLICY IF EXISTS order_kitchen_voids_no_direct_insert ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_direct_insert ON public.order_kitchen_voids
FOR INSERT TO authenticated WITH CHECK (false);

DROP POLICY IF EXISTS order_kitchen_voids_no_update ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_update ON public.order_kitchen_voids
FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS order_kitchen_voids_no_delete ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_delete ON public.order_kitchen_voids
FOR DELETE TO authenticated USING (false);

-- A sent order-item may not be reduced or deleted directly by a cashier.
-- The approved cancellation RPC temporarily enables the exact mutation by
-- setting a transaction-local GUC. Managers/admins with approval review access
-- can perform the operation without a request.
CREATE OR REPLACE FUNCTION public.guard_sent_order_item_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_sent boolean;
  v_is_reduction boolean := false;
  v_internal boolean := COALESCE(current_setting('app.approved_sent_item_void', true), '') = '1';
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = OLD.id
  ) INTO v_is_sent;

  IF NOT v_is_sent THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_is_reduction := true;
  ELSIF TG_OP = 'UPDATE' AND COALESCE(NEW.quantity, 0) < COALESCE(OLD.quantity, 0) THEN
    v_is_reduction := true;
  END IF;

  IF v_is_reduction
     AND NOT v_internal
     AND NOT is_pos_admin()
     AND NOT can_permission('approvals.review') THEN
    RAISE EXCEPTION 'SENT_ITEM_APPROVAL_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_sent_order_item_mutation ON public.order_items;
CREATE TRIGGER trg_guard_sent_order_item_mutation
BEFORE UPDATE OF quantity OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.guard_sent_order_item_mutation();

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
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

  IF NOT user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT oi.* INTO v_item
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = oi.id
    )
  ORDER BY oi.created_at, oi.id
  LIMIT 1
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

  v_privileged := is_pos_admin() OR can_permission('approvals.review');

  IF NOT v_privileged THEN
    -- Reuse only an exact approved request for this item and quantity.
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
      AND ar.payload->>'product_id' = p_product_id::text
      AND abs(COALESCE((ar.payload->>'quantity')::numeric, -1) - p_quantity) < 0.0001
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      -- request_manager_approval already de-duplicates matching pending requests
      -- by requester/action/entity. Payload stores the exact scope that will be
      -- checked again before execution.
      v_request_result := public.request_manager_approval(
        'cancel_sent_item',
        'order_item',
        v_item.id,
        jsonb_build_object(
          'order_id', p_order_id,
          'product_id', p_product_id,
          'product_name', v_product_name,
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

  -- Allow only this transaction's server-side sent-line reduction through the
  -- trigger. No inventory table is modified here: KDS never deducted stock.
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

  -- Recalculate order header from remaining lines. `discount_amount` on orders
  -- is already the computed order-level discount value in the current POS path.
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
      'product_id', p_product_id,
      'product_name', v_product_name,
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
    'product_id', p_product_id,
    'voided_quantity', p_quantity,
    'remaining_quantity', GREATEST(v_new_qty, 0),
    'inventory_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='order_kitchen_voids'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.order_kitchen_voids;
  END IF;
END $$;
