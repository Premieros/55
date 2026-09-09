-- Repair treasury bootstrap and make KDS routing category/user aware.
-- KDS remains inventory-neutral: send_to_kitchen only changes kitchen state/snapshots.

-- ---------------------------------------------------------------------------
-- Accounting / treasury bootstrap
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_treasury_accounts(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.ensure_chart_of_accounts(p_branch_id);
  PERFORM public.seed_account_mappings(p_branch_id);

  INSERT INTO public.treasury_accounts (branch_id, account_id, account_type, account_name)
  SELECT p_branch_id, m.account_id, m.semantic_key, a.name
  FROM public.account_mappings m
  JOIN public.chart_of_accounts a ON a.id = m.account_id
  WHERE m.branch_id = p_branch_id
    AND m.semantic_key IN ('cash', 'bank')
  ON CONFLICT (branch_id, account_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.seed_treasury_for_new_branch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.seed_treasury_accounts(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_treasury_on_branch_insert ON public.branches;
CREATE TRIGGER trg_seed_treasury_on_branch_insert
AFTER INSERT ON public.branches
FOR EACH ROW EXECUTE FUNCTION public.seed_treasury_for_new_branch();

-- Repair existing branches that were created before treasury auto-bootstrap.
DO $$
DECLARE v_branch record;
BEGIN
  FOR v_branch IN SELECT id FROM public.branches LOOP
    PERFORM public.seed_treasury_accounts(v_branch.id);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.seed_treasury_accounts(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.seed_treasury_for_new_branch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public.seed_treasury_for_new_branch() TO service_role, postgres;

-- Make the existing opening-balance action usable by users who actually have
-- accounts.manage, while preserving branch isolation and server-side posting.
DO $patch_opening_balances$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid::regprocedure::text = 'seed_opening_balances(uuid)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'seed_opening_balances(uuid) not found';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(
    v_def,
    'IF NOT is_pos_admin() THEN',
    'IF NOT (public.is_pos_admin() OR public.can_permission(''accounts.manage'')) THEN'
  );

  IF position('PERFORM public.seed_treasury_accounts(p_branch_id);' in v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'BEGIN\n  BEGIN',
      E'BEGIN\n  BEGIN\n    IF NOT public.user_may_access_branch(p_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;\n    PERFORM public.seed_treasury_accounts(p_branch_id);'
    );
  END IF;

  EXECUTE v_def;
END
$patch_opening_balances$;

-- ---------------------------------------------------------------------------
-- Category -> station -> user routing
-- ---------------------------------------------------------------------------
ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS kitchen_station_id uuid
  REFERENCES public.kitchen_stations(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_categories_kitchen_station
  ON public.categories(kitchen_station_id)
  WHERE kitchen_station_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.user_kitchen_station_assignments (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  station_id uuid NOT NULL REFERENCES public.kitchen_stations(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, branch_id, station_id)
);

CREATE INDEX IF NOT EXISTS idx_user_kitchen_station_branch
  ON public.user_kitchen_station_assignments(branch_id, user_id);

ALTER TABLE public.user_kitchen_station_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_kitchen_station_select ON public.user_kitchen_station_assignments;
CREATE POLICY user_kitchen_station_select
ON public.user_kitchen_station_assignments
FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR (
    public.user_may_access_branch(branch_id)
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role IN ('super_admin','owner','branch_manager')
    )
  )
);

REVOKE ALL ON public.user_kitchen_station_assignments FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.user_kitchen_station_assignments FROM authenticated;
GRANT SELECT ON public.user_kitchen_station_assignments TO authenticated;
GRANT ALL ON public.user_kitchen_station_assignments TO service_role;

CREATE OR REPLACE FUNCTION public._guard_kitchen_station_assignment_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE v_user_branch uuid;
BEGIN
  SELECT branch_id INTO v_user_branch FROM public.users WHERE id = NEW.user_id;
  IF v_user_branch IS NULL THEN RAISE EXCEPTION 'KITCHEN_USER_NOT_FOUND'; END IF;
  IF v_user_branch <> NEW.branch_id THEN RAISE EXCEPTION 'KITCHEN_USER_BRANCH_MISMATCH'; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_kitchen_station_assignment_branch ON public.user_kitchen_station_assignments;
CREATE TRIGGER trg_kitchen_station_assignment_branch
BEFORE INSERT OR UPDATE OF user_id, branch_id
ON public.user_kitchen_station_assignments
FOR EACH ROW EXECUTE FUNCTION public._guard_kitchen_station_assignment_branch();

REVOKE ALL ON FUNCTION public._guard_kitchen_station_assignment_branch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._guard_kitchen_station_assignment_branch() TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.get_my_kitchen_stations(p_branch_id uuid DEFAULT public.get_branch_id())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_has_assignments boolean;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN '[]'::jsonb; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() AND is_active = true;
  SELECT EXISTS(
    SELECT 1 FROM public.user_kitchen_station_assignments a
    WHERE a.user_id = auth.uid() AND a.branch_id = p_branch_id
  ) INTO v_has_assignments;

  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.sort_order, s.code), '[]'::jsonb)
  INTO v_rows
  FROM public.kitchen_stations s
  WHERE s.is_active = true
    AND (
      v_role IN ('super_admin','owner','branch_manager')
      OR NOT v_has_assignments
      OR EXISTS (
        SELECT 1 FROM public.user_kitchen_station_assignments a
        WHERE a.user_id = auth.uid()
          AND a.branch_id = p_branch_id
          AND a.station_id = s.id
      )
    );

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_kitchen_stations(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_kitchen_stations(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_kitchen_station_assignments(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role text; v_rows jsonb;
BEGIN
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() AND is_active = true;
  IF v_role NOT IN ('super_admin','owner','branch_manager')
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'code', s.code,
    'name_ar', s.name_ar,
    'name_en', s.name_en,
    'is_active', s.is_active,
    'sort_order', s.sort_order,
    'user_ids', COALESCE((
      SELECT jsonb_agg(a.user_id ORDER BY a.user_id)
      FROM public.user_kitchen_station_assignments a
      WHERE a.branch_id = p_branch_id AND a.station_id = s.id
    ), '[]'::jsonb),
    'category_ids', COALESCE((
      SELECT jsonb_agg(c.id ORDER BY c.name)
      FROM public.categories c
      WHERE c.branch_id = p_branch_id AND c.kitchen_station_id = s.id
    ), '[]'::jsonb)
  ) ORDER BY s.sort_order, s.code), '[]'::jsonb)
  INTO v_rows
  FROM public.kitchen_stations s;

  RETURN jsonb_build_object('success', true, 'stations', v_rows);
END;
$$;

CREATE OR REPLACE FUNCTION public.save_kitchen_station_assignments(
  p_branch_id uuid,
  p_station_id uuid,
  p_user_ids uuid[] DEFAULT '{}'::uuid[],
  p_category_ids uuid[] DEFAULT '{}'::uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role text;
BEGIN
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() AND is_active = true;
  IF v_role NOT IN ('super_admin','owner','branch_manager')
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.kitchen_stations WHERE id = p_station_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'STATION_NOT_FOUND');
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_user_ids, '{}'::uuid[])) x(id)
    LEFT JOIN public.users u ON u.id = x.id
    WHERE u.id IS NULL OR u.branch_id <> p_branch_id OR u.is_active IS NOT TRUE
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_BRANCH_MISMATCH');
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(COALESCE(p_category_ids, '{}'::uuid[])) x(id)
    LEFT JOIN public.categories c ON c.id = x.id
    WHERE c.id IS NULL OR c.branch_id <> p_branch_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'CATEGORY_BRANCH_MISMATCH');
  END IF;

  DELETE FROM public.user_kitchen_station_assignments
  WHERE branch_id = p_branch_id AND station_id = p_station_id;

  INSERT INTO public.user_kitchen_station_assignments(user_id, branch_id, station_id, created_by)
  SELECT DISTINCT x.id, p_branch_id, p_station_id, auth.uid()
  FROM unnest(COALESCE(p_user_ids, '{}'::uuid[])) x(id)
  ON CONFLICT DO NOTHING;

  -- One category routes to one kitchen station. Categories removed from this
  -- station become unassigned; categories selected here move atomically to it.
  UPDATE public.categories
  SET kitchen_station_id = NULL
  WHERE branch_id = p_branch_id
    AND kitchen_station_id = p_station_id
    AND NOT (id = ANY(COALESCE(p_category_ids, '{}'::uuid[])));

  UPDATE public.categories
  SET kitchen_station_id = p_station_id
  WHERE branch_id = p_branch_id
    AND id = ANY(COALESCE(p_category_ids, '{}'::uuid[]));

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_station_assignments(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_kitchen_station_assignments(uuid,uuid,uuid[],uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_station_assignments(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_kitchen_station_assignments(uuid,uuid,uuid[],uuid[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- KDS state synchronization
-- ---------------------------------------------------------------------------
DO $patch_send_to_kitchen_state$
DECLARE v_oid oid; v_def text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid::regprocedure::text = 'send_to_kitchen(uuid,uuid)';
  IF v_oid IS NULL THEN RAISE EXCEPTION 'send_to_kitchen(uuid,uuid) not found'; END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('kitchen_sent_at = COALESCE(kitchen_sent_at, now())' in v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'    SELECT NOT EXISTS (',
      E'    IF v_count > 0 THEN\n      UPDATE public.orders\n      SET kitchen_status = CASE\n            WHEN kitchen_status IN (''cooking'',''ready'',''served'') THEN kitchen_status\n            ELSE ''sent''\n          END,\n          kitchen_sent_at = COALESCE(kitchen_sent_at, now()),\n          station = COALESCE(NULLIF(station, ''''), ''main''),\n          updated_at = now()\n      WHERE id = p_order_id;\n    END IF;\n\n    SELECT NOT EXISTS ('
    );
    EXECUTE v_def;
  END IF;
END
$patch_send_to_kitchen_state$;

-- Repair currently sent open/held orders that predate the state-sync fix.
UPDATE public.orders o
SET kitchen_status = CASE
      WHEN o.kitchen_status IN ('cooking','ready','served') THEN o.kitchen_status
      ELSE 'sent'
    END,
    kitchen_sent_at = COALESCE(o.kitchen_sent_at, s.first_sent_at),
    station = COALESCE(NULLIF(o.station, ''), 'main'),
    updated_at = now()
FROM (
  SELECT order_id, min(sent_at) AS first_sent_at
  FROM public.order_kitchen_sends
  GROUP BY order_id
) s
WHERE o.id = s.order_id
  AND o.status IN ('open','held')
  AND COALESCE(o.kitchen_status, 'pending') NOT IN ('served','cancelled');

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
  WITH sent_items AS (
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
  ), allowed_items AS (
    SELECT si.*
    FROM sent_items si
    WHERE (p_station IS NULL OR si.station_code = p_station)
      AND (
        v_role IN ('super_admin','owner','branch_manager')
        OR NOT v_has_assignments
        OR EXISTS (
          SELECT 1 FROM public.user_kitchen_station_assignments a
          WHERE a.user_id = auth.uid()
            AND a.branch_id = p_branch_id
            AND a.station_id = si.station_id
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
    EXTRACT(EPOCH FROM (now() - MIN(ai.queue_at)))::integer
  FROM allowed_items ai
  GROUP BY ai.oid, ai.onumber, ai.station_code, ai.kstatus, ai.guests, ai.onotes
  ORDER BY MIN(ai.queue_at), ai.onumber, ai.station_code;
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_queue(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_queue(text,uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
