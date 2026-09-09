-- Atomic post-sale payment-method correction with manager approval.
-- Keeps sales, shift operations and the accounting journal consistent.

CREATE OR REPLACE FUNCTION public.change_sale_payment_method(
  p_sale_id uuid,
  p_new_method text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_sale record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
  v_entry_id uuid;
  v_old_account uuid;
  v_new_account uuid;
  v_old_key text;
  v_new_key text;
  v_changed integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  p_new_method := lower(btrim(COALESCE(p_new_method, '')));
  IF p_new_method NOT IN ('cash', 'card', 'transfer') THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNSUPPORTED_PAYMENT_METHOD',
      'detail', 'Only cash, card and transfer can be corrected after sale. Credit requires a receivables workflow.');
  END IF;

  SELECT id, branch_id, payment_method, paid_amount, status, invoice_number
    INTO v_sale
  FROM public.sales
  WHERE id = p_sale_id
  FOR UPDATE;

  IF v_sale.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SALE_NOT_FOUND');
  END IF;

  IF v_sale.status = 'returned' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SALE_RETURNED');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_sale.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF lower(COALESCE(v_sale.payment_method, 'cash')) = p_new_method THEN
    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'payment_method', p_new_method, 'unchanged', true);
  END IF;

  -- Branch manager/admin can execute directly. Other operators require a
  -- one-time approval that explicitly names the requested destination method.
  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_sale.branch_id
      AND ar.action_type = 'change_payment_method'
      AND ar.entity_type = 'sale'
      AND ar.entity_id = p_sale_id
      AND ar.status = 'approved'
      AND ar.consumed_at IS NULL
      AND ar.expires_at > now()
      AND lower(COALESCE(ar.payload->>'new_method', '')) = p_new_method
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_approval_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED',
        'action_type', 'change_payment_method', 'entity_type', 'sale',
        'entity_id', p_sale_id, 'new_method', p_new_method);
    END IF;
  END IF;

  v_old_key := CASE WHEN lower(COALESCE(v_sale.payment_method, 'cash')) = 'cash' THEN 'cash' ELSE 'bank' END;
  v_new_key := CASE WHEN p_new_method = 'cash' THEN 'cash' ELSE 'bank' END;

  -- Validate the accounting correction before any write.
  IF COALESCE(v_sale.paid_amount, 0) > 0 AND v_old_key <> v_new_key THEN
    v_old_account := public.resolve_account_key(v_sale.branch_id, v_old_key);
    v_new_account := public.resolve_account_key(v_sale.branch_id, v_new_key);

    SELECT id INTO v_entry_id
    FROM public.journal_entries
    WHERE branch_id = v_sale.branch_id
      AND reference_type = 'sale'
      AND reference_id = p_sale_id
    LIMIT 1;

    IF v_entry_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'SALE_JOURNAL_NOT_FOUND');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.journal_entry_lines
      WHERE journal_entry_id = v_entry_id
        AND account_id = v_old_account
        AND debit > 0
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_JOURNAL_LINE_NOT_FOUND',
        'old_method', v_sale.payment_method);
    END IF;
  END IF;

  UPDATE public.sales
  SET payment_method = p_new_method,
      notes = CASE WHEN p_reason IS NULL OR btrim(p_reason) = '' THEN notes
                   ELSE concat_ws(E'\n', NULLIF(notes, ''), 'Payment method changed: ' || p_reason) END
  WHERE id = p_sale_id;

  UPDATE public.shift_operations
  SET payment_method = p_new_method
  WHERE operation_type = 'sale'
    AND reference_type = 'sale'
    AND reference_id = p_sale_id;

  GET DIAGNOSTICS v_changed = ROW_COUNT;

  IF COALESCE(v_sale.paid_amount, 0) > 0 AND v_old_key <> v_new_key THEN
    UPDATE public.journal_entry_lines
    SET account_id = v_new_account
    WHERE journal_entry_id = v_entry_id
      AND account_id = v_old_account
      AND debit > 0;
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'change_payment_method'
      AND entity_type = 'sale'
      AND entity_id = p_sale_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'CHANGE_PAYMENT_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  PERFORM public.log_audit_action(v_sale.branch_id, 'change_payment_method', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number,
      'old_method', v_sale.payment_method, 'new_method', p_new_method,
      'reason', p_reason, 'shift_rows_updated', v_changed));

  RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
    'old_method', v_sale.payment_method, 'payment_method', p_new_method);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.change_sale_payment_method(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_sale_payment_method(uuid,text,text) TO authenticated, service_role;
