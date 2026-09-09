-- Preserve the historical KDS contract for older orders/tests that have an
-- active kitchen_status but predate order_kitchen_sends, while keeping modern
-- orders exact: once an order has send rows, only actually-sent items are shown.

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
BEGIN
  IF auth.uid() IS NULL OR p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN;
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() AND is_active = true;
  SELECT id INTO v_main_station_id FROM public.kitchen_stations WHERE code = 'main' LIMIT 1;
  SELECT EXISTS(
    SELECT 1 FROM public.user_kitchen_station_assignments a
    WHERE a.user_id = auth.uid() AND a.branch_id = p_branch_id
  ) INTO v_has_assignments;

  RETURN QUERY
  WITH active_items AS (
    SELECT
      o.id AS oid,
      o.order_number AS onumber,
      o.kitchen_status AS kstatus,
      o.guest_count AS guests,
      o.notes AS onotes,
      COALESCE(o.kitchen_sent_at, send_info.first_sent_at, o.created_at) AS queue_at,
      oi.id AS item_id,
      oi.quantity,
      oi.modifiers_snapshot,
      p.name AS product_name,
      COALESCE(ks.id, v_main_station_id) AS station_id,
      COALESCE(ks.code, NULLIF(o.station, ''), 'main') AS station_code
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    JOIN public.products p ON p.id = oi.product_id
    LEFT JOIN public.categories c ON c.id = p.category_id AND c.branch_id = o.branch_id
    LEFT JOIN public.kitchen_stations ks ON ks.id = c.kitchen_station_id AND ks.is_active = true
    LEFT JOIN LATERAL (
      SELECT
        MIN(s.sent_at) AS first_sent_at,
        BOOL_OR(s.order_item_id = oi.id) AS item_was_sent,
        COUNT(*) AS send_count
      FROM public.order_kitchen_sends s
      WHERE s.order_id = o.id
    ) send_info ON true
    WHERE o.branch_id = p_branch_id
      AND o.status IN ('open','held')
      AND o.kitchen_status IN ('sent','cooking','ready')
      AND (
        COALESCE(send_info.send_count, 0) = 0
        OR COALESCE(send_info.item_was_sent, false)
      )
  ), allowed_items AS (
    SELECT ai.*
    FROM active_items ai
    WHERE (p_station IS NULL OR ai.station_code = p_station)
      AND (
        v_role IN ('super_admin','owner','branch_manager')
        OR NOT v_has_assignments
        OR EXISTS (
          SELECT 1 FROM public.user_kitchen_station_assignments a
          WHERE a.user_id = auth.uid()
            AND a.branch_id = p_branch_id
            AND a.station_id = ai.station_id
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
    jsonb_agg(jsonb_build_object(
      'order_item_id', ai.item_id,
      'product_name', ai.product_name,
      'quantity', ai.quantity,
      'modifiers', COALESCE(ai.modifiers_snapshot, '[]'::jsonb)
    ) ORDER BY ai.item_id),
    GREATEST(EXTRACT(EPOCH FROM (now() - MIN(ai.queue_at)))::integer, 0)
  FROM allowed_items ai
  GROUP BY ai.oid, ai.onumber, ai.station_code, ai.kstatus, ai.guests, ai.onotes
  ORDER BY MIN(ai.queue_at), ai.onumber, ai.station_code;
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_queue(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_queue(text,uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
