-- Permission-First regression closure.
-- Keeps role management capability-driven and branch-scoped, and aligns
-- stock-count approval scope with canonical multi-branch access.

CREATE OR REPLACE FUNCTION public.guard_role_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_permission text;
  v_primary_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_pos_admin() THEN
    RETURN NEW;
  END IF;

  IF NOT public.can_permission('roles.permissions.manage') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED:roles.permissions.manage';
  END IF;

  IF TG_OP = 'INSERT' AND (NEW.scope IS DISTINCT FROM 'branch' OR NEW.branch_id IS NULL) THEN
    SELECT u.branch_id INTO v_primary_branch
    FROM public.users u
    WHERE u.id = auth.uid() AND u.is_active = true;

    IF v_primary_branch IS NULL THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: branch-scoped role requires a caller primary branch';
    END IF;

    NEW.scope := 'branch';
    NEW.branch_id := v_primary_branch;
  END IF;

  IF NEW.scope IS DISTINCT FROM 'branch'
     OR NEW.branch_id IS NULL
     OR NOT public.user_may_access_branch(NEW.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: role outside caller branch scope';
  END IF;

  FOR v_permission IN
    SELECT jsonb_array_elements_text(COALESCE(NEW.permissions, '[]'::jsonb))
  LOOP
    IF NOT public.can_permission(v_permission) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: cannot grant capability %', v_permission;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP POLICY IF EXISTS auth_write_roles ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_upd ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_del ON public.roles;

CREATE POLICY auth_write_roles
ON public.roles
FOR INSERT TO authenticated
WITH CHECK (
  public.is_pos_admin()
  OR (
    public.can_permission('roles.permissions.manage')
    AND scope = 'branch'
    AND public.user_may_access_branch(branch_id)
  )
);

CREATE POLICY auth_write_roles_upd
ON public.roles
FOR UPDATE TO authenticated
USING (
  public.is_pos_admin()
  OR (
    public.can_permission('roles.permissions.manage')
    AND scope = 'branch'
    AND public.user_may_access_branch(branch_id)
  )
)
WITH CHECK (
  public.is_pos_admin()
  OR (
    public.can_permission('roles.permissions.manage')
    AND scope = 'branch'
    AND public.user_may_access_branch(branch_id)
  )
);

CREATE POLICY auth_write_roles_del
ON public.roles
FOR DELETE TO authenticated
USING (
  public.is_pos_admin()
  OR (
    public.can_permission('roles.permissions.manage')
    AND scope = 'branch'
    AND public.user_may_access_branch(branch_id)
  )
);

-- Operational approval transitions must use the same canonical capability as
-- the RPC they protect. Otherwise a valid secondary-branch approver can pass
-- the RPC check and still be rejected by the BEFORE UPDATE policy trigger.
CREATE OR REPLACE FUNCTION public.enforce_approval_policy_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_scope text;
  v_fallback text;
  v_amount numeric := 0;
BEGIN
  IF auth.uid() IS NULL
     OR NEW.status IS NOT DISTINCT FROM OLD.status
     OR NEW.status NOT IN ('approved', 'rejected') THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'waste_entries' THEN
    v_scope := 'waste';
    v_fallback := 'waste.approve';
    v_amount := COALESCE(NEW.total_cost, 0);
  ELSIF TG_TABLE_NAME = 'stock_counts' THEN
    v_scope := 'stock_count';
    v_fallback := 'inventory.count.approve';
  ELSIF TG_TABLE_NAME = 'warehouse_transfers' THEN
    v_scope := 'warehouse_transfer';
    v_fallback := 'inventory.transfer.approve';
  ELSE
    RETURN NEW;
  END IF;

  IF NOT public.can_approve_by_policy(v_scope, NEW.branch_id, v_amount, v_fallback) THEN
    RAISE EXCEPTION 'APPROVAL_POLICY_DENIED:%', v_scope;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count record;
BEGIN
  BEGIN
    IF NOT public.can_permission('inventory.count.approve') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'NOT_ALLOWED',
        'detail', 'Approving stock counts requires the inventory.count.approve permission.'
      );
    END IF;

    SELECT * INTO v_count
    FROM public.stock_counts
    WHERE id = p_stock_count_id
    FOR UPDATE;

    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;

    IF v_count.status <> 'submitted' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
    END IF;

    IF NOT public.user_may_access_branch(v_count.branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    UPDATE public.stock_counts
    SET status = 'approved',
        approved_by = auth.uid(),
        approved_at = now(),
        rejection_reason = NULL
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_stock_count(
  p_stock_count_id uuid,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count record;
BEGIN
  BEGIN
    IF NOT public.can_permission('inventory.count.approve') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;

    SELECT * INTO v_count
    FROM public.stock_counts
    WHERE id = p_stock_count_id
    FOR UPDATE;

    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;

    IF v_count.status <> 'submitted' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
    END IF;

    IF NOT public.user_may_access_branch(v_count.branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    UPDATE public.stock_counts
    SET status = 'rejected',
        approved_by = auth.uid(),
        approved_at = now(),
        rejection_reason = p_reason
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count public.stock_counts%ROWTYPE;
  v_item public.stock_count_items%ROWTYPE;
  v_current numeric(14,4);
  v_variance numeric(14,4);
  v_applied integer := 0;
  v_res jsonb;
  v_shortage numeric(14,4);
BEGIN
  BEGIN
    SELECT * INTO v_count
    FROM public.stock_counts
    WHERE id = p_stock_count_id
    FOR UPDATE;

    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;

    IF v_count.status <> 'approved' THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_APPROVED', 'status', v_count.status);
    END IF;

    IF NOT public.can_permission('inventory.count.approve') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'NOT_ALLOWED',
        'detail', 'Applying stock counts requires the inventory.count.approve permission.'
      );
    END IF;

    IF NOT public.user_may_access_branch(v_count.branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    FOR v_item IN
      SELECT *
      FROM public.stock_count_items
      WHERE stock_count_id = p_stock_count_id
      ORDER BY id
      FOR UPDATE
    LOOP
      SELECT COALESCE(quantity, 0)
      INTO v_current
      FROM public.inventory
      WHERE product_id = v_item.product_id
        AND warehouse_id = v_count.warehouse_id;

      IF v_current IS NULL THEN
        v_current := 0;
      END IF;

      v_variance := v_item.counted_quantity - v_current;

      IF v_variance > 0 THEN
        v_res := public._product_inv_add(
          v_item.product_id,
          v_count.warehouse_id,
          v_count.branch_id,
          v_variance,
          v_item.unit_cost,
          NULL,
          NULL,
          NULL,
          'adjustment',
          'stock_count',
          v_count.id,
          v_count.count_number,
          auth.uid()
        );

        IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
          RETURN jsonb_build_object(
            'success', false,
            'error', 'ADJUST_FAILED',
            'product_id', v_item.product_id,
            'detail', v_res->>'error'
          );
        END IF;
      ELSIF v_variance < 0 THEN
        v_res := public._product_inv_remove_fifo(
          v_item.product_id,
          v_count.warehouse_id,
          v_count.branch_id,
          -v_variance,
          'adjustment',
          'stock_count',
          v_count.id,
          v_count.count_number,
          auth.uid()
        );

        v_shortage := COALESCE((v_res->>'shortage')::numeric, 0);
        IF v_shortage > 0 THEN
          RETURN jsonb_build_object(
            'success', false,
            'error', 'STOCK_COUNT_SHORTAGE',
            'product_id', v_item.product_id,
            'shortage', v_shortage
          );
        END IF;
      END IF;

      v_applied := v_applied + 1;
    END LOOP;

    UPDATE public.stock_counts
    SET status = 'applied', applied_at = now()
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'items_applied', v_applied);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;
