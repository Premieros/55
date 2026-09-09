-- Financial Visibility Policy — phase 2
--
-- Extend the owner-only full-history rule to purchase/expense/accounting and
-- movement history without changing operational truth. Current stock balances,
-- writes, posting, sale processing, and refund logic remain untouched.

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
BEGIN
  IF p_row_id IS NULL OR p_branch_id IS NULL OR p_created_at IS NULL THEN
    RETURN false;
  END IF;

  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN
    RETURN true;
  END IF;

  IF NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN false;
  END IF;

  IF public.get_user_role() = 'owner' THEN
    RETURN true;
  END IF;

  IF p_created_at >= (now() - interval '7 days') THEN
    RETURN true;
  END IF;

  v_bucket := (('x' || substr(md5(p_branch_id::text || ':' || p_row_id::text), 1, 8))::bit(32)::bigint % 100);
  RETURN v_bucket < 30;
END;
$$;

REVOKE ALL ON FUNCTION private.financial_row_visible(uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.financial_row_visible(uuid, uuid, timestamptz) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.purchase_read_visible_by_id(p_purchase_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT private.financial_row_visible(p.id, p.branch_id, p.created_at)
      FROM public.purchases p
      WHERE p.id = p_purchase_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION private.expense_read_visible_by_id(p_expense_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT private.financial_row_visible(e.id, e.branch_id, e.created_at)
      FROM public.expenses e
      WHERE e.id = p_expense_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION private.customer_payment_read_visible_by_id(p_payment_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN cp.sale_id IS NOT NULL THEN private.sale_read_visible_by_id(cp.sale_id)
        ELSE private.financial_row_visible(cp.id, cp.branch_id, cp.created_at)
      END
      FROM public.customer_payments cp
      WHERE cp.id = p_payment_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION private.supplier_payment_read_visible_by_id(p_payment_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN sp.purchase_id IS NOT NULL THEN private.purchase_read_visible_by_id(sp.purchase_id)
        ELSE private.financial_row_visible(sp.id, sp.branch_id, sp.created_at)
      END
      FROM public.supplier_payments sp
      WHERE sp.id = p_payment_id
    ),
    false
  );
$$;

REVOKE ALL ON FUNCTION private.purchase_read_visible_by_id(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.expense_read_visible_by_id(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.customer_payment_read_visible_by_id(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.supplier_payment_read_visible_by_id(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.purchase_read_visible_by_id(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.expense_read_visible_by_id(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.customer_payment_read_visible_by_id(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.supplier_payment_read_visible_by_id(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.financial_reference_visible(
  p_reference_type text,
  p_reference_id uuid,
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
  v_type text := lower(COALESCE(p_reference_type, ''));
BEGIN
  IF COALESCE(current_setting('role', true), '') = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_type IN ('sale', 'refund', 'sale_refund') AND p_reference_id IS NOT NULL THEN
    RETURN private.sale_read_visible_by_id(p_reference_id);
  END IF;

  IF v_type IN ('purchase', 'purchase_return') AND p_reference_id IS NOT NULL THEN
    RETURN private.purchase_read_visible_by_id(p_reference_id);
  END IF;

  IF v_type = 'expense' AND p_reference_id IS NOT NULL THEN
    RETURN private.expense_read_visible_by_id(p_reference_id);
  END IF;

  IF v_type = 'customer_payment' AND p_reference_id IS NOT NULL THEN
    RETURN private.customer_payment_read_visible_by_id(p_reference_id);
  END IF;

  IF v_type = 'supplier_payment' AND p_reference_id IS NOT NULL THEN
    RETURN private.supplier_payment_read_visible_by_id(p_reference_id);
  END IF;

  RETURN private.financial_row_visible(p_row_id, p_branch_id, p_created_at);
END;
$$;

REVOKE ALL ON FUNCTION private.financial_reference_visible(text, uuid, uuid, uuid, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.financial_reference_visible(text, uuid, uuid, uuid, timestamptz) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.journal_entry_read_visible_by_id(p_entry_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT private.financial_reference_visible(
        je.reference_type,
        je.reference_id,
        je.id,
        je.branch_id,
        je.created_at
      )
      FROM public.journal_entries je
      WHERE je.id = p_entry_id
    ),
    false
  );
$$;

REVOKE ALL ON FUNCTION private.journal_entry_read_visible_by_id(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.journal_entry_read_visible_by_id(uuid) TO authenticated, service_role;

-- Purchases and their details.
DROP POLICY IF EXISTS financial_visibility_purchases ON public.purchases;
CREATE POLICY financial_visibility_purchases
  ON public.purchases
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.financial_row_visible(id, branch_id, created_at));

DROP POLICY IF EXISTS financial_visibility_purchase_items ON public.purchase_items;
CREATE POLICY financial_visibility_purchase_items
  ON public.purchase_items
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.purchase_read_visible_by_id(purchase_id));

-- Expenses are sampled with the same rule so restricted historical profit
-- reports do not combine partial revenue with full old expenses.
DROP POLICY IF EXISTS financial_visibility_expenses ON public.expenses;
CREATE POLICY financial_visibility_expenses
  ON public.expenses
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.financial_row_visible(id, branch_id, created_at));

-- AR/AP payment rows inherit their linked invoice when one exists.
DROP POLICY IF EXISTS financial_visibility_customer_payments ON public.customer_payments;
CREATE POLICY financial_visibility_customer_payments
  ON public.customer_payments
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    CASE
      WHEN sale_id IS NOT NULL THEN private.sale_read_visible_by_id(sale_id)
      ELSE private.financial_row_visible(id, branch_id, created_at)
    END
  );

DROP POLICY IF EXISTS financial_visibility_supplier_payments ON public.supplier_payments;
CREATE POLICY financial_visibility_supplier_payments
  ON public.supplier_payments
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    CASE
      WHEN purchase_id IS NOT NULL THEN private.purchase_read_visible_by_id(purchase_id)
      ELSE private.financial_row_visible(id, branch_id, created_at)
    END
  );

-- Financial statements are computed from journal rows. Keep the immutable full
-- ledger intact, but restrict what historical entries non-owners can read.
DROP POLICY IF EXISTS financial_visibility_journal_entries ON public.journal_entries;
CREATE POLICY financial_visibility_journal_entries
  ON public.journal_entries
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(reference_type, reference_id, id, branch_id, created_at)
  );

DROP POLICY IF EXISTS financial_visibility_journal_entry_lines ON public.journal_entry_lines;
CREATE POLICY financial_visibility_journal_entry_lines
  ON public.journal_entry_lines
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (private.journal_entry_read_visible_by_id(journal_entry_id));

-- Historical movement ledgers can disclose hidden invoice volume/cost. Only
-- their READ path is filtered; aggregate/batch stock tables remain untouched.
DROP POLICY IF EXISTS financial_visibility_stock_transactions ON public.stock_transactions;
CREATE POLICY financial_visibility_stock_transactions
  ON public.stock_transactions
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(reference_type, reference_id, id, branch_id, created_at)
  );

DROP POLICY IF EXISTS financial_visibility_inventory_ledger ON public.inventory_ledger;
CREATE POLICY financial_visibility_inventory_ledger
  ON public.inventory_ledger
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(reference_type, reference_id, md5(id::text)::uuid, branch_id, created_at)
  );

DROP POLICY IF EXISTS financial_visibility_inventory_unit_entries ON public.inventory_unit_entries;
CREATE POLICY financial_visibility_inventory_unit_entries
  ON public.inventory_unit_entries
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(reference_type, reference_id, id, branch_id, created_at)
  );

-- Legacy movement tables do not carry reference_type, so use movement_type as
-- the semantic reference discriminator where possible.
DROP POLICY IF EXISTS financial_visibility_inventory_movements ON public.inventory_movements;
CREATE POLICY financial_visibility_inventory_movements
  ON public.inventory_movements
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(movement_type, reference_id, id, branch_id, created_at)
  );

DROP POLICY IF EXISTS financial_visibility_raw_material_movements ON public.raw_material_movements;
CREATE POLICY financial_visibility_raw_material_movements
  ON public.raw_material_movements
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    private.financial_reference_visible(movement_type, reference_id, id, branch_id, created_at)
  );

-- Shift operation history can otherwise reveal a hidden sale amount directly.
DROP POLICY IF EXISTS financial_visibility_shift_operations ON public.shift_operations;
CREATE POLICY financial_visibility_shift_operations
  ON public.shift_operations
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    CASE
      WHEN lower(COALESCE(reference_type, '')) IN ('sale', 'refund', 'sale_refund')
           AND reference_id IS NOT NULL
        THEN private.sale_read_visible_by_id(reference_id)
      ELSE true
    END
  );

COMMENT ON FUNCTION private.financial_row_visible(uuid, uuid, timestamptz)
  IS 'Internal read-side owner/7-day/deterministic-history visibility predicate. Never use for writes, stock truth, or accounting posting.';
