-- Fix KDS permission regressions introduced by granular POS authorization.
-- KDS operations are independent from POS selling, while service_role remains
-- available for trusted internal workflows and CI setup.

-- Cashiers should not see/manage KDS by default. Production managers need KDS
-- access for kitchen routing and supervision.
UPDATE public.roles
SET permissions = COALESCE(permissions, '[]'::jsonb) - 'pos.kds_view'
WHERE role = 'cashier';

UPDATE public.roles
SET permissions = CASE
  WHEN COALESCE(permissions, '[]'::jsonb) ? 'pos.kds_view' THEN COALESCE(permissions, '[]'::jsonb)
  ELSE COALESCE(permissions, '[]'::jsonb) || '["pos.kds_view"]'::jsonb
END
WHERE role = 'production_manager';

CREATE OR REPLACE FUNCTION public.enforce_pos_permission_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  -- Trusted server-side workflows must not be blocked by end-user permission
  -- checks. RLS/grants still protect direct client access.
  IF v_is_service_role OR v_uid IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'sales' THEN
    IF TG_OP = 'INSERT' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_kitchen_sends' THEN
    IF NOT public.can_permission('pos.send_kitchen') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.send_kitchen';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      END IF;
      RETURN OLD;
    END IF;

    -- KDS status-only updates require KDS permission, not POS selling.
    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    -- Station-only updates are KDS routing operations. They must not require
    -- pos.sell, but cannot be used to change any other order field.
    IF NEW.station IS DISTINCT FROM OLD.station
       AND (to_jsonb(NEW) - ARRAY['station','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['station','updated_at']::text[]) THEN
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'cancelled' AND NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      ELSIF NEW.status = 'completed' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
      ELSIF NEW.status IN ('open', 'held') AND NOT public.can_permission('pos.hold') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.hold';
      END IF;
    END IF;

    IF NEW.table_id IS DISTINCT FROM OLD.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT public.can_permission('pos.transfer_order') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.transfer_order';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.table_id IS NOT DISTINCT FROM OLD.table_id
       AND NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.void') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.void';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      IF NOT public.can_permission('pos.split_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.split_order';
      END IF;
    ELSIF NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_kitchen_status(p_order_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_branch_id uuid;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  IF NOT v_is_service_role AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_status NOT IN ('pending','sent','cooking','ready','served','cancelled') THEN
    RAISE EXCEPTION 'Invalid kitchen_status: %', p_status;
  END IF;

  SELECT branch_id INTO v_branch_id
  FROM public.orders
  WHERE id = p_order_id;

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT v_is_service_role AND (
       NOT public.user_may_access_branch(v_branch_id)
       OR NOT public.can_permission('pos.kds_view')
     ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
  END IF;

  UPDATE public.orders
  SET kitchen_status = p_status,
      kitchen_sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE kitchen_sent_at END,
      kitchen_ready_at = CASE WHEN p_status = 'ready' THEN now() ELSE kitchen_ready_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (
    auth.uid(),
    'kitchen_status',
    'order',
    p_order_id,
    jsonb_build_object('kitchen_status', p_status),
    v_branch_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.route_to_station(
  p_order_id uuid,
  p_station text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exists boolean;
  v_branch_id uuid;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.kitchen_stations
    WHERE code = p_station AND is_active = true
  ) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION 'Invalid or inactive station: %', p_station;
  END IF;

  SELECT branch_id INTO v_branch_id
  FROM public.orders
  WHERE id = p_order_id;

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT v_is_service_role AND (
       auth.uid() IS NULL
       OR NOT public.user_may_access_branch(v_branch_id)
       OR NOT public.can_permission('pos.kds_view')
     ) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
  END IF;

  UPDATE public.orders
  SET station = p_station, updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (
    auth.uid(),
    'route_station',
    'order',
    p_order_id,
    jsonb_build_object('station', p_station),
    v_branch_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_kitchen_status(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.route_to_station(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_kitchen_status(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.route_to_station(uuid, text) TO authenticated, service_role;
