-- Keep the KDS communicated quantity aligned with the order line after an
-- approved kitchen void. The inventory-boundary migration already adjusts the
-- send row before writing the void audit row, while the legacy trigger also
-- subtracts the void quantity. Subtracting twice makes the next send look like
-- a fresh positive delta and can deduct inventory again.
--
-- Make the trigger idempotent: after the void finishes, the authoritative net
-- sent quantity is simply the current order-item quantity (or zero when the
-- line was fully removed).
CREATE OR REPLACE FUNCTION public.sync_kitchen_sent_quantity_after_void()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_current_quantity numeric(14,4);
BEGIN
  IF NEW.order_item_id IS NOT NULL THEN
    SELECT oi.quantity
    INTO v_current_quantity
    FROM public.order_items oi
    WHERE oi.id = NEW.order_item_id;

    UPDATE public.order_kitchen_sends
    SET sent_quantity = GREATEST(COALESCE(v_current_quantity, 0), 0),
        sent_at = now(),
        sent_by = COALESCE(NEW.voided_by, sent_by)
    WHERE order_item_id = NEW.order_item_id;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.sync_kitchen_sent_quantity_after_void()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_kitchen_sent_quantity_after_void()
  TO service_role;
