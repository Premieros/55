CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_purchase public.purchases%ROWTYPE;
  v_is_fully_returned boolean := false;
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

  IF v_purchase.status = 'returned' THEN
    SELECT COALESCE(bool_and(COALESCE(returned_quantity, 0) >= quantity), false)
      INTO v_is_fully_returned
    FROM public.purchase_items
    WHERE purchase_id = p_purchase_id;

    IF NOT v_is_fully_returned OR COALESCE(v_purchase.returned_amount, 0) < COALESCE(v_purchase.total, 0) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FULLY_RETURNED', 'detail', 'Only fully returned purchases can be deleted.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.supplier_payments WHERE purchase_id = p_purchase_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_HAS_SUPPLIER_PAYMENTS', 'detail', 'Purchase has supplier payments and cannot be deleted.');
    END IF;

    -- Inventory/accounting reversal records are intentionally preserved for audit.
    DELETE FROM public.purchases WHERE id = p_purchase_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (
      auth.uid(),
      'delete',
      'purchase',
      p_purchase_id,
      jsonb_build_object(
        'invoice_number', v_purchase.invoice_number,
        'status', v_purchase.status,
        'fully_returned', true,
        'preserved_reversal_audit', true
      ),
      v_purchase.branch_id
    );

    RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id, 'invoice_number', v_purchase.invoice_number, 'deleted_after_full_return', true);
  END IF;

  IF v_purchase.status NOT IN ('draft','cancelled') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_REVERSAL_REQUIRED', 'detail', 'Completed, approved, submitted or partial purchases must be reversed/returned before deletion.');
  END IF;

  IF EXISTS (SELECT 1 FROM public.inventory_ledger WHERE reference_type = 'purchase' AND reference_id = p_purchase_id)
     OR EXISTS (SELECT 1 FROM public.journal_entries WHERE reference_type = 'purchase' AND reference_id = p_purchase_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_HAS_POSTINGS', 'detail', 'Purchase has inventory/accounting postings and cannot be hard-deleted before reversal.');
  END IF;

  DELETE FROM public.purchases WHERE id = p_purchase_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (auth.uid(),'delete','purchase',p_purchase_id,jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),v_purchase.branch_id);

  RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id, 'invoice_number', v_purchase.invoice_number);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;
