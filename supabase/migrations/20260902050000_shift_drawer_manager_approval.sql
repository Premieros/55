-- Server-authoritative manager approval for force-closing a shift and opening the cash drawer.
-- Normal close_shift remains unchanged. These RPCs are explicit sensitive-operation paths.

CREATE OR REPLACE FUNCTION public.force_close_shift(
  p_shift_id uuid,
  p_actual_amount numeric DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
  v_expected numeric(14,2) := 0;
  v_actual numeric(14,2) := 0;
  v_difference numeric(14,2) := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT id, branch_id, cashier_id, opening_amount, status, notes
    INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;
  IF v_shift.status <> 'open' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_OPEN');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_shift.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  -- Non-manager operators may only force-close their own shift and must consume
  -- an approval tied to the exact shift and requested actual cash amount.
  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    IF v_shift.cashier_id <> v_uid THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_SHIFT_CASHIER');
    END IF;

    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_shift.branch_id
      AND ar.action_type = 'force_close_shift'
      AND ar.entity_type = 'shift'
      AND ar.entity_id = p_shift_id
      AND ar.status = 'approved'
      AND ar.consumed_at IS NULL
      AND ar.expires_at > now()
      AND (
        p_actual_amount IS NULL
        OR (ar.payload->>'actual_amount')::numeric = p_actual_amount
      )
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_approval_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'APPROVAL_REQUIRED',
        'action_type', 'force_close_shift',
        'entity_type', 'shift',
        'entity_id', p_shift_id,
        'actual_amount', p_actual_amount
      );
    END IF;
  END IF;

  SELECT round(COALESCE(v_shift.opening_amount, 0) + COALESCE(sum(
    CASE
      WHEN operation_type IN ('sale', 'cash_in') THEN amount
      WHEN operation_type IN ('refund', 'expense', 'cash_out') THEN -amount
      ELSE 0
    END
  ) FILTER (WHERE payment_method = 'cash'), 0), 2)
  INTO v_expected
  FROM public.shift_operations
  WHERE shift_id = p_shift_id;

  v_actual := round(COALESCE(p_actual_amount, v_expected), 2);
  IF v_actual < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTUAL_AMOUNT');
  END IF;
  v_difference := round(v_actual - v_expected, 2);

  UPDATE public.shifts
  SET status = 'closed',
      closed_at = now(),
      expected_amount = v_expected,
      actual_amount = v_actual,
      difference = v_difference,
      notes = CASE
        WHEN p_reason IS NULL OR btrim(p_reason) = '' THEN notes
        ELSE concat_ws(E'\n', NULLIF(notes, ''), 'Force close: ' || btrim(p_reason))
      END
  WHERE id = p_shift_id AND status = 'open';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FORCE_CLOSE_SHIFT_UPDATE_FAILED';
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'force_close_shift'
      AND entity_type = 'shift'
      AND entity_id = p_shift_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FORCE_CLOSE_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  PERFORM public.log_audit_action(
    v_shift.branch_id,
    'force_close_shift',
    'shift',
    p_shift_id,
    jsonb_build_object(
      'cashier_id', v_shift.cashier_id,
      'expected', v_expected,
      'actual', v_actual,
      'difference', v_difference,
      'reason', p_reason,
      'approval_id', v_approval_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'expected', v_expected,
    'actual', v_actual,
    'difference', v_difference,
    'forced', true
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.authorize_open_drawer(
  p_shift_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT id, branch_id, cashier_id, status
    INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;
  IF v_shift.status <> 'open' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_OPEN');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_shift.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    IF v_shift.cashier_id <> v_uid THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_SHIFT_CASHIER');
    END IF;

    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_shift.branch_id
      AND ar.action_type = 'open_drawer'
      AND ar.entity_type = 'shift'
      AND ar.entity_id = p_shift_id
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
        'action_type', 'open_drawer',
        'entity_type', 'shift',
        'entity_id', p_shift_id
      );
    END IF;
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'open_drawer'
      AND entity_type = 'shift'
      AND entity_id = p_shift_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'OPEN_DRAWER_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  -- This RPC authorizes and audits the sensitive action. A physical drawer kick
  -- is performed only by a configured printer/native hardware bridge; browsers
  -- must not fabricate a hardware-open success.
  PERFORM public.log_audit_action(
    v_shift.branch_id,
    'open_drawer_authorized',
    'shift',
    p_shift_id,
    jsonb_build_object(
      'cashier_id', v_shift.cashier_id,
      'reason', p_reason,
      'approval_id', v_approval_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'authorized', true,
    'shift_id', p_shift_id,
    'hardware_action_required', true
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.force_close_shift(uuid,numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.authorize_open_drawer(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.force_close_shift(uuid,numeric,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.authorize_open_drawer(uuid,text) TO authenticated, service_role;
