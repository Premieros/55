-- Track the quantity already communicated to KDS for each stable order_item_id.
-- Increasing a previously-sent line sends only the positive delta. Kitchen
-- voids reduce the communicated quantity so later increases are also correct.

ALTER TABLE public.order_kitchen_sends
  ADD COLUMN IF NOT EXISTS sent_quantity numeric(14,4) NOT NULL DEFAULT 0;

-- Existing snapshot rows represented the then-current quantity. Any historical
-- approved void already changed order_items, so current quantity is the correct
-- net quantity the kitchen should be considered to have after that void event.
UPDATE public.order_kitchen_sends s
SET sent_quantity = GREATEST(COALESCE(oi.quantity, 0), 0)
FROM public.order_items oi
WHERE oi.id = s.order_item_id
  AND s.sent_quantity = 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.order_kitchen_sends'::regclass
      AND conname = 'order_kitchen_sends_sent_quantity_nonnegative'
  ) THEN
    ALTER TABLE public.order_kitchen_sends
      ADD CONSTRAINT order_kitchen_sends_sent_quantity_nonnegative
      CHECK (sent_quantity >= 0);
  END IF;
END $$;

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
BEGIN
  BEGIN
    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders WHERE id = p_order_id;
    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.');
    END IF;

    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF NOT is_pos_admin()
       AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

    -- Candidate delta is current cart quantity minus the net quantity already
    -- communicated to KDS. The conflict WHERE clause is concurrency-safe: if a
    -- second sender races after the first reaches the target quantity, it gets
    -- no RETURNING row and therefore prints no duplicate ticket.
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
        'notes', oi.notes
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
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

-- An approved kitchen void is itself a communication to the kitchen. Keep the
-- net communicated quantity aligned with that void so future increases send the
-- correct delta rather than comparing against the pre-void quantity.
CREATE OR REPLACE FUNCTION public.sync_kitchen_sent_quantity_after_void()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NEW.order_item_id IS NOT NULL THEN
    UPDATE public.order_kitchen_sends
    SET sent_quantity = GREATEST(sent_quantity - NEW.quantity, 0)
    WHERE order_item_id = NEW.order_item_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_kitchen_sent_quantity_after_void
  ON public.order_kitchen_voids;
CREATE TRIGGER trg_sync_kitchen_sent_quantity_after_void
AFTER INSERT ON public.order_kitchen_voids
FOR EACH ROW EXECUTE FUNCTION public.sync_kitchen_sent_quantity_after_void();

REVOKE ALL ON FUNCTION public.sync_kitchen_sent_quantity_after_void() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_kitchen_sent_quantity_after_void() TO service_role;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;
