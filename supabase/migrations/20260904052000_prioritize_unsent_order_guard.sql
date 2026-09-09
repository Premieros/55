-- An unsent linked order has no inventory_warehouse_id yet. Reject payment for
-- the real lifecycle violation first so callers receive ORDER_NOT_FULLY_SENT
-- instead of the secondary warehouse-binding error.
CREATE OR REPLACE FUNCTION public._prepare_kitchen_sale_settlement(
  p_order_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_order_shape jsonb;
  v_payload_shape jsonb;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.branch_id IS DISTINCT FROM p_branch_id OR NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_order.status NOT IN ('open','held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;

  -- Kitchen completion is the primary settlement precondition. Before the
  -- first kitchen send an order is intentionally not warehouse-bound yet.
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FULLY_SENT');
  END IF;

  -- Once all lines are sent, payment must use exactly the warehouse bound by
  -- send_to_kitchen so inventory can never be settled against another store.
  IF p_warehouse_id IS NULL
     OR v_order.inventory_warehouse_id IS DISTINCT FROM p_warehouse_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'KITCHEN_WAREHOUSE_MISMATCH',
      'expected_warehouse_id', v_order.inventory_warehouse_id
    );
  END IF;

  SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
  INTO v_order_shape
  FROM (
    SELECT jsonb_build_object(
      'product_id', oi.product_id,
      'unit_name', COALESCE(oi.unit_name, 'piece'),
      'quantity', oi.quantity,
      'modifier_option_ids', to_jsonb(ARRAY(
        SELECT u.id::text
        FROM unnest(COALESCE(oi.modifier_option_ids, '{}'::uuid[])) AS u(id)
        ORDER BY u.id::text
      ))
    ) AS shape
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id
  ) x;

  BEGIN
    SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
    INTO v_payload_shape
    FROM (
      SELECT jsonb_build_object(
        'product_id', NULLIF(item->>'product_id','')::uuid,
        'unit_name', COALESCE(NULLIF(item->>'unit_name',''), 'piece'),
        'quantity', COALESCE((item->>'quantity')::numeric, 0),
        'modifier_option_ids', to_jsonb(ARRAY(
          SELECT j.id
          FROM jsonb_array_elements_text(COALESCE(item->'modifier_option_ids','[]'::jsonb)) AS j(id)
          ORDER BY j.id
        ))
      ) AS shape
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS j(item)
    ) x;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH', 'detail', SQLERRM);
  END;

  IF v_order_shape IS DISTINCT FROM v_payload_shape THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.kitchen_settlement_queue (
    seq bigint GENERATED ALWAYS AS IDENTITY,
    order_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    product_id uuid NOT NULL,
    unit_name text NOT NULL,
    quantity numeric(14,6) NOT NULL,
    modifier_option_ids uuid[] NOT NULL,
    consumed boolean NOT NULL DEFAULT false,
    PRIMARY KEY(seq)
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.kitchen_settlement_queue RESTART IDENTITY;

  INSERT INTO pg_temp.kitchen_settlement_queue(
    order_id, order_item_id, product_id, unit_name, quantity, modifier_option_ids
  )
  SELECT p_order_id, oi.id, oi.product_id, COALESCE(oi.unit_name,'piece'), oi.quantity,
         COALESCE(oi.modifier_option_ids, '{}'::uuid[])
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
  ORDER BY oi.created_at, oi.id;

  PERFORM set_config('app.kitchen_inventory_settlement', 'on', true);
  PERFORM set_config('app.kitchen_inventory_order_id', p_order_id::text, true);
  RETURN jsonb_build_object('success', true);
END;
$function$;
