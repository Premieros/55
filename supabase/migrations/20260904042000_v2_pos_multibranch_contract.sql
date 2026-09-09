-- Frontend V2 POS multi-branch contract.
-- Narrowly replaces legacy users.branch_id equality checks with the canonical
-- user_may_access_branch() primitive. Business logic, pricing, KDS and
-- inventory semantics remain unchanged.

-- Every active application role can enter POS and run its own normal shift.
-- Sensitive actions (pay, discount, void, refund, approvals...) stay separate.
UPDATE public.roles
SET permissions = (
  SELECT jsonb_agg(DISTINCT value ORDER BY value)
  FROM jsonb_array_elements_text(
    COALESCE(permissions, '[]'::jsonb)
    || '["pos.sell","shifts.view","shifts.open","shifts.close"]'::jsonb
  ) AS p(value)
), updated_at = now()
WHERE is_active = true;

DO $migration$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  -- create_order: allow any explicitly authorized branch, not only users.branch_id.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='create_order'
    AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid, p_order_type text, p_table_id uuid, p_customer_id uuid, p_guest_count integer, p_notes text, p_items jsonb, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_total numeric, p_cashier_id uuid';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_CREATE_ORDER_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> p_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''AUTH_REQUIRED'');\n    END IF;\n    IF NOT public.user_may_access_branch(p_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_CREATE_ORDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- update_order: access follows the order branch and explicit grants.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='update_order';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_UPDATE_ORDER_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''AUTH_REQUIRED'');\n    END IF;\n    IF NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_UPDATE_ORDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- Legacy two-arg kitchen sender: preserve delta-send/KDS logic, patch scope only.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='send_to_kitchen'
    AND pg_get_function_identity_arguments(p.oid)='p_order_id uuid, p_sent_by uuid';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_KITCHEN_SENDER_MISSING'; END IF;
  v_old := E'      select branch_id into v_user_branch\n      from public.users\n      where id = auth.uid() and is_active = true;\n\n      if not is_pos_admin()\n         and coalesce(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id then\n        return jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n      end if;';
  v_new := E'      if not public.user_may_access_branch(v_branch_id) then\n        return jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n      end if;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_KITCHEN_SENDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- set_order_status: status changes remain guarded by existing mutation trigger.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='set_order_status';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_ORDER_STATUS_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL OR NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_ORDER_STATUS_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- set_table_status: same branch primitive, occupancy guard remains untouched.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='set_table_status';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_TABLE_STATUS_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL OR NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_TABLE_STATUS_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$migration$;

-- get_active_shift remains caller-owned, but revoked branch access must not leak
-- or reactivate a shift from a branch the user no longer may access.
CREATE OR REPLACE FUNCTION public.get_active_shift(p_branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_cash_sales numeric(14,2);
  v_cash_expenses numeric(14,2);
  v_total_sales numeric(14,2);
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  IF p_branch_id IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE cashier_id = v_uid AND status = 'open'
    AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ORDER BY opened_at DESC LIMIT 1;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'open', false);
  END IF;
  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'open', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT COALESCE(SUM(amount), 0),
         COALESCE(SUM(CASE WHEN payment_method = 'cash' AND operation_type='sale' THEN amount ELSE 0 END), 0),
         COALESCE(SUM(CASE WHEN payment_method = 'cash' AND operation_type='expense' THEN amount ELSE 0 END), 0)
  INTO v_total_sales, v_cash_sales, v_cash_expenses
  FROM public.shift_operations
  WHERE shift_id = v_shift.id;

  RETURN jsonb_build_object(
    'success', true, 'open', true,
    'shift', jsonb_build_object(
      'id', v_shift.id,
      'branch_id', v_shift.branch_id,
      'cashier_id', v_shift.cashier_id,
      'opened_at', v_shift.opened_at,
      'opening_amount', v_shift.opening_amount,
      'expected', v_shift.opening_amount + v_cash_sales - v_cash_expenses,
      'cash_sales', v_cash_sales,
      'total_sales', v_total_sales,
      'notes', v_shift.notes
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- Harden only functions touched by this migration.
ALTER FUNCTION public.create_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.update_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,text) SET search_path = public, pg_temp;
ALTER FUNCTION public.send_to_kitchen(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.set_order_status(uuid,text,text) SET search_path = public, pg_temp;
ALTER FUNCTION public.set_table_status(uuid,text) SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION public.get_active_shift(uuid) TO authenticated;