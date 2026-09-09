-- Financial Visibility Policy — completed/cancelled order history
--
-- Operational POS orders remain fully readable while active (open/held).
-- Historical orders follow the same owner/recent/stable-sample rule used by
-- sales, without changing any order write, payment, kitchen, or inventory path.

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
BEGIN
  IF p_order_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN
    RETURN false;
  END IF;

  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN
    RETURN true;
  END IF;

  IF NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN false;
  END IF;

  -- Active operational truth must never be sampled. POS/table/KDS workflows
  -- depend on every open or held order being visible to authorized branch users.
  IF p_status IN ('open', 'held') THEN
    RETURN true;
  END IF;

  v_role := public.get_user_role();
  IF v_role = 'owner' THEN
    RETURN true;
  END IF;

  IF p_created_at >= (now() - interval '7 days') THEN
    RETURN true;
  END IF;

  -- Branch-stable deterministic 30/100 sample for historical orders.
  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_order_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < 30;
END;
$$;

REVOKE ALL ON FUNCTION private.order_read_visible(uuid, uuid, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.order_read_visible(uuid, uuid, text, timestamptz) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.order_read_visible_by_id(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT private.order_read_visible(o.id, o.branch_id, o.status, o.created_at)
      FROM public.orders o
      WHERE o.id = p_order_id
    ),
    false
  );
$$;

REVOKE ALL ON FUNCTION private.order_read_visible_by_id(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.order_read_visible_by_id(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS financial_visibility_orders ON public.orders;
CREATE POLICY financial_visibility_orders
  ON public.orders
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.order_read_visible(id, branch_id, status, created_at));

DROP POLICY IF EXISTS financial_visibility_order_items ON public.order_items;
CREATE POLICY financial_visibility_order_items
  ON public.order_items
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.order_read_visible_by_id(order_id));

COMMENT ON POLICY financial_visibility_orders ON public.orders
  IS 'Keeps active orders fully visible; restricts historical order reads to owner/recent/stable 30 percent visibility.';
COMMENT ON POLICY financial_visibility_order_items ON public.order_items
  IS 'Order items inherit the parent order read-visibility decision.';
