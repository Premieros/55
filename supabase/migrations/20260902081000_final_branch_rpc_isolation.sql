-- Final audit: internal inventory mutators are service-only; client-facing
-- branch readers enforce branch access even under SECURITY DEFINER.

REVOKE EXECUTE ON FUNCTION public.deduct_raw_material_inventory(uuid,numeric,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_raw_material_inventory(uuid,numeric,uuid,uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid,uuid,jsonb,uuid,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_audit_action(uuid,text,text,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_audit_action(uuid,text,text,uuid,jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.system_integrity_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.system_integrity_audit() TO service_role;

REVOKE EXECUTE ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) TO service_role;

-- Define the latest availability function directly instead of patching its text.
-- This preserves the p_cap upper-bound fix and adds branch authorization.
CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product record;
  v_low integer;
  v_high integer;
  v_mid integer;
  v_check jsonb;
  v_high_ok boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF p_cap IS NULL OR p_cap < 1 THEN
    p_cap := 1;
  END IF;

  FOR v_product IN
    SELECT p.id
    FROM public.products p
    WHERE p.branch_id = p_branch_id
      AND p.is_active = true
    ORDER BY p.id
  LOOP
    v_low := 0;
    v_high := 1;
    v_high_ok := false;

    LOOP
      v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_high);
      v_high_ok := COALESCE((v_check->>'success')::boolean, false);
      EXIT WHEN NOT v_high_ok;
      v_low := v_high;
      EXIT WHEN v_high >= p_cap;
      v_high := LEAST(v_high * 2, p_cap);
    END LOOP;

    IF v_low < p_cap AND NOT v_high_ok THEN
      WHILE v_high - v_low > 1 LOOP
        v_mid := (v_low + v_high) / 2;
        v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_mid);
        IF COALESCE((v_check->>'success')::boolean, false) THEN
          v_low := v_mid;
        ELSE
          v_high := v_mid;
        END IF;
      END LOOP;
    END IF;

    product_id := v_product.id;
    available_quantity := v_low;
    is_available := v_low > 0;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.subscription_status(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r public.branch_subscriptions%ROWTYPE;
  s text;
  e boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('status','denied','expired',true,'error','BRANCH_ACCESS_DENIED');
  END IF;

  SELECT * INTO r FROM public.branch_subscriptions WHERE branch_id=p_branch_id;
  IF r.branch_id IS NULL THEN
    RETURN jsonb_build_object('status','none','expired',true,'branch_id',p_branch_id);
  END IF;

  s:=r.status;
  e:=false;
  IF s='trial' AND r.trial_ends_at IS NOT NULL AND r.trial_ends_at<=now() THEN
    s:='expired'; e:=true;
  ELSIF s IN ('active','past_due') AND r.current_period_ends_at IS NOT NULL AND r.current_period_ends_at<=now() THEN
    s:='expired'; e:=true;
  ELSIF s IN ('cancelled','expired') THEN
    e:=true;
  END IF;

  RETURN jsonb_build_object(
    'branch_id',p_branch_id,'status',s,'plan_id',r.plan_id,'expired',e,
    'trial_ends_at',r.trial_ends_at,'current_period_ends_at',r.current_period_ends_at,
    'cancelled_at',r.cancelled_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.subscription_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_feature_access(p_feature_key text, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tid uuid;
  v_bid uuid := p_branch_id;
BEGIN
  IF v_bid IS NOT NULL AND auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(v_bid) THEN
    RETURN jsonb_build_object('allowed',false,'feature_key',p_feature_key,'error','BRANCH_ACCESS_DENIED');
  END IF;

  IF v_bid IS NULL THEN
    v_bid := get_branch_id();
  END IF;

  IF v_bid IS NOT NULL THEN
    SELECT organization_id INTO v_tid FROM public.branches WHERE id = v_bid;
  END IF;

  IF v_tid IS NULL THEN
    SELECT organization_id INTO v_tid
    FROM public.organization_members
    WHERE user_id = auth.uid() AND is_active = true
    LIMIT 1;
  END IF;

  RETURN public.resolve_feature_access(v_tid, v_bid, p_feature_key, auth.uid());
END;
$$;

REVOKE ALL ON FUNCTION public.get_feature_access(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_feature_access(text,uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
