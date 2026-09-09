-- Refund approval hardening.
-- Managers/admins with refunds.approve keep direct execution.
-- Other operators (cashier) require an approved, unexpired request that matches
-- the exact sale, requester, branch and action. The approval row is locked for
-- the whole refund transaction and consumed only after a successful refund.
-- Also preserve the original payment method in shift refund movements so card
-- refunds never reduce the physical cash drawer.

DO $migration$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT p.oid
    INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'process_refund'
    AND p.oid::regprocedure::text = 'process_refund(uuid,jsonb,text)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'process_refund(uuid,jsonb,text) not found';
  END IF;

  v_def := pg_get_functiondef(v_oid);

  IF position('v_approval_id uuid;' in v_def) = 0 THEN
    v_old := '  v_diff numeric(14,2);';
    v_new := '  v_diff numeric(14,2);' || E'\n' || '  v_approval_id uuid;';
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund declaration marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('APPROVAL_REQUIRED' in v_def) = 0 THEN
    v_old := $old$    -- Permission: refunds.approve (admins always pass)
    IF NOT is_pos_admin() AND NOT can_permission('refunds.approve') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'You need the refunds.approve permission.');
    END IF;$old$;

    v_new := $new$    -- Permission: managers/admins execute directly. Cashiers need a matching manager approval.
    IF NOT is_pos_admin() AND NOT can_permission('refunds.approve') THEN
      SELECT ar.id
        INTO v_approval_id
      FROM public.approval_requests ar
      WHERE ar.requester_id = auth.uid()
        AND ar.branch_id = v_sale.branch_id
        AND ar.action_type = 'refund'
        AND ar.entity_type = 'sale'
        AND ar.entity_id = p_sale_id
        AND ar.status = 'approved'
        AND ar.consumed_at IS NULL
        AND ar.expires_at > now()
      ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
      LIMIT 1
      FOR UPDATE SKIP LOCKED;

      IF v_approval_id IS NULL THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'APPROVAL_REQUIRED',
          'action_type', 'refund',
          'entity_type', 'sale',
          'entity_id', p_sale_id
        );
      END IF;
    END IF;$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund permission marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  -- The original refund function did not select payment_method into v_sale and
  -- hard-coded every shift refund as cash. Preserve the sale payment method.
  IF position('payment_method, invoice_number' in v_def) = 0 THEN
    v_old := 'SELECT id, branch_id, warehouse_id, status, total, paid_amount, customer_id, invoice_number';
    v_new := 'SELECT id, branch_id, warehouse_id, status, total, paid_amount, customer_id, payment_method, invoice_number';
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund sale select marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position($needle$COALESCE(v_sale.payment_method, 'cash')$needle$ in v_def) = 0 THEN
    v_old := $old$VALUES (v_shift_id, 'refund', v_refund_total, 'cash', 'refund', p_sale_id, auth.uid());$old$;
    v_new := $new$VALUES (v_shift_id, 'refund', v_refund_total, COALESCE(v_sale.payment_method, 'cash'), 'refund', p_sale_id, auth.uid());$new$;
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund shift payment marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('REFUND_APPROVAL_CONSUME_FAILED' in v_def) = 0 THEN
    v_old := $old$    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'refunded_amount', v_refund_total, 'fully_refunded', v_all_refunded);$old$;

    v_new := $new$    IF v_approval_id IS NOT NULL THEN
      UPDATE public.approval_requests
      SET status = 'consumed', consumed_at = now()
      WHERE id = v_approval_id
        AND requester_id = auth.uid()
        AND action_type = 'refund'
        AND entity_type = 'sale'
        AND entity_id = p_sale_id
        AND status = 'approved'
        AND consumed_at IS NULL
        AND expires_at > now();

      IF NOT FOUND THEN
        RAISE EXCEPTION 'REFUND_APPROVAL_CONSUME_FAILED';
      END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'refunded_amount', v_refund_total, 'fully_refunded', v_all_refunded);$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund success marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  -- Keep SECURITY DEFINER functions hardened against temp-schema object shadowing.
  v_def := replace(v_def, 'SET search_path TO ''public''', 'SET search_path TO public, pg_temp');

  EXECUTE v_def;
END
$migration$;
