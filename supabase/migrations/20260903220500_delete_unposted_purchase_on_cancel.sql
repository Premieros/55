-- Make the existing cancel action behave as a real delete for unposted purchase invoices.
-- This avoids requiring a new frontend button immediately while preserving accounting safety.

CREATE OR REPLACE FUNCTION public.delete_unposted_purchase_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'cancelled'
     AND OLD.status IN ('draft','submitted')
     AND NOT EXISTS (
       SELECT 1 FROM public.inventory_ledger
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.journal_entries
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     ) THEN
    DELETE FROM public.purchases WHERE id = NEW.id;
    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_unposted_purchase_on_cancel ON public.purchases;
CREATE TRIGGER trg_delete_unposted_purchase_on_cancel
AFTER UPDATE OF status ON public.purchases
FOR EACH ROW
WHEN (NEW.status = 'cancelled')
EXECUTE FUNCTION public.delete_unposted_purchase_on_cancel();
