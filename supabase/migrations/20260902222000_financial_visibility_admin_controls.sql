-- Financial Visibility Policy — configurable Super Admin controls
--
-- Keeps the existing read-side architecture, but moves the recent-history
-- window and deterministic historical percentage out of hard-coded function
-- bodies into one private singleton configuration. Only Super Admin can read
-- or change the configuration through the public RPC surface.

CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE IF NOT EXISTS private.financial_visibility_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  recent_days integer NOT NULL DEFAULT 7 CHECK (recent_days BETWEEN 1 AND 365),
  historical_percent integer NOT NULL DEFAULT 30 CHECK (historical_percent BETWEEN 0 AND 100),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL
);

INSERT INTO private.financial_visibility_settings(singleton, recent_days, historical_percent)
VALUES (true, 7, 30)
ON CONFLICT (singleton) DO NOTHING;

REVOKE ALL ON TABLE private.financial_visibility_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE private.financial_visibility_settings TO service_role, postgres;

CREATE OR REPLACE FUNCTION private.get_financial_visibility_limits()
RETURNS TABLE(recent_days integer, historical_percent integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT s.recent_days, s.historical_percent
  FROM private.financial_visibility_settings s
  WHERE s.singleton = true
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION private.get_financial_visibility_limits() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.get_financial_visibility_limits() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_financial_visibility_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_recent_days integer;
  v_historical_percent integer;
BEGIN
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN
    SELECT recent_days, historical_percent
      INTO v_recent_days, v_historical_percent
    FROM private.financial_visibility_settings
    WHERE singleton = true;

    RETURN jsonb_build_object(
      'success', true,
      'recent_days', COALESCE(v_recent_days, 7),
      'historical_percent', COALESCE(v_historical_percent, 30)
    );
  END IF;

  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_role IS DISTINCT FROM 'super_admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT recent_days, historical_percent
    INTO v_recent_days, v_historical_percent
  FROM private.financial_visibility_settings
  WHERE singleton = true;

  RETURN jsonb_build_object(
    'success', true,
    'recent_days', COALESCE(v_recent_days, 7),
    'historical_percent', COALESCE(v_historical_percent, 30)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_financial_visibility_settings(
  p_recent_days integer,
  p_historical_percent integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
BEGIN
  IF COALESCE(current_setting('role', true), '') <> 'service_role' THEN
    SELECT role INTO v_role
    FROM public.users
    WHERE id = auth.uid() AND is_active = true;

    IF v_role IS DISTINCT FROM 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF p_recent_days IS NULL OR p_recent_days < 1 OR p_recent_days > 365 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_RECENT_DAYS');
  END IF;

  IF p_historical_percent IS NULL OR p_historical_percent < 0 OR p_historical_percent > 100 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_HISTORICAL_PERCENT');
  END IF;

  INSERT INTO private.financial_visibility_settings(
    singleton,
    recent_days,
    historical_percent,
    updated_at,
    updated_by
  )
  VALUES (
    true,
    p_recent_days,
    p_historical_percent,
    now(),
    CASE WHEN COALESCE(current_setting('role', true), '') = 'service_role' THEN NULL ELSE auth.uid() END
  )
  ON CONFLICT (singleton) DO UPDATE
    SET recent_days = EXCLUDED.recent_days,
        historical_percent = EXCLUDED.historical_percent,
        updated_at = EXCLUDED.updated_at,
        updated_by = EXCLUDED.updated_by;

  RETURN jsonb_build_object(
    'success', true,
    'recent_days', p_recent_days,
    'historical_percent', p_historical_percent
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_financial_visibility_settings() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_financial_visibility_settings(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_financial_visibility_settings() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_financial_visibility_settings(integer, integer) TO authenticated, service_role;

-- Rebind the three root visibility predicates to the singleton configuration.
CREATE OR REPLACE FUNCTION private.sale_read_visible(
  p_sale_id uuid,
  p_branch_id uuid,
  p_created_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_bucket bigint;
  v_recent_days integer := 7;
  v_historical_percent integer := 30;
BEGIN
  IF p_sale_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN
    RETURN false;
  END IF;
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN RETURN true; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN RETURN false; END IF;

  v_role := public.get_user_role();
  IF v_role = 'owner' THEN RETURN true; END IF;

  SELECT l.recent_days, l.historical_percent
    INTO v_recent_days, v_historical_percent
  FROM private.get_financial_visibility_limits() l;
  v_recent_days := COALESCE(v_recent_days, 7);
  v_historical_percent := COALESCE(v_historical_percent, 30);

  IF p_created_at >= (now() - make_interval(days => v_recent_days)) THEN RETURN true; END IF;

  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_sale_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < v_historical_percent;
END;
$$;

CREATE OR REPLACE FUNCTION private.financial_row_visible(
  p_row_id uuid,
  p_branch_id uuid,
  p_created_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bucket bigint;
  v_recent_days integer := 7;
  v_historical_percent integer := 30;
BEGIN
  IF p_row_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN RETURN false; END IF;
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN RETURN true; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN RETURN false; END IF;
  IF public.get_user_role() = 'owner' THEN RETURN true; END IF;

  SELECT l.recent_days, l.historical_percent
    INTO v_recent_days, v_historical_percent
  FROM private.get_financial_visibility_limits() l;
  v_recent_days := COALESCE(v_recent_days, 7);
  v_historical_percent := COALESCE(v_historical_percent, 30);

  IF p_created_at >= (now() - make_interval(days => v_recent_days)) THEN RETURN true; END IF;

  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_row_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < v_historical_percent;
END;
$$;

CREATE OR REPLACE FUNCTION private.order_read_visible(
  p_order_id uuid,
  p_branch_id uuid,
  p_status text,
  p_created_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_bucket bigint;
  v_recent_days integer := 7;
  v_historical_percent integer := 30;
BEGIN
  IF p_order_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN RETURN false; END IF;
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN RETURN true; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN RETURN false; END IF;

  -- Active POS/KDS operational truth remains complete regardless of the policy.
  IF p_status IN ('open', 'held') THEN RETURN true; END IF;

  v_role := public.get_user_role();
  IF v_role = 'owner' THEN RETURN true; END IF;

  SELECT l.recent_days, l.historical_percent
    INTO v_recent_days, v_historical_percent
  FROM private.get_financial_visibility_limits() l;
  v_recent_days := COALESCE(v_recent_days, 7);
  v_historical_percent := COALESCE(v_historical_percent, 30);

  IF p_created_at >= (now() - make_interval(days => v_recent_days)) THEN RETURN true; END IF;

  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_order_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < v_historical_percent;
END;
$$;

REVOKE ALL ON FUNCTION private.sale_read_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.financial_row_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.order_read_visible(uuid, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.sale_read_visible(uuid, uuid, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.financial_row_visible(uuid, uuid, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.order_read_visible(uuid, uuid, text, timestamptz) TO authenticated, service_role;

COMMENT ON TABLE private.financial_visibility_settings IS
  'Private singleton controlling recent-history days and deterministic historical visibility percentage. Read-side only.';
