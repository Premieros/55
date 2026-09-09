-- Dedicated permission for hard-deleting unposted purchase drafts/cancellations.
-- Completed/posted purchases remain protected and require reversal/return.

UPDATE public.roles
SET permissions = CASE
  WHEN permissions ? 'purchases.delete' THEN permissions
  ELSE permissions || jsonb_build_array('purchases.delete')
END,
updated_at = now()
WHERE role IN ('super_admin', 'owner', 'branch_manager');

CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_purchase public.purchases%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_purchase
  FROM public.purchases
  WHERE id = p_purchase_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_purchase.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.can_permission('purchases.delete') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED', 'detail', 'purchases.delete permission is required.');
  END IF;

  IF v_purchase.status NOT IN ('draft','cancelled') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_REVERSAL_REQUIRED',
      'detail', 'Completed, approved, submitted, partial or returned purchases cannot be hard-deleted; reverse/return them first.'
    );
  END IF;

  IF EXISTS (
       SELECT 1 FROM public.inventory_ledger
       WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
     )
     OR EXISTS (
       SELECT 1 FROM public.journal_entries
       WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_HAS_POSTINGS',
      'detail', 'Purchase has inventory/accounting postings and cannot be hard-deleted.'
    );
  END IF;

  DELETE FROM public.purchases WHERE id = p_purchase_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (
    auth.uid(), 'delete', 'purchase', p_purchase_id,
    jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),
    v_purchase.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'invoice_number', v_purchase.invoice_number
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_unposted_purchase_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.status = 'cancelled'
     AND OLD.status IN ('draft','submitted')
     AND public.can_permission('purchases.delete')
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
$function$;
