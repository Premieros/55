-- Keep POS sending and KDS management as separate capabilities.
-- send_to_kitchen is the authoritative SECURITY DEFINER boundary, while direct
-- writes to order_kitchen_sends remain protected by RLS. Avoid a nested trigger
-- permission check inside the SECURITY DEFINER RPC.

DROP TRIGGER IF EXISTS trg_pos_permission_kitchen_sends ON public.order_kitchen_sends;

DROP POLICY IF EXISTS "auth_select_order_kitchen_sends" ON public.order_kitchen_sends;
CREATE POLICY "auth_select_order_kitchen_sends"
ON public.order_kitchen_sends FOR SELECT TO authenticated
USING (
  is_pos_admin()
  OR (
    branch_id = get_branch_id()
    AND (can_permission('pos.send_kitchen') OR can_permission('pos.kds_view'))
  )
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends"
ON public.order_kitchen_sends FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends_upd" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends_upd"
ON public.order_kitchen_sends FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
)
WITH CHECK (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends_del" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends_del"
ON public.order_kitchen_sends FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

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
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  BEGIN
    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders WHERE id = p_order_id;

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
      LEFT JOIN public.products p ON p.id = oi.product_id;
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
