-- Legacy compatibility: old KDS callers/tests may persist an active kitchen
-- order before any order_items exist. Keep only that narrow legacy shape
-- visible with items=[]. Modern orders remain exact: only actually-sent lines
-- from order_kitchen_sends are returned.

CREATE OR REPLACE FUNCTION public.get_kitchen_queue(
  p_station text DEFAULT NULL,
  p_branch_id uuid DEFAULT public.get_branch_id()
)
RETURNS TABLE(
  order_id uuid,
  order_number text,
  table_number integer,
  station text,
  kitchen_status text,
  guest_count integer,
  notes text,
  created_at timestamptz,
  items jsonb,
  elapsed_seconds integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_has_assignments boolean;
  v_main_station_id uuid;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  -- EXECUTE is restricted to authenticated/service_role below. Ordinary client
  -- callers remain branch-scoped; the trusted PostgreSQL service_role may read
  -- across branches for server/CI administration and cannot be assumed from
  -- auth.uid() because the CI auth stub deliberately impersonates a user.
  IF p_branch_id IS NULL
     OR (NOT v_is_service_role AND NOT public.user_may_access_branch(p_branch_id)) THEN
    RETURN;
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() AND is_active = true;
  SELECT id INTO v_main_station_id FROM public.kitchen_stations WHERE code = 'main' LIMIT 1;
  SELECT EXISTS(
    SELECT 1 FROM public.user_kitchen_station_assignments a
    WHERE a.user_id = auth.uid() AND a.branch_id = p_branch_id
  ) INTO v_has_assignments;

  RETURN QUERY
  WITH sent_items AS (
    -- Modern path: an item is in KDS only when that exact order_item_id has a
    -- kitchen send row. This preserves exact sent-item routing and modifiers.
    SELECT
      o.id AS oid,
      o.order_number AS onumber,
      o.kitchen_status AS kstatus,
      o.guest_count AS guests,
      o.notes AS onotes,
      COALESCE(o.kitchen_sent_at, MIN(oks.sent_at) OVER (PARTITION BY o.id), o.created_at) AS queue_at,
      oi.id AS item_id,
      oi.quantity,
      oi.modifiers_snapshot,
      p.name AS product_name,
      COALESCE(ks.id, v_main_station_id) AS station_id,
      COALESCE(ks.code, 'main') AS station_code
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    JOIN public.order_kitchen_sends oks ON oks.order_item_id = oi.id
    JOIN public.products p ON p.id = oi.product_id
    LEFT JOIN public.categories c ON c.id = p.category_id AND c.branch_id = o.branch_id
    LEFT JOIN public.kitchen_stations ks ON ks.id = c.kitchen_station_id AND ks.is_active = true
    WHERE o.branch_id = p_branch_id
      AND o.status IN ('open','held')
      AND o.kitchen_status IN ('sent','cooking','ready')
  ), legacy_empty_orders AS (
    -- Narrow backwards compatibility only: active historical order with no
    -- items and no send rows. Its legacy station comes from orders.station.
    SELECT
      o.id AS oid,
      o.order_number AS onumber,
      o.kitchen_status AS kstatus,
      o.guest_count AS guests,
      o.notes AS onotes,
      COALESCE(o.kitchen_sent_at, o.created_at) AS queue_at,
      NULL::uuid AS item_id,
      NULL::numeric AS quantity,
      NULL::jsonb AS modifiers_snapshot,
      NULL::text AS product_name,
      COALESCE(
        legacy_station.id,
        CASE WHEN NULLIF(o.station, '') IS NULL THEN v_main_station_id ELSE NULL END
      ) AS station_id,
      COALESCE(NULLIF(o.station, ''), legacy_station.code, 'main') AS station_code
    FROM public.orders o
    LEFT JOIN public.kitchen_stations legacy_station
      ON legacy_station.code = COALESCE(NULLIF(o.station, ''), 'main')
     AND legacy_station.is_active = true
    WHERE o.branch_id = p_branch_id
      AND o.status IN ('open','held')
      AND o.kitchen_status IN ('sent','cooking','ready')
      AND NOT EXISTS (
        SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.order_kitchen_sends oks WHERE oks.order_id = o.id
      )
  ), queue_items AS (
    SELECT * FROM sent_items
    UNION ALL
    SELECT * FROM legacy_empty_orders
  ), allowed_items AS (
    SELECT qi.*
    FROM queue_items qi
    WHERE (p_station IS NULL OR qi.station_code = p_station)
      AND (
        v_is_service_role
        OR v_role IN ('super_admin','owner','branch_manager')
        OR NOT v_has_assignments
        OR EXISTS (
          SELECT 1 FROM public.user_kitchen_station_assignments a
          WHERE a.user_id = auth.uid()
            AND a.branch_id = p_branch_id
            AND a.station_id = qi.station_id
        )
      )
  )
  SELECT
    ai.oid,
    ai.onumber,
    NULL::integer,
    ai.station_code,
    ai.kstatus,
    ai.guests,
    ai.onotes,
    MIN(ai.queue_at),
    COALESCE(
      jsonb_agg(jsonb_build_object(
        'order_item_id', ai.item_id,
        'product_name', ai.product_name,
        'quantity', ai.quantity,
        'modifiers', COALESCE(ai.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY ai.item_id) FILTER (WHERE ai.item_id IS NOT NULL),
      '[]'::jsonb
    ),
    GREATEST(EXTRACT(EPOCH FROM (now() - MIN(ai.queue_at)))::integer, 0)
  FROM allowed_items ai
  GROUP BY ai.oid, ai.onumber, ai.station_code, ai.kstatus, ai.guests, ai.onotes
  ORDER BY MIN(ai.queue_at), ai.onumber, ai.station_code;
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_queue(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_queue(text,uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
