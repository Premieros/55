-- Safe purchase invoice deletion.
-- Only non-posted invoices may be physically deleted. Completed/received invoices
-- must go through the existing return/reversal workflow so inventory and accounting
-- history cannot be silently removed.

CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase public.purchases%ROWTYPE;
  v_role text;
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

  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF NOT public.can_permission('purchases.manage')
     AND v_role NOT IN ('super_admin','owner','branch_manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
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
  ) OR EXISTS (
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
    auth.uid(),
    'delete',
    'purchase',
    p_purchase_id,
    jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),
    v_purchase.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'invoice_number', v_purchase.invoice_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;
