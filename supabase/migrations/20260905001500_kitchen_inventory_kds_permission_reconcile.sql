-- Reconcile the authoritative kitchen-inventory boundary with the newer KDS
-- lifecycle and granular POS permission model. This migration intentionally
-- runs after 20260904050000_kitchen_send_inventory_boundary.sql.

DO $preflight$
BEGIN
  IF to_regclass('public.order_kitchen_inventory_events') IS NULL
     OR to_regclass('public.order_kitchen_inventory_effects') IS NULL
     OR to_regprocedure('public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)') IS NULL
     OR to_regprocedure('public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_INVENTORY_BOUNDARY_REQUIRED';
  END IF;
END;
$preflight$;

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
  v_inventory jsonb;
  v_failure_product uuid;
  v_failure_name text;
  v_first_sent_at timestamptz;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
  v_effective_sent_by uuid;
BEGIN
  BEGIN
    IF NOT v_is_service_role AND auth.uid() IS NULL THEN
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

    IF NOT v_is_service_role THEN
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
      IF NOT (public.is_platform_admin() OR public.can_permission('pos.send_kitchen')) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'pos.send_kitchen');
      END IF;
    END IF;

    IF v_status NOT IN ('open','held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
    END IF;

    IF v_warehouse_id IS NULL THEN
      SELECT w.id INTO v_warehouse_id
      FROM public.warehouses w
      WHERE w.branch_id = v_branch_id
        AND w.is_active = true
      ORDER BY COALESCE(w.is_default, false) DESC, w.created_at, w.id
      LIMIT 1;

      IF v_warehouse_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_FOUND');
      END IF;

      UPDATE public.orders
      SET inventory_warehouse_id = v_warehouse_id
      WHERE id = p_order_id;
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name
      FROM public.dining_tables
      WHERE id = v_table_id
        AND branch_id = v_branch_id;
    END IF;

    v_effective_sent_by := CASE
      WHEN v_is_service_role THEN COALESCE(p_sent_by, auth.uid())
      ELSE auth.uid()
    END;

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
        RAISE EXCEPTION 'KITCHEN_INVENTORY_DEDUCTION_FAILED: %',
          COALESCE(v_inventory->>'detail', v_inventory->>'error', 'UNKNOWN');
      END IF;

      UPDATE public.inventory_unit_entries
      SET entry_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND entry_type = 'sale';

      UPDATE public.inventory_ledger
      SET entry_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND entry_type = 'sale';

      UPDATE public.stock_transactions
      SET transaction_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND transaction_type = 'sale';

      INSERT INTO public.order_kitchen_inventory_events(
        id, branch_id, warehouse_id, order_id, order_item_id, sent_quantity,
        total_cost, created_by
      ) VALUES (
        v_row.event_id, v_branch_id, v_warehouse_id, p_order_id, v_row.order_item_id,
        v_row.delta_quantity, COALESCE((v_inventory->>'total_cost')::numeric, 0), auth.uid()
      );

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'inventory_unit',
             (e->>'unit_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((
               SELECT sum((-iue.quantity) * COALESCE(iue.unit_cost, 0))
               FROM public.inventory_unit_entries iue
               WHERE iue.reference_id = v_row.event_id
                 AND iue.reference_type = 'kitchen_send'
                 AND iue.unit_id = (e->>'unit_id')::uuid
                 AND iue.quantity < 0
             ), 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'units_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'raw_material',
             (e->>'raw_material_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric, 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'raw_materials_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'product',
             (e->>'product_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric, 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'ready_products_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      v_failure_product := NULL;
      v_failure_name := NULL;
    END LOOP;

    WITH candidates AS (
      SELECT d.order_item_id, d.delta_quantity, oi.quantity AS target_quantity
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT v_branch_id, p_order_id, c.order_item_id, now(), v_effective_sent_by, c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity = EXCLUDED.sent_quantity,
          sent_at = now(),
          sent_by = EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    UPDATE pg_temp.kns_delta d
    SET send_id = u.id
    FROM upserted u
    WHERE u.order_item_id = d.order_item_id;

    UPDATE public.order_kitchen_inventory_events e
    SET kitchen_send_id = d.send_id
    FROM pg_temp.kns_delta d
    WHERE e.id = d.event_id;

    SELECT count(*) INTO v_count FROM pg_temp.kns_delta;

    IF v_count > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id', d.send_id,
        'order_item_id', d.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'station_code', COALESCE(ks.code, 'main'),
        'quantity', d.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', COALESCE(oi.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN public.categories c ON c.id = p.category_id AND c.branch_id = v_branch_id
      LEFT JOIN public.kitchen_stations ks ON ks.id = c.kitchen_station_id AND ks.is_active = true;
    END IF;

    SELECT NOT EXISTS(
      SELECT 1
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ) INTO v_all_sent;

    SELECT min(s.sent_at)
    INTO v_first_sent_at
    FROM public.order_kitchen_sends s
    WHERE s.order_id = p_order_id;

    IF v_first_sent_at IS NOT NULL THEN
      UPDATE public.orders
      SET kitchen_status = CASE
            WHEN kitchen_status = 'pending' THEN 'sent'
            ELSE kitchen_status
          END,
          kitchen_sent_at = COALESCE(kitchen_sent_at, v_first_sent_at)
      WHERE id = p_order_id;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'warehouse_id', v_warehouse_id,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent,
      'inventory_deducted', v_count > 0
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', CASE WHEN v_failure_product IS NULL THEN 'TRANSACTION_FAILED' ELSE 'INSUFFICIENT_STOCK' END,
      'product_id', v_failure_product,
      'product_name', v_failure_name,
      'detail', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid,uuid) TO authenticated, service_role;

-- Eliminate the legacy one-argument path as an inventory bypass. Keep the RPC
-- for compatibility, but delegate every call to the authoritative implementation.
CREATE OR REPLACE FUNCTION public.send_to_kitchen(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  RETURN public.send_to_kitchen(p_order_id, auth.uid());
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid) TO authenticated, service_role;
