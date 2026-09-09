-- Financial Visibility Policy — phase 1 (sales root + sale_items only)
--
-- Read-side policy only:
--   * owner: full accessible branch history
--   * every other authenticated role: all sales from the last 7 days
--     plus the stable 30/100 hash buckets for older sales
--
-- Operational truth is intentionally untouched. process_sale, inventory,
-- accounting, refunds, and all write policies continue to operate on 100% of
-- the underlying rows.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

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
BEGIN
  IF p_sale_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN
    RETURN false;
  END IF;

  -- Keep branch/tenant isolation as the first boundary. service_role is a
  -- trusted server role and normally bypasses RLS already; retaining this
  -- explicit case keeps SECURITY DEFINER/server maintenance paths predictable.
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN
    RETURN true;
  END IF;

  IF NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN false;
  END IF;

  -- Deliberately exact-role based. super_admin, branch_manager, accountant,
  -- cashier, etc. do NOT inherit full historical visibility merely because
  -- they hold broad administrative permissions.
  v_role := public.get_user_role();
  IF v_role = 'owner' THEN
    RETURN true;
  END IF;

  IF p_created_at >= (now() - interval '7 days') THEN
    RETURN true;
  END IF;

  -- Deterministic, branch-stable sampling: the same sale always maps to the
  -- same bucket for every restricted user. This prevents users from combining
  -- different per-user samples to reconstruct the hidden history.
  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_sale_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < 30;
END;
$$;

REVOKE ALL ON FUNCTION private.sale_read_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.sale_read_visible(uuid, uuid, timestamptz) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.sale_read_visible_by_id(p_sale_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT private.sale_read_visible(s.id, s.branch_id, s.created_at)
      FROM public.sales s
      WHERE s.id = p_sale_id
    ),
    false
  );
$$;

REVOKE ALL ON FUNCTION private.sale_read_visible_by_id(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.sale_read_visible_by_id(uuid) TO authenticated, service_role;

-- RESTRICTIVE policies are intentionally additive to the existing permissive
-- branch policies. A row must pass BOTH branch access and financial visibility,
-- and a future permissive SELECT policy cannot accidentally OR around this
-- restriction.
DROP POLICY IF EXISTS financial_visibility_sales ON public.sales;
CREATE POLICY financial_visibility_sales
  ON public.sales
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.sale_read_visible(id, branch_id, created_at));

DROP POLICY IF EXISTS financial_visibility_sale_items ON public.sale_items;
CREATE POLICY financial_visibility_sale_items
  ON public.sale_items
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.sale_read_visible_by_id(sale_id));

COMMENT ON FUNCTION private.sale_read_visible(uuid, uuid, timestamptz)
  IS 'Internal read-visibility predicate for historical sales; not an operational/accounting filter.';
COMMENT ON POLICY financial_visibility_sales ON public.sales
  IS 'Restricts historical sales reads without altering writes or operational truth.';
COMMENT ON POLICY financial_visibility_sale_items ON public.sale_items
  IS 'Makes sale item visibility inherit the parent sale read decision.';
