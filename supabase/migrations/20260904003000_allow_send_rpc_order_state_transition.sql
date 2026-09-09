-- A cashier may send an order to the kitchen without having KDS-management
-- permission. The send_to_kitchen RPC writes order_kitchen_sends first, then
-- synchronizes orders.kitchen_status from pending -> sent. The generic orders
-- mutation guard previously treated that synchronization as a KDS-management
-- action and rejected it because cashier intentionally lacks pos.kds_view.
--
-- Keep the separation strict:
--   * pending -> sent is allowed with pos.send_kitchen only after an actual
--     kitchen-send snapshot exists for the order.
--   * cooking / ready / served and all other KDS status changes still require
--     pos.kds_view.
--   * direct order edits remain subject to the existing POS permissions.

CREATE OR REPLACE FUNCTION public.enforce_pos_permission_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  IF v_is_service_role OR v_uid IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'sales' THEN
    IF TG_OP = 'INSERT' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_kitchen_sends' THEN
    IF NOT public.can_permission('pos.send_kitchen') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.send_kitchen';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF OLD.kitchen_status = 'pending'
         AND NEW.kitchen_status = 'sent'
         AND public.can_permission('pos.send_kitchen')
         AND EXISTS (
           SELECT 1
           FROM public.order_kitchen_sends s
           WHERE s.order_id = OLD.id
         ) THEN
        RETURN NEW;
      END IF;

      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.station IS DISTINCT FROM OLD.station
       AND (to_jsonb(NEW) - ARRAY['station','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['station','updated_at']::text[]) THEN
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'cancelled' AND NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      ELSIF NEW.status = 'completed' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
      ELSIF NEW.status IN ('open', 'held') AND NOT public.can_permission('pos.hold') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.hold';
      END IF;
    END IF;

    IF NEW.table_id IS DISTINCT FROM OLD.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT public.can_permission('pos.transfer_order') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.transfer_order';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.table_id IS NOT DISTINCT FROM OLD.table_id
       AND NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.void') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.void';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      IF NOT public.can_permission('pos.split_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.split_order';
      END IF;
    ELSIF NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;
