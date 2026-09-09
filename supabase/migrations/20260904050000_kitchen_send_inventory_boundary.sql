-- Authoritative kitchen inventory boundary.
-- Positive kitchen deltas deduct stock once. Payment reuses the exact effects,
-- while an approved sent-line void restores only the effects actually consumed.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS inventory_warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.order_kitchen_inventory_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL,
  kitchen_send_id uuid REFERENCES public.order_kitchen_sends(id) ON DELETE SET NULL,
  sent_quantity numeric(14,6) NOT NULL CHECK (sent_quantity > 0),
  voided_quantity numeric(14,6) NOT NULL DEFAULT 0
    CHECK (voided_quantity >= 0 AND voided_quantity <= sent_quantity),
  total_cost numeric(18,6) NOT NULL DEFAULT 0 CHECK (total_cost >= 0),
  settled_sale_id uuid REFERENCES public.sales(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.order_kitchen_inventory_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.order_kitchen_inventory_events(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  target_type text NOT NULL CHECK (target_type IN ('inventory_unit','raw_material','product')),
  target_id uuid NOT NULL,
  quantity numeric(14,6) NOT NULL CHECK (quantity > 0),
  total_cost numeric(18,6) NOT NULL DEFAULT 0 CHECK (total_cost >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(event_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_events_order
  ON public.order_kitchen_inventory_events(order_id, order_item_id, created_at);
CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_events_unsettled
  ON public.order_kitchen_inventory_events(order_id) WHERE settled_sale_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_effects_event
  ON public.order_kitchen_inventory_effects(event_id);

ALTER TABLE public.order_kitchen_inventory_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_kitchen_inventory_effects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kitchen_inventory_events_select ON public.order_kitchen_inventory_events;
CREATE POLICY kitchen_inventory_events_select ON public.order_kitchen_inventory_events
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS kitchen_inventory_effects_select ON public.order_kitchen_inventory_effects;
CREATE POLICY kitchen_inventory_effects_select ON public.order_kitchen_inventory_effects
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

REVOKE ALL ON public.order_kitchen_inventory_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.order_kitchen_inventory_effects FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_kitchen_inventory_events TO authenticated;
GRANT SELECT ON public.order_kitchen_inventory_effects TO authenticated;
GRANT ALL ON public.order_kitchen_inventory_events TO service_role, postgres;
GRANT ALL ON public.order_kitchen_inventory_effects TO service_role, postgres;

-- The finished-product helper writes this legacy ledger. Allow the two new,
-- explicit movement labels before any kitchen deduction/restoration uses it.
ALTER TABLE public.stock_transactions
  DROP CONSTRAINT IF EXISTS stock_transactions_transaction_type_check;
ALTER TABLE public.stock_transactions
  ADD CONSTRAINT stock_transactions_transaction_type_check
  CHECK (transaction_type IN (
    'sale','purchase','adjustment','refund','transfer','production','waste',
    'opening','purchase_return','kitchen_send','kitchen_void'
  ));

-- Preserve the existing, thoroughly tested inventory executor as an internal
-- core. Its public signature becomes a settlement-aware wrapper below.
DO $rename_inventory_core$
BEGIN
  IF to_regprocedure('public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)') IS NULL THEN
    IF to_regprocedure('public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)') IS NULL THEN
      RAISE EXCEPTION 'KITCHEN_INVENTORY_CORE_MISSING';
    END IF;
    ALTER FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
      RENAME TO _deduct_sale_inventory_with_modifiers_core;
  END IF;
END;
$rename_inventory_core$;

REVOKE ALL ON FUNCTION public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)
  TO service_role, postgres;

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
  IF p_warehouse_id IS NULL
     OR v_order.inventory_warehouse_id IS DISTINCT FROM p_warehouse_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'KITCHEN_WAREHOUSE_MISMATCH',
      'expected_warehouse_id', v_order.inventory_warehouse_id
    );
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FULLY_SENT');
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

CREATE OR REPLACE FUNCTION public._consume_kitchen_sale_settlement(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_sale_id uuid,
  p_reference_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item jsonb;
  v_queue record;
  v_event_qty numeric(14,6);
  v_missing numeric(14,6);
  v_legacy jsonb;
  v_units jsonb := '[]'::jsonb;
  v_raws jsonb := '[]'::jsonb;
  v_products jsonb := '[]'::jsonb;
  v_total_cost numeric(18,6) := 0;
BEGIN
  IF to_regclass('pg_temp.kitchen_settlement_queue') IS NULL
     OR p_items IS NULL OR jsonb_array_length(p_items) <> 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'KITCHEN_SETTLEMENT_CONTEXT_MISSING');
  END IF;

  v_item := p_items->0;
  SELECT q.* INTO v_queue
  FROM pg_temp.kitchen_settlement_queue q
  WHERE NOT q.consumed
    AND q.product_id = NULLIF(v_item->>'product_id','')::uuid
    AND q.unit_name = COALESCE(NULLIF(v_item->>'unit_name',''), 'piece')
    AND abs(q.quantity - COALESCE((v_item->>'quantity')::numeric, 0)) < 0.000001
    AND ARRAY(
      SELECT u.id FROM unnest(q.modifier_option_ids) AS u(id) ORDER BY u.id
    ) = ARRAY(
      SELECT j.id::uuid
      FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids','[]'::jsonb)) AS j(id)
      ORDER BY j.id::uuid
    )
  ORDER BY q.seq
  LIMIT 1
  FOR UPDATE;

  IF v_queue.order_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH');
  END IF;

  SELECT COALESCE(sum(e.sent_quantity - e.voided_quantity), 0)
  INTO v_event_qty
  FROM public.order_kitchen_inventory_events e
  WHERE e.order_id = v_queue.order_id
    AND e.order_item_id = v_queue.order_item_id;

  IF v_event_qty > v_queue.quantity + 0.000001 THEN
    RETURN jsonb_build_object('success', false, 'error', 'KITCHEN_INVENTORY_EVENT_MISMATCH');
  END IF;

  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'unit_id', z.target_id,
      'quantity', z.quantity
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='inventory_unit'), '[]'::jsonb),
    COALESCE(jsonb_agg(jsonb_build_object(
      'raw_material_id', z.target_id,
      'quantity', z.quantity,
      'total_cost', z.total_cost
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='raw_material'), '[]'::jsonb),
    COALESCE(jsonb_agg(jsonb_build_object(
      'product_id', z.target_id,
      'quantity', z.quantity,
      'total_cost', z.total_cost
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='product'), '[]'::jsonb),
    COALESCE(sum(z.total_cost), 0)
  INTO v_units, v_raws, v_products, v_total_cost
  FROM (
    SELECT ef.target_type, ef.target_id,
           sum(ef.quantity * (ev.sent_quantity - ev.voided_quantity) / ev.sent_quantity) AS quantity,
           sum(ef.total_cost * (ev.sent_quantity - ev.voided_quantity) / ev.sent_quantity) AS total_cost
    FROM public.order_kitchen_inventory_events ev
    JOIN public.order_kitchen_inventory_effects ef ON ef.event_id = ev.id
    WHERE ev.order_id = v_queue.order_id
      AND ev.order_item_id = v_queue.order_item_id
      AND ev.sent_quantity > ev.voided_quantity
    GROUP BY ef.target_type, ef.target_id
  ) z;

  -- Orders already partly sent before this migration have no event for that
  -- historical quantity. Deduct only that uncovered remainder at settlement.
  v_missing := GREATEST(v_queue.quantity - v_event_qty, 0);
  IF v_missing > 0.000001 THEN
    v_legacy := public._deduct_sale_inventory_with_modifiers_core(
      p_branch_id,
      p_warehouse_id,
      jsonb_build_array(jsonb_set(v_item, '{quantity}', to_jsonb(v_missing), true)),
      p_sale_id,
      p_reference_number
    );
    IF COALESCE((v_legacy->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_legacy;
    END IF;
    v_units := v_units || COALESCE(v_legacy->'units_deducted', '[]'::jsonb);
    v_raws := v_raws || COALESCE(v_legacy->'raw_materials_deducted', '[]'::jsonb);
    v_products := v_products || COALESCE(v_legacy->'ready_products_deducted', '[]'::jsonb);
    v_total_cost := v_total_cost + COALESCE((v_legacy->>'total_cost')::numeric, 0);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'unit_id', x.target_id,
    'quantity', x.quantity
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_units
  FROM (
    SELECT (e->>'unit_id')::uuid AS target_id, sum((e->>'quantity')::numeric) AS quantity
    FROM jsonb_array_elements(v_units) e
    GROUP BY (e->>'unit_id')::uuid
  ) x;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'raw_material_id', x.target_id,
    'quantity', x.quantity,
    'total_cost', x.total_cost
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_raws
  FROM (
    SELECT (e->>'raw_material_id')::uuid AS target_id,
           sum((e->>'quantity')::numeric) AS quantity,
           sum(COALESCE((e->>'total_cost')::numeric,0)) AS total_cost
    FROM jsonb_array_elements(v_raws) e
    GROUP BY (e->>'raw_material_id')::uuid
  ) x;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'product_id', x.target_id,
    'quantity', x.quantity,
    'total_cost', x.total_cost
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_products
  FROM (
    SELECT (e->>'product_id')::uuid AS target_id,
           sum((e->>'quantity')::numeric) AS quantity,
           sum(COALESCE((e->>'total_cost')::numeric,0)) AS total_cost
    FROM jsonb_array_elements(v_products) e
    GROUP BY (e->>'product_id')::uuid
  ) x;

  UPDATE pg_temp.kitchen_settlement_queue SET consumed = true WHERE seq = v_queue.seq;

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', v_raws,
    'ready_products_deducted', v_products,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public._finalize_kitchen_sale_settlement(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF to_regclass('pg_temp.kitchen_settlement_queue') IS NULL
     OR EXISTS (SELECT 1 FROM pg_temp.kitchen_settlement_queue WHERE NOT consumed) THEN
    RAISE EXCEPTION 'KITCHEN_SETTLEMENT_INCOMPLETE';
  END IF;

  UPDATE public.order_kitchen_inventory_events e
  SET settled_sale_id = p_sale_id
  WHERE e.order_item_id IN (SELECT order_item_id FROM pg_temp.kitchen_settlement_queue)
    AND e.settled_sale_id IS NULL;

  PERFORM set_config('app.kitchen_inventory_settlement', 'off', true);
  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL::uuid,
  p_reference_number text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF COALESCE(current_setting('app.kitchen_inventory_settlement', true), '') = 'on' THEN
    RETURN public._consume_kitchen_sale_settlement(
      p_branch_id, p_warehouse_id, p_items, p_reference_id, p_reference_number
    );
  END IF;
  RETURN public._deduct_sale_inventory_with_modifiers_core(
    p_branch_id, p_warehouse_id, p_items, p_reference_id, p_reference_number
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
  TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_warehouse_id uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_row record;
  v_event_id uuid;
  v_inventory jsonb;
  v_failure_product uuid;
  v_failure_name text;
BEGIN
  BEGIN
    IF auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    SELECT branch_id, status, order_number, table_id, order_type, guest_count, inventory_warehouse_id
    INTO v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count, v_warehouse_id
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF NOT public.user_may_access_branch(v_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
    IF NOT (public.is_platform_admin() OR public.can_permission('pos.send_kitchen')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'pos.send_kitchen');
    END IF;
    IF v_status NOT IN ('open','held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
    END IF;

    IF v_warehouse_id IS NULL THEN
      SELECT w.id INTO v_warehouse_id
      FROM public.warehouses w
      WHERE w.branch_id = v_branch_id AND w.is_active = true
      ORDER BY COALESCE(w.is_default, false) DESC, w.created_at, w.id
      LIMIT 1;
      IF v_warehouse_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_FOUND');
      END IF;
      UPDATE public.orders SET inventory_warehouse_id = v_warehouse_id WHERE id = p_order_id;
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name FROM public.dining_tables
      WHERE id = v_table_id AND branch_id = v_branch_id;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.kns_delta (
      order_item_id uuid PRIMARY KEY,
      send_id uuid,
      event_id uuid,
      delta_quantity numeric(14,4) NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.kns_delta;

    INSERT INTO pg_temp.kns_delta(order_item_id, event_id, delta_quantity)
    SELECT oi.id, gen_random_uuid(), oi.quantity - COALESCE(s.sent_quantity, 0)
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0);

    FOR v_row IN
      SELECT d.order_item_id, d.event_id, d.delta_quantity,
             oi.product_id, oi.modifier_option_ids, p.name AS product_name
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
      JOIN public.products p ON p.id = oi.product_id
      ORDER BY oi.created_at, oi.id
    LOOP
      v_failure_product := v_row.product_id;
      v_failure_name := v_row.product_name;
      v_inventory := public._deduct_sale_inventory_with_modifiers_core(
        v_branch_id,
        v_warehouse_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_row.product_id,
          'quantity', v_row.delta_quantity,
          'modifier_option_ids', to_jsonb(COALESCE(v_row.modifier_option_ids, '{}'::uuid[]))
        )),
        v_row.event_id,
        v_order_number
      );

      IF COALESCE((v_inventory->>'success')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'KITCHEN_INVENTORY_DEDUCTION_FAILED: %', COALESCE(v_inventory->>'detail', v_inventory->>'error', 'UNKNOWN');
      END IF;

      UPDATE public.inventory_unit_entries
      SET entry_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND entry_type='sale';
      UPDATE public.inventory_ledger
      SET entry_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND entry_type='sale';
      UPDATE public.stock_transactions
      SET transaction_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND transaction_type='sale';

      INSERT INTO public.order_kitchen_inventory_events(
        id, branch_id, warehouse_id, order_id, order_item_id, sent_quantity,
        total_cost, created_by
      ) VALUES (
        v_row.event_id, v_branch_id, v_warehouse_id, p_order_id, v_row.order_item_id,
        v_row.delta_quantity, COALESCE((v_inventory->>'total_cost')::numeric,0), auth.uid()
      );

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'inventory_unit',
             (e->>'unit_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((SELECT sum((-iue.quantity)*COALESCE(iue.unit_cost,0))
                       FROM public.inventory_unit_entries iue
                       WHERE iue.reference_id=v_row.event_id
                         AND iue.reference_type='kitchen_send'
                         AND iue.unit_id=(e->>'unit_id')::uuid
                         AND iue.quantity<0),0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'units_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'raw_material',
             (e->>'raw_material_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric,0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'raw_materials_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'product',
             (e->>'product_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric,0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'ready_products_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      -- Any error after the inventory executor is an implementation failure,
      -- not an insufficient-stock response for this product.
      v_failure_product:=NULL;
      v_failure_name:=NULL;
    END LOOP;

    WITH candidates AS (
      SELECT d.order_item_id, d.delta_quantity, oi.quantity AS target_quantity
      FROM pg_temp.kns_delta d JOIN public.order_items oi ON oi.id=d.order_item_id
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT v_branch_id, p_order_id, c.order_item_id, now(), auth.uid(), c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity=EXCLUDED.sent_quantity, sent_at=now(), sent_by=EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    UPDATE pg_temp.kns_delta d SET send_id=u.id FROM upserted u WHERE u.order_item_id=d.order_item_id;

    UPDATE public.order_kitchen_inventory_events e
    SET kitchen_send_id=d.send_id
    FROM pg_temp.kns_delta d
    WHERE e.id=d.event_id;

    SELECT count(*) INTO v_count FROM pg_temp.kns_delta;
    IF v_count>0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id',d.send_id,
        'order_item_id',d.order_item_id,
        'product_id',oi.product_id,
        'product_name',p.name,
        'unit_name',oi.unit_name,
        'station_code',COALESCE(ks.code,'main'),
        'quantity',d.delta_quantity,
        'current_quantity',oi.quantity,
        'unit_price',oi.unit_price,
        'discount_amount',oi.discount_amount,
        'bonus_quantity',oi.bonus_quantity,
        'total',oi.total,
        'notes',oi.notes,
        'modifiers',COALESCE(oi.modifiers_snapshot,'[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id=d.order_item_id
      LEFT JOIN public.products p ON p.id=oi.product_id
      LEFT JOIN public.categories c ON c.id=p.category_id AND c.branch_id=v_branch_id
      LEFT JOIN public.kitchen_stations ks ON ks.id=c.kitchen_station_id AND ks.is_active=true;
    END IF;

    SELECT NOT EXISTS(
      SELECT 1 FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id=oi.id
      WHERE oi.order_id=p_order_id AND oi.quantity>COALESCE(s.sent_quantity,0)
    ) INTO v_all_sent;

    RETURN jsonb_build_object(
      'success',true,'order_id',p_order_id,'order_number',v_order_number,
      'table_name',v_table_name,'order_type',v_order_type,'guest_count',v_guest_count,
      'warehouse_id',v_warehouse_id,'sent',v_sent_items,
      'items_sent_count',v_count,'all_sent',v_all_sent,'inventory_deducted',v_count>0
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success',false,
      'error',CASE WHEN v_failure_product IS NULL THEN 'TRANSACTION_FAILED' ELSE 'INSUFFICIENT_STOCK' END,
      'product_id',v_failure_product,
      'product_name',v_failure_name,
      'detail',SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid,uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._restore_kitchen_inventory_for_void(
  p_order_id uuid,
  p_order_item_id uuid,
  p_quantity numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_remaining numeric(14,6) := p_quantity;
  v_event record;
  v_effect record;
  v_take numeric(14,6);
  v_restore numeric(14,6);
  v_cost numeric(18,6);
  v_batch text;
  v_res jsonb;
  v_restored numeric(14,6) := 0;
BEGIN
  IF p_quantity IS NULL OR p_quantity<=0 THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY');
  END IF;

  FOR v_event IN
    SELECT * FROM public.order_kitchen_inventory_events
    WHERE order_id=p_order_id AND order_item_id=p_order_item_id
      AND sent_quantity>voided_quantity AND settled_sale_id IS NULL
    ORDER BY created_at DESC,id DESC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining<=0;
    v_take:=LEAST(v_remaining,v_event.sent_quantity-v_event.voided_quantity);

    FOR v_effect IN
      SELECT * FROM public.order_kitchen_inventory_effects
      WHERE event_id=v_event.id ORDER BY target_type,target_id
    LOOP
      v_restore:=round(v_effect.quantity*v_take/v_event.sent_quantity,6);
      IF v_restore<=0 THEN CONTINUE; END IF;
      v_cost:=CASE WHEN v_effect.quantity>0 THEN v_effect.total_cost/v_effect.quantity ELSE 0 END;
      v_batch:='KV-'||substr(replace(gen_random_uuid()::text,'-',''),1,12);

      IF v_effect.target_type='inventory_unit' THEN
        INSERT INTO public.inventory_unit_batches(
          unit_id,branch_id,warehouse_id,batch_number,quantity,unit_cost,production_date
        ) VALUES (
          v_effect.target_id,v_event.branch_id,v_event.warehouse_id,v_batch,v_restore,v_cost,CURRENT_DATE
        );
        INSERT INTO public.inventory_unit_entries(
          unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,
          reference_type,reference_id,reference_number,batch_number,created_by
        ) VALUES (
          v_effect.target_id,v_event.branch_id,v_event.warehouse_id,v_restore,v_cost,'kitchen_void',
          'kitchen_send',v_event.id,p_order_id::text,v_batch,auth.uid()
        );
      ELSIF v_effect.target_type='raw_material' THEN
        v_res:=public._raw_add(
          v_effect.target_id,v_event.branch_id,v_restore,v_cost,v_batch,CURRENT_DATE,NULL,
          'kitchen_void','kitchen_send',v_event.id,p_order_id::text,auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean,false) IS NOT TRUE THEN
          RAISE EXCEPTION 'KITCHEN_VOID_RAW_RESTORE_FAILED: %',v_res;
        END IF;
      ELSE
        v_res:=public._product_inv_add(
          v_effect.target_id,v_event.warehouse_id,v_event.branch_id,v_restore,v_cost,v_batch,
          CURRENT_DATE,NULL,'kitchen_void','kitchen_send',v_event.id,p_order_id::text,auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean,false) IS NOT TRUE THEN
          RAISE EXCEPTION 'KITCHEN_VOID_PRODUCT_RESTORE_FAILED: %',v_res;
        END IF;
      END IF;
    END LOOP;

    UPDATE public.order_kitchen_inventory_events
    SET voided_quantity=voided_quantity+v_take WHERE id=v_event.id;
    v_remaining:=v_remaining-v_take;
    v_restored:=v_restored+v_take;
  END LOOP;

  RETURN jsonb_build_object(
    'success',true,
    'inventory_changed',v_restored>0,
    'restored_sent_quantity',v_restored,
    'legacy_untracked_quantity',GREATEST(v_remaining,0)
  );
END;
$function$;

-- Force every sent-line reduction, including managers, through the audited RPC
-- so no direct UPDATE can bypass exact inventory restoration.
CREATE OR REPLACE FUNCTION public.guard_sent_order_item_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_is_sent boolean;
  v_is_reduction boolean:=false;
  v_internal boolean:=COALESCE(current_setting('app.approved_sent_item_void',true),'')='1';
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id=OLD.id)
  INTO v_is_sent;
  IF NOT v_is_sent THEN RETURN COALESCE(NEW,OLD); END IF;
  IF TG_OP='DELETE' THEN v_is_reduction:=true;
  ELSIF TG_OP='UPDATE' AND COALESCE(NEW.quantity,0)<COALESCE(OLD.quantity,0) THEN v_is_reduction:=true;
  END IF;
  IF v_is_reduction AND NOT v_internal THEN
    RAISE EXCEPTION 'SENT_ITEM_APPROVAL_REQUIRED' USING ERRCODE='P0001';
  END IF;
  RETURN COALESCE(NEW,OLD);
END;
$function$;

DO $patch_exact_void$
DECLARE
  v_oid regprocedure:=to_regprocedure('public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN RAISE EXCEPTION 'EXACT_SENT_VOID_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(v_def,'  v_privileged boolean := false;',E'  v_privileged boolean := false;\n  v_inventory jsonb;');
  v_new:=replace(
    v_new,
    '  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);',
    E'  v_inventory := public._restore_kitchen_inventory_for_void(p_order_id, v_item.id, p_quantity);\n  IF COALESCE((v_inventory->>''success'')::boolean, false) IS NOT TRUE THEN\n    RETURN v_inventory;\n  END IF;\n\n  UPDATE public.order_kitchen_sends\n  SET sent_quantity = GREATEST(sent_quantity - p_quantity, 0), sent_at = now(), sent_by = auth.uid()\n  WHERE order_item_id = v_item.id;\n\n  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);'
  );
  v_new:=replace(
    v_new,
    '''inventory_changed'', false',
    '''inventory_changed'', COALESCE((v_inventory->>''inventory_changed'')::boolean, false)'
  );
  IF v_new=v_def OR position('_restore_kitchen_inventory_for_void' IN v_new)=0 THEN
    RAISE EXCEPTION 'EXACT_SENT_VOID_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;
END;
$patch_exact_void$;

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item_id uuid;
  v_count integer;
BEGIN
  SELECT count(*),min(oi.id)
  INTO v_count,v_item_id
  FROM public.order_items oi
  WHERE oi.order_id=p_order_id AND oi.product_id=p_product_id
    AND EXISTS(SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id=oi.id);
  IF v_count=0 THEN RETURN jsonb_build_object('success',false,'error','SENT_ITEM_NOT_FOUND'); END IF;
  IF v_count>1 THEN
    RETURN jsonb_build_object('success',false,'error','AMBIGUOUS_SENT_ITEM',
      'detail','Use cancel_sent_order_item_exact with order_item_id','matching_lines',v_count);
  END IF;
  RETURN public.cancel_sent_order_item_exact(p_order_id,v_item_id,p_quantity,p_reason);
END;
$function$;

REVOKE ALL ON FUNCTION public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._consume_kitchen_sale_settlement(uuid,uuid,jsonb,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._finalize_kitchen_sale_settlement(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._restore_kitchen_inventory_for_void(uuid,uuid,numeric) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._consume_kitchen_sale_settlement(uuid,uuid,jsonb,uuid,text) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._finalize_kitchen_sale_settlement(uuid) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._restore_kitchen_inventory_for_void(uuid,uuid,numeric) TO service_role,postgres;
REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;
REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated,service_role;

-- Patch both payment entry points around the preserved sale core. The inventory
-- executor sees a transaction-local settlement context and therefore returns
-- the kitchen effects instead of deducting them a second time.
DO $patch_sale_entry_points$
DECLARE
  v_oid regprocedure;
  v_def text;
  v_new text;
BEGIN
  v_oid:=to_regprocedure('public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'PROCESS_SALE_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(
    v_def,
    '  v_result:=public._process_sale_core(',
    E'  IF p_order_id IS NOT NULL THEN\n    v_result := public._prepare_kitchen_sale_settlement(p_order_id,p_branch_id,p_warehouse_id,p_items);\n    IF COALESCE((v_result->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_result; END IF;\n  END IF;\n\n  v_result:=public._process_sale_core('
  );
  v_new:=replace(
    v_new,
    '  IF p_order_id IS NOT NULL AND COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN',
    E'  IF p_order_id IS NOT NULL THEN\n    PERFORM set_config(''app.kitchen_inventory_settlement'',''off'',true);\n    IF COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN\n      v_result := v_result || public._finalize_kitchen_sale_settlement(NULLIF(v_result->>''sale_id'','''')::uuid);\n    END IF;\n  END IF;\n\n  IF p_order_id IS NOT NULL AND COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN'
  );
  IF v_new=v_def OR position('_prepare_kitchen_sale_settlement' IN v_new)=0
     OR position('_finalize_kitchen_sale_settlement' IN v_new)=0 THEN
    RAISE EXCEPTION 'PROCESS_SALE_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;

  v_oid:=to_regprocedure('public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'PROCESS_SALE_SPLIT_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(
    v_def,
    '    v_core := public._process_sale_core(',
    E'    IF p_order_id IS NOT NULL THEN\n      v_core := public._prepare_kitchen_sale_settlement(p_order_id,p_branch_id,p_warehouse_id,p_items);\n      IF COALESCE((v_core->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_core; END IF;\n    END IF;\n\n    v_core := public._process_sale_core('
  );
  v_new:=replace(
    v_new,
    '    IF COALESCE((v_core->>''success'')::boolean, false) IS NOT TRUE THEN',
    E'    IF p_order_id IS NOT NULL THEN\n      PERFORM set_config(''app.kitchen_inventory_settlement'',''off'',true);\n      IF COALESCE((v_core->>''success'')::boolean,false) IS TRUE THEN\n        v_core := v_core || public._finalize_kitchen_sale_settlement(NULLIF(v_core->>''sale_id'','''')::uuid);\n      END IF;\n    END IF;\n\n    IF COALESCE((v_core->>''success'')::boolean, false) IS NOT TRUE THEN'
  );
  IF v_new=v_def OR position('_prepare_kitchen_sale_settlement' IN v_new)=0
     OR position('_finalize_kitchen_sale_settlement' IN v_new)=0 THEN
    RAISE EXCEPTION 'PROCESS_SALE_SPLIT_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;
END;
$patch_sale_entry_points$;
