-- V2 shift contract: own-shift close and managing another user's shift are
-- separate permissions. Branch manager is not a global or implicit bypass.

CREATE OR REPLACE FUNCTION public.close_shift(
  p_shift_id uuid,
  p_actual_amount numeric,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift public.shifts%ROWTYPE;
  v_expected numeric(14,2);
  v_diff numeric(14,2);
  v_is_own boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF v_shift.status = 'closed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_CLOSED');
  END IF;

  v_is_own := v_shift.cashier_id = v_uid;

  IF v_is_own THEN
    IF NOT (public.is_pos_admin() OR public.can_permission('shifts.close')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SHIFT_CLOSE_DENIED');
    END IF;
  ELSE
    IF NOT (public.is_pos_admin() OR public.can_permission('shifts.manage')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SHIFT_MANAGE_DENIED');
    END IF;
  END IF;

  SELECT COALESCE(v_shift.opening_amount, 0)
       + COALESCE(SUM(CASE WHEN op.operation_type = 'sale' AND COALESCE(op.payment_method, 'cash') = 'cash' THEN op.amount ELSE 0 END), 0)
       - COALESCE(SUM(CASE WHEN op.operation_type = 'expense' AND COALESCE(op.payment_method, 'cash') = 'cash' THEN op.amount ELSE 0 END), 0)
       - COALESCE(SUM(CASE WHEN op.operation_type = 'refund' THEN op.amount ELSE 0 END), 0)
    INTO v_expected
  FROM public.shift_operations op
  WHERE op.shift_id = p_shift_id;

  v_diff := COALESCE(p_actual_amount, v_expected) - v_expected;

  UPDATE public.shifts
  SET status = 'closed',
      closed_at = now(),
      expected_amount = v_expected,
      actual_amount = COALESCE(p_actual_amount, v_expected),
      difference = v_diff,
      notes = COALESCE(p_notes, notes)
  WHERE id = p_shift_id;

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'expected', v_expected,
    'actual', COALESCE(p_actual_amount, v_expected),
    'difference', v_diff
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.close_shift(uuid,numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_shift(uuid,numeric,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid,numeric,text) TO service_role;
