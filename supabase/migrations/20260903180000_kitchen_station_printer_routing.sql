-- Browser POS printer routing: keep physical printer names local to the Windows
-- terminal, but return the authoritative KDS station for each delta sent by
-- send_to_kitchen. No inventory/accounting semantics change.

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
) RETURNS jsonb
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
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  BEGIN
    SELECT branch_id, status, order_number, table_id, order_type, guest_count
      INTO v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count
    FROM public.orders
    WHERE id = p_order_id;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name
      FROM public.dining_tables
      WHERE id = v_table_id AND branch_id = v_branch_id;
    END IF;

    IF NOT v_is_service_role THEN
      IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
      END IF;

      SELECT branch_id INTO v_user_branch
      FROM public.users
      WHERE id = auth.uid() AND is_active = true;

      IF NOT is_pos_admin()
         AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;

      IF NOT is_pos_admin() AND NOT can_permission('pos.send_kitchen') THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'PERMISSION_DENIED',
          'detail', 'pos.send_kitchen'
        );
      END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

    WITH candidates AS (
      SELECT
        oi.id AS order_item_id,
        oi.quantity AS target_quantity,
        oi.quantity - COALESCE(s.sent_quantity, 0) AS delta_quantity
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT
        v_branch_id,
        p_order_id,
        c.order_item_id,
        now(),
        COALESCE(p_sent_by, auth.uid()),
        c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity = EXCLUDED.sent_quantity,
          sent_at = now(),
          sent_by = EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    INSERT INTO _kns_delta(order_item_id, send_id, delta_quantity)
    SELECT u.order_item_id, u.id, c.delta_quantity
    FROM upserted u
    JOIN candidates c ON c.order_item_id = u.order_item_id;

    SELECT COUNT(*) INTO v_count FROM _kns_delta;

    IF v_count > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id', k.send_id,
        'order_item_id', k.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'station_code', COALESCE(ks.code, 'main'),
        'quantity', k.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', COALESCE(oi.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM _kns_delta k
      JOIN public.order_items oi ON oi.id = k.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN public.categories c
        ON c.id = p.category_id AND c.branch_id = v_branch_id
      LEFT JOIN public.kitchen_stations ks
        ON ks.id = c.kitchen_station_id AND ks.is_active = true;
    END IF;

    SELECT NOT EXISTS (
      SELECT 1
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ) INTO v_all_sent;

    RETURN jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_FAILED',
      'detail', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;
