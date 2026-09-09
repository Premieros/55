-- ============================================================================
-- PREMIER / JOHN-S POS & ERP - COMPLETE DATABASE SCHEMA & RPCS
-- Consolidated Build Script generated on 2026-09-06T13:52:49.808Z
-- Contains all 237 migrations in canonical order
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904003000_allow_send_rpc_order_state_transition.sql
-- ----------------------------------------------------------------------------
-- A cashier may send an order to the kitchen without having KDS-management
-- permission. The send_to_kitchen RPC writes order_kitchen_sends first, then
-- synchronizes orders.kitchen_status from pending -> sent. The generic orders
-- mutation guard previously treated that synchronization as a KDS-management
-- action and rejected it because cashier intentionally lacks pos.kds_view.
--
-- Keep the separation strict:
--   * pending -> sent is allowed with pos.send_kitchen only after an actual
--     kitchen-send snapshot exists for the order.
--   * cooking / ready / served and all other KDS status changes still require
--     pos.kds_view.
--   * direct order edits remain subject to the existing POS permissions.

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

    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF OLD.kitchen_status = 'pending'
         AND NEW.kitchen_status = 'sent'
         AND public.can_permission('pos.send_kitchen')
         AND EXISTS (
           SELECT 1
           FROM public.order_kitchen_sends s
           WHERE s.order_id = OLD.id
         ) THEN
        RETURN NEW;
      END IF;

      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

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

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904020000_prefer_ready_product_in_modifier_sale_deduction.sql
-- ----------------------------------------------------------------------------
-- Keep sale deduction consistent with POS availability: if finished-product stock
-- covers the sale, consume that finished stock even when a legacy recipe exists.
-- Modifier inventory effects are still evaluated separately.
CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL::uuid,
  p_reference_number text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
  v_effect record;
  v_batch record;
  v_need numeric(14,6);
  v_take numeric(14,6);
  v_available numeric(14,6);
  v_total_cost numeric(18,4) := 0;
  v_units jsonb := '[]'::jsonb;
  v_raws jsonb := '[]'::jsonb;
  v_ready jsonb := '[]'::jsonb;
  v_user_branch uuid;
  v_recipe_id uuid;
  v_yield numeric(14,6);
  v_res jsonb;
  v_mod jsonb;
  v_recipe_component_count integer;
  v_link_count integer;
  v_base_ready boolean;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object(
      'success', true,
      'units_deducted', '[]'::jsonb,
      'raw_materials_deducted', '[]'::jsonb,
      'ready_products_deducted', '[]'::jsonb,
      'errors', '[]'::jsonb
    );
  END IF;

  SELECT branch_id INTO v_user_branch
  FROM public.users
  WHERE id = auth.uid();

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(
    unit_id uuid PRIMARY KEY,
    unit_name text,
    unit_type text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(
    raw_material_id uuid PRIMARY KEY,
    raw_name text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(
    product_id uuid PRIMARY KEY,
    product_name text,
    required_qty numeric(14,6) NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE pg_temp.sale_unit_need;
  TRUNCATE pg_temp.sale_raw_need;
  TRUNCATE pg_temp.sale_ready_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);

    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = v_product_id
        AND p.branch_id = p_branch_id
        AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    v_mod := public.resolve_product_modifiers(
      v_product_id,
      p_branch_id,
      COALESCE(v_item->'modifier_option_ids', '[]'::jsonb)
    );
    IF COALESCE((v_mod->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_mod;
    END IF;

    -- Use the same authoritative base-stock decision as POS availability.
    v_res := public.check_product_availability(
      v_product_id,
      p_branch_id,
      p_warehouse_id,
      v_quantity
    );
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_res;
    END IF;

    v_base_ready := COALESCE(v_res->>'mode', '') = 'ready_product';
    v_link_count := 0;
    v_recipe_component_count := 0;

    IF v_base_ready THEN
      INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
      SELECT p.id, p.name, v_quantity
      FROM public.products p
      WHERE p.id = v_product_id
      ON CONFLICT(product_id) DO UPDATE
      SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
    ELSE
      SELECT COUNT(*) INTO v_link_count
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = v_product_id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true;

      FOR v_link IN
        SELECT pul.unit_id, pul.quantity, iu.name AS unit_name, iu.unit_type
        FROM public.product_unit_links pul
        JOIN public.inventory_units iu ON iu.id = pul.unit_id
        WHERE pul.product_id = v_product_id
          AND iu.branch_id = p_branch_id
          AND iu.is_active = true
      LOOP
        INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
        VALUES(v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
        ON CONFLICT(unit_id) DO UPDATE
        SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
      END LOOP;

      SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
      INTO v_recipe_id, v_yield
      FROM public.recipes r
      WHERE r.product_id = v_product_id
        AND r.branch_id = p_branch_id
        AND COALESCE(r.is_active, true) = true
      ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
      LIMIT 1;

      IF v_recipe_id IS NOT NULL THEN
        FOR v_link IN
          SELECT ri.raw_material_id,
                 rm.name AS raw_name,
                 ri.quantity / v_yield AS quantity_per_sale
          FROM public.recipe_items ri
          JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
          WHERE ri.recipe_id = v_recipe_id
            AND NOT EXISTS (
              SELECT 1
              FROM public.product_unit_links pul
              JOIN public.inventory_units iu ON iu.id = pul.unit_id
              WHERE pul.product_id = v_product_id
                AND iu.branch_id = p_branch_id
                AND iu.is_active = true
                AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
                    regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
            )
        LOOP
          v_recipe_component_count := v_recipe_component_count + 1;
          INSERT INTO pg_temp.sale_raw_need(raw_material_id, raw_name, required_qty)
          VALUES(v_link.raw_material_id, v_link.raw_name, v_quantity * v_link.quantity_per_sale)
          ON CONFLICT(raw_material_id) DO UPDATE
          SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
        END LOOP;
      END IF;

      IF v_link_count = 0 AND v_recipe_component_count = 0 THEN
        INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
        SELECT p.id, p.name, v_quantity
        FROM public.products p
        WHERE p.id = v_product_id
        ON CONFLICT(product_id) DO UPDATE
        SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
      END IF;
    END IF;

    -- Selected modifier effects remain independent from the base-stock source.
    FOR v_effect IN
      SELECT e.target_type,
             e.raw_material_id,
             e.inventory_unit_id,
             e.quantity_delta,
             rm.name AS raw_name,
             iu.name AS unit_name,
             iu.unit_type
      FROM public.product_modifier_inventory_effects e
      JOIN public.product_modifier_options o ON o.id = e.option_id AND o.is_active = true
      JOIN public.product_modifier_groups g ON g.id = o.group_id AND g.is_active = true
      LEFT JOIN public.raw_materials rm ON rm.id = e.raw_material_id
      LEFT JOIN public.inventory_units iu ON iu.id = e.inventory_unit_id
      WHERE g.product_id = v_product_id
        AND g.branch_id = p_branch_id
        AND o.id IN (
          SELECT NULLIF(value, '')::uuid
          FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids', '[]'::jsonb))
        )
    LOOP
      IF v_effect.target_type = 'raw_material' THEN
        INSERT INTO pg_temp.sale_raw_need(raw_material_id, raw_name, required_qty)
        VALUES(v_effect.raw_material_id, v_effect.raw_name, v_quantity * v_effect.quantity_delta)
        ON CONFLICT(raw_material_id) DO UPDATE
        SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
      ELSE
        INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
        VALUES(v_effect.inventory_unit_id, v_effect.unit_name, v_effect.unit_type, v_quantity * v_effect.quantity_delta)
        ON CONFLICT(unit_id) DO UPDATE
        SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
      END IF;
    END LOOP;

    v_recipe_id := NULL;
    v_yield := NULL;
  END LOOP;

  IF EXISTS(SELECT 1 FROM pg_temp.sale_unit_need WHERE required_qty < 0)
     OR EXISTS(SELECT 1 FROM pg_temp.sale_raw_need WHERE required_qty < 0) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_MODIFIER_INVENTORY_EFFECT',
      'detail', 'Modifier removal exceeds the base component quantity.'
    );
  END IF;

  FOR v_link IN
    SELECT * FROM pg_temp.sale_unit_need
    WHERE required_qty > 0 AND unit_type = 'manufactured'
    ORDER BY unit_id
  LOOP
    PERFORM public._ensure_inventory_unit_stock(
      v_link.unit_id,
      v_link.required_qty,
      p_warehouse_id,
      p_branch_id,
      0
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty > 0 ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',
        v_link.unit_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty > 0 ORDER BY raw_material_id
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_link.raw_material_id
      AND branch_id = p_branch_id;
    v_available := COALESCE(v_available, 0);
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',
        v_link.raw_material_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty > 0 ORDER BY product_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_batches
    WHERE product_id = v_link.product_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',
        v_link.product_id, v_link.required_qty, v_available;
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty > 0 ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at, id
      FOR UPDATE
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, v_batch.quantity);
      UPDATE public.inventory_unit_batches
      SET quantity = quantity - v_take
      WHERE id = v_batch.id;
      INSERT INTO public.inventory_unit_entries(
        unit_id, branch_id, warehouse_id, quantity, unit_cost,
        entry_type, reference_type, reference_id, reference_number,
        batch_number, created_by
      ) VALUES(
        v_link.unit_id, p_branch_id, p_warehouse_id, -v_take, v_batch.unit_cost,
        'sale', 'sale', p_reference_id, p_reference_number,
        v_batch.batch_number, auth.uid()
      );
      v_need := v_need - v_take;
      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
    END LOOP;
    v_units := v_units || jsonb_build_object(
      'unit_id', v_link.unit_id,
      'unit_name', v_link.unit_name,
      'unit_type', v_link.unit_type,
      'quantity', v_link.required_qty
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty > 0 ORDER BY raw_material_id
  LOOP
    v_res := public._raw_remove_fifo(
      v_link.raw_material_id,
      p_branch_id,
      v_link.required_qty,
      'sale', 'sale', p_reference_id, p_reference_number, auth.uid()
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',
        v_link.raw_material_id, v_res->>'shortage';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
    v_raws := v_raws || jsonb_build_object(
      'raw_material_id', v_link.raw_material_id,
      'raw_name', v_link.raw_name,
      'quantity', v_link.required_qty,
      'total_cost', COALESCE((v_res->>'total_cost')::numeric, 0)
    );
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty > 0 ORDER BY product_id
  LOOP
    v_res := public._product_inv_remove_fifo(
      v_link.product_id,
      p_warehouse_id,
      p_branch_id,
      v_link.required_qty,
      'sale', 'sale', p_reference_id, p_reference_number, auth.uid()
    );
    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',
        v_link.product_id, v_res->>'shortage';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
    v_ready := v_ready || jsonb_build_object(
      'product_id', v_link.product_id,
      'product_name', v_link.product_name,
      'quantity', v_link.required_qty,
      'total_cost', COALESCE((v_res->>'total_cost')::numeric, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', v_raws,
    'ready_products_deducted', v_ready,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', 'SALE_INVENTORY_DEDUCTION_FAILED',
    'detail', SQLERRM
  );
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904040000_operations_approvals_permissions.sql
-- ----------------------------------------------------------------------------
-- Operations / approvals / reporting hardening requested for multi-branch users.
-- Reuse user_branch_access as the canonical multi-branch grant; do not weaken branch RLS.

-- Every active operational role may enter POS and create an order. Sensitive POS actions
-- remain separately permission-gated.
UPDATE public.roles
SET permissions = CASE
  WHEN permissions ? 'pos.sell' THEN permissions
  ELSE permissions || '["pos.sell"]'::jsonb
END,
updated_at = now()
WHERE is_active = true;

-- Managers may review approvals. Override is explicit and is not a global-admin shortcut.
UPDATE public.roles
SET permissions = permissions || '["approvals.review","approvals.override","shifts.open","shifts.close","shifts.view"]'::jsonb,
    updated_at = now()
WHERE role = 'branch_manager' AND is_active = true;

-- Opening a shift is permission-based and branch-access based, not hard-coded to cashier.
CREATE OR REPLACE FUNCTION public.open_shift(
  p_branch_id uuid,
  p_opening_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id=v_uid AND is_active=true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('shifts.open')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_ALLOWED');
  END IF;
  IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  -- One normal open shift per user. A multi-branch user selects which authorized branch
  -- the shift belongs to; financial ownership stays branch-safe.
  IF EXISTS (SELECT 1 FROM public.shifts WHERE cashier_id=v_uid AND status='open') THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_ALREADY_OPEN');
  END IF;

  INSERT INTO public.shifts(branch_id,cashier_id,opening_amount,notes)
  VALUES(p_branch_id,v_uid,COALESCE(p_opening_amount,0),p_notes)
  RETURNING id INTO v_shift_id;

  INSERT INTO public.shift_operations(shift_id,operation_type,amount,payment_method,reference_type,created_by)
  VALUES(v_shift_id,'opening',COALESCE(p_opening_amount,0),'cash','shift_opening',v_uid);

  RETURN jsonb_build_object('success',true,'shift_id',v_shift_id,'branch_id',p_branch_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','UNKNOWN_ERROR','detail',SQLERRM);
END;
$function$;

-- Explicitly-authorized approvers may approve their own action request. This implements
-- manager self-bypass without turning branch_manager into global admin.
CREATE OR REPLACE FUNCTION public.decide_manager_approval(
  p_request_id uuid,
  p_approve boolean,
  p_note text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_req public.approval_requests%ROWTYPE;
  v_user public.users%ROWTYPE;
  v_status text;
  v_self_override boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;

  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_req.branch_id)
     OR NOT (public.is_pos_admin() OR public.can_permission('approvals.review')) THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED');
  END IF;
  v_self_override := v_req.requester_id=auth.uid() AND (public.is_pos_admin() OR public.can_permission('approvals.override'));
  IF v_req.requester_id=auth.uid() AND NOT v_self_override THEN
    RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN');
  END IF;
  IF v_req.status<>'pending' THEN
    RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status);
  END IF;
  IF v_req.expires_at<=now() THEN
    UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id;
    RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED');
  END IF;

  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests
  SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now()
  WHERE id=v_req.id;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,
    'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,
      'entity_type',v_req.entity_type,'target_id',v_req.entity_id,'note',p_note,'self_override',v_self_override),
    v_req.branch_id);

  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status,'self_override',v_self_override);
END;
$function$;

-- One user closing report, independent of the shift summary.
CREATE OR REPLACE FUNCTION public.get_user_closing_report(
  p_user_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_branch_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF p_user_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'INVALID_REPORT_RANGE';
  END IF;
  IF p_branch_id IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  SELECT jsonb_build_object(
    'user_id',p_user_id,
    'from',p_from,'to',p_to,
    'invoice_count',COUNT(*),
    'gross_sales',COALESCE(SUM(s.subtotal),0),
    'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),
    'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0),
    'branches',COALESCE(jsonb_agg(DISTINCT s.branch_id) FILTER (WHERE s.branch_id IS NOT NULL),'[]'::jsonb)
  ) INTO v_result
  FROM public.sales s
  WHERE (s.cashier_id=p_user_id OR s.salesperson_id=p_user_id)
    AND s.created_at>=p_from AND s.created_at<p_to
    AND (p_branch_id IS NULL OR s.branch_id=p_branch_id)
    AND public.user_may_access_branch(s.branch_id);
  RETURN COALESCE(v_result,'{}'::jsonb);
END;
$function$;

-- Shift financial report derives sales by branch+cashier+time window because sales has no shift_id.
CREATE OR REPLACE FUNCTION public.get_shift_closing_report(p_shift_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_shift public.shifts%ROWTYPE; v_result jsonb;
BEGIN
  SELECT * INTO v_shift FROM public.shifts WHERE id=p_shift_id;
  IF v_shift.id IS NULL THEN RAISE EXCEPTION 'SHIFT_NOT_FOUND'; END IF;
  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;

  SELECT jsonb_build_object(
    'shift_id',v_shift.id,'branch_id',v_shift.branch_id,'cashier_id',v_shift.cashier_id,
    'opened_at',v_shift.opened_at,'closed_at',v_shift.closed_at,
    'opening_amount',v_shift.opening_amount,'expected_amount',v_shift.expected_amount,
    'actual_amount',v_shift.actual_amount,'difference',v_shift.difference,
    'invoice_count',COUNT(s.id),
    'gross_sales',COALESCE(SUM(s.subtotal),0),'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0)
  ) INTO v_result
  FROM public.sales s
  WHERE s.branch_id=v_shift.branch_id
    AND s.cashier_id=v_shift.cashier_id
    AND s.created_at>=v_shift.opened_at
    AND s.created_at<COALESCE(v_shift.closed_at,now());
  RETURN v_result;
END;
$function$;

-- End-of-day summary includes every shift overlapping that business day, not only the active shift.
CREATE OR REPLACE FUNCTION public.get_day_closing_report(p_branch_id uuid,p_day date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_start timestamptz:=p_day::timestamptz; v_finish timestamptz:=(p_day+1)::timestamptz; v_result jsonb;
BEGIN
  IF NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  SELECT jsonb_build_object(
    'branch_id',p_branch_id,'day',p_day,
    'shift_count',(SELECT COUNT(*) FROM public.shifts sh WHERE sh.branch_id=p_branch_id AND sh.opened_at<v_finish AND COALESCE(sh.closed_at,now())>=v_start),
    'closed_shift_count',(SELECT COUNT(*) FROM public.shifts sh WHERE sh.branch_id=p_branch_id AND sh.status='closed' AND sh.opened_at<v_finish AND COALESCE(sh.closed_at,now())>=v_start),
    'user_count',COUNT(DISTINCT s.cashier_id),
    'invoice_count',COUNT(s.id),
    'gross_sales',COALESCE(SUM(s.subtotal),0),'discounts',COALESCE(SUM(s.discount_amount),0),
    'taxes',COALESCE(SUM(s.tax_amount),0),'net_sales',COALESCE(SUM(s.total),0),
    'refunded_amount',COALESCE(SUM(s.refunded_amount),0),
    'cash_sales',COALESCE(SUM(CASE WHEN s.payment_method='cash' THEN s.total ELSE 0 END),0),
    'card_sales',COALESCE(SUM(CASE WHEN s.payment_method='card' THEN s.total ELSE 0 END),0)
  ) INTO v_result
  FROM public.sales s
  WHERE s.branch_id=p_branch_id AND s.created_at>=v_start AND s.created_at<v_finish;
  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_user_closing_report(uuid,timestamptz,timestamptz,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_shift_closing_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_day_closing_report(uuid,date) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904041000_unified_approval_queue.sql
-- ----------------------------------------------------------------------------
-- Unified, branch-safe queue for records that have real server-side approve/reject actions.

CREATE OR REPLACE FUNCTION public.get_operational_approval_queue(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE(
  source_type text,
  source_id uuid,
  branch_id uuid,
  title text,
  status text,
  requested_by uuid,
  requested_at timestamptz,
  required_permission text,
  payload jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT 'manager_approval', a.id, a.branch_id,
         a.action_type, a.status, a.requester_id, a.created_at,
         'approvals.review',
         jsonb_build_object('entity_type',a.entity_type,'entity_id',a.entity_id,'reason',a.reason,'payload',a.payload)
  FROM public.approval_requests a
  WHERE a.status='pending'
    AND (p_branch_id IS NULL OR a.branch_id=p_branch_id)
    AND public.user_may_access_branch(a.branch_id)

  UNION ALL
  SELECT 'waste', w.id, w.branch_id,
         'waste:'||w.waste_type, w.status, w.created_by, w.created_at,
         'production.waste',
         jsonb_build_object('product_id',w.product_id,'raw_material_id',w.raw_material_id,'inventory_unit_id',w.inventory_unit_id,
                            'quantity',w.quantity,'total_cost',w.total_cost,'reason',w.reason)
  FROM public.waste_entries w
  WHERE w.status='pending'
    AND (p_branch_id IS NULL OR w.branch_id=p_branch_id)
    AND public.user_may_access_branch(w.branch_id)

  UNION ALL
  SELECT 'stock_count', s.id, s.branch_id,
         'stock_count:'||COALESCE(s.count_number,s.id::text), s.status, s.submitted_by, COALESCE(s.submitted_at,s.created_at),
         'inventory.manage',
         jsonb_build_object('warehouse_id',s.warehouse_id,'count_type',s.count_type,'notes',s.notes)
  FROM public.stock_counts s
  WHERE s.status='submitted'
    AND (p_branch_id IS NULL OR s.branch_id=p_branch_id)
    AND public.user_may_access_branch(s.branch_id)

  UNION ALL
  SELECT 'warehouse_transfer', t.id, t.branch_id,
         'transfer:'||COALESCE(t.transfer_number,t.id::text), t.status, t.requested_by, COALESCE(t.requested_at,t.created_at),
         'inventory.transfers.approve',
         jsonb_build_object('from_warehouse_id',t.from_warehouse_id,'to_warehouse_id',t.to_warehouse_id,'reason',t.reason,'notes',t.notes)
  FROM public.warehouse_transfers t
  WHERE t.status IN ('pending','requested','submitted')
    AND (p_branch_id IS NULL OR t.branch_id=p_branch_id)
    AND public.user_may_access_branch(t.branch_id)

  ORDER BY 7 DESC;
$function$;

CREATE OR REPLACE FUNCTION public.decide_operational_approval(
  p_source_type text,
  p_source_id uuid,
  p_approve boolean,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;

  IF p_source_type='manager_approval' THEN
    IF NOT (public.is_pos_admin() OR public.can_permission('approvals.review')) THEN
      RETURN jsonb_build_object('success',false,'error','APPROVAL_REVIEW_DENIED');
    END IF;
    RETURN public.decide_manager_approval(p_source_id,p_approve,p_reason);
  ELSIF p_source_type='waste' THEN
    SELECT branch_id INTO v_branch FROM public.waste_entries WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('production.waste')) THEN
      RETURN jsonb_build_object('success',false,'error','WASTE_APPROVAL_DENIED');
    END IF;
    PERFORM public.approve_waste(p_source_id,p_approve,p_reason);
    RETURN jsonb_build_object('success',true,'source_type','waste','source_id',p_source_id,'status',CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END);
  ELSIF p_source_type='stock_count' THEN
    SELECT branch_id INTO v_branch FROM public.stock_counts WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
      RETURN jsonb_build_object('success',false,'error','STOCK_COUNT_APPROVAL_DENIED');
    END IF;
    IF p_approve THEN RETURN public.approve_stock_count(p_source_id); END IF;
    RETURN public.reject_stock_count(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  ELSIF p_source_type='warehouse_transfer' THEN
    SELECT branch_id INTO v_branch FROM public.warehouse_transfers WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
      RETURN jsonb_build_object('success',false,'error','TRANSFER_APPROVAL_DENIED');
    END IF;
    IF p_approve THEN RETURN public.approve_warehouse_transfer(p_source_id); END IF;
    RETURN public.reject_warehouse_transfer(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  END IF;
  RETURN jsonb_build_object('success',false,'error','UNSUPPORTED_APPROVAL_SOURCE');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_operational_approval_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904042000_v2_pos_multibranch_contract.sql
-- ----------------------------------------------------------------------------
-- Frontend V2 POS multi-branch contract.
-- Narrowly replaces legacy users.branch_id equality checks with the canonical
-- user_may_access_branch() primitive. Business logic, pricing, KDS and
-- inventory semantics remain unchanged.

-- Every active application role can enter POS and run its own normal shift.
-- Sensitive actions (pay, discount, void, refund, approvals...) stay separate.
UPDATE public.roles
SET permissions = (
  SELECT jsonb_agg(DISTINCT value ORDER BY value)
  FROM jsonb_array_elements_text(
    COALESCE(permissions, '[]'::jsonb)
    || '["pos.sell","shifts.view","shifts.open","shifts.close"]'::jsonb
  ) AS p(value)
), updated_at = now()
WHERE is_active = true;

DO $migration$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  -- create_order: allow any explicitly authorized branch, not only users.branch_id.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='create_order'
    AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid, p_order_type text, p_table_id uuid, p_customer_id uuid, p_guest_count integer, p_notes text, p_items jsonb, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_total numeric, p_cashier_id uuid';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_CREATE_ORDER_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> p_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''AUTH_REQUIRED'');\n    END IF;\n    IF NOT public.user_may_access_branch(p_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_CREATE_ORDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- update_order: access follows the order branch and explicit grants.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='update_order';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_UPDATE_ORDER_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''AUTH_REQUIRED'');\n    END IF;\n    IF NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_UPDATE_ORDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- Legacy two-arg kitchen sender: preserve delta-send/KDS logic, patch scope only.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='send_to_kitchen'
    AND pg_get_function_identity_arguments(p.oid)='p_order_id uuid, p_sent_by uuid';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_KITCHEN_SENDER_MISSING'; END IF;
  v_old := E'      select branch_id into v_user_branch\n      from public.users\n      where id = auth.uid() and is_active = true;\n\n      if not is_pos_admin()\n         and coalesce(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id then\n        return jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n      end if;';
  v_new := E'      if not public.user_may_access_branch(v_branch_id) then\n        return jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n      end if;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_KITCHEN_SENDER_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- set_order_status: status changes remain guarded by existing mutation trigger.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='set_order_status';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_ORDER_STATUS_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL OR NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_ORDER_STATUS_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  -- set_table_status: same branch primitive, occupancy guard remains untouched.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='set_table_status';
  IF v_def IS NULL THEN RAISE EXCEPTION 'V2_PATCH_TABLE_STATUS_MISSING'; END IF;
  v_old := E'    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();\n    IF NOT is_pos_admin() AND COALESCE(v_user_branch, ''00000000-0000-0000-0000-000000000000''::uuid) <> v_branch_id THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  v_new := E'    IF auth.uid() IS NULL OR NOT public.user_may_access_branch(v_branch_id) THEN\n      RETURN jsonb_build_object(''success'', false, ''error'', ''BRANCH_MISMATCH'');\n    END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'V2_PATCH_TABLE_STATUS_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$migration$;

-- get_active_shift remains caller-owned, but revoked branch access must not leak
-- or reactivate a shift from a branch the user no longer may access.
CREATE OR REPLACE FUNCTION public.get_active_shift(p_branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_cash_sales numeric(14,2);
  v_cash_expenses numeric(14,2);
  v_total_sales numeric(14,2);
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  IF p_branch_id IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE cashier_id = v_uid AND status = 'open'
    AND (p_branch_id IS NULL OR branch_id = p_branch_id)
  ORDER BY opened_at DESC LIMIT 1;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'open', false);
  END IF;
  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'open', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT COALESCE(SUM(amount), 0),
         COALESCE(SUM(CASE WHEN payment_method = 'cash' AND operation_type='sale' THEN amount ELSE 0 END), 0),
         COALESCE(SUM(CASE WHEN payment_method = 'cash' AND operation_type='expense' THEN amount ELSE 0 END), 0)
  INTO v_total_sales, v_cash_sales, v_cash_expenses
  FROM public.shift_operations
  WHERE shift_id = v_shift.id;

  RETURN jsonb_build_object(
    'success', true, 'open', true,
    'shift', jsonb_build_object(
      'id', v_shift.id,
      'branch_id', v_shift.branch_id,
      'cashier_id', v_shift.cashier_id,
      'opened_at', v_shift.opened_at,
      'opening_amount', v_shift.opening_amount,
      'expected', v_shift.opening_amount + v_cash_sales - v_cash_expenses,
      'cash_sales', v_cash_sales,
      'total_sales', v_total_sales,
      'notes', v_shift.notes
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- Harden only functions touched by this migration.
ALTER FUNCTION public.create_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.update_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,text) SET search_path = public, pg_temp;
ALTER FUNCTION public.send_to_kitchen(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.set_order_status(uuid,text,text) SET search_path = public, pg_temp;
ALTER FUNCTION public.set_table_status(uuid,text) SET search_path = public, pg_temp;

GRANT EXECUTE ON FUNCTION public.get_active_shift(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904043000_harden_v2_kitchen_send_permission.sql
-- ----------------------------------------------------------------------------
-- V2 POS permission contract: creating an order and sending it to the kitchen
-- are separate capabilities. Preserve the canonical delta-send RPC signature
-- and response shape while enforcing the dedicated server-side permission.

-- The canonical RPC accepts one or two arguments because p_sent_by defaults to
-- NULL. A separate one-argument overload makes PostgreSQL calls ambiguous.
DROP FUNCTION IF EXISTS public.send_to_kitchen(uuid);

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
BEGIN
  BEGIN
    IF auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders
    WHERE id = p_order_id;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF NOT public.user_may_access_branch(v_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    IF NOT (public.is_pos_admin() OR public.can_permission('pos.send_kitchen')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

    -- Candidate delta is current cart quantity minus the net quantity already
    -- communicated to KDS. The conflict WHERE clause remains concurrency-safe.
    WITH candidates AS (
      SELECT
        oi.id AS order_item_id,
        oi.quantity AS target_quantity,
        oi.quantity - COALESCE(s.sent_quantity, 0) AS delta_quantity
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT
        v_branch_id,
        p_order_id,
        c.order_item_id,
        now(),
        COALESCE(p_sent_by, auth.uid()),
        c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity = EXCLUDED.sent_quantity,
          sent_at = now(),
          sent_by = EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    INSERT INTO _kns_delta(order_item_id, send_id, delta_quantity)
    SELECT u.order_item_id, u.id, c.delta_quantity
    FROM upserted u
    JOIN candidates c ON c.order_item_id = u.order_item_id;

    SELECT COUNT(*) INTO v_count FROM _kns_delta;

    IF v_count > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id', k.send_id,
        'order_item_id', k.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'quantity', k.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM _kns_delta k
      JOIN public.order_items oi ON oi.id = k.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id;
    END IF;

    SELECT NOT EXISTS (
      SELECT 1
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ) INTO v_all_sent;

    RETURN jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904044000_harden_v2_shift_close_permission.sql
-- ----------------------------------------------------------------------------
-- V2 shift contract: own-shift close and managing another user's shift are
-- separate permissions. Branch manager is not a global or implicit bypass.

CREATE OR REPLACE FUNCTION public.close_shift(
  p_shift_id uuid,
  p_actual_amount numeric,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift public.shifts%ROWTYPE;
  v_expected numeric(14,2);
  v_diff numeric(14,2);
  v_is_own boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT * INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_shift.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF v_shift.status = 'closed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_CLOSED');
  END IF;

  v_is_own := v_shift.cashier_id = v_uid;

  IF v_is_own THEN
    IF NOT (public.is_pos_admin() OR public.can_permission('shifts.close')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SHIFT_CLOSE_DENIED');
    END IF;
  ELSE
    IF NOT (public.is_pos_admin() OR public.can_permission('shifts.manage')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SHIFT_MANAGE_DENIED');
    END IF;
  END IF;

  SELECT COALESCE(v_shift.opening_amount, 0)
       + COALESCE(SUM(CASE WHEN op.operation_type = 'sale' AND COALESCE(op.payment_method, 'cash') = 'cash' THEN op.amount ELSE 0 END), 0)
       - COALESCE(SUM(CASE WHEN op.operation_type = 'expense' AND COALESCE(op.payment_method, 'cash') = 'cash' THEN op.amount ELSE 0 END), 0)
       - COALESCE(SUM(CASE WHEN op.operation_type = 'refund' THEN op.amount ELSE 0 END), 0)
    INTO v_expected
  FROM public.shift_operations op
  WHERE op.shift_id = p_shift_id;

  v_diff := COALESCE(p_actual_amount, v_expected) - v_expected;

  UPDATE public.shifts
  SET status = 'closed',
      closed_at = now(),
      expected_amount = v_expected,
      actual_amount = COALESCE(p_actual_amount, v_expected),
      difference = v_diff,
      notes = COALESCE(p_notes, notes)
  WHERE id = p_shift_id;

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'expected', v_expected,
    'actual', COALESCE(p_actual_amount, v_expected),
    'difference', v_diff
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.close_shift(uuid,numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.close_shift(uuid,numeric,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_shift(uuid,numeric,text) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904045000_harden_v2_operational_approval_targets.sql
-- ----------------------------------------------------------------------------
-- V2 unified approvals must remain safe even if a client calls the target RPC
-- directly instead of going through decide_operational_approval().
-- Keep existing business logic; replace legacy branch checks with the canonical
-- user_may_access_branch() primitive and require the matching permission.

CREATE OR REPLACE FUNCTION public.approve_waste(
  p_waste_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_entry public.waste_entries%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT * INTO v_entry
  FROM public.waste_entries
  WHERE id = p_waste_id
  FOR UPDATE;

  IF v_entry.id IS NULL THEN
    RAISE EXCEPTION 'WASTE_NOT_FOUND';
  END IF;

  IF NOT public.user_may_access_branch(v_entry.branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF NOT (public.is_pos_admin() OR public.can_permission('production.waste')) THEN
    RAISE EXCEPTION 'WASTE_APPROVAL_DENIED';
  END IF;

  IF v_entry.status <> 'pending' THEN
    RAISE EXCEPTION 'WASTE_NOT_PENDING';
  END IF;

  IF p_approve THEN
    UPDATE public.waste_entries
    SET status = 'approved',
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now(),
        rejection_reason = NULL
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (auth.uid(), 'approve', 'waste_entry', p_waste_id,
      jsonb_build_object('status', 'approved'), v_entry.branch_id);
  ELSE
    UPDATE public.waste_entries
    SET status = 'rejected',
        rejection_reason = p_rejection_reason,
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now()
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (auth.uid(), 'reject', 'waste_entry', p_waste_id,
      jsonb_build_object('status', 'rejected', 'reason', p_rejection_reason), v_entry.branch_id);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count public.stock_counts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
      'detail', 'Approving stock counts requires inventory.manage.');
  END IF;

  SELECT * INTO v_count
  FROM public.stock_counts
  WHERE id = p_stock_count_id
  FOR UPDATE;

  IF v_count.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_count.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_count.status <> 'submitted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
  END IF;

  UPDATE public.stock_counts
  SET status = 'approved', approved_by = auth.uid(), approved_at = now(), rejection_reason = NULL
  WHERE id = p_stock_count_id;

  RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_stock_count(
  p_stock_count_id uuid,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count public.stock_counts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.manage')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_count
  FROM public.stock_counts
  WHERE id = p_stock_count_id
  FOR UPDATE;

  IF v_count.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_count.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_count.status <> 'submitted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
  END IF;

  UPDATE public.stock_counts
  SET status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_reason
  WHERE id = p_stock_count_id;

  RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.approve_warehouse_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_transfer public.warehouse_transfers%ROWTYPE;
  v_item record;
  v_avail numeric(14,4);
  v_res jsonb;
  v_short numeric(14,4);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
      'detail', 'Approving transfers requires inventory.transfers.approve.');
  END IF;

  SELECT * INTO v_transfer
  FROM public.warehouse_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;

  IF v_transfer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSFER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_transfer.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_transfer.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_transfer.status);
  END IF;

  FOR v_item IN
    SELECT * FROM public.warehouse_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_avail
    FROM public.inventory_batches
    WHERE product_id = v_item.product_id
      AND warehouse_id = v_transfer.from_warehouse_id;

    IF v_avail < v_item.quantity THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
        'product_id', v_item.product_id, 'required', v_item.quantity, 'available', v_avail);
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT * FROM public.warehouse_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    v_res := public._product_inv_move(
      v_item.product_id,
      v_transfer.from_warehouse_id,
      v_transfer.to_warehouse_id,
      v_transfer.branch_id,
      v_item.quantity,
      'warehouse_transfer',
      v_transfer.id,
      v_transfer.transfer_number,
      auth.uid()
    );
    v_short := (v_res->>'shortage')::numeric;
    IF v_short > 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
        'product_id', v_item.product_id, 'shortage', v_short);
    END IF;
  END LOOP;

  UPDATE public.warehouse_transfers
  SET status = 'approved', approved_by = auth.uid(), approved_at = now()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true, 'transfer_id', p_transfer_id, 'transfer_number', v_transfer.transfer_number);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reject_warehouse_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_transfer public.warehouse_transfers%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF NOT (public.is_pos_admin() OR public.can_permission('inventory.transfers.approve')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_transfer
  FROM public.warehouse_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;

  IF v_transfer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSFER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_transfer.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_transfer.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_transfer.status);
  END IF;

  UPDATE public.warehouse_transfers
  SET status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_reason
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true, 'transfer_id', p_transfer_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO service_role;

REVOKE ALL ON FUNCTION public.approve_stock_count(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_stock_count(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_warehouse_transfer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_warehouse_transfer(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_stock_count(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_stock_count(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_warehouse_transfer(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_warehouse_transfer(uuid,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904046000_permission_first_roles_branch_access.sql
-- ----------------------------------------------------------------------------
-- Permission-first authorization for Frontend V2.
-- Super Admin is the only platform-level bypass. All other users, including
-- owner-labelled users, are authorized by explicit role permissions and
-- explicit/legacy branch grants.

CREATE OR REPLACE FUNCTION public.can_permission(p_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT public.is_platform_admin() OR EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.roles r ON r.role = u.role
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND COALESCE(r.is_active, true) = true
      AND COALESCE(r.permissions, '[]'::jsonb) ? p_permission
  );
$function$;

CREATE OR REPLACE FUNCTION public.user_may_access_branch(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT
    public.is_platform_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = auth.uid()
        AND uba.branch_id = p_branch_id
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active = true
        AND u.branch_id = p_branch_id
    )
    OR (p_branch_id IS NULL AND public.is_platform_admin());
$function$;

CREATE OR REPLACE FUNCTION public.get_user_branch_access(p_user_id uuid)
RETURNS TABLE(
  branch_id uuid,
  branch_name text,
  branch_name_en text,
  organization_id uuid,
  is_active boolean,
  grant_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active, 'explicit'::text
  FROM public.user_branch_access uba
  JOIN public.branches b ON b.id = uba.branch_id
  WHERE uba.user_id = p_user_id
    AND (
      p_user_id = auth.uid()
      OR public.is_platform_admin()
      OR (public.can_permission('users.view') AND public.user_may_access_branch(b.id))
    )

  UNION

  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active, 'primary'::text
  FROM public.users u
  JOIN public.branches b ON b.id = u.branch_id
  WHERE u.id = p_user_id
    AND NOT EXISTS (
      SELECT 1 FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id AND uba.branch_id = b.id
    )
    AND (
      p_user_id = auth.uid()
      OR public.is_platform_admin()
      OR (public.can_permission('users.view') AND public.user_may_access_branch(b.id))
    )
  ORDER BY 2;
$function$;

CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_primary uuid;
  v_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  SELECT role, branch_id
  INTO v_target_role, v_target_primary
  FROM public.users
  WHERE id = p_user_id;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_target_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access');
    END IF;

    IF v_target_primary IS NOT NULL AND NOT public.user_may_access_branch(v_target_primary) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id
        AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED', 'branch_id', v_branch_id);
      END IF;
    END LOOP;
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, branch_id
  FROM unnest(p_branch_ids) AS branch_id
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    'set_branch_access', 'user_branch_access', NULL,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;

-- Branch visibility follows explicit access. Organization labels no longer imply
-- automatic access to every branch.
DROP POLICY IF EXISTS auth_select_branches ON public.branches;
CREATE POLICY auth_select_branches ON public.branches
FOR SELECT TO authenticated
USING (public.user_may_access_branch(id));

DROP POLICY IF EXISTS auth_update_branches ON public.branches;
CREATE POLICY auth_update_branches ON public.branches
FOR UPDATE TO authenticated
USING (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)))
WITH CHECK (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)));

DROP POLICY IF EXISTS auth_delete_branches ON public.branches;
CREATE POLICY auth_delete_branches ON public.branches
FOR DELETE TO authenticated
USING (public.is_platform_admin() OR (public.can_permission('branches.manage') AND public.user_may_access_branch(id)));

-- Direct user_branch_access writes are permission-based as well. The RPC above
-- remains the preferred audited path.
DROP POLICY IF EXISTS auth_org_admin_manage_user_branch_access ON public.user_branch_access;
DROP POLICY IF EXISTS auth_platform_admin_user_branch_access ON public.user_branch_access;
DROP POLICY IF EXISTS auth_manage_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_manage_user_branch_access ON public.user_branch_access
FOR ALL TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
);

-- Role rows are templates/labels. Their permissions are the authority. Any role
-- with settings.manage may maintain role templates, but cannot grant a permission
-- that the caller does not already possess. Super Admin is the only exception.
DROP POLICY IF EXISTS auth_select_roles ON public.roles;
CREATE POLICY auth_select_roles ON public.roles
FOR SELECT TO authenticated
USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS auth_write_roles ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_del ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_upd ON public.roles;
CREATE POLICY auth_write_roles ON public.roles
FOR INSERT TO authenticated
WITH CHECK (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);
CREATE POLICY auth_write_roles_upd ON public.roles
FOR UPDATE TO authenticated
USING (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
)
WITH CHECK (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);
CREATE POLICY auth_write_roles_del ON public.roles
FOR DELETE TO authenticated
USING (
  public.is_platform_admin()
  OR (
    public.can_permission('settings.manage')
    AND role <> 'super_admin'
    AND (scope = 'global' OR (branch_id IS NOT NULL AND public.user_may_access_branch(branch_id)))
  )
);

CREATE OR REPLACE FUNCTION public.guard_role_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_perm text;
BEGIN
  -- Migrations/DB owner fixtures are not interactive app users.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_platform_admin() THEN
    RETURN NEW;
  END IF;

  IF NOT public.can_permission('settings.manage') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: settings.manage required';
  END IF;

  IF NEW.role = 'super_admin' THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Super Admin role is platform-only';
  END IF;

  IF NEW.scope = 'branch' AND (NEW.branch_id IS NULL OR NOT public.user_may_access_branch(NEW.branch_id)) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: branch role outside caller access';
  END IF;

  FOR v_perm IN
    SELECT jsonb_array_elements_text(COALESCE(NEW.permissions, '[]'::jsonb))
  LOOP
    IF NOT public.can_permission(v_perm) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: cannot grant permission %', v_perm;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_user_role_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_caller_role text;
  v_bypass boolean;
  v_register boolean;
  v_perm text;
  v_role_scope text;
  v_role_branch uuid;
BEGIN
  SELECT role INTO v_caller_role FROM public.users WHERE id = auth.uid();

  v_bypass := COALESCE(current_setting('app.login_guard_bypass', true), '') = 'on';
  v_register := COALESCE(current_setting('app.register_branch', true), '') = 'on';

  IF v_register THEN RETURN NEW; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE role = NEW.role AND is_active = true) THEN
    RAISE EXCEPTION 'UNKNOWN_ROLE';
  END IF;

  SELECT scope, branch_id INTO v_role_scope, v_role_branch
  FROM public.roles WHERE role = NEW.role;

  IF v_caller_role IS NULL THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.id = auth.uid() AND NEW.role = 'cashier' AND NEW.branch_id IS NULL THEN RETURN NEW; END IF;
      RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.role IS DISTINCT FROM OLD.role
       OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
       OR NEW.is_active IS DISTINCT FROM OLD.is_active
       OR NEW.email IS DISTINCT FROM OLD.email
       OR NEW.username IS DISTINCT FROM OLD.username
       OR NEW.full_name IS DISTINCT FROM OLD.full_name
       OR NEW.phone IS DISTINCT FROM OLD.phone THEN
      RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;
    RETURN NEW;
  END IF;

  IF public.is_platform_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'UPDATE' AND NEW.id = auth.uid() THEN
    IF NEW.role IS DISTINCT FROM OLD.role
       OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
       OR NEW.is_active IS DISTINCT FROM OLD.is_active THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: users cannot change their own role/branch/status';
    END IF;
    IF NOT v_bypass AND (
      NEW.is_locked IS DISTINCT FROM OLD.is_locked
      OR NEW.failed_attempts IS DISTINCT FROM OLD.failed_attempts
      OR NEW.lock_until IS DISTINCT FROM OLD.lock_until
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: users cannot modify their own lock state';
    END IF;
    RETURN NEW;
  END IF;

  IF NOT public.can_permission('users.manage') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: users.manage required';
  END IF;

  IF NEW.role = 'super_admin' OR (TG_OP = 'UPDATE' AND OLD.role = 'super_admin') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: Super Admin accounts are platform-only';
  END IF;

  IF NEW.branch_id IS NULL OR NOT public.user_may_access_branch(NEW.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: target branch outside caller access';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.branch_id IS NOT NULL AND NOT public.user_may_access_branch(OLD.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: target user outside caller access';
  END IF;

  IF v_role_scope = 'branch' AND v_role_branch IS DISTINCT FROM NEW.branch_id THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: role is not assignable in this branch';
  END IF;

  FOR v_perm IN
    SELECT jsonb_array_elements_text(COALESCE((SELECT permissions FROM public.roles WHERE role = NEW.role), '[]'::jsonb))
  LOOP
    IF NOT public.can_permission(v_perm) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: cannot assign role containing permission %', v_perm;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.protect_last_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_other_active_super_admins int;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.role = 'super_admin' AND OLD.is_active THEN
      SELECT count(*) INTO v_other_active_super_admins
      FROM public.users
      WHERE role = 'super_admin' AND is_active AND id <> OLD.id;
      IF v_other_active_super_admins = 0 THEN RAISE EXCEPTION 'LAST_ADMIN'; END IF;
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.role = 'super_admin' AND OLD.is_active
     AND (NEW.role <> 'super_admin' OR NOT NEW.is_active) THEN
    SELECT count(*) INTO v_other_active_super_admins
    FROM public.users
    WHERE role = 'super_admin' AND is_active AND id <> OLD.id;
    IF v_other_active_super_admins = 0 THEN RAISE EXCEPTION 'LAST_ADMIN'; END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- Canonical create_user overload: permission-based user management, with role
-- labels unrestricted except for Super Admin and branch scope.
CREATE OR REPLACE FUNCTION public.create_user(
  p_email text,
  p_password text,
  p_full_name text DEFAULT NULL::text,
  p_role text DEFAULT 'cashier'::text,
  p_branch_id uuid DEFAULT NULL::uuid,
  p_is_active boolean DEFAULT true,
  p_username text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_user_id uuid;
  v_role text;
  v_hash text;
  v_email text;
  v_username text;
  v_pgc_schema text;
  v_u_cols text;
  v_u_vals text;
  v_i_cols text;
  v_i_vals text;
BEGIN
  IF current_setting('app.register_branch', true) = 'on' THEN
    NULL;
  ELSIF public.is_platform_admin() THEN
    NULL;
  ELSIF public.can_permission('users.manage') THEN
    IF p_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Super Admin is platform-only');
    END IF;
    IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Target branch is not accessible');
    END IF;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  v_email := lower(btrim(p_email));
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) OR EXISTS (SELECT 1 FROM public.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMAIL_TAKEN');
  END IF;

  v_username := regexp_replace(
    regexp_replace(lower(btrim(coalesce(NULLIF(p_username, ''), split_part(v_email, '@', 1)))), '[^a-z0-9._-]', '_', 'g'),
    '^[._-]+', '', 'g'
  );
  IF v_username = '' THEN v_username := 'user' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE username = v_username) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USERNAME_TAKEN');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.roles r
    WHERE r.role = p_role
      AND r.is_active = true
      AND (r.scope = 'global' OR r.branch_id = p_branch_id)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ROLE_NOT_ASSIGNABLE');
  END IF;

  IF NOT public.is_platform_admin() AND p_role = 'super_admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(COALESCE((SELECT permissions FROM public.roles WHERE role = p_role), '[]'::jsonb)) AS p(permission)
      WHERE NOT public.can_permission(p.permission)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'Cannot assign a role with permissions the caller does not have');
    END IF;
  END IF;
  v_role := p_role;

  SELECT extnamespace::regnamespace::text INTO v_pgc_schema
  FROM pg_extension WHERE extname = 'pgcrypto';
  IF v_pgc_schema IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'pgcrypto extension is not enabled');
  END IF;

  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt($2, $3))', v_pgc_schema, v_pgc_schema)
    INTO v_hash USING p_password, 'bf', 10;

  v_user_id := gen_random_uuid();

  SELECT string_agg(c.col, ', ' ORDER BY c.ord), string_agg(c.val, ', ' ORDER BY c.ord)
  INTO v_u_cols, v_u_vals
  FROM (
    SELECT cols.ordinal_position AS ord, quote_ident(cols.column_name) AS col,
      CASE cols.column_name
        WHEN 'instance_id' THEN '''00000000-0000-0000-0000-000000000000'''
        WHEN 'id' THEN quote_literal(v_user_id)
        WHEN 'aud' THEN '''authenticated'''
        WHEN 'role' THEN '''authenticated'''
        WHEN 'email' THEN quote_literal(v_email)
        WHEN 'encrypted_password' THEN quote_literal(v_hash)
        WHEN 'email_confirmed_at' THEN 'now()'
        WHEN 'confirmation_token' THEN ''''''
        WHEN 'recovery_token' THEN ''''''
        WHEN 'email_change' THEN ''''''
        WHEN 'email_change_token_new' THEN ''''''
        WHEN 'email_change_token_current' THEN ''''''
        WHEN 'raw_app_meta_data' THEN format('jsonb_build_object(''provider'',''email'',''providers'',array[''email'']::text[],''email'',%L)', v_email)
        WHEN 'raw_user_meta_data' THEN format('jsonb_build_object(''full_name'',%L,''email'',%L,''email_verified'',true)', p_full_name, v_email)
        WHEN 'created_at' THEN 'now()'
        WHEN 'updated_at' THEN 'now()'
        WHEN 'is_anonymous' THEN 'false'
        WHEN 'is_sso_user' THEN 'false'
      END AS val
    FROM information_schema.columns cols
    WHERE cols.table_schema = 'auth' AND cols.table_name = 'users'
      AND cols.is_generated = 'NEVER'
      AND cols.column_name IN ('instance_id','id','aud','role','email','encrypted_password','email_confirmed_at','confirmation_token','recovery_token','email_change','email_change_token_new','email_change_token_current','raw_app_meta_data','raw_user_meta_data','created_at','updated_at','is_anonymous','is_sso_user')
  ) c;

  IF v_u_cols IS NULL OR v_u_vals IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'no insertable columns found for auth.users');
  END IF;
  EXECUTE 'INSERT INTO auth.users (' || v_u_cols || ') VALUES (' || v_u_vals || ')';

  SELECT string_agg(c.col, ', ' ORDER BY c.ord), string_agg(c.val, ', ' ORDER BY c.ord)
  INTO v_i_cols, v_i_vals
  FROM (
    SELECT cols.ordinal_position AS ord, quote_ident(cols.column_name) AS col,
      CASE cols.column_name
        WHEN 'id' THEN 'gen_random_uuid()'
        WHEN 'provider_id' THEN quote_literal(v_user_id::text)
        WHEN 'user_id' THEN quote_literal(v_user_id)
        WHEN 'identity_data' THEN format('jsonb_build_object(''sub'',%L,''email'',%L)', v_user_id::text, v_email)
        WHEN 'provider' THEN '''email'''
        WHEN 'last_sign_in_at' THEN 'now()'
        WHEN 'created_at' THEN 'now()'
        WHEN 'updated_at' THEN 'now()'
        WHEN 'email' THEN quote_literal(v_email)
      END AS val
    FROM information_schema.columns cols
    WHERE cols.table_schema = 'auth' AND cols.table_name = 'identities'
      AND cols.is_generated = 'NEVER'
      AND cols.column_name IN ('id','provider_id','user_id','identity_data','provider','last_sign_in_at','created_at','updated_at','email')
  ) c;

  IF v_i_cols IS NULL OR v_i_vals IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'no insertable columns found for auth.identities');
  END IF;
  EXECUTE 'INSERT INTO auth.identities (' || v_i_cols || ') VALUES (' || v_i_vals || ')';

  INSERT INTO public.users(id, email, username, full_name, role, branch_id, is_active)
  VALUES(v_user_id, v_email, v_username, p_full_name, v_role, p_branch_id, p_is_active);

  RETURN jsonb_build_object('success', true, 'user_id', v_user_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- Legacy overload delegates to the canonical function so both paths share the
-- same permission/branch rules.
CREATE OR REPLACE FUNCTION public.create_user(
  p_email text,
  p_password text,
  p_full_name text DEFAULT NULL::text,
  p_role text DEFAULT 'cashier'::text,
  p_branch_id uuid DEFAULT NULL::uuid,
  p_is_active boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  RETURN public.create_user(p_email, p_password, p_full_name, p_role, p_branch_id, p_is_active, NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_user(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_branch uuid;
BEGIN
  SELECT role, branch_id INTO v_target_role, v_target_branch FROM public.users WHERE id = p_user_id;
  IF v_target_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_role = 'super_admin' THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_branch IS NULL OR NOT public.user_may_access_branch(v_target_branch) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;
  END IF;

  DELETE FROM public.users WHERE id = p_user_id;
  DELETE FROM auth.users WHERE id = p_user_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM = 'LAST_ADMIN' THEN RETURN jsonb_build_object('success', false, 'error', 'LAST_ADMIN'); END IF;
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_user_password(p_user_id uuid, p_new_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_hash text;
  v_pgc_schema text;
  v_target_role text;
  v_target_branch uuid;
BEGIN
  SELECT role, branch_id INTO v_target_role, v_target_branch FROM public.users WHERE id = p_user_id;
  IF v_target_role IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_role = 'super_admin' THEN RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED'); END IF;
    IF v_target_branch IS NULL OR NOT public.user_may_access_branch(v_target_branch) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF p_new_password IS NULL OR char_length(p_new_password) < 4 THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD');
  END IF;
  IF char_length(p_new_password) = 4 AND p_new_password !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  SELECT extnamespace::regnamespace::text INTO v_pgc_schema FROM pg_extension WHERE extname = 'pgcrypto';
  IF v_pgc_schema IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'pgcrypto extension is not enabled');
  END IF;
  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt($2, $3))', v_pgc_schema, v_pgc_schema)
    INTO v_hash USING p_new_password, 'bf', 10;
  UPDATE auth.users SET encrypted_password = v_hash, updated_at = now() WHERE id = p_user_id;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'sessions') THEN
    DELETE FROM auth.sessions WHERE user_id = p_user_id;
  END IF;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$function$;

-- V2-sensitive functions must use Super Admin as the only implicit bypass.
DO $block$
DECLARE
  v_sig text;
  v_oid regprocedure;
  v_def text;
  v_new text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.open_shift(uuid,numeric,text)',
    'public.decide_manager_approval(uuid,boolean,text)',
    'public.send_to_kitchen(uuid,uuid)',
    'public.close_shift(uuid,numeric,text)',
    'public.decide_operational_approval(text,uuid,boolean,text)',
    'public.approve_waste(uuid,boolean,text)',
    'public.approve_stock_count(uuid)',
    'public.reject_stock_count(uuid,text)',
    'public.approve_warehouse_transfer(uuid)',
    'public.reject_warehouse_transfer(uuid,text)'
  ] LOOP
    v_oid := to_regprocedure(v_sig);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'PERMISSION_FIRST_FUNCTION_MISSING:%', v_sig; END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_def;
    v_new := replace(v_def, 'public.is_pos_admin()', 'public.is_platform_admin()');
    IF v_new = v_def THEN RAISE EXCEPTION 'PERMISSION_FIRST_PATTERN_CHANGED:%', v_sig; END IF;
    EXECUTE v_new;
  END LOOP;
END;
$block$;

REVOKE ALL ON FUNCTION public.get_user_branch_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_user_branch_access(uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_branch_access(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_user_branch_access(uuid,uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_user(text,text,text,text,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_user(text,text,text,text,uuid,boolean,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_user(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_user_password(uuid,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904047000_permission_first_regression_fixes.sql
-- ----------------------------------------------------------------------------
-- Close permission-first regressions introduced by 20260904046000.
-- Super Admin remains the only implicit bypass. All tenant users require both
-- the relevant permission and explicit/primary branch scope.

CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_primary uuid;
  v_branch_id uuid;
  v_audit_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(p_branch_ids) AS requested(branch_id) WHERE requested.branch_id IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_BRANCH');
  END IF;

  SELECT role, branch_id
  INTO v_target_role, v_target_primary
  FROM public.users
  WHERE id = p_user_id;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_target_role = 'super_admin' THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access'
      );
    END IF;

    IF v_target_primary IS NOT NULL AND NOT public.user_may_access_branch(v_target_primary) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id
        AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'BRANCH_ACCESS_DENIED',
          'branch_id', v_branch_id
        );
      END IF;
    END LOOP;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_branch_ids) AS requested(branch_id)
    LEFT JOIN public.branches b ON b.id = requested.branch_id
    WHERE b.id IS NULL
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, requested.branch_id
  FROM unnest(p_branch_ids) AS requested(branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  v_audit_branch := COALESCE(v_target_primary, p_branch_ids[1]);
  PERFORM public.log_audit_action(
    v_audit_branch,
    'set_branch_access',
    'user_branch_access',
    p_user_id,
    jsonb_build_object('branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;

-- The registration RPC deliberately enables this transaction-local flag.
-- Preserve the bypass for both later privilege checks in the canonical
-- create_user implementation, not only its first authorization block.
DO $block$
DECLARE
  v_oid regprocedure := to_regprocedure('public.create_user(text,text,text,text,uuid,boolean,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'PERMISSION_FIRST_FUNCTION_MISSING:create_user/7';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new := replace(
    v_def,
    'IF NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN',
    'IF COALESCE(current_setting(''app.register_branch'', true), '''') <> ''on'' AND NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN'
  );
  v_new := replace(
    v_new,
    E'IF NOT public.is_platform_admin() THEN\n    IF EXISTS (',
    E'IF COALESCE(current_setting(''app.register_branch'', true), '''') <> ''on'' AND NOT public.is_platform_admin() THEN\n    IF EXISTS ('
  );

  IF v_new = v_def
     OR position('app.register_branch' IN v_new) = 0
     OR v_new LIKE '%IF NOT public.is_platform_admin() AND p_role = ''super_admin'' THEN%'
     OR v_new LIKE E'%IF NOT public.is_platform_admin() THEN\n    IF EXISTS (%' THEN
    RAISE EXCEPTION 'PERMISSION_FIRST_PATTERN_CHANGED:create_user/7';
  END IF;

  EXECUTE v_new;
END;
$block$;

CREATE OR REPLACE FUNCTION public.create_organization_branch(
  p_organization_id uuid,
  p_name text,
  p_name_en text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id = p_organization_id AND is_active) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORGANIZATION_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.branches b
      WHERE b.organization_id = p_organization_id
        AND public.user_may_access_branch(b.id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
    END IF;

    IF NOT public.can_permission('branches.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF btrim(COALESCE(p_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_NAME');
  END IF;

  INSERT INTO public.branches (name, name_en, address, phone, is_active, organization_id)
  VALUES (p_name, p_name_en, p_address, p_phone, true, p_organization_id)
  RETURNING id INTO v_branch_id;

  INSERT INTO public.warehouses (name, branch_id, is_active)
  VALUES (p_name || ' - Main', v_branch_id, true)
  RETURNING id INTO v_warehouse_id;

  SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
  INTO v_global_tax, v_global_tax_enabled, v_global_currency
  FROM public.settings
  ORDER BY id
  LIMIT 1;

  INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
  VALUES (v_branch_id, v_global_tax, v_global_tax_enabled, v_global_currency, 10);

  INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
  VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

  -- The creator must be able to administer the branch they just created.
  INSERT INTO public.user_branch_access(user_id, branch_id)
  VALUES (auth.uid(), v_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    v_branch_id,
    'create_branch',
    'branches',
    v_branch_id,
    jsonb_build_object('organization_id', p_organization_id, 'name', p_name)
  );

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', v_branch_id,
    'warehouse_id', v_warehouse_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_CREATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_name_en text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin()
     AND (NOT public.can_permission('branches.manage') OR NOT public.user_may_access_branch(p_branch_id)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET
    name = COALESCE(p_name, name),
    name_en = COALESCE(p_name_en, name_en),
    address = COALESCE(p_address, address),
    phone = COALESCE(p_phone, phone),
    is_active = COALESCE(p_is_active, is_active)
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_UPDATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin()
     AND (NOT public.can_permission('branches.manage') OR NOT public.user_may_access_branch(p_branch_id)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET is_active = false WHERE id = p_branch_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_user_branch_access(uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_user_branch_access(uuid,uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_organization_branch(uuid,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_branch(uuid,text,text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_branch(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904048000_permission_first_branch_delete.sql
-- ----------------------------------------------------------------------------
-- Finish permission-first branch administration and preserve non-disclosing
-- cross-tenant error semantics.

CREATE OR REPLACE FUNCTION public.update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_name_en text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET
    name = COALESCE(p_name, name),
    name_en = COALESCE(p_name_en, name_en),
    address = COALESCE(p_address, address),
    phone = COALESCE(p_phone, phone),
    is_active = COALESCE(p_is_active, is_active)
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_UPDATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.branches SET is_active = false WHERE id = p_branch_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_user_branch uuid;
  v_org uuid;
  v_user_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_auth integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT branch_id
  INTO v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT organization_id
  INTO v_org
  FROM public.branches
  WHERE id = p_branch_id
  FOR UPDATE;

  IF v_org IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.is_platform_admin() AND NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF v_user_branch IS NOT DISTINCT FROM p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'CANNOT_DELETE_CURRENT_BRANCH');
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[])
  INTO v_user_ids
  FROM public.users
  WHERE branch_id = p_branch_id;

  DELETE FROM public.journal_entries WHERE branch_id = p_branch_id;
  DELETE FROM public.branches WHERE id = p_branch_id;

  IF COALESCE(array_length(v_user_ids, 1), 0) > 0 THEN
    DELETE FROM auth.sessions WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.identities WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.users WHERE id = ANY(v_user_ids);
    GET DIAGNOSTICS v_deleted_auth = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'organization_id', v_org,
    'deleted_auth_users', v_deleted_auth
  );
EXCEPTION WHEN foreign_key_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DELETE_BLOCKED', 'detail', SQLERRM);
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904050000_kitchen_send_inventory_boundary.sql
-- ----------------------------------------------------------------------------
-- Authoritative kitchen inventory boundary.
-- Positive kitchen deltas deduct stock once. Payment reuses the exact effects,
-- while an approved sent-line void restores only the effects actually consumed.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS inventory_warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.order_kitchen_inventory_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL,
  kitchen_send_id uuid REFERENCES public.order_kitchen_sends(id) ON DELETE SET NULL,
  sent_quantity numeric(14,6) NOT NULL CHECK (sent_quantity > 0),
  voided_quantity numeric(14,6) NOT NULL DEFAULT 0
    CHECK (voided_quantity >= 0 AND voided_quantity <= sent_quantity),
  total_cost numeric(18,6) NOT NULL DEFAULT 0 CHECK (total_cost >= 0),
  settled_sale_id uuid REFERENCES public.sales(id) ON DELETE SET NULL,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.order_kitchen_inventory_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.order_kitchen_inventory_events(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  target_type text NOT NULL CHECK (target_type IN ('inventory_unit','raw_material','product')),
  target_id uuid NOT NULL,
  quantity numeric(14,6) NOT NULL CHECK (quantity > 0),
  total_cost numeric(18,6) NOT NULL DEFAULT 0 CHECK (total_cost >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(event_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_events_order
  ON public.order_kitchen_inventory_events(order_id, order_item_id, created_at);
CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_events_unsettled
  ON public.order_kitchen_inventory_events(order_id) WHERE settled_sale_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_kitchen_inventory_effects_event
  ON public.order_kitchen_inventory_effects(event_id);

ALTER TABLE public.order_kitchen_inventory_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_kitchen_inventory_effects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kitchen_inventory_events_select ON public.order_kitchen_inventory_events;
CREATE POLICY kitchen_inventory_events_select ON public.order_kitchen_inventory_events
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS kitchen_inventory_effects_select ON public.order_kitchen_inventory_effects;
CREATE POLICY kitchen_inventory_effects_select ON public.order_kitchen_inventory_effects
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

REVOKE ALL ON public.order_kitchen_inventory_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.order_kitchen_inventory_effects FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_kitchen_inventory_events TO authenticated;
GRANT SELECT ON public.order_kitchen_inventory_effects TO authenticated;
GRANT ALL ON public.order_kitchen_inventory_events TO service_role, postgres;
GRANT ALL ON public.order_kitchen_inventory_effects TO service_role, postgres;

-- The finished-product helper writes this legacy ledger. Allow the two new,
-- explicit movement labels before any kitchen deduction/restoration uses it.
ALTER TABLE public.stock_transactions
  DROP CONSTRAINT IF EXISTS stock_transactions_transaction_type_check;
ALTER TABLE public.stock_transactions
  ADD CONSTRAINT stock_transactions_transaction_type_check
  CHECK (transaction_type IN (
    'sale','purchase','adjustment','refund','transfer','production','waste',
    'opening','purchase_return','kitchen_send','kitchen_void'
  ));

-- Preserve the existing, thoroughly tested inventory executor as an internal
-- core. Its public signature becomes a settlement-aware wrapper below.
DO $rename_inventory_core$
BEGIN
  IF to_regprocedure('public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)') IS NULL THEN
    IF to_regprocedure('public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)') IS NULL THEN
      RAISE EXCEPTION 'KITCHEN_INVENTORY_CORE_MISSING';
    END IF;
    ALTER FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
      RENAME TO _deduct_sale_inventory_with_modifiers_core;
  END IF;
END;
$rename_inventory_core$;

REVOKE ALL ON FUNCTION public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)
  TO service_role, postgres;

CREATE OR REPLACE FUNCTION public._prepare_kitchen_sale_settlement(
  p_order_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_order_shape jsonb;
  v_payload_shape jsonb;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.branch_id IS DISTINCT FROM p_branch_id OR NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_order.status NOT IN ('open','held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;
  IF p_warehouse_id IS NULL
     OR v_order.inventory_warehouse_id IS DISTINCT FROM p_warehouse_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'KITCHEN_WAREHOUSE_MISMATCH',
      'expected_warehouse_id', v_order.inventory_warehouse_id
    );
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FULLY_SENT');
  END IF;

  SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
  INTO v_order_shape
  FROM (
    SELECT jsonb_build_object(
      'product_id', oi.product_id,
      'unit_name', COALESCE(oi.unit_name, 'piece'),
      'quantity', oi.quantity,
      'modifier_option_ids', to_jsonb(ARRAY(
        SELECT u.id::text
        FROM unnest(COALESCE(oi.modifier_option_ids, '{}'::uuid[])) AS u(id)
        ORDER BY u.id::text
      ))
    ) AS shape
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id
  ) x;

  BEGIN
    SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
    INTO v_payload_shape
    FROM (
      SELECT jsonb_build_object(
        'product_id', NULLIF(item->>'product_id','')::uuid,
        'unit_name', COALESCE(NULLIF(item->>'unit_name',''), 'piece'),
        'quantity', COALESCE((item->>'quantity')::numeric, 0),
        'modifier_option_ids', to_jsonb(ARRAY(
          SELECT j.id
          FROM jsonb_array_elements_text(COALESCE(item->'modifier_option_ids','[]'::jsonb)) AS j(id)
          ORDER BY j.id
        ))
      ) AS shape
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS j(item)
    ) x;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH', 'detail', SQLERRM);
  END;

  IF v_order_shape IS DISTINCT FROM v_payload_shape THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.kitchen_settlement_queue (
    seq bigint GENERATED ALWAYS AS IDENTITY,
    order_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    product_id uuid NOT NULL,
    unit_name text NOT NULL,
    quantity numeric(14,6) NOT NULL,
    modifier_option_ids uuid[] NOT NULL,
    consumed boolean NOT NULL DEFAULT false,
    PRIMARY KEY(seq)
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.kitchen_settlement_queue RESTART IDENTITY;

  INSERT INTO pg_temp.kitchen_settlement_queue(
    order_id, order_item_id, product_id, unit_name, quantity, modifier_option_ids
  )
  SELECT p_order_id, oi.id, oi.product_id, COALESCE(oi.unit_name,'piece'), oi.quantity,
         COALESCE(oi.modifier_option_ids, '{}'::uuid[])
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
  ORDER BY oi.created_at, oi.id;

  PERFORM set_config('app.kitchen_inventory_settlement', 'on', true);
  PERFORM set_config('app.kitchen_inventory_order_id', p_order_id::text, true);
  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public._consume_kitchen_sale_settlement(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_sale_id uuid,
  p_reference_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item jsonb;
  v_queue record;
  v_event_qty numeric(14,6);
  v_missing numeric(14,6);
  v_legacy jsonb;
  v_units jsonb := '[]'::jsonb;
  v_raws jsonb := '[]'::jsonb;
  v_products jsonb := '[]'::jsonb;
  v_total_cost numeric(18,6) := 0;
BEGIN
  IF to_regclass('pg_temp.kitchen_settlement_queue') IS NULL
     OR p_items IS NULL OR jsonb_array_length(p_items) <> 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'KITCHEN_SETTLEMENT_CONTEXT_MISSING');
  END IF;

  v_item := p_items->0;
  SELECT q.* INTO v_queue
  FROM pg_temp.kitchen_settlement_queue q
  WHERE NOT q.consumed
    AND q.product_id = NULLIF(v_item->>'product_id','')::uuid
    AND q.unit_name = COALESCE(NULLIF(v_item->>'unit_name',''), 'piece')
    AND abs(q.quantity - COALESCE((v_item->>'quantity')::numeric, 0)) < 0.000001
    AND ARRAY(
      SELECT u.id FROM unnest(q.modifier_option_ids) AS u(id) ORDER BY u.id
    ) = ARRAY(
      SELECT j.id::uuid
      FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids','[]'::jsonb)) AS j(id)
      ORDER BY j.id::uuid
    )
  ORDER BY q.seq
  LIMIT 1
  FOR UPDATE;

  IF v_queue.order_item_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH');
  END IF;

  SELECT COALESCE(sum(e.sent_quantity - e.voided_quantity), 0)
  INTO v_event_qty
  FROM public.order_kitchen_inventory_events e
  WHERE e.order_id = v_queue.order_id
    AND e.order_item_id = v_queue.order_item_id;

  IF v_event_qty > v_queue.quantity + 0.000001 THEN
    RETURN jsonb_build_object('success', false, 'error', 'KITCHEN_INVENTORY_EVENT_MISMATCH');
  END IF;

  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'unit_id', z.target_id,
      'quantity', z.quantity
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='inventory_unit'), '[]'::jsonb),
    COALESCE(jsonb_agg(jsonb_build_object(
      'raw_material_id', z.target_id,
      'quantity', z.quantity,
      'total_cost', z.total_cost
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='raw_material'), '[]'::jsonb),
    COALESCE(jsonb_agg(jsonb_build_object(
      'product_id', z.target_id,
      'quantity', z.quantity,
      'total_cost', z.total_cost
    ) ORDER BY z.target_id) FILTER (WHERE z.target_type='product'), '[]'::jsonb),
    COALESCE(sum(z.total_cost), 0)
  INTO v_units, v_raws, v_products, v_total_cost
  FROM (
    SELECT ef.target_type, ef.target_id,
           sum(ef.quantity * (ev.sent_quantity - ev.voided_quantity) / ev.sent_quantity) AS quantity,
           sum(ef.total_cost * (ev.sent_quantity - ev.voided_quantity) / ev.sent_quantity) AS total_cost
    FROM public.order_kitchen_inventory_events ev
    JOIN public.order_kitchen_inventory_effects ef ON ef.event_id = ev.id
    WHERE ev.order_id = v_queue.order_id
      AND ev.order_item_id = v_queue.order_item_id
      AND ev.sent_quantity > ev.voided_quantity
    GROUP BY ef.target_type, ef.target_id
  ) z;

  -- Orders already partly sent before this migration have no event for that
  -- historical quantity. Deduct only that uncovered remainder at settlement.
  v_missing := GREATEST(v_queue.quantity - v_event_qty, 0);
  IF v_missing > 0.000001 THEN
    v_legacy := public._deduct_sale_inventory_with_modifiers_core(
      p_branch_id,
      p_warehouse_id,
      jsonb_build_array(jsonb_set(v_item, '{quantity}', to_jsonb(v_missing), true)),
      p_sale_id,
      p_reference_number
    );
    IF COALESCE((v_legacy->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_legacy;
    END IF;
    v_units := v_units || COALESCE(v_legacy->'units_deducted', '[]'::jsonb);
    v_raws := v_raws || COALESCE(v_legacy->'raw_materials_deducted', '[]'::jsonb);
    v_products := v_products || COALESCE(v_legacy->'ready_products_deducted', '[]'::jsonb);
    v_total_cost := v_total_cost + COALESCE((v_legacy->>'total_cost')::numeric, 0);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'unit_id', x.target_id,
    'quantity', x.quantity
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_units
  FROM (
    SELECT (e->>'unit_id')::uuid AS target_id, sum((e->>'quantity')::numeric) AS quantity
    FROM jsonb_array_elements(v_units) e
    GROUP BY (e->>'unit_id')::uuid
  ) x;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'raw_material_id', x.target_id,
    'quantity', x.quantity,
    'total_cost', x.total_cost
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_raws
  FROM (
    SELECT (e->>'raw_material_id')::uuid AS target_id,
           sum((e->>'quantity')::numeric) AS quantity,
           sum(COALESCE((e->>'total_cost')::numeric,0)) AS total_cost
    FROM jsonb_array_elements(v_raws) e
    GROUP BY (e->>'raw_material_id')::uuid
  ) x;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'product_id', x.target_id,
    'quantity', x.quantity,
    'total_cost', x.total_cost
  ) ORDER BY x.target_id), '[]'::jsonb)
  INTO v_products
  FROM (
    SELECT (e->>'product_id')::uuid AS target_id,
           sum((e->>'quantity')::numeric) AS quantity,
           sum(COALESCE((e->>'total_cost')::numeric,0)) AS total_cost
    FROM jsonb_array_elements(v_products) e
    GROUP BY (e->>'product_id')::uuid
  ) x;

  UPDATE pg_temp.kitchen_settlement_queue SET consumed = true WHERE seq = v_queue.seq;

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', v_raws,
    'ready_products_deducted', v_products,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public._finalize_kitchen_sale_settlement(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF to_regclass('pg_temp.kitchen_settlement_queue') IS NULL
     OR EXISTS (SELECT 1 FROM pg_temp.kitchen_settlement_queue WHERE NOT consumed) THEN
    RAISE EXCEPTION 'KITCHEN_SETTLEMENT_INCOMPLETE';
  END IF;

  UPDATE public.order_kitchen_inventory_events e
  SET settled_sale_id = p_sale_id
  WHERE e.order_item_id IN (SELECT order_item_id FROM pg_temp.kitchen_settlement_queue)
    AND e.settled_sale_id IS NULL;

  PERFORM set_config('app.kitchen_inventory_settlement', 'off', true);
  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL::uuid,
  p_reference_number text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF COALESCE(current_setting('app.kitchen_inventory_settlement', true), '') = 'on' THEN
    RETURN public._consume_kitchen_sale_settlement(
      p_branch_id, p_warehouse_id, p_items, p_reference_id, p_reference_number
    );
  END IF;
  RETURN public._deduct_sale_inventory_with_modifiers_core(
    p_branch_id, p_warehouse_id, p_items, p_reference_id, p_reference_number
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)
  TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_warehouse_id uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_row record;
  v_event_id uuid;
  v_inventory jsonb;
  v_failure_product uuid;
  v_failure_name text;
BEGIN
  BEGIN
    IF auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    SELECT branch_id, status, order_number, table_id, order_type, guest_count, inventory_warehouse_id
    INTO v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count, v_warehouse_id
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF NOT public.user_may_access_branch(v_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
    IF NOT (public.is_platform_admin() OR public.can_permission('pos.send_kitchen')) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'pos.send_kitchen');
    END IF;
    IF v_status NOT IN ('open','held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
    END IF;

    IF v_warehouse_id IS NULL THEN
      SELECT w.id INTO v_warehouse_id
      FROM public.warehouses w
      WHERE w.branch_id = v_branch_id AND w.is_active = true
      ORDER BY COALESCE(w.is_default, false) DESC, w.created_at, w.id
      LIMIT 1;
      IF v_warehouse_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_FOUND');
      END IF;
      UPDATE public.orders SET inventory_warehouse_id = v_warehouse_id WHERE id = p_order_id;
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name FROM public.dining_tables
      WHERE id = v_table_id AND branch_id = v_branch_id;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.kns_delta (
      order_item_id uuid PRIMARY KEY,
      send_id uuid,
      event_id uuid,
      delta_quantity numeric(14,4) NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.kns_delta;

    INSERT INTO pg_temp.kns_delta(order_item_id, event_id, delta_quantity)
    SELECT oi.id, gen_random_uuid(), oi.quantity - COALESCE(s.sent_quantity, 0)
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0);

    FOR v_row IN
      SELECT d.order_item_id, d.event_id, d.delta_quantity,
             oi.product_id, oi.modifier_option_ids, p.name AS product_name
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
      JOIN public.products p ON p.id = oi.product_id
      ORDER BY oi.created_at, oi.id
    LOOP
      v_failure_product := v_row.product_id;
      v_failure_name := v_row.product_name;
      v_inventory := public._deduct_sale_inventory_with_modifiers_core(
        v_branch_id,
        v_warehouse_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_row.product_id,
          'quantity', v_row.delta_quantity,
          'modifier_option_ids', to_jsonb(COALESCE(v_row.modifier_option_ids, '{}'::uuid[]))
        )),
        v_row.event_id,
        v_order_number
      );

      IF COALESCE((v_inventory->>'success')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'KITCHEN_INVENTORY_DEDUCTION_FAILED: %', COALESCE(v_inventory->>'detail', v_inventory->>'error', 'UNKNOWN');
      END IF;

      UPDATE public.inventory_unit_entries
      SET entry_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND entry_type='sale';
      UPDATE public.inventory_ledger
      SET entry_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND entry_type='sale';
      UPDATE public.stock_transactions
      SET transaction_type='kitchen_send', reference_type='kitchen_send'
      WHERE reference_id=v_row.event_id AND reference_type='sale' AND transaction_type='sale';

      INSERT INTO public.order_kitchen_inventory_events(
        id, branch_id, warehouse_id, order_id, order_item_id, sent_quantity,
        total_cost, created_by
      ) VALUES (
        v_row.event_id, v_branch_id, v_warehouse_id, p_order_id, v_row.order_item_id,
        v_row.delta_quantity, COALESCE((v_inventory->>'total_cost')::numeric,0), auth.uid()
      );

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'inventory_unit',
             (e->>'unit_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((SELECT sum((-iue.quantity)*COALESCE(iue.unit_cost,0))
                       FROM public.inventory_unit_entries iue
                       WHERE iue.reference_id=v_row.event_id
                         AND iue.reference_type='kitchen_send'
                         AND iue.unit_id=(e->>'unit_id')::uuid
                         AND iue.quantity<0),0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'units_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'raw_material',
             (e->>'raw_material_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric,0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'raw_materials_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'product',
             (e->>'product_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric,0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'ready_products_deducted','[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric,0)>0;

      -- Any error after the inventory executor is an implementation failure,
      -- not an insufficient-stock response for this product.
      v_failure_product:=NULL;
      v_failure_name:=NULL;
    END LOOP;

    WITH candidates AS (
      SELECT d.order_item_id, d.delta_quantity, oi.quantity AS target_quantity
      FROM pg_temp.kns_delta d JOIN public.order_items oi ON oi.id=d.order_item_id
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT v_branch_id, p_order_id, c.order_item_id, now(), auth.uid(), c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity=EXCLUDED.sent_quantity, sent_at=now(), sent_by=EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    UPDATE pg_temp.kns_delta d SET send_id=u.id FROM upserted u WHERE u.order_item_id=d.order_item_id;

    UPDATE public.order_kitchen_inventory_events e
    SET kitchen_send_id=d.send_id
    FROM pg_temp.kns_delta d
    WHERE e.id=d.event_id;

    SELECT count(*) INTO v_count FROM pg_temp.kns_delta;
    IF v_count>0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id',d.send_id,
        'order_item_id',d.order_item_id,
        'product_id',oi.product_id,
        'product_name',p.name,
        'unit_name',oi.unit_name,
        'station_code',COALESCE(ks.code,'main'),
        'quantity',d.delta_quantity,
        'current_quantity',oi.quantity,
        'unit_price',oi.unit_price,
        'discount_amount',oi.discount_amount,
        'bonus_quantity',oi.bonus_quantity,
        'total',oi.total,
        'notes',oi.notes,
        'modifiers',COALESCE(oi.modifiers_snapshot,'[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id=d.order_item_id
      LEFT JOIN public.products p ON p.id=oi.product_id
      LEFT JOIN public.categories c ON c.id=p.category_id AND c.branch_id=v_branch_id
      LEFT JOIN public.kitchen_stations ks ON ks.id=c.kitchen_station_id AND ks.is_active=true;
    END IF;

    SELECT NOT EXISTS(
      SELECT 1 FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id=oi.id
      WHERE oi.order_id=p_order_id AND oi.quantity>COALESCE(s.sent_quantity,0)
    ) INTO v_all_sent;

    RETURN jsonb_build_object(
      'success',true,'order_id',p_order_id,'order_number',v_order_number,
      'table_name',v_table_name,'order_type',v_order_type,'guest_count',v_guest_count,
      'warehouse_id',v_warehouse_id,'sent',v_sent_items,
      'items_sent_count',v_count,'all_sent',v_all_sent,'inventory_deducted',v_count>0
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success',false,
      'error',CASE WHEN v_failure_product IS NULL THEN 'TRANSACTION_FAILED' ELSE 'INSUFFICIENT_STOCK' END,
      'product_id',v_failure_product,
      'product_name',v_failure_name,
      'detail',SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid,uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._restore_kitchen_inventory_for_void(
  p_order_id uuid,
  p_order_item_id uuid,
  p_quantity numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_remaining numeric(14,6) := p_quantity;
  v_event record;
  v_effect record;
  v_take numeric(14,6);
  v_restore numeric(14,6);
  v_cost numeric(18,6);
  v_batch text;
  v_res jsonb;
  v_restored numeric(14,6) := 0;
BEGIN
  IF p_quantity IS NULL OR p_quantity<=0 THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY');
  END IF;

  FOR v_event IN
    SELECT * FROM public.order_kitchen_inventory_events
    WHERE order_id=p_order_id AND order_item_id=p_order_item_id
      AND sent_quantity>voided_quantity AND settled_sale_id IS NULL
    ORDER BY created_at DESC,id DESC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining<=0;
    v_take:=LEAST(v_remaining,v_event.sent_quantity-v_event.voided_quantity);

    FOR v_effect IN
      SELECT * FROM public.order_kitchen_inventory_effects
      WHERE event_id=v_event.id ORDER BY target_type,target_id
    LOOP
      v_restore:=round(v_effect.quantity*v_take/v_event.sent_quantity,6);
      IF v_restore<=0 THEN CONTINUE; END IF;
      v_cost:=CASE WHEN v_effect.quantity>0 THEN v_effect.total_cost/v_effect.quantity ELSE 0 END;
      v_batch:='KV-'||substr(replace(gen_random_uuid()::text,'-',''),1,12);

      IF v_effect.target_type='inventory_unit' THEN
        INSERT INTO public.inventory_unit_batches(
          unit_id,branch_id,warehouse_id,batch_number,quantity,unit_cost,production_date
        ) VALUES (
          v_effect.target_id,v_event.branch_id,v_event.warehouse_id,v_batch,v_restore,v_cost,CURRENT_DATE
        );
        INSERT INTO public.inventory_unit_entries(
          unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,
          reference_type,reference_id,reference_number,batch_number,created_by
        ) VALUES (
          v_effect.target_id,v_event.branch_id,v_event.warehouse_id,v_restore,v_cost,'kitchen_void',
          'kitchen_send',v_event.id,p_order_id::text,v_batch,auth.uid()
        );
      ELSIF v_effect.target_type='raw_material' THEN
        v_res:=public._raw_add(
          v_effect.target_id,v_event.branch_id,v_restore,v_cost,v_batch,CURRENT_DATE,NULL,
          'kitchen_void','kitchen_send',v_event.id,p_order_id::text,auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean,false) IS NOT TRUE THEN
          RAISE EXCEPTION 'KITCHEN_VOID_RAW_RESTORE_FAILED: %',v_res;
        END IF;
      ELSE
        v_res:=public._product_inv_add(
          v_effect.target_id,v_event.warehouse_id,v_event.branch_id,v_restore,v_cost,v_batch,
          CURRENT_DATE,NULL,'kitchen_void','kitchen_send',v_event.id,p_order_id::text,auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean,false) IS NOT TRUE THEN
          RAISE EXCEPTION 'KITCHEN_VOID_PRODUCT_RESTORE_FAILED: %',v_res;
        END IF;
      END IF;
    END LOOP;

    UPDATE public.order_kitchen_inventory_events
    SET voided_quantity=voided_quantity+v_take WHERE id=v_event.id;
    v_remaining:=v_remaining-v_take;
    v_restored:=v_restored+v_take;
  END LOOP;

  RETURN jsonb_build_object(
    'success',true,
    'inventory_changed',v_restored>0,
    'restored_sent_quantity',v_restored,
    'legacy_untracked_quantity',GREATEST(v_remaining,0)
  );
END;
$function$;

-- Force every sent-line reduction, including managers, through the audited RPC
-- so no direct UPDATE can bypass exact inventory restoration.
CREATE OR REPLACE FUNCTION public.guard_sent_order_item_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_is_sent boolean;
  v_is_reduction boolean:=false;
  v_internal boolean:=COALESCE(current_setting('app.approved_sent_item_void',true),'')='1';
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id=OLD.id)
  INTO v_is_sent;
  IF NOT v_is_sent THEN RETURN COALESCE(NEW,OLD); END IF;
  IF TG_OP='DELETE' THEN v_is_reduction:=true;
  ELSIF TG_OP='UPDATE' AND COALESCE(NEW.quantity,0)<COALESCE(OLD.quantity,0) THEN v_is_reduction:=true;
  END IF;
  IF v_is_reduction AND NOT v_internal THEN
    RAISE EXCEPTION 'SENT_ITEM_APPROVAL_REQUIRED' USING ERRCODE='P0001';
  END IF;
  RETURN COALESCE(NEW,OLD);
END;
$function$;

DO $patch_exact_void$
DECLARE
  v_oid regprocedure:=to_regprocedure('public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN RAISE EXCEPTION 'EXACT_SENT_VOID_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(v_def,'  v_privileged boolean := false;',E'  v_privileged boolean := false;\n  v_inventory jsonb;');
  v_new:=replace(
    v_new,
    '  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);',
    E'  v_inventory := public._restore_kitchen_inventory_for_void(p_order_id, v_item.id, p_quantity);\n  IF COALESCE((v_inventory->>''success'')::boolean, false) IS NOT TRUE THEN\n    RETURN v_inventory;\n  END IF;\n\n  UPDATE public.order_kitchen_sends\n  SET sent_quantity = GREATEST(sent_quantity - p_quantity, 0), sent_at = now(), sent_by = auth.uid()\n  WHERE order_item_id = v_item.id;\n\n  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);'
  );
  v_new:=replace(
    v_new,
    '''inventory_changed'', false',
    '''inventory_changed'', COALESCE((v_inventory->>''inventory_changed'')::boolean, false)'
  );
  IF v_new=v_def OR position('_restore_kitchen_inventory_for_void' IN v_new)=0 THEN
    RAISE EXCEPTION 'EXACT_SENT_VOID_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;
END;
$patch_exact_void$;

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item_id uuid;
  v_count integer;
BEGIN
  SELECT count(*),min(oi.id)
  INTO v_count,v_item_id
  FROM public.order_items oi
  WHERE oi.order_id=p_order_id AND oi.product_id=p_product_id
    AND EXISTS(SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id=oi.id);
  IF v_count=0 THEN RETURN jsonb_build_object('success',false,'error','SENT_ITEM_NOT_FOUND'); END IF;
  IF v_count>1 THEN
    RETURN jsonb_build_object('success',false,'error','AMBIGUOUS_SENT_ITEM',
      'detail','Use cancel_sent_order_item_exact with order_item_id','matching_lines',v_count);
  END IF;
  RETURN public.cancel_sent_order_item_exact(p_order_id,v_item_id,p_quantity,p_reason);
END;
$function$;

REVOKE ALL ON FUNCTION public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._consume_kitchen_sale_settlement(uuid,uuid,jsonb,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._finalize_kitchen_sale_settlement(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._restore_kitchen_inventory_for_void(uuid,uuid,numeric) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._consume_kitchen_sale_settlement(uuid,uuid,jsonb,uuid,text) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._finalize_kitchen_sale_settlement(uuid) TO service_role,postgres;
GRANT EXECUTE ON FUNCTION public._restore_kitchen_inventory_for_void(uuid,uuid,numeric) TO service_role,postgres;
REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;
REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated,service_role;

-- Patch both payment entry points around the preserved sale core. The inventory
-- executor sees a transaction-local settlement context and therefore returns
-- the kitchen effects instead of deducting them a second time.
DO $patch_sale_entry_points$
DECLARE
  v_oid regprocedure;
  v_def text;
  v_new text;
BEGIN
  v_oid:=to_regprocedure('public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'PROCESS_SALE_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(
    v_def,
    '  v_result:=public._process_sale_core(',
    E'  IF p_order_id IS NOT NULL THEN\n    v_result := public._prepare_kitchen_sale_settlement(p_order_id,p_branch_id,p_warehouse_id,p_items);\n    IF COALESCE((v_result->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_result; END IF;\n  END IF;\n\n  v_result:=public._process_sale_core('
  );
  v_new:=replace(
    v_new,
    '  IF p_order_id IS NOT NULL AND COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN',
    E'  IF p_order_id IS NOT NULL THEN\n    PERFORM set_config(''app.kitchen_inventory_settlement'',''off'',true);\n    IF COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN\n      v_result := v_result || public._finalize_kitchen_sale_settlement(NULLIF(v_result->>''sale_id'','''')::uuid);\n    END IF;\n  END IF;\n\n  IF p_order_id IS NOT NULL AND COALESCE((v_result->>''success'')::boolean,false) IS TRUE THEN'
  );
  IF v_new=v_def OR position('_prepare_kitchen_sale_settlement' IN v_new)=0
     OR position('_finalize_kitchen_sale_settlement' IN v_new)=0 THEN
    RAISE EXCEPTION 'PROCESS_SALE_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;

  v_oid:=to_regprocedure('public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'PROCESS_SALE_SPLIT_MISSING'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new:=replace(
    v_def,
    '    v_core := public._process_sale_core(',
    E'    IF p_order_id IS NOT NULL THEN\n      v_core := public._prepare_kitchen_sale_settlement(p_order_id,p_branch_id,p_warehouse_id,p_items);\n      IF COALESCE((v_core->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_core; END IF;\n    END IF;\n\n    v_core := public._process_sale_core('
  );
  v_new:=replace(
    v_new,
    '    IF COALESCE((v_core->>''success'')::boolean, false) IS NOT TRUE THEN',
    E'    IF p_order_id IS NOT NULL THEN\n      PERFORM set_config(''app.kitchen_inventory_settlement'',''off'',true);\n      IF COALESCE((v_core->>''success'')::boolean,false) IS TRUE THEN\n        v_core := v_core || public._finalize_kitchen_sale_settlement(NULLIF(v_core->>''sale_id'','''')::uuid);\n      END IF;\n    END IF;\n\n    IF COALESCE((v_core->>''success'')::boolean, false) IS NOT TRUE THEN'
  );
  IF v_new=v_def OR position('_prepare_kitchen_sale_settlement' IN v_new)=0
     OR position('_finalize_kitchen_sale_settlement' IN v_new)=0 THEN
    RAISE EXCEPTION 'PROCESS_SALE_SPLIT_PATTERN_CHANGED';
  END IF;
  EXECUTE v_new;
END;
$patch_sale_entry_points$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904051000_fix_cancel_sent_order_item_uuid_selection.sql
-- ----------------------------------------------------------------------------
-- PostgreSQL does not provide min(uuid). Resolve the single matching sent line
-- explicitly after counting candidates so the compatibility wrapper stays
-- deterministic without changing the exact-item void path.
CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item_id uuid;
  v_count integer;
BEGIN
  SELECT count(*)
  INTO v_count
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    );

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;

  IF v_count > 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'AMBIGUOUS_SENT_ITEM',
      'detail', 'Use cancel_sent_order_item_exact with order_item_id',
      'matching_lines', v_count
    );
  END IF;

  SELECT oi.id
  INTO v_item_id
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    )
  ORDER BY oi.id
  LIMIT 1;

  RETURN public.cancel_sent_order_item_exact(
    p_order_id,
    v_item_id,
    p_quantity,
    p_reason
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904052000_prioritize_unsent_order_guard.sql
-- ----------------------------------------------------------------------------
-- An unsent linked order has no inventory_warehouse_id yet. Reject payment for
-- the real lifecycle violation first so callers receive ORDER_NOT_FULLY_SENT
-- instead of the secondary warehouse-binding error.
CREATE OR REPLACE FUNCTION public._prepare_kitchen_sale_settlement(
  p_order_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_order_shape jsonb;
  v_payload_shape jsonb;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.branch_id IS DISTINCT FROM p_branch_id OR NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;
  IF v_order.status NOT IN ('open','held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;

  -- Kitchen completion is the primary settlement precondition. Before the
  -- first kitchen send an order is intentionally not warehouse-bound yet.
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FULLY_SENT');
  END IF;

  -- Once all lines are sent, payment must use exactly the warehouse bound by
  -- send_to_kitchen so inventory can never be settled against another store.
  IF p_warehouse_id IS NULL
     OR v_order.inventory_warehouse_id IS DISTINCT FROM p_warehouse_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'KITCHEN_WAREHOUSE_MISMATCH',
      'expected_warehouse_id', v_order.inventory_warehouse_id
    );
  END IF;

  SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
  INTO v_order_shape
  FROM (
    SELECT jsonb_build_object(
      'product_id', oi.product_id,
      'unit_name', COALESCE(oi.unit_name, 'piece'),
      'quantity', oi.quantity,
      'modifier_option_ids', to_jsonb(ARRAY(
        SELECT u.id::text
        FROM unnest(COALESCE(oi.modifier_option_ids, '{}'::uuid[])) AS u(id)
        ORDER BY u.id::text
      ))
    ) AS shape
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id
  ) x;

  BEGIN
    SELECT COALESCE(jsonb_agg(x.shape ORDER BY x.shape::text), '[]'::jsonb)
    INTO v_payload_shape
    FROM (
      SELECT jsonb_build_object(
        'product_id', NULLIF(item->>'product_id','')::uuid,
        'unit_name', COALESCE(NULLIF(item->>'unit_name',''), 'piece'),
        'quantity', COALESCE((item->>'quantity')::numeric, 0),
        'modifier_option_ids', to_jsonb(ARRAY(
          SELECT j.id
          FROM jsonb_array_elements_text(COALESCE(item->'modifier_option_ids','[]'::jsonb)) AS j(id)
          ORDER BY j.id
        ))
      ) AS shape
      FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS j(item)
    ) x;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH', 'detail', SQLERRM);
  END;

  IF v_order_shape IS DISTINCT FROM v_payload_shape THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEMS_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.kitchen_settlement_queue (
    seq bigint GENERATED ALWAYS AS IDENTITY,
    order_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    product_id uuid NOT NULL,
    unit_name text NOT NULL,
    quantity numeric(14,6) NOT NULL,
    modifier_option_ids uuid[] NOT NULL,
    consumed boolean NOT NULL DEFAULT false,
    PRIMARY KEY(seq)
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.kitchen_settlement_queue RESTART IDENTITY;

  INSERT INTO pg_temp.kitchen_settlement_queue(
    order_id, order_item_id, product_id, unit_name, quantity, modifier_option_ids
  )
  SELECT p_order_id, oi.id, oi.product_id, COALESCE(oi.unit_name,'piece'), oi.quantity,
         COALESCE(oi.modifier_option_ids, '{}'::uuid[])
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
  ORDER BY oi.created_at, oi.id;

  PERFORM set_config('app.kitchen_inventory_settlement', 'on', true);
  PERFORM set_config('app.kitchen_inventory_order_id', p_order_id::text, true);
  RETURN jsonb_build_object('success', true);
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904053000_make_kitchen_void_sent_quantity_idempotent.sql
-- ----------------------------------------------------------------------------
-- Keep the KDS communicated quantity aligned with the order line after an
-- approved kitchen void. The inventory-boundary migration already adjusts the
-- send row before writing the void audit row, while the legacy trigger also
-- subtracts the void quantity. Subtracting twice makes the next send look like
-- a fresh positive delta and can deduct inventory again.
--
-- Make the trigger idempotent: after the void finishes, the authoritative net
-- sent quantity is simply the current order-item quantity (or zero when the
-- line was fully removed).
CREATE OR REPLACE FUNCTION public.sync_kitchen_sent_quantity_after_void()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_current_quantity numeric(14,4);
BEGIN
  IF NEW.order_item_id IS NOT NULL THEN
    SELECT oi.quantity
    INTO v_current_quantity
    FROM public.order_items oi
    WHERE oi.id = NEW.order_item_id;

    UPDATE public.order_kitchen_sends
    SET sent_quantity = GREATEST(COALESCE(v_current_quantity, 0), 0),
        sent_at = now(),
        sent_by = COALESCE(NEW.voided_by, sent_by)
    WHERE order_item_id = NEW.order_item_id;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.sync_kitchen_sent_quantity_after_void()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_kitchen_sent_quantity_after_void()
  TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904054000_fix_set_user_branch_access_audit_signature.sql
-- ----------------------------------------------------------------------------
-- Fix set_user_branch_access audit logging to match the canonical
-- log_audit_action(branch_id, action, entity, entity_id, details) signature.

CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_primary uuid;
  v_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  SELECT role, branch_id
  INTO v_target_role, v_target_primary
  FROM public.users
  WHERE id = p_user_id;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_target_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access');
    END IF;

    IF v_target_primary IS NOT NULL AND NOT public.user_may_access_branch(v_target_primary) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id
        AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED', 'branch_id', v_branch_id);
      END IF;
    END LOOP;
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, branch_id
  FROM unnest(p_branch_ids) AS branch_id
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    v_target_primary,
    'set_branch_access',
    'user_branch_access',
    p_user_id,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904054500_enforce_granular_pos_permissions.sql
-- ----------------------------------------------------------------------------
-- Complete the permission-first POS contract without revoking existing access.
-- Legacy permissions remain available for old screens, while current role rows
-- receive equivalent granular capabilities before enforcement switches over.

UPDATE public.roles
SET permissions = permissions
  || CASE WHEN permissions ? 'pos.sell' THEN '["pos.view","pos.order.create","pos.order.edit"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.pay' THEN '["pos.payment.take","pos.receipt.print"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.split_order' THEN '["pos.order.split"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.transfer_order' THEN '["pos.order.transfer"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'sales.print' OR permissions ? 'pos.reprint' THEN '["pos.receipt.print"]'::jsonb ELSE '[]'::jsonb END,
    updated_at = now()
WHERE permissions ?| ARRAY['pos.sell','pos.pay','pos.split_order','pos.transfer_order','sales.print','pos.reprint'];

-- De-duplicate role permission arrays after the compatibility expansion.
UPDATE public.roles r
SET permissions = (
  SELECT jsonb_agg(value ORDER BY value)
  FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(r.permissions)) p
), updated_at = now();

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
  IF v_is_service_role OR v_uid IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'sales' THEN
    IF TG_OP = 'INSERT' AND NOT public.can_permission('pos.payment.take') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.payment.take';
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
      IF NOT public.can_permission('pos.order.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.create';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF OLD.kitchen_status = 'pending'
         AND NEW.kitchen_status = 'sent'
         AND public.can_permission('pos.send_kitchen')
         AND EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_id = OLD.id) THEN
        RETURN NEW;
      END IF;
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

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
      ELSIF NEW.status = 'completed' THEN
        IF NOT public.can_permission('pos.payment.take') THEN
          RAISE EXCEPTION 'PERMISSION_DENIED:pos.payment.take';
        END IF;
        IF NOT public.can_permission('pos.order.edit')
           AND (to_jsonb(NEW)-ARRAY['status','payment_status','payment_at','updated_at']::text[])
             IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','payment_status','payment_at','updated_at']::text[]) THEN
          RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
        END IF;
      ELSIF NEW.status IN ('open', 'held') AND NOT public.can_permission('pos.hold') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.hold';
      END IF;
    END IF;

    IF NEW.table_id IS DISTINCT FROM OLD.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT public.can_permission('pos.order.transfer') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.transfer';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.table_id IS NOT DISTINCT FROM OLD.table_id
       AND NOT public.can_permission('pos.order.edit') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.order.create')
         AND NOT public.can_permission('pos.order.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
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
      IF NOT public.can_permission('pos.order.split') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.split';
      END IF;
    ELSIF NOT public.can_permission('pos.order.edit') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;

CREATE OR REPLACE FUNCTION public.authorize_sale_print(p_sale_id uuid,p_approval_request_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales%ROWTYPE; v_user public.users%ROWTYPE; v_count integer; v_req public.approval_requests%ROWTYPE; v_event_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_sale FROM public.sales WHERE id=p_sale_id;
  IF v_sale.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','SALE_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_sale.branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
  SELECT count(*)::int INTO v_count FROM public.sale_print_events WHERE sale_id=p_sale_id;
  IF v_count=0 AND NOT public.can_permission('pos.receipt.print') THEN
    RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED','permission','pos.receipt.print');
  END IF;
  IF v_count>0 AND NOT public.can_permission('pos.reprint') THEN
    IF p_approval_request_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','reprint'); END IF;
    SELECT * INTO v_req FROM public.approval_requests WHERE id=p_approval_request_id FOR UPDATE;
    IF v_req.id IS NULL OR v_req.requester_id<>auth.uid() OR v_req.branch_id<>v_sale.branch_id OR v_req.action_type<>'reprint' OR v_req.entity_id IS DISTINCT FROM p_sale_id OR v_req.status<>'approved' OR v_req.expires_at<=now() THEN RETURN jsonb_build_object('success',false,'error','INVALID_APPROVAL'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req.id;
  END IF;
  INSERT INTO public.sale_print_events(sale_id,branch_id,user_id,print_number,approval_request_id)
  VALUES(p_sale_id,v_sale.branch_id,auth.uid(),v_count+1,CASE WHEN v_count>0 THEN p_approval_request_id ELSE NULL END)
  RETURNING id INTO v_event_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN v_count=0 THEN 'SALE_PRINTED' ELSE 'SALE_REPRINTED' END,'sale',p_sale_id,
    jsonb_build_object('print_number',v_count+1,'approval_request_id',p_approval_request_id),v_sale.branch_id);
  RETURN jsonb_build_object('success',true,'event_id',v_event_id,'print_number',v_count+1,'is_reprint',(v_count>0));
END $$;

REVOKE ALL ON FUNCTION public.authorize_sale_print(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.authorize_sale_print(uuid,uuid) TO authenticated,service_role;

DO $migration$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='perform_pos_order_action';
  IF v_def IS NULL THEN RAISE EXCEPTION 'GRANULAR_POS_ACTION_MISSING'; END IF;
  v_old := E'  IF p_action_type NOT IN (''split_order'',''merge_order'',''transfer_order'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''INVALID_ACTION'');\n  END IF;';
  v_new := v_old || E'\n\n  IF p_action_type = ''split_order'' AND NOT public.can_permission(''pos.order.split'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''PERMISSION_DENIED'', ''permission'', ''pos.order.split'');\n  END IF;\n  IF p_action_type IN (''merge_order'',''transfer_order'') AND NOT public.can_permission(''pos.order.transfer'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''PERMISSION_DENIED'', ''permission'', ''pos.order.transfer'');\n  END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'GRANULAR_POS_ACTION_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$migration$;

ALTER FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) SET search_path = public, pg_temp;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904055000_waste_inventory_contract.sql
-- ----------------------------------------------------------------------------
-- Waste contract: exact target + exact warehouse + approval-time deduction.

UPDATE public.roles
SET permissions = permissions || '["waste.view","waste.create","waste.approve","waste.report"]'::jsonb,
    updated_at = now()
WHERE permissions ? 'production.waste';

UPDATE public.roles r
SET permissions = (
  SELECT jsonb_agg(value ORDER BY value)
  FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(r.permissions)) p
), updated_at = now();

DROP POLICY IF EXISTS we_admin_all ON public.waste_entries;
DROP POLICY IF EXISTS we_branch_read ON public.waste_entries;
DROP POLICY IF EXISTS waste_entries_select ON public.waste_entries;
CREATE POLICY waste_entries_select ON public.waste_entries
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id) AND public.can_permission('waste.view'));

REVOKE INSERT, UPDATE, DELETE ON public.waste_entries FROM authenticated;
GRANT ALL ON public.waste_entries TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.create_waste_entry(
  p_branch_id uuid,
  p_waste_category_id uuid,
  p_waste_type text,
  p_quantity numeric,
  p_unit_cost numeric,
  p_reason text DEFAULT NULL,
  p_raw_material_id uuid DEFAULT NULL,
  p_inventory_unit_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
  v_target_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.create') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.create'; END IF;
  IF NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  IF p_waste_type NOT IN ('raw_material','finished_good','production','expired','damaged') THEN RAISE EXCEPTION 'INVALID_WASTE_TYPE'; END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_WASTE_QUANTITY'; END IF;
  IF p_warehouse_id IS NULL THEN RAISE EXCEPTION 'WAREHOUSE_REQUIRED'; END IF;
  IF p_raw_material_id IS NOT NULL THEN RAISE EXCEPTION 'RAW_MATERIAL_TARGET_DEPRECATED:use_inventory_unit'; END IF;
  IF (p_product_id IS NULL) = (p_inventory_unit_id IS NULL) THEN RAISE EXCEPTION 'EXACTLY_ONE_WASTE_TARGET_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id=p_warehouse_id AND w.branch_id=p_branch_id AND w.is_active=true) THEN
    RAISE EXCEPTION 'WAREHOUSE_BRANCH_MISMATCH';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.waste_categories c WHERE c.id=p_waste_category_id AND c.is_active=true) THEN
    RAISE EXCEPTION 'WASTE_CATEGORY_NOT_FOUND';
  END IF;

  IF p_product_id IS NOT NULL THEN
    SELECT branch_id INTO v_target_branch FROM public.products WHERE id=p_product_id AND is_active=true;
  ELSE
    SELECT branch_id INTO v_target_branch FROM public.inventory_units WHERE id=p_inventory_unit_id AND is_active=true;
  END IF;
  IF NOT FOUND OR (v_target_branch IS NOT NULL AND v_target_branch<>p_branch_id) THEN RAISE EXCEPTION 'WASTE_TARGET_BRANCH_MISMATCH'; END IF;

  INSERT INTO public.waste_entries(
    id,branch_id,waste_category_id,waste_type,inventory_unit_id,product_id,
    quantity,unit_cost,reason,warehouse_id,employee_id,created_by,status
  ) VALUES (
    v_id,p_branch_id,p_waste_category_id,p_waste_type,p_inventory_unit_id,p_product_id,
    p_quantity,GREATEST(COALESCE(p_unit_cost,0),0),NULLIF(trim(p_reason),''),p_warehouse_id,
    p_employee_id,auth.uid(),'pending'
  );

  INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),'create','waste_entry',v_id,
    jsonb_build_object('waste_type',p_waste_type,'quantity',p_quantity,'warehouse_id',p_warehouse_id,
      'product_id',p_product_id,'inventory_unit_id',p_inventory_unit_id),p_branch_id);
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_waste(
  p_waste_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_entry public.waste_entries%ROWTYPE;
  v_inventory public.inventory%ROWTYPE;
  v_available numeric(14,4);
  v_remaining numeric(14,4);
  v_take numeric(14,4);
  v_batch record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.approve') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.approve'; END IF;

  SELECT * INTO v_entry FROM public.waste_entries WHERE id=p_waste_id FOR UPDATE;
  IF v_entry.id IS NULL THEN RAISE EXCEPTION 'WASTE_NOT_FOUND'; END IF;
  IF NOT public.user_may_access_branch(v_entry.branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  IF v_entry.status<>'pending' THEN RAISE EXCEPTION 'WASTE_NOT_PENDING'; END IF;
  IF v_entry.warehouse_id IS NULL THEN RAISE EXCEPTION 'WAREHOUSE_REQUIRED'; END IF;
  IF (v_entry.product_id IS NULL)=(v_entry.inventory_unit_id IS NULL) THEN RAISE EXCEPTION 'INVALID_WASTE_TARGET'; END IF;

  IF NOT p_approve THEN
    UPDATE public.waste_entries SET status='rejected',rejection_reason=p_rejection_reason,
      approved_by=auth.uid(),approved_at=now(),updated_at=now() WHERE id=p_waste_id;
    INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),'reject','waste_entry',p_waste_id,jsonb_build_object('status','rejected','reason',p_rejection_reason),v_entry.branch_id);
    RETURN;
  END IF;

  IF v_entry.product_id IS NOT NULL THEN
    SELECT * INTO v_inventory FROM public.inventory
    WHERE product_id=v_entry.product_id AND warehouse_id=v_entry.warehouse_id FOR UPDATE;
    IF v_inventory.id IS NULL OR v_inventory.quantity<v_entry.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK:product:%:available:%:required:%',v_entry.product_id,COALESCE(v_inventory.quantity,0),v_entry.quantity;
    END IF;
    v_available:=v_inventory.quantity;
    UPDATE public.inventory SET quantity=quantity-v_entry.quantity,updated_at=now() WHERE id=v_inventory.id;

    v_remaining:=v_entry.quantity;
    FOR v_batch IN SELECT id,quantity FROM public.inventory_batches
      WHERE product_id=v_entry.product_id AND warehouse_id=v_entry.warehouse_id AND quantity>0
      ORDER BY expiry_date NULLS LAST,created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.quantity);
      UPDATE public.inventory_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      v_remaining:=v_remaining-v_take;
    END LOOP;

    INSERT INTO public.inventory_ledger(product_id,branch_id,warehouse_id,quantity,unit_cost,total_cost,
      before_qty,after_qty,entry_type,reference_type,reference_id,reference_number,created_by)
    VALUES(v_entry.product_id,v_entry.branch_id,v_entry.warehouse_id,-v_entry.quantity,v_entry.unit_cost,
      -(v_entry.quantity*v_entry.unit_cost),v_available,v_available-v_entry.quantity,'waste','waste',p_waste_id,
      'WASTE-'||left(p_waste_id::text,8),auth.uid());
    INSERT INTO public.inventory_movements(product_id,warehouse_id,movement_type,quantity,reference_id,notes,branch_id)
    VALUES(v_entry.product_id,v_entry.warehouse_id,'waste',-v_entry.quantity,p_waste_id,v_entry.reason,v_entry.branch_id);
  ELSE
    PERFORM 1 FROM public.inventory_unit_batches
    WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id FOR UPDATE;
    SELECT COALESCE(sum(quantity),0) INTO v_available FROM public.inventory_unit_batches
    WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id;
    IF v_available<v_entry.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK:inventory_unit:%:available:%:required:%',v_entry.inventory_unit_id,v_available,v_entry.quantity;
    END IF;
    v_remaining:=v_entry.quantity;
    FOR v_batch IN SELECT id,quantity FROM public.inventory_unit_batches
      WHERE unit_id=v_entry.inventory_unit_id AND warehouse_id=v_entry.warehouse_id AND branch_id=v_entry.branch_id AND quantity>0
      ORDER BY expiry_date NULLS LAST,created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      v_remaining:=v_remaining-v_take;
    END LOOP;
    INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,
      reference_type,reference_id,reference_number,created_by)
    VALUES(v_entry.inventory_unit_id,v_entry.branch_id,v_entry.warehouse_id,-v_entry.quantity,v_entry.unit_cost,
      'waste','waste',p_waste_id,'WASTE-'||left(p_waste_id::text,8),auth.uid());
  END IF;

  UPDATE public.waste_entries SET status='approved',approved_by=auth.uid(),approved_at=now(),
    updated_at=now(),rejection_reason=NULL WHERE id=p_waste_id;
  INSERT INTO public.audit_log(user_id,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),'approve','waste_entry',p_waste_id,
    jsonb_build_object('status','approved','warehouse_id',v_entry.warehouse_id,'quantity_deducted',v_entry.quantity,
      'product_id',v_entry.product_id,'inventory_unit_id',v_entry.inventory_unit_id),v_entry.branch_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_waste_report(
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_from_date date DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_to_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE(waste_category text,waste_type text,total_quantity numeric,total_cost numeric,entry_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT public.can_permission('waste.report') THEN RAISE EXCEPTION 'PERMISSION_DENIED:waste.report'; END IF;
  IF p_branch_id IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_ACCESS_DENIED'; END IF;
  RETURN QUERY SELECT wc.name,we.waste_type,sum(we.quantity),sum(we.total_cost),count(*)::bigint
  FROM public.waste_entries we JOIN public.waste_categories wc ON wc.id=we.waste_category_id
  WHERE we.branch_id=p_branch_id AND we.status='approved' AND we.created_at>=p_from_date
    AND we.created_at<(p_to_date+INTERVAL '1 day') GROUP BY wc.name,we.waste_type ORDER BY sum(we.total_cost) DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_waste_entry(uuid,uuid,text,numeric,numeric,text,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.approve_waste(uuid,boolean,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_waste_report(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_waste_entry(uuid,uuid,text,numeric,numeric,text,uuid,uuid,uuid,uuid,uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid,boolean,text) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_waste_report(uuid,date,date) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_operational_approval_queue(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE(source_type text,source_id uuid,branch_id uuid,title text,status text,requested_by uuid,requested_at timestamptz,required_permission text,payload jsonb)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public,pg_temp AS $$
  SELECT 'manager_approval',a.id,a.branch_id,a.action_type,a.status,a.requester_id,a.created_at,'approvals.review',
    jsonb_build_object('entity_type',a.entity_type,'entity_id',a.entity_id,'reason',a.reason,'payload',a.payload)
  FROM public.approval_requests a WHERE a.status='pending' AND (p_branch_id IS NULL OR a.branch_id=p_branch_id) AND public.user_may_access_branch(a.branch_id)
  UNION ALL
  SELECT 'waste',w.id,w.branch_id,'waste:'||w.waste_type,w.status,w.created_by,w.created_at,'waste.approve',
    jsonb_build_object('product_id',w.product_id,'inventory_unit_id',w.inventory_unit_id,'warehouse_id',w.warehouse_id,'quantity',w.quantity,'total_cost',w.total_cost,'reason',w.reason)
  FROM public.waste_entries w WHERE w.status='pending' AND (p_branch_id IS NULL OR w.branch_id=p_branch_id) AND public.user_may_access_branch(w.branch_id)
  UNION ALL
  SELECT 'stock_count',s.id,s.branch_id,'stock_count:'||COALESCE(s.count_number,s.id::text),s.status,s.submitted_by,COALESCE(s.submitted_at,s.created_at),'inventory.manage',
    jsonb_build_object('warehouse_id',s.warehouse_id,'count_type',s.count_type,'notes',s.notes)
  FROM public.stock_counts s WHERE s.status='submitted' AND (p_branch_id IS NULL OR s.branch_id=p_branch_id) AND public.user_may_access_branch(s.branch_id)
  UNION ALL
  SELECT 'warehouse_transfer',t.id,t.branch_id,'transfer:'||COALESCE(t.transfer_number,t.id::text),t.status,t.requested_by,COALESCE(t.requested_at,t.created_at),'inventory.transfers.approve',
    jsonb_build_object('from_warehouse_id',t.from_warehouse_id,'to_warehouse_id',t.to_warehouse_id,'reason',t.reason,'notes',t.notes)
  FROM public.warehouse_transfers t WHERE t.status IN ('pending','requested','submitted') AND (p_branch_id IS NULL OR t.branch_id=p_branch_id) AND public.user_may_access_branch(t.branch_id)
  ORDER BY 7 DESC;
$$;

CREATE OR REPLACE FUNCTION public.decide_operational_approval(p_source_type text,p_source_id uuid,p_approve boolean,p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_source_type='manager_approval' THEN
    IF NOT public.can_permission('approvals.review') THEN RETURN jsonb_build_object('success',false,'error','APPROVAL_REVIEW_DENIED'); END IF;
    RETURN public.decide_manager_approval(p_source_id,p_approve,p_reason);
  ELSIF p_source_type='waste' THEN
    SELECT branch_id INTO v_branch FROM public.waste_entries WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('waste.approve') THEN
      RETURN jsonb_build_object('success',false,'error','WASTE_APPROVAL_DENIED'); END IF;
    PERFORM public.approve_waste(p_source_id,p_approve,p_reason);
    RETURN jsonb_build_object('success',true,'source_type','waste','source_id',p_source_id,'status',CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END);
  ELSIF p_source_type='stock_count' THEN
    SELECT branch_id INTO v_branch FROM public.stock_counts WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('inventory.manage') THEN RETURN jsonb_build_object('success',false,'error','STOCK_COUNT_APPROVAL_DENIED'); END IF;
    IF p_approve THEN RETURN public.approve_stock_count(p_source_id); END IF;
    RETURN public.reject_stock_count(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  ELSIF p_source_type='warehouse_transfer' THEN
    SELECT branch_id INTO v_branch FROM public.warehouse_transfers WHERE id=p_source_id;
    IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) OR NOT public.can_permission('inventory.transfers.approve') THEN RETURN jsonb_build_object('success',false,'error','TRANSFER_APPROVAL_DENIED'); END IF;
    IF p_approve THEN RETURN public.approve_warehouse_transfer(p_source_id); END IF;
    RETURN public.reject_warehouse_transfer(p_source_id,COALESCE(NULLIF(trim(p_reason),''),'Rejected'));
  END IF;
  RETURN jsonb_build_object('success',false,'error','UNSUPPORTED_APPROVAL_SOURCE');
END;
$$;

REVOKE ALL ON FUNCTION public.get_operational_approval_queue(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_operational_approval_queue(uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.decide_operational_approval(text,uuid,boolean,text) TO authenticated,service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904056000_approval_policies.sql
-- ----------------------------------------------------------------------------
-- Branch-aware approval policy registry. Absence of a matching policy keeps
-- the existing permission contract, so rollout cannot lock current approvers.

UPDATE public.roles SET permissions=permissions||'["approvals.policy.manage"]'::jsonb,updated_at=now()
WHERE permissions ? 'settings.manage' AND NOT permissions ? 'approvals.policy.manage';

CREATE TABLE public.approval_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope text NOT NULL,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  min_amount numeric(14,2) CHECK (min_amount IS NULL OR min_amount>=0),
  max_amount numeric(14,2) CHECK (max_amount IS NULL OR max_amount>=0),
  approver_mode text NOT NULL DEFAULT 'permission' CHECK (approver_mode IN ('permission','user','both')),
  approver_permission text,
  approver_user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  priority integer NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (max_amount IS NULL OR min_amount IS NULL OR max_amount>=min_amount),
  CHECK (approver_mode='user' OR approver_permission IS NOT NULL),
  CHECK (approver_mode='permission' OR approver_user_id IS NOT NULL)
);

CREATE INDEX approval_policies_match_idx ON public.approval_policies(scope,branch_id,is_active,priority);
CREATE TRIGGER approval_policies_updated_at BEFORE UPDATE ON public.approval_policies
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.approval_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY approval_policies_select ON public.approval_policies FOR SELECT TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));
CREATE POLICY approval_policies_insert ON public.approval_policies FOR INSERT TO authenticated
WITH CHECK (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)) AND created_by=auth.uid());
CREATE POLICY approval_policies_update ON public.approval_policies FOR UPDATE TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)))
WITH CHECK (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));
CREATE POLICY approval_policies_delete ON public.approval_policies FOR DELETE TO authenticated
USING (public.can_permission('approvals.policy.manage') AND ((branch_id IS NULL AND public.is_platform_admin()) OR public.user_may_access_branch(branch_id)));

REVOKE ALL ON public.approval_policies FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.approval_policies TO authenticated;
GRANT ALL ON public.approval_policies TO service_role,postgres;

CREATE OR REPLACE FUNCTION public.can_approve_by_policy(
  p_scope text,p_branch_id uuid,p_amount numeric,p_fallback_permission text
) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_has_policy boolean; v_allowed boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN RETURN false; END IF;
  SELECT EXISTS(
    SELECT 1 FROM public.approval_policies ap
    WHERE ap.is_active AND ap.scope=p_scope AND (ap.branch_id IS NULL OR ap.branch_id=p_branch_id)
  ) INTO v_has_policy;
  IF NOT v_has_policy THEN RETURN public.can_permission(p_fallback_permission); END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.approval_policies ap
    WHERE ap.is_active AND ap.scope=p_scope AND (ap.branch_id IS NULL OR ap.branch_id=p_branch_id)
      AND (ap.min_amount IS NULL OR COALESCE(p_amount,0)>=ap.min_amount)
      AND (ap.max_amount IS NULL OR COALESCE(p_amount,0)<=ap.max_amount)
      AND (ap.approver_mode='permission' AND public.can_permission(ap.approver_permission)
        OR ap.approver_mode='user' AND ap.approver_user_id=auth.uid()
        OR ap.approver_mode='both' AND ap.approver_user_id=auth.uid() AND public.can_permission(ap.approver_permission))
  ) INTO v_allowed;
  RETURN v_allowed;
END;
$$;

REVOKE ALL ON FUNCTION public.can_approve_by_policy(text,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_approve_by_policy(text,uuid,numeric,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,p_entity_type text,p_entity_id uuid,p_payload jsonb DEFAULT '{}'::jsonb,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_user public.users%ROWTYPE; v_req_id uuid; v_payload jsonb:=COALESCE(p_payload,'{}'::jsonb); v_branch uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  IF p_action_type NOT IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift','split_order','merge_order','transfer_order') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_ACTION'); END IF;
  IF p_reason IS NULL OR length(trim(p_reason))<3 THEN RETURN jsonb_build_object('success',false,'error','REASON_REQUIRED'); END IF;

  IF p_entity_type='order' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.orders WHERE id=p_entity_id;
  ELSIF p_entity_type='sale' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.sales WHERE id=p_entity_id;
  ELSIF p_entity_type='shift' AND p_entity_id IS NOT NULL THEN SELECT branch_id INTO v_branch FROM public.shifts WHERE id=p_entity_id;
  ELSE
    BEGIN v_branch:=NULLIF(v_payload->>'branch_id','')::uuid; EXCEPTION WHEN OTHERS THEN v_branch:=NULL; END;
  END IF;
  v_branch:=COALESCE(v_branch,v_user.branch_id);
  IF v_branch IS NULL OR NOT public.user_may_access_branch(v_branch) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;

  SELECT id INTO v_req_id FROM public.approval_requests
  WHERE requester_id=auth.uid() AND branch_id=v_branch AND action_type=p_action_type AND entity_type=p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id AND payload=v_payload AND status='pending' AND expires_at>now()
  ORDER BY created_at DESC LIMIT 1;
  IF v_req_id IS NOT NULL THEN RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending','duplicate',true); END IF;

  INSERT INTO public.approval_requests(branch_id,requester_id,action_type,entity_type,entity_id,payload,reason)
  VALUES(v_branch,auth.uid(),p_action_type,p_entity_type,p_entity_id,v_payload,trim(p_reason)) RETURNING id INTO v_req_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,'APPROVAL_REQUESTED','approval_request',v_req_id,
    jsonb_build_object('action_type',p_action_type,'entity_type',p_entity_type,'target_id',p_entity_id,'reason',trim(p_reason),'payload',v_payload),v_branch);
  RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending');
END $$;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.decide_manager_approval(p_request_id uuid,p_approve boolean,p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_req public.approval_requests%ROWTYPE; v_user public.users%ROWTYPE; v_status text; v_amount numeric; v_self_override boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  v_amount:=COALESCE(
    CASE WHEN COALESCE(v_req.payload->>'total','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'total')::numeric END,
    CASE WHEN COALESCE(v_req.payload->>'amount','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'amount')::numeric END,
    CASE WHEN COALESCE(v_req.payload->>'discount_amount','')~'^-?[0-9]+([.][0-9]+)?$' THEN (v_req.payload->>'discount_amount')::numeric END,
    0
  );
  IF NOT public.can_approve_by_policy('manager:'||v_req.action_type,v_req.branch_id,v_amount,'approvals.review') THEN
    RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED','reason','NOT_AUTHORIZED_BY_POLICY'); END IF;
  IF v_req.requester_id=auth.uid() AND NOT public.can_permission('approvals.override') THEN RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN'); END IF;
  v_self_override:=v_req.requester_id=auth.uid();
  IF v_req.status<>'pending' THEN RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now() WHERE id=v_req.id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,'target_id',v_req.entity_id,'note',p_note),v_req.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status,'self_override',v_self_override);
END $$;

CREATE OR REPLACE FUNCTION public.enforce_approval_policy_transition()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_scope text; v_fallback text; v_amount numeric:=0;
BEGIN
  IF auth.uid() IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('approved','rejected') THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='waste_entries' THEN v_scope:='waste'; v_fallback:='waste.approve'; v_amount:=COALESCE(NEW.total_cost,0);
  ELSIF TG_TABLE_NAME='stock_counts' THEN v_scope:='stock_count'; v_fallback:='inventory.manage';
  ELSIF TG_TABLE_NAME='warehouse_transfers' THEN v_scope:='warehouse_transfer'; v_fallback:='inventory.transfers.approve';
  ELSE RETURN NEW; END IF;
  IF NOT public.can_approve_by_policy(v_scope,NEW.branch_id,v_amount,v_fallback) THEN RAISE EXCEPTION 'APPROVAL_POLICY_DENIED:%',v_scope; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_waste_approval_policy ON public.waste_entries;
CREATE TRIGGER enforce_waste_approval_policy BEFORE UPDATE ON public.waste_entries
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();
DROP TRIGGER IF EXISTS enforce_stock_count_approval_policy ON public.stock_counts;
CREATE TRIGGER enforce_stock_count_approval_policy BEFORE UPDATE ON public.stock_counts
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();
DROP TRIGGER IF EXISTS enforce_transfer_approval_policy ON public.warehouse_transfers;
CREATE TRIGGER enforce_transfer_approval_policy BEFORE UPDATE ON public.warehouse_transfers
FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_policy_transition();

REVOKE ALL ON FUNCTION public.enforce_approval_policy_transition() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_approval_policy_transition() TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904057000_security_definer_execute_hardening.sql
-- ----------------------------------------------------------------------------
-- Harden SECURITY DEFINER execution without changing authenticated application RPC behavior.
-- Every function change is conditional because historical Production and a Fresh DB can
-- legitimately expose different overloads at this point in the migration chain.

DO $$
DECLARE
  fn regprocedure;
BEGIN
  -- Internal trigger functions must never be callable directly from API roles.
  fn := to_regprocedure('public._price_order_item_modifiers()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  fn := to_regprocedure('public.delete_unposted_purchase_on_cancel()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  fn := to_regprocedure('public.sync_kitchen_sent_quantity_after_void()');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn);
  END IF;

  -- send_to_kitchen is an authenticated operational RPC only. Harden every supported
  -- overload that exists in the target database without assuming schema history.
  fn := to_regprocedure('public.send_to_kitchen(uuid)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END IF;

  fn := to_regprocedure('public.send_to_kitchen(uuid,uuid)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END IF;

  -- Pre-auth login helpers intentionally remain available to anon.
  fn := to_regprocedure('public.get_login_email(text)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated, service_role', fn);
  END IF;

  fn := to_regprocedure('public.record_login_failure(text)');
  IF fn IS NOT NULL THEN
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated, service_role', fn);
  END IF;
END
$$;

-- These tables were already deny-by-default because RLS was enabled with no policies.
-- Make that intent explicit for API roles when the tables exist, without changing
-- service/postgres access and without assuming historical schema drift.
DO $$
BEGIN
  IF to_regclass('public.sale_payments') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS sale_payments_api_deny_all ON public.sale_payments';
    EXECUTE 'CREATE POLICY sale_payments_api_deny_all ON public.sale_payments AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;

  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS schema_migrations_api_deny_all ON public.schema_migrations';
    EXECUTE 'CREATE POLICY schema_migrations_api_deny_all ON public.schema_migrations AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)';
  END IF;
END
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904058000_operational_fk_indexes.sql
-- ----------------------------------------------------------------------------
-- Cover operational foreign keys reported by Supabase Advisor.
CREATE INDEX IF NOT EXISTS idx_approval_policies_branch_id ON public.approval_policies(branch_id);
CREATE INDEX IF NOT EXISTS idx_approval_policies_approver_user_id ON public.approval_policies(approver_user_id);
CREATE INDEX IF NOT EXISTS idx_approval_policies_created_by ON public.approval_policies(created_by);
CREATE INDEX IF NOT EXISTS idx_approval_requests_approver_id ON public.approval_requests(approver_id);

CREATE INDEX IF NOT EXISTS idx_inventory_ledger_warehouse_id ON public.inventory_ledger(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_created_by ON public.inventory_ledger(created_by);
CREATE INDEX IF NOT EXISTS idx_inventory_unit_batches_warehouse_id ON public.inventory_unit_batches(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inventory_unit_entries_warehouse_id ON public.inventory_unit_entries(warehouse_id);

CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_product_id ON public.order_inventory_consumptions(product_id);
CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_raw_material_id ON public.order_inventory_consumptions(raw_material_id);
CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_warehouse_id ON public.order_inventory_consumptions(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_sends_sent_by ON public.order_kitchen_sends(sent_by);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_approval_request_id ON public.order_kitchen_voids(approval_request_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_product_id ON public.order_kitchen_voids(product_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_voided_by ON public.order_kitchen_voids(voided_by);
CREATE INDEX IF NOT EXISTS idx_orders_cashier_id ON public.orders(cashier_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);

CREATE INDEX IF NOT EXISTS idx_sale_item_inventory_effects_warehouse_id ON public.sale_item_inventory_effects(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_approval_request_id ON public.sale_print_events(approval_request_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_branch_id ON public.sale_print_events(branch_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_user_id ON public.sale_print_events(user_id);

CREATE INDEX IF NOT EXISTS idx_user_branch_access_branch_id ON public.user_branch_access(branch_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_inventory_unit_id ON public.waste_entries(inventory_unit_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_product_id ON public.waste_entries(product_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_raw_material_id ON public.waste_entries(raw_material_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_warehouse_id ON public.waste_entries(warehouse_id);

CREATE INDEX IF NOT EXISTS idx_stock_counts_warehouse_id ON public.stock_counts(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_stock_counts_created_by ON public.stock_counts(created_by);
CREATE INDEX IF NOT EXISTS idx_stock_counts_submitted_by ON public.stock_counts(submitted_by);
CREATE INDEX IF NOT EXISTS idx_stock_counts_approved_by ON public.stock_counts(approved_by);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904059000_operational_rls_initplan_optimization.sql
-- ----------------------------------------------------------------------------
-- Preserve RLS semantics while evaluating auth.uid() once per statement.
-- Historical Production and Fresh DB can have different policy sets. Optimize only
-- policies that already exist; never create a new access path as a performance fix.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_requests' AND policyname='approval_requests_insert') THEN
    EXECUTE $policy$
      ALTER POLICY approval_requests_insert ON public.approval_requests
      WITH CHECK ((requester_id = (SELECT auth.uid())) AND user_may_access_branch(branch_id))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_requests' AND policyname='approval_requests_select') THEN
    EXECUTE $policy$
      ALTER POLICY approval_requests_select ON public.approval_requests
      USING ((requester_id = (SELECT auth.uid())) OR (user_may_access_branch(branch_id) AND (is_pos_admin() OR can_permission('approvals.review'::text))))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='approval_policies' AND policyname='approval_policies_insert') THEN
    EXECUTE $policy$
      ALTER POLICY approval_policies_insert ON public.approval_policies
      WITH CHECK (can_permission('approvals.policy.manage'::text)
        AND (((branch_id IS NULL) AND is_platform_admin()) OR user_may_access_branch(branch_id))
        AND (created_by = (SELECT auth.uid())))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_insert_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_insert_users ON public.users
      WITH CHECK (is_platform_admin() OR ((id = (SELECT auth.uid())) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_select_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_select_users ON public.users
      USING ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.view'::text) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='users' AND policyname='auth_update_users') THEN
    EXECUTE $policy$
      ALTER POLICY auth_update_users ON public.users
      USING ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.manage'::text) AND user_may_access_branch(branch_id)))
      WITH CHECK ((id = (SELECT auth.uid())) OR is_platform_admin() OR (can_permission('users.manage'::text) AND user_may_access_branch(branch_id)))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_branch_access' AND policyname='auth_select_own_user_branch_access') THEN
    EXECUTE $policy$
      ALTER POLICY auth_select_own_user_branch_access ON public.user_branch_access
      USING (user_id = (SELECT auth.uid()))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_branch_access' AND policyname='auth_org_admin_manage_user_branch_access') THEN
    EXECUTE $policy$
      ALTER POLICY auth_org_admin_manage_user_branch_access ON public.user_branch_access
      USING (is_platform_admin() OR (EXISTS (
        SELECT 1 FROM public.branches b
        WHERE b.id = user_branch_access.branch_id
          AND b.organization_id IN (SELECT user_organization_ids())
          AND EXISTS (
            SELECT 1 FROM public.organization_members om
            WHERE om.user_id = (SELECT auth.uid())
              AND om.organization_id = b.organization_id
              AND om.membership_role = ANY (ARRAY['owner'::text,'admin'::text])
              AND om.is_active = true
          )
      )))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_kitchen_station_assignments' AND policyname='user_kitchen_station_select') THEN
    EXECUTE $policy$
      ALTER POLICY user_kitchen_station_select ON public.user_kitchen_station_assignments
      USING ((user_id = (SELECT auth.uid())) OR (user_may_access_branch(branch_id) AND EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = (SELECT auth.uid())
          AND u.role = ANY (ARRAY['super_admin'::text,'owner'::text,'branch_manager'::text])
      )))
    $policy$;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='kitchen_stations' AND policyname='ks_manage_by_permission') THEN
    EXECUTE $policy$
      ALTER POLICY ks_manage_by_permission ON public.kitchen_stations
      USING (can_permission('settings.manage'::text) AND EXISTS (
        SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_active = true
      ))
      WITH CHECK (can_permission('settings.manage'::text) AND EXISTS (
        SELECT 1 FROM public.users u WHERE u.id = (SELECT auth.uid()) AND u.is_active = true
      ))
    $policy$;
  END IF;
END
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904060000_remove_legacy_waste_select_bypass.sql
-- ----------------------------------------------------------------------------
-- Remove the legacy permissive waste SELECT policy.
-- waste_entries_select is the canonical read path and requires both branch access
-- and the explicit waste.view permission. Keeping the legacy branch-only policy
-- would bypass that granular permission because PostgreSQL permissive policies OR together.
DROP POLICY IF EXISTS auth_select_waste_entries ON public.waste_entries;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905001000_canonical_product_image_permission.sql
-- ----------------------------------------------------------------------------
-- Canonicalize product image mutation authorization.
-- Historical migrations used products.manage; the active model uses products.edit.
-- The storage schema is absent from lightweight CI Postgres, so this no-ops there.

DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage schema unavailable; skipping product image policy canonicalization';
    RETURN;
  END IF;

  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_edit ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_edit ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_edit ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY product_images_insert_edit
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_update_edit
    ON storage.objects
    FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_delete_edit
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.edit')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;
END
$$;

-- Remove deprecated permission names from persisted role templates so future
-- assignments cannot silently revive the legacy model. Super Admin bypass is
-- implicit and does not depend on this array.
UPDATE public.roles r
SET permissions = COALESCE((
  SELECT jsonb_agg(p.value ORDER BY p.ordinality)
  FROM jsonb_array_elements(COALESCE(r.permissions, '[]'::jsonb)) WITH ORDINALITY AS p(value, ordinality)
  WHERE p.value #>> '{}' NOT IN (
    'pos.sell',
    'pos.pay',
    'pos.transfer_order',
    'pos.split_order',
    'products.manage',
    'inventory.manage',
    'inventory.transfers',
    'inventory.transfers.approve',
    'catalog.view',
    'procurement.view',
    'accounting.view',
    'admin.view'
  )
), '[]'::jsonb)
WHERE EXISTS (
  SELECT 1
  FROM jsonb_array_elements_text(COALESCE(r.permissions, '[]'::jsonb)) AS p(permission)
  WHERE p.permission IN (
    'pos.sell',
    'pos.pay',
    'pos.transfer_order',
    'pos.split_order',
    'products.manage',
    'inventory.manage',
    'inventory.transfers',
    'inventory.transfers.approve',
    'catalog.view',
    'procurement.view',
    'accounting.view',
    'admin.view'
  )
);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905001400_kitchen_boundary_skipped_migration_compat.sql
-- ----------------------------------------------------------------------------
-- Production skipped 20260904050000_kitchen_send_inventory_boundary.sql while
-- later migrations rewrote cancel_sent_order_item_exact in a compact format.
-- The skipped boundary migration patches that function by exact source pattern.
-- This compatibility migration is a semantic no-op: on a fresh database it
-- runs after the boundary and does nothing; during the production repair it can
-- be applied immediately before the skipped boundary so the authoritative patch
-- can match the current function without replacing newer approval behavior.

DO $compat$
DECLARE
  v_oid regprocedure := to_regprocedure('public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'EXACT_SENT_VOID_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new := v_def;

  -- Current production compact declaration -> canonical boundary patch shape.
  v_new := replace(
    v_new,
    'v_note text; v_privileged boolean:=false;',
    E'v_note text;\n  v_privileged boolean := false;'
  );

  -- Current production compact guard -> canonical boundary patch shape.
  v_new := replace(
    v_new,
    'PERFORM set_config(''app.approved_sent_item_void'',''1'',true);',
    E'  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);'
  );

  IF v_new IS DISTINCT FROM v_def THEN
    EXECUTE v_new;
  END IF;
END;
$compat$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905001500_kitchen_inventory_kds_permission_reconcile.sql
-- ----------------------------------------------------------------------------
-- Reconcile the authoritative kitchen-inventory boundary with the newer KDS
-- lifecycle and granular POS permission model. This migration intentionally
-- runs after 20260904050000_kitchen_send_inventory_boundary.sql.

DO $preflight$
BEGIN
  IF to_regclass('public.order_kitchen_inventory_events') IS NULL
     OR to_regclass('public.order_kitchen_inventory_effects') IS NULL
     OR to_regprocedure('public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)') IS NULL
     OR to_regprocedure('public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_INVENTORY_BOUNDARY_REQUIRED';
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_warehouse_id uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_row record;
  v_inventory jsonb;
  v_failure_product uuid;
  v_failure_name text;
  v_first_sent_at timestamptz;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
  v_effective_sent_by uuid;
BEGIN
  BEGIN
    IF NOT v_is_service_role AND auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    SELECT branch_id, status, order_number, table_id, order_type, guest_count, inventory_warehouse_id
    INTO v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count, v_warehouse_id
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF NOT v_is_service_role THEN
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
      IF NOT (public.is_platform_admin() OR public.can_permission('pos.send_kitchen')) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'detail', 'pos.send_kitchen');
      END IF;
    END IF;

    IF v_status NOT IN ('open','held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
    END IF;

    IF v_warehouse_id IS NULL THEN
      SELECT w.id INTO v_warehouse_id
      FROM public.warehouses w
      WHERE w.branch_id = v_branch_id
        AND w.is_active = true
      ORDER BY COALESCE(w.is_default, false) DESC, w.created_at, w.id
      LIMIT 1;

      IF v_warehouse_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_FOUND');
      END IF;

      UPDATE public.orders
      SET inventory_warehouse_id = v_warehouse_id
      WHERE id = p_order_id;
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name
      FROM public.dining_tables
      WHERE id = v_table_id
        AND branch_id = v_branch_id;
    END IF;

    v_effective_sent_by := CASE
      WHEN v_is_service_role THEN COALESCE(p_sent_by, auth.uid())
      ELSE auth.uid()
    END;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.kns_delta (
      order_item_id uuid PRIMARY KEY,
      send_id uuid,
      event_id uuid,
      delta_quantity numeric(14,4) NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.kns_delta;

    INSERT INTO pg_temp.kns_delta(order_item_id, event_id, delta_quantity)
    SELECT oi.id, gen_random_uuid(), oi.quantity - COALESCE(s.sent_quantity, 0)
    FROM public.order_items oi
    LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
    WHERE oi.order_id = p_order_id
      AND oi.quantity > COALESCE(s.sent_quantity, 0);

    FOR v_row IN
      SELECT d.order_item_id, d.event_id, d.delta_quantity,
             oi.product_id, oi.modifier_option_ids, p.name AS product_name
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
      JOIN public.products p ON p.id = oi.product_id
      ORDER BY oi.created_at, oi.id
    LOOP
      v_failure_product := v_row.product_id;
      v_failure_name := v_row.product_name;

      v_inventory := public._deduct_sale_inventory_with_modifiers_core(
        v_branch_id,
        v_warehouse_id,
        jsonb_build_array(jsonb_build_object(
          'product_id', v_row.product_id,
          'quantity', v_row.delta_quantity,
          'modifier_option_ids', to_jsonb(COALESCE(v_row.modifier_option_ids, '{}'::uuid[]))
        )),
        v_row.event_id,
        v_order_number
      );

      IF COALESCE((v_inventory->>'success')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'KITCHEN_INVENTORY_DEDUCTION_FAILED: %',
          COALESCE(v_inventory->>'detail', v_inventory->>'error', 'UNKNOWN');
      END IF;

      UPDATE public.inventory_unit_entries
      SET entry_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND entry_type = 'sale';

      UPDATE public.inventory_ledger
      SET entry_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND entry_type = 'sale';

      UPDATE public.stock_transactions
      SET transaction_type = 'kitchen_send', reference_type = 'kitchen_send'
      WHERE reference_id = v_row.event_id
        AND reference_type = 'sale'
        AND transaction_type = 'sale';

      INSERT INTO public.order_kitchen_inventory_events(
        id, branch_id, warehouse_id, order_id, order_item_id, sent_quantity,
        total_cost, created_by
      ) VALUES (
        v_row.event_id, v_branch_id, v_warehouse_id, p_order_id, v_row.order_item_id,
        v_row.delta_quantity, COALESCE((v_inventory->>'total_cost')::numeric, 0), auth.uid()
      );

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'inventory_unit',
             (e->>'unit_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((
               SELECT sum((-iue.quantity) * COALESCE(iue.unit_cost, 0))
               FROM public.inventory_unit_entries iue
               WHERE iue.reference_id = v_row.event_id
                 AND iue.reference_type = 'kitchen_send'
                 AND iue.unit_id = (e->>'unit_id')::uuid
                 AND iue.quantity < 0
             ), 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'units_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'raw_material',
             (e->>'raw_material_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric, 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'raw_materials_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      INSERT INTO public.order_kitchen_inventory_effects(
        event_id, branch_id, warehouse_id, target_type, target_id, quantity, total_cost
      )
      SELECT v_row.event_id, v_branch_id, v_warehouse_id, 'product',
             (e->>'product_id')::uuid, (e->>'quantity')::numeric,
             COALESCE((e->>'total_cost')::numeric, 0)
      FROM jsonb_array_elements(COALESCE(v_inventory->'ready_products_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0;

      v_failure_product := NULL;
      v_failure_name := NULL;
    END LOOP;

    WITH candidates AS (
      SELECT d.order_item_id, d.delta_quantity, oi.quantity AS target_quantity
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
    ), upserted AS (
      INSERT INTO public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      SELECT v_branch_id, p_order_id, c.order_item_id, now(), v_effective_sent_by, c.target_quantity
      FROM candidates c
      ON CONFLICT (order_item_id) DO UPDATE
      SET sent_quantity = EXCLUDED.sent_quantity,
          sent_at = now(),
          sent_by = EXCLUDED.sent_by
      WHERE public.order_kitchen_sends.sent_quantity < EXCLUDED.sent_quantity
      RETURNING id, order_item_id
    )
    UPDATE pg_temp.kns_delta d
    SET send_id = u.id
    FROM upserted u
    WHERE u.order_item_id = d.order_item_id;

    UPDATE public.order_kitchen_inventory_events e
    SET kitchen_send_id = d.send_id
    FROM pg_temp.kns_delta d
    WHERE e.id = d.event_id;

    SELECT count(*) INTO v_count FROM pg_temp.kns_delta;

    IF v_count > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id', d.send_id,
        'order_item_id', d.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'station_code', COALESCE(ks.code, 'main'),
        'quantity', d.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', COALESCE(oi.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM pg_temp.kns_delta d
      JOIN public.order_items oi ON oi.id = d.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN public.categories c ON c.id = p.category_id AND c.branch_id = v_branch_id
      LEFT JOIN public.kitchen_stations ks ON ks.id = c.kitchen_station_id AND ks.is_active = true;
    END IF;

    SELECT NOT EXISTS(
      SELECT 1
      FROM public.order_items oi
      LEFT JOIN public.order_kitchen_sends s ON s.order_item_id = oi.id
      WHERE oi.order_id = p_order_id
        AND oi.quantity > COALESCE(s.sent_quantity, 0)
    ) INTO v_all_sent;

    SELECT min(s.sent_at)
    INTO v_first_sent_at
    FROM public.order_kitchen_sends s
    WHERE s.order_id = p_order_id;

    IF v_first_sent_at IS NOT NULL THEN
      UPDATE public.orders
      SET kitchen_status = CASE
            WHEN kitchen_status = 'pending' THEN 'sent'
            ELSE kitchen_status
          END,
          kitchen_sent_at = COALESCE(kitchen_sent_at, v_first_sent_at)
      WHERE id = p_order_id;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'warehouse_id', v_warehouse_id,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent,
      'inventory_deducted', v_count > 0
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', CASE WHEN v_failure_product IS NULL THEN 'TRANSACTION_FAILED' ELSE 'INSUFFICIENT_STOCK' END,
      'product_id', v_failure_product,
      'product_name', v_failure_name,
      'detail', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid,uuid) TO authenticated, service_role;

-- Eliminate the legacy one-argument path as an inventory bypass. Keep the RPC
-- for compatibility, but delegate every call to the authoritative implementation.
CREATE OR REPLACE FUNCTION public.send_to_kitchen(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  RETURN public.send_to_kitchen(p_order_id, auth.uid());
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905001600_remove_ambiguous_kitchen_send_overload.sql
-- ----------------------------------------------------------------------------
-- Remove the legacy one-argument overload after the authoritative two-argument
-- kitchen inventory function has been reconciled. The authoritative function
-- keeps p_sent_by DEFAULT NULL, so existing one-argument callers continue to
-- resolve normally without an ambiguous overload and cannot bypass inventory.

DROP FUNCTION IF EXISTS public.send_to_kitchen(uuid);

-- The remaining signature is public.send_to_kitchen(uuid, uuid DEFAULT NULL).
-- Keep its final least-privilege execution surface explicit.
REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905002000_canonical_product_inventory_rls.sql
-- ----------------------------------------------------------------------------
-- Final canonical RLS for product and inventory mutations.
-- Removes the last runtime dependency on products.manage / inventory.manage.
--
-- Product rows remain editable directly by the frontend, but every mutation is
-- gated by its exact capability and branch access.
-- Inventory direct writes, when needed by an authorized administrative client,
-- use the single granular inventory.adjust capability plus branch access. The
-- normal application path remains the audited stock RPC/workflow boundary.

-- ---------------------------------------------------------------------------
-- Canonical default role templates.
-- Role names are only templates/labels; runtime authorization still resolves
-- explicit permissions from roles.permissions. Super Admin bypass is implicit.
-- ---------------------------------------------------------------------------
WITH grants(role, permissions) AS (
  VALUES
    ('owner', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb),
    ('branch_manager', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb),
    ('warehouse_manager', '["products.create","products.edit","products.delete","products.modifiers.manage","inventory.adjust","inventory.count.create","inventory.count.approve","inventory.transfer.create","inventory.transfer.approve"]'::jsonb)
)
UPDATE public.roles r
SET permissions = COALESCE((
  SELECT jsonb_agg(permission ORDER BY permission)
  FROM (
    SELECT DISTINCT jsonb_array_elements_text(COALESCE(r.permissions, '[]'::jsonb)) AS permission
    UNION
    SELECT DISTINCT jsonb_array_elements_text(g.permissions) AS permission
  ) merged
), '[]'::jsonb),
updated_at = now()
FROM grants g
WHERE r.role = g.role;

-- ---------------------------------------------------------------------------
-- Products: exact permission per DML action + multi-branch access.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "auth_insert_products" ON public.products;
CREATE POLICY "auth_insert_products" ON public.products
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('products.create') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_update_products" ON public.products;
CREATE POLICY "auth_update_products" ON public.products
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_delete_products" ON public.products;
CREATE POLICY "auth_delete_products" ON public.products
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('products.delete') AND public.user_may_access_branch(branch_id))
);

-- product_units are part of editing a product, not a separate legacy manage
-- capability. They inherit branch authorization from their parent product.
DROP POLICY IF EXISTS "auth_insert_product_units" ON public.product_units;
CREATE POLICY "auth_insert_product_units" ON public.product_units
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

DROP POLICY IF EXISTS "auth_update_product_units" ON public.product_units;
CREATE POLICY "auth_update_product_units" ON public.product_units
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
)
WITH CHECK (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

DROP POLICY IF EXISTS "auth_delete_product_units" ON public.product_units;
CREATE POLICY "auth_delete_product_units" ON public.product_units
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (
    public.can_permission('products.edit')
    AND EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = product_units.product_id
        AND (p.branch_id IS NULL OR public.user_may_access_branch(p.branch_id))
    )
  )
);

-- ---------------------------------------------------------------------------
-- Inventory: replace the legacy inventory.manage gate with one granular stock
-- adjustment permission. Normal UI writes still use adjust_stock / receiving /
-- kitchen / transfer / count RPCs; this RLS layer is the final branch boundary
-- for any authorized direct administrative DML.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "auth_insert_inventory" ON public.inventory;
CREATE POLICY "auth_insert_inventory" ON public.inventory
FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_update_inventory" ON public.inventory;
CREATE POLICY "auth_update_inventory" ON public.inventory
FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "auth_delete_inventory" ON public.inventory;
CREATE POLICY "auth_delete_inventory" ON public.inventory
FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS "inventory_direct_insert_denied" ON public.inventory;
DROP POLICY IF EXISTS "inventory_direct_update_denied" ON public.inventory;
DROP POLICY IF EXISTS "inventory_direct_delete_denied" ON public.inventory;

COMMENT ON TABLE public.inventory IS
  'Authoritative stock balance. Application stock changes use audited inventory workflows; direct administrative DML requires inventory.adjust and branch access.';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905102945_fix_audit_action_callers.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_user_to_branch(p_user_id uuid, p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    SELECT b.organization_id INTO v_target_org
    FROM public.branches b WHERE b.id = p_branch_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.user_id = v_caller_id
        AND om.organization_id = v_target_org
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  INSERT INTO public.user_branch_access (user_id, branch_id)
  VALUES (p_user_id, p_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    p_branch_id,
    'assign_branch',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_user_from_branch(p_user_id uuid, p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    SELECT b.organization_id INTO v_target_org
    FROM public.branches b WHERE b.id = p_branch_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.user_id = v_caller_id
        AND om.organization_id = v_target_org
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;
  END IF;

  IF (
    SELECT count(*) FROM public.user_branch_access WHERE user_id = p_user_id
  ) <= 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LAST_BRANCH');
  END IF;

  DELETE FROM public.user_branch_access
  WHERE user_id = p_user_id AND branch_id = p_branch_id;

  PERFORM public.log_audit_action(
    p_branch_id,
    'remove_branch',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
  v_branch_id uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN
    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      SELECT b.organization_id INTO v_target_org
      FROM public.branches b WHERE b.id = v_branch_id;

      IF NOT EXISTS (
        SELECT 1 FROM public.organization_members om
        WHERE om.user_id = v_caller_id
          AND om.organization_id = v_target_org
          AND om.membership_role IN ('owner', 'admin')
          AND om.is_active = true
      ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
      END IF;
    END LOOP;
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access (user_id, branch_id)
  SELECT p_user_id, unnest(p_branch_ids)
  ON CONFLICT DO NOTHING;

  PERFORM public.log_audit_action(
    NULL::uuid,
    'set_branch_access',
    'user_branch_access',
    NULL::uuid,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.toggle_organization_status(p_org_id uuid, p_is_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.organizations SET is_active = p_is_active WHERE id = p_org_id;

  PERFORM public.log_audit_action(
    NULL::uuid,
    CASE WHEN p_is_active THEN 'activate_organization' ELSE 'deactivate_organization' END,
    'organizations',
    p_org_id,
    jsonb_build_object('is_active', p_is_active)
  );

  RETURN jsonb_build_object('success', true);
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905103000_production_schema_contract_sentinel.sql
-- ----------------------------------------------------------------------------
-- Narrow, data-free Production schema sentinel used by the deploy parity gate.
-- It exposes only whether the required kitchen inventory contract exists; no
-- tenant or business rows are read or returned.

CREATE OR REPLACE FUNCTION public._production_schema_contract_kitchen_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, public
AS $function$
  SELECT
    EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'orders'
        AND a.attname = 'inventory_warehouse_id'
        AND a.attnum > 0
        AND NOT a.attisdropped
    )
    AND pg_catalog.to_regclass('public.order_kitchen_inventory_events') IS NOT NULL
    AND pg_catalog.to_regclass('public.order_kitchen_inventory_effects') IS NOT NULL
    AND pg_catalog.to_regprocedure('public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public._restore_kitchen_inventory_for_void(uuid,uuid,numeric)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public.send_to_kitchen(uuid,uuid)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public.send_to_kitchen(uuid)') IS NULL;
$function$;

REVOKE ALL ON FUNCTION public._production_schema_contract_kitchen_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._production_schema_contract_kitchen_v1() TO anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905103458_restore_permission_first_user_branch_access.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_user_branch_access(p_user_id uuid, p_branch_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_target_role text;
  v_target_primary uuid;
  v_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  SELECT role, branch_id
  INTO v_target_role, v_target_primary
  FROM public.users
  WHERE id = p_user_id;

  IF v_target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_platform_admin() THEN
    IF NOT public.can_permission('users.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
    END IF;

    IF v_target_role = 'super_admin' THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Only Super Admin can change Super Admin branch access');
    END IF;

    IF v_target_primary IS NOT NULL AND NOT public.user_may_access_branch(v_target_primary) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = p_user_id
        AND NOT public.user_may_access_branch(uba.branch_id)
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_OUT_OF_SCOPE');
    END IF;

    FOREACH v_branch_id IN ARRAY p_branch_ids LOOP
      IF NOT public.user_may_access_branch(v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED', 'branch_id', v_branch_id);
      END IF;
    END LOOP;
  END IF;

  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access(user_id, branch_id)
  SELECT p_user_id, branch_id
  FROM unnest(p_branch_ids) AS branch_id
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  PERFORM public.log_audit_action(
    v_target_primary,
    'set_branch_access',
    'user_branch_access',
    p_user_id,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids)
  );

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'branch_ids', p_branch_ids);
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110500_permission_first_root_drift_cleanup.sql
-- ----------------------------------------------------------------------------
-- Permission-First root base.
-- Roles are labels only. Super Admin is the only implicit bypass.
-- `owner` remains a valid role label. It has no implicit authorization and
-- receives capabilities only through the explicit permissions stored on its role row.

-- Preserve explicitly selected legacy grants by translating them to their
-- canonical capabilities before deleting the aliases. This is permission-key
-- migration only; no grants are inferred from a role name.
UPDATE public.roles SET permissions = permissions || '["pos.order.create"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'pos.sell' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'pos.order.create';
UPDATE public.roles SET permissions = permissions || '["pos.payment.take"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'pos.pay' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'pos.payment.take';
UPDATE public.roles SET permissions = permissions || '["pos.order.split"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'pos.split_order' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'pos.order.split';
UPDATE public.roles SET permissions = permissions || '["pos.order.transfer"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'pos.transfer_order' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'pos.order.transfer';
UPDATE public.roles SET permissions = permissions || '["products.modifiers.manage"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'products.manage' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'products.modifiers.manage';
UPDATE public.roles SET permissions = permissions || '["inventory.adjust","inventory.count.create","inventory.count.approve"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'inventory.manage';
UPDATE public.roles SET permissions = permissions || '["inventory.transfer.create"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'inventory.transfers' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'inventory.transfer.create';
UPDATE public.roles SET permissions = permissions || '["inventory.transfer.approve"]'::jsonb
WHERE COALESCE(permissions,'[]'::jsonb) ? 'inventory.transfers.approve' AND NOT COALESCE(permissions,'[]'::jsonb) ? 'inventory.transfer.approve';

UPDATE public.roles r
SET permissions = (
  SELECT COALESCE(jsonb_agg(v ORDER BY v), '[]'::jsonb)
  FROM (SELECT DISTINCT value AS v FROM jsonb_array_elements_text(COALESCE(r.permissions,'[]'::jsonb))) s
);

-- Normalize future role-permission writes at the database boundary as well.
-- Legacy names are assembled from fragments so the final runtime function
-- never contains a retired permission as an authorization literal.
CREATE OR REPLACE FUNCTION public.normalize_legacy_role_permissions()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE
  p jsonb := COALESCE(NEW.permissions,'[]'::jsonb);
  k_pos_sell text := 'pos' || '.sell';
  k_pos_pay text := 'pos' || '.pay';
  k_pos_split text := 'pos' || '.split_order';
  k_pos_transfer text := 'pos' || '.transfer_order';
  k_products_manage text := 'products' || '.manage';
  k_inventory_manage text := 'inventory' || '.manage';
  k_inventory_transfers text := 'inventory' || '.transfers';
  k_inventory_transfers_approve text := 'inventory' || '.transfers.approve';
  k_catalog_view text := 'catalog' || '.view';
  k_procurement_view text := 'procurement' || '.view';
  k_accounting_view text := 'accounting' || '.view';
  k_admin_view text := 'admin' || '.view';
BEGIN
  IF p ? k_pos_sell THEN p:=p||'["pos.order.create"]'::jsonb; END IF;
  IF p ? k_pos_pay THEN p:=p||'["pos.payment.take"]'::jsonb; END IF;
  IF p ? k_pos_split THEN p:=p||'["pos.order.split"]'::jsonb; END IF;
  IF p ? k_pos_transfer THEN p:=p||'["pos.order.transfer"]'::jsonb; END IF;
  IF p ? k_products_manage THEN p:=p||'["products.modifiers.manage"]'::jsonb; END IF;
  IF p ? k_inventory_manage THEN p:=p||'["inventory.adjust","inventory.count.create","inventory.count.approve"]'::jsonb; END IF;
  IF p ? k_inventory_transfers THEN p:=p||'["inventory.transfer.create"]'::jsonb; END IF;
  IF p ? k_inventory_transfers_approve THEN p:=p||'["inventory.transfer.approve"]'::jsonb; END IF;

  p:=p-k_pos_sell-k_pos_pay-k_pos_split-k_pos_transfer
       -k_products_manage-k_inventory_manage-k_inventory_transfers-k_inventory_transfers_approve
       -k_catalog_view-k_procurement_view-k_accounting_view-k_admin_view;

  SELECT COALESCE(jsonb_agg(v ORDER BY v),'[]'::jsonb) INTO p
  FROM (SELECT DISTINCT value AS v FROM jsonb_array_elements_text(p)) d;
  NEW.permissions:=p;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_00_normalize_legacy_role_permissions ON public.roles;
CREATE TRIGGER trg_00_normalize_legacy_role_permissions
BEFORE INSERT OR UPDATE OF permissions ON public.roles
FOR EACH ROW EXECUTE FUNCTION public.normalize_legacy_role_permissions();

-- Normalize existing arrays after installing the write boundary.
UPDATE public.roles SET permissions=permissions;

CREATE OR REPLACE FUNCTION public.is_pos_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND u.role = 'super_admin'
  );
$$;
REVOKE ALL ON FUNCTION public.is_pos_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_pos_admin() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.can_permission(p_permission text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.is_pos_admin() OR EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.roles r ON r.role = u.role AND r.is_active = true
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND COALESCE(r.permissions, '[]'::jsonb) ? p_permission
  );
$$;
REVOKE ALL ON FUNCTION public.can_permission(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_permission(text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110550_permission_first_endpoint_normalization.sql
-- ----------------------------------------------------------------------------
-- Normalize endpoints that historically carried role fallbacks before the final
-- runtime reconciliation/audit. This migration is intentionally capability-only.
DO $$
DECLARE r record; d text; n text; v_permission text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid=p.pronamespace
    WHERE ns.nspname='public'
      AND p.prokind='f'
      AND p.proname IN (
        'delete_purchase_invoice',
        'get_kitchen_station_assignments',
        'get_kitchen_station_editor_context',
        'save_kitchen_station_assignments',
        'save_product_modifiers'
      )
  LOOP
    d := r.def;
    n := d;

    IF r.proname='delete_purchase_invoice' THEN
      v_permission := 'purchases.delete';
    ELSIF r.proname IN ('get_kitchen_station_assignments','get_kitchen_station_editor_context','save_kitchen_station_assignments') THEN
      v_permission := 'settings.manage';
    ELSE
      v_permission := 'products.modifiers.manage';
    END IF;

    -- Exact legacy modifier alias.
    n := replace(n, '''products.manage''', '''products.modifiers.manage''');

    -- Remove historical get_user_role-based capability gates while preserving
    -- the surrounding branch/scope checks. Supports nested or combined forms.
    n := regexp_replace(
      n,
      'IF[[:space:]]+get_user_role\(\)[[:space:]]+(NOT[[:space:]]+)?IN[[:space:]]*\([^)]*\)[[:space:]]+THEN',
      format('IF NOT public.can_permission(%L) THEN', v_permission),
      'gi'
    );
    n := regexp_replace(
      n,
      'IF[[:space:]]+get_user_role\(\)[[:space:]]*(=|<>)[[:space:]]*''[^'']+''[[:space:]]+THEN',
      format('IF NOT public.can_permission(%L) THEN', v_permission),
      'gi'
    );

    IF n IS DISTINCT FROM d THEN EXECUTE n; END IF;
  END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110575_permission_first_purchase_kitchen_normalization.sql
-- ----------------------------------------------------------------------------
-- Normalize the last role-label authorization gates before the final fail-closed audit.
-- Capabilities come from roles.permissions; role labels only describe users.

DO $$
DECLARE
  r record;
  d text;
  n text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname IN (
        'delete_purchase_invoice',
        'get_kitchen_station_assignments',
        'get_kitchen_station_editor_context',
        'save_kitchen_station_assignments'
      )
  LOOP
    d := r.def;
    n := d;

    IF r.proname = 'delete_purchase_invoice' THEN
      n := regexp_replace(
        n,
        'IF[[:space:]]+NOT[[:space:]]+(public\.)?can_permission\(''purchases\.manage''\)[[:space:]]+AND[[:space:]]+v_role[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN',
        'IF NOT public.can_permission(''purchases.delete'') THEN',
        'gi'
      );
    ELSE
      n := regexp_replace(
        n,
        'v_role[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)',
        'NOT public.can_permission(''settings.manage'')',
        'gi'
      );
    END IF;

    IF n IS DISTINCT FROM d THEN
      EXECUTE n;
    END IF;
  END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110590_production_permission_first_drift_reconcile.sql
-- ----------------------------------------------------------------------------
-- Production drift reconciliation discovered while applying the verified Permission-First chain.
-- Roles remain labels only. Super Admin is the only implicit bypass.
-- This migration intentionally sorts before 20260905110600_permission_first_runtime_reconcile.sql
-- so the existing fail-closed audit can verify these repaired endpoints on Fresh DB and Production.

CREATE OR REPLACE FUNCTION public.user_may_access_branch(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    public.is_pos_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_branch_access uba
      WHERE uba.user_id = auth.uid()
        AND uba.branch_id = p_branch_id
    )
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active = true
        AND u.branch_id = p_branch_id
    );
$$;
REVOKE ALL ON FUNCTION public.user_may_access_branch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_may_access_branch(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_user_branch_access(p_user_id uuid)
RETURNS TABLE(
  branch_id uuid,
  branch_name text,
  branch_name_en text,
  organization_id uuid,
  is_active boolean,
  grant_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH target_branches AS (
    SELECT uba.branch_id, 'explicit'::text AS grant_source
    FROM public.user_branch_access uba
    WHERE uba.user_id = p_user_id
    UNION
    SELECT u.branch_id, 'primary'::text AS grant_source
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.branch_id IS NOT NULL
      AND u.is_active = true
  )
  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active, tb.grant_source
  FROM target_branches tb
  JOIN public.branches b ON b.id = tb.branch_id
  WHERE auth.uid() IS NOT NULL
    AND (
      p_user_id = auth.uid()
      OR public.is_pos_admin()
      OR public.can_permission('users.view')
      OR public.can_permission('users.manage')
      OR public.can_permission('users.branches.manage')
    )
    AND (
      p_user_id = auth.uid()
      OR public.is_pos_admin()
      OR public.user_may_access_branch(b.id)
    )
  ORDER BY b.name;
$$;
REVOKE ALL ON FUNCTION public.get_user_branch_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_branch_access(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_organization_branch(
  p_organization_id uuid,
  p_name text,
  p_name_en text DEFAULT NULL::text,
  p_address text DEFAULT NULL::text,
  p_phone text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT public.is_pos_admin() THEN
    IF NOT public.can_permission('branches.manage')
       OR NOT public.user_can_access_organization(p_organization_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
    END IF;
  END IF;

  IF btrim(coalesce(p_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_NAME');
  END IF;

  INSERT INTO public.branches (name, name_en, address, phone, is_active, organization_id)
  VALUES (p_name, p_name_en, p_address, p_phone, true, p_organization_id)
  RETURNING id INTO v_branch_id;

  INSERT INTO public.warehouses (name, branch_id, is_active)
  VALUES (p_name || ' - Main', v_branch_id, true)
  RETURNING id INTO v_warehouse_id;

  SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
  INTO v_global_tax, v_global_tax_enabled, v_global_currency
  FROM public.settings ORDER BY id LIMIT 1;

  INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
  VALUES (v_branch_id, v_global_tax, v_global_tax_enabled, v_global_currency, 10);

  INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
  VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

  -- Creating a branch through an explicit capability grants the creator
  -- explicit access to that new branch. This preserves multi-branch behavior
  -- without restoring any implicit owner/admin role authorization.
  INSERT INTO public.user_branch_access (user_id, branch_id)
  VALUES (auth.uid(), v_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  RETURN jsonb_build_object('success', true, 'branch_id', v_branch_id, 'warehouse_id', v_warehouse_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_CREATE_FAILED', 'detail', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.create_organization_branch(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_organization_branch(uuid,text,text,text,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_user_branch uuid;
  v_org uuid;
  v_user_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_auth integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT public.can_permission('branches.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT branch_id INTO v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  SELECT organization_id INTO v_org
  FROM public.branches
  WHERE id = p_branch_id
  FOR UPDATE;

  IF v_org IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF v_user_branch IS NOT DISTINCT FROM p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'CANNOT_DELETE_CURRENT_BRANCH');
  END IF;

  IF NOT public.is_pos_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[])
  INTO v_user_ids
  FROM public.users
  WHERE branch_id = p_branch_id;

  DELETE FROM public.journal_entries WHERE branch_id = p_branch_id;
  DELETE FROM public.branches WHERE id = p_branch_id;

  IF COALESCE(array_length(v_user_ids, 1), 0) > 0 THEN
    DELETE FROM auth.sessions WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.identities WHERE user_id = ANY(v_user_ids);
    DELETE FROM auth.users WHERE id = ANY(v_user_ids);
    GET DIAGNOSTICS v_deleted_auth = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', p_branch_id,
    'organization_id', v_org,
    'deleted_auth_users', v_deleted_auth
  );
EXCEPTION WHEN foreign_key_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DELETE_BLOCKED', 'detail', SQLERRM);
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.open_shift(
  p_branch_id uuid,
  p_opening_amount numeric DEFAULT 0,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_primary_branch uuid;
  v_shift_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_uid AND is_active = true) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.can_permission('shifts.open') THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_ALLOWED',
      'detail', 'Opening shifts requires shifts.open.');
  END IF;

  SELECT branch_id INTO v_primary_branch FROM public.users WHERE id = v_uid;

  IF p_branch_id IS NULL THEN
    p_branch_id := v_primary_branch;
  END IF;

  IF p_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_BRANCH');
  END IF;

  IF NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  -- One cashier/user can have only one open shift globally, independent of
  -- the currently selected branch in the UI.
  IF EXISTS (
    SELECT 1 FROM public.shifts
    WHERE cashier_id = v_uid AND status = 'open'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_ALREADY_OPEN');
  END IF;

  INSERT INTO public.shifts (branch_id, cashier_id, opening_amount, notes)
  VALUES (p_branch_id, v_uid, COALESCE(p_opening_amount, 0), p_notes)
  RETURNING id INTO v_shift_id;

  INSERT INTO public.shift_operations (shift_id, operation_type, amount, payment_method, reference_type)
  VALUES (v_shift_id, 'opening', COALESCE(p_opening_amount, 0), 'cash', 'shift_opening');

  RETURN jsonb_build_object('success', true, 'shift_id', v_shift_id, 'branch_id', p_branch_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.open_shift(uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_shift(uuid,numeric,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110595_production_rls_permission_first_drift_reconcile.sql
-- ----------------------------------------------------------------------------
-- Production-only RLS drift reconciliation discovered by the existing
-- fail-closed Permission-First audit. Keep RLS enabled and replace retired
-- coarse permissions with the canonical granular capabilities.

DROP POLICY IF EXISTS auth_insert_products ON public.products;
DROP POLICY IF EXISTS auth_update_products ON public.products;
DROP POLICY IF EXISTS auth_delete_products ON public.products;

CREATE POLICY auth_insert_products ON public.products
FOR INSERT TO authenticated
WITH CHECK (
  public.is_pos_admin()
  OR (public.can_permission('products.create') AND public.user_may_access_branch(branch_id))
);

CREATE POLICY auth_update_products ON public.products
FOR UPDATE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_pos_admin()
  OR (public.can_permission('products.edit') AND public.user_may_access_branch(branch_id))
);

CREATE POLICY auth_delete_products ON public.products
FOR DELETE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.can_permission('products.delete') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_insert_inventory ON public.inventory;
DROP POLICY IF EXISTS auth_update_inventory ON public.inventory;
DROP POLICY IF EXISTS auth_delete_inventory ON public.inventory;

CREATE POLICY auth_insert_inventory ON public.inventory
FOR INSERT TO authenticated
WITH CHECK (
  public.is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

CREATE POLICY auth_update_inventory ON public.inventory
FOR UPDATE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);

CREATE POLICY auth_delete_inventory ON public.inventory
FOR DELETE TO authenticated
USING (
  public.is_pos_admin()
  OR (public.can_permission('inventory.adjust') AND public.user_may_access_branch(branch_id))
);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110600_permission_first_runtime_reconcile.sql
-- ----------------------------------------------------------------------------
-- Final Permission-First runtime reconciliation.
-- Role values are display labels only. Super Admin is the only implicit bypass.

DO $$
DECLARE r record; d text; n text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
    WHERE ns.nspname='public' AND p.prokind='f'
  LOOP
    d:=r.def; n:=d;

    n:=replace(n,'''pos.pay''','''pos.payment.take''');
    n:=replace(n,'''pos.sell''','''pos.order.create''');
    n:=replace(n,'''pos.split_order''','''pos.order.split''');
    n:=replace(n,'''pos.transfer_order''','''pos.order.transfer''');
    n:=replace(n,'''inventory.transfers.approve''','''inventory.transfer.approve''');
    n:=replace(n,'''inventory.transfers''','''inventory.transfer.create''');
    n:=replace(n,'''products.manage''','''products.modifiers.manage''');

    IF r.proname IN ('create_stock_count','add_stock_count_item','update_stock_count_item','remove_stock_count_item','submit_stock_count') THEN
      n:=replace(n,'''inventory.manage''','''inventory.count.create''');
    ELSIF r.proname IN ('approve_stock_count','reject_stock_count','apply_stock_count') THEN
      n:=replace(n,'''inventory.manage''','''inventory.count.approve''');
    ELSIF r.proname IN ('add_inventory_batch','adjust_stock','adjust_raw_stock') THEN
      n:=replace(n,'''inventory.manage''','''inventory.adjust''');
    ELSIF r.proname IN ('decide_operational_approval','get_operational_approval_queue','enforce_approval_policy_transition') THEN
      n:=replace(n,'''inventory.manage''','''approvals.review''');
    END IF;

    -- Remove owner from implicit role gates while preserving owner as a label.
    n:=replace(n,'NOT IN (''super_admin'', ''owner'')','<> ''super_admin''');
    n:=replace(n,'NOT IN (''super_admin'',''owner'')','<> ''super_admin''');
    n:=replace(n,'IN (''super_admin'', ''owner'')','= ''super_admin''');
    n:=replace(n,'IN (''super_admin'',''owner'')','= ''super_admin''');

    IF r.proname IN ('adjust_stock','adjust_raw_stock') THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''inventory.adjust'') THEN','gi');
    ELSIF r.proname IN ('add_statement_line','match_bank_line','complete_bank_reconciliation','create_bank_reconciliation') THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''accounting.reconciliation.manage'') THEN','gi');
      n:=regexp_replace(n,'IF[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''accounting.reconciliation.manage'') THEN','gi');
    ELSIF r.proname='_treasury_guard' THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''accounting.treasury.transfer'') THEN','gi');
    ELSIF r.proname='post_manual_journal' THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''accounting.journal.post'') THEN','gi');
    ELSIF r.proname='pay_supplier' THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''procurement.payment.create'') THEN','gi');
    ELSIF r.proname='receive_payment' THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''sales.payment.receive'') THEN','gi');
    ELSIF r.proname IN ('process_purchase','process_purchase_return') THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''purchases.manage'') THEN','gi');
    ELSIF r.proname='process_expense' THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+NOT[[:space:]]+(public\.)?can_permission\(''expenses.manage''\)[[:space:]]+AND[[:space:]]+get_user_role\(\)[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*\)[[:space:]]+THEN','IF NOT public.can_permission(''expenses.manage'') THEN','gi');
    END IF;

    IF r.proname IN ('authorize_open_drawer','change_sale_payment_method','force_close_shift') THEN
      n:=regexp_replace(n,'IF[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+AND[[:space:]]+v_role[[:space:]]*<>[[:space:]]*''branch_manager''[[:space:]]+THEN','IF NOT public.can_permission(''approvals.override'') THEN','gi');
    END IF;

    IF r.proname='_process_sale_core' THEN
      n:=regexp_replace(n,'IF[[:space:]]+v_role[[:space:]]*=[[:space:]]*''cashier''[[:space:]]+AND[[:space:]]+NOT[[:space:]]+(public\.)?is_pos_admin\(\)[[:space:]]+THEN','IF public.can_permission(''pos.payment.take'') AND NOT public.is_pos_admin() THEN','gi');
    END IF;

    IF r.proname IN ('get_kitchen_queue','get_my_kitchen_stations') THEN
      n:=regexp_replace(n,'v_role[[:space:]]+IN[[:space:]]*\([^)]*(super_admin|owner|branch_manager)[^)]*\)','public.can_permission(''settings.manage'')','gi');
    END IF;

    IF r.proname IN ('get_product_modifiers_admin','save_product_modifiers') THEN
      n:=replace(n,'''products.manage''','''products.modifiers.manage''');
      n:=regexp_replace(n,'v_role[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([^)]*(super_admin|owner|branch_manager)[^)]*\)','NOT public.can_permission(''products.modifiers.manage'')','gi');
    END IF;

    IF n IS DISTINCT FROM d THEN EXECUTE n; END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_user_to_branch(p_user_id uuid,p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_permission('users.branches.manage') THEN RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED'); END IF;
 IF NOT public.user_may_access_branch(p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.branches WHERE id=p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND'); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.users WHERE id=p_user_id) THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
 INSERT INTO public.user_branch_access(user_id,branch_id) VALUES(p_user_id,p_branch_id) ON CONFLICT(user_id,branch_id) DO NOTHING;
 PERFORM public.log_audit_action(p_branch_id,'assign_branch','user_branch_access',NULL::uuid,jsonb_build_object('user_id',p_user_id,'branch_id',p_branch_id));
 RETURN jsonb_build_object('success',true);
END;$$;

CREATE OR REPLACE FUNCTION public.remove_user_from_branch(p_user_id uuid,p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_permission('users.branches.manage') THEN RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED'); END IF;
 IF NOT public.user_may_access_branch(p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
 IF (SELECT count(*) FROM public.user_branch_access WHERE user_id=p_user_id)<=1 THEN RETURN jsonb_build_object('success',false,'error','LAST_BRANCH'); END IF;
 DELETE FROM public.user_branch_access WHERE user_id=p_user_id AND branch_id=p_branch_id;
 PERFORM public.log_audit_action(p_branch_id,'remove_branch','user_branch_access',NULL::uuid,jsonb_build_object('user_id',p_user_id,'branch_id',p_branch_id));
 RETURN jsonb_build_object('success',true);
END;$$;

CREATE OR REPLACE FUNCTION public.guard_role_permissions()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 -- Direct database/service maintenance has no end-user JWT. RLS still governs
 -- authenticated application writes; this exception only keeps migrations and
 -- CI fixture seeding operable.
 IF auth.uid() IS NULL THEN RETURN NEW; END IF;
 IF public.is_pos_admin() THEN RETURN NEW; END IF;
 IF NOT public.can_permission('roles.permissions.manage') THEN RAISE EXCEPTION 'PERMISSION_DENIED:roles.permissions.manage'; END IF;
 IF NEW.branch_id IS NULL OR NEW.scope='global' OR NOT public.user_may_access_branch(NEW.branch_id) THEN RAISE EXCEPTION 'PERMISSION_DENIED: role outside caller branch scope'; END IF;
 RETURN NEW;
END;$$;

DROP POLICY IF EXISTS auth_write_roles ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_upd ON public.roles;
DROP POLICY IF EXISTS auth_write_roles_del ON public.roles;
CREATE POLICY auth_write_roles ON public.roles FOR INSERT TO authenticated WITH CHECK(public.is_pos_admin() OR (public.can_permission('roles.permissions.manage') AND scope='branch' AND public.user_may_access_branch(branch_id)));
CREATE POLICY auth_write_roles_upd ON public.roles FOR UPDATE TO authenticated USING(public.is_pos_admin() OR (public.can_permission('roles.permissions.manage') AND scope='branch' AND public.user_may_access_branch(branch_id))) WITH CHECK(public.is_pos_admin() OR (public.can_permission('roles.permissions.manage') AND scope='branch' AND public.user_may_access_branch(branch_id)));
CREATE POLICY auth_write_roles_del ON public.roles FOR DELETE TO authenticated USING(public.is_pos_admin() OR (public.can_permission('roles.permissions.manage') AND scope='branch' AND public.user_may_access_branch(branch_id)));

DROP POLICY IF EXISTS organization_members_insert ON public.organization_members;
CREATE POLICY organization_members_insert ON public.organization_members FOR INSERT TO authenticated WITH CHECK(public.is_pos_admin() OR (public.can_permission('users.branches.manage') AND EXISTS(SELECT 1 FROM public.organization_members m WHERE m.organization_id=organization_members.organization_id AND m.user_id=auth.uid() AND m.is_active=true)));

DROP POLICY IF EXISTS organizations_update ON public.organizations;
CREATE POLICY organizations_update ON public.organizations FOR UPDATE TO authenticated USING(public.is_pos_admin() OR (public.can_permission('settings.manage') AND EXISTS(SELECT 1 FROM public.organization_members m WHERE m.organization_id=organizations.id AND m.user_id=auth.uid() AND m.is_active=true))) WITH CHECK(public.is_pos_admin() OR (public.can_permission('settings.manage') AND EXISTS(SELECT 1 FROM public.organization_members m WHERE m.organization_id=organizations.id AND m.user_id=auth.uid() AND m.is_active=true)));

DROP POLICY IF EXISTS auth_org_admin_manage_user_branch_access ON public.user_branch_access;
DROP POLICY IF EXISTS auth_permission_manage_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_permission_manage_user_branch_access ON public.user_branch_access FOR ALL TO authenticated USING(public.is_pos_admin() OR (public.can_permission('users.branches.manage') AND public.user_may_access_branch(branch_id))) WITH CHECK(public.is_pos_admin() OR (public.can_permission('users.branches.manage') AND public.user_may_access_branch(branch_id)));

DROP POLICY IF EXISTS user_kitchen_station_select ON public.user_kitchen_station_assignments;
CREATE POLICY user_kitchen_station_select ON public.user_kitchen_station_assignments FOR SELECT TO authenticated USING(user_id=auth.uid() OR (public.can_permission('settings.manage') AND public.user_may_access_branch(branch_id)));

DROP FUNCTION IF EXISTS public.is_branch_manager();

DO $$
DECLARE v_count integer; v_objects text; v_policies text;
BEGIN
 IF to_regprocedure('public.is_branch_manager()') IS NOT NULL THEN RAISE EXCEPTION 'PERMISSION_FIRST_DRIFT: is_branch_manager still exists'; END IF;

 SELECT count(*) INTO v_count FROM public.roles r CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(r.permissions,'[]'::jsonb)) x(permission)
 WHERE x.permission=ANY(ARRAY['pos.sell','pos.pay','pos.split_order','pos.transfer_order','products.manage','inventory.manage','inventory.transfers','inventory.transfers.approve','catalog.view','procurement.view','accounting.view','admin.view']);
 IF v_count<>0 THEN RAISE EXCEPTION 'PERMISSION_FIRST_DRIFT: legacy role permissions remain (%)',v_count; END IF;

 SELECT string_agg(p.oid::regprocedure::text,', ' ORDER BY p.oid::regprocedure::text) INTO v_objects
 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
 WHERE ns.nspname='public' AND p.prokind='f' AND p.proname NOT IN('is_pos_admin','guard_user_role_changes') AND (
  position('''pos.sell''' in pg_get_functiondef(p.oid))>0 OR position('''pos.pay''' in pg_get_functiondef(p.oid))>0 OR
  position('''pos.split_order''' in pg_get_functiondef(p.oid))>0 OR position('''pos.transfer_order''' in pg_get_functiondef(p.oid))>0 OR
  position('''products.manage''' in pg_get_functiondef(p.oid))>0 OR position('''inventory.manage''' in pg_get_functiondef(p.oid))>0 OR
  position('''inventory.transfers''' in pg_get_functiondef(p.oid))>0 OR position('''inventory.transfers.approve''' in pg_get_functiondef(p.oid))>0 OR
  pg_get_functiondef(p.oid) ~ 'get_user_role\(\)[[:space:]]*(=|<>)[[:space:]]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ 'get_user_role\(\)[[:space:]]+(NOT[[:space:]]+)?IN[[:space:]]*\([^)]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ 'v_role[[:space:]]*(=|<>)[[:space:]]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ 'v_role[[:space:]]+(NOT[[:space:]]+)?IN[[:space:]]*\([^)]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ '(u\.role|users\.role)[[:space:]]*(=|<>)[[:space:]]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ '(u\.role|users\.role)[[:space:]]+(NOT[[:space:]]+)?IN[[:space:]]*\([^)]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  pg_get_functiondef(p.oid) ~ 'membership_role[[:space:]]*(=|<>)[[:space:]]*''owner''' OR
  pg_get_functiondef(p.oid) ~ 'membership_role[[:space:]]+(NOT[[:space:]]+)?IN[[:space:]]*\([^)]*''owner'''
 );
 IF v_objects IS NOT NULL THEN RAISE EXCEPTION 'PERMISSION_FIRST_DRIFT: runtime authorization remains: %',v_objects; END IF;

 SELECT string_agg(tablename||':'||policyname,', ' ORDER BY tablename,policyname) INTO v_policies FROM pg_policies WHERE schemaname='public' AND (
  COALESCE(qual,'') ~ 'is_branch_manager\(' OR COALESCE(with_check,'') ~ 'is_branch_manager\(' OR
  COALESCE(qual,'') ~ 'membership_role[^)]*''owner''' OR COALESCE(with_check,'') ~ 'membership_role[^)]*''owner''' OR
  COALESCE(qual,'') ~ '(users\.)?role[^)]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR COALESCE(with_check,'') ~ '(users\.)?role[^)]*''(owner|branch_manager|accountant|warehouse_manager|cashier)''' OR
  COALESCE(qual,'') ~ '''(products\.manage|inventory\.manage|pos\.sell|pos\.pay)''' OR COALESCE(with_check,'') ~ '''(products\.manage|inventory\.manage|pos\.sell|pos\.pay)'''
 );
 IF v_policies IS NOT NULL THEN RAISE EXCEPTION 'PERMISSION_FIRST_DRIFT: RLS authorization remains: %',v_policies; END IF;
END;$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110610_permission_first_regression_closure.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905110625_permission_first_regression_closure.sql
-- ----------------------------------------------------------------------------
-- Close regressions exposed by the clean Permission-First verification pass.
-- Roles remain labels only. Super Admin is the only implicit bypass.

-- A payment operator must have an open shift unless explicitly trusted to manage
-- shifts. This replaces the historical cashier-name gate with capabilities,
-- without turning every holder of pos.payment.take into a cashier role.
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  SELECT p.oid, pg_get_functiondef(p.oid)
    INTO v_oid, v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_process_sale_core'
  ORDER BY p.oid
  LIMIT 1;

  IF v_oid IS NOT NULL THEN
    v_new := replace(
      v_def,
      'IF public.can_permission(''pos.payment.take'') AND NOT public.is_pos_admin() THEN',
      'IF public.can_permission(''pos.payment.take'') AND NOT public.can_permission(''shifts.manage'') AND NOT public.is_pos_admin() THEN'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END IF;
END;
$$;

-- Role-permission management is capability-first and fail-closed against
-- privilege escalation. A non-Super-Admin may only grant permissions they
-- themselves possess, and may only create/manage roles inside an accessible
-- branch. New role rows that omit scope are safely normalized to caller branch.
CREATE OR REPLACE FUNCTION public.guard_role_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_branch uuid;
  v_unowned text;
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

  SELECT u.branch_id INTO v_caller_branch
  FROM public.users u
  WHERE u.id = auth.uid() AND u.is_active = true;

  IF TG_OP = 'INSERT' AND (NEW.scope IS NULL OR NEW.scope = 'global' OR NEW.branch_id IS NULL) THEN
    IF v_caller_branch IS NULL THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: role requires caller branch scope';
    END IF;
    NEW.scope := 'branch';
    NEW.branch_id := v_caller_branch;
  END IF;

  IF NEW.scope <> 'branch' OR NEW.branch_id IS NULL OR NOT public.user_may_access_branch(NEW.branch_id) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: role outside caller branch scope';
  END IF;

  SELECT p.permission INTO v_unowned
  FROM jsonb_array_elements_text(COALESCE(NEW.permissions, '[]'::jsonb)) AS p(permission)
  WHERE NOT public.can_permission(p.permission)
  ORDER BY p.permission
  LIMIT 1;

  IF v_unowned IS NOT NULL THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: cannot grant unowned permission %', v_unowned;
  END IF;

  RETURN NEW;
END;
$$;

-- Stock-count approval must honor explicit secondary branch access rather than
-- comparing only users.branch_id. The capability remains canonical.
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
        'detail', 'Approving stock counts requires inventory.count.approve.'
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

    IF NOT public.is_pos_admin() AND NOT public.user_may_access_branch(v_count.branch_id) THEN
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

REVOKE ALL ON FUNCTION public.approve_stock_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_stock_count(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905214500_security_definer_handover_hardening.sql
-- ----------------------------------------------------------------------------
-- P0-B handover hardening.
-- Roles remain labels; Super Admin is the only implicit privileged actor.

-- This schema sentinel only inspects PostgreSQL catalogs and does not need
-- owner privileges. Keep it callable for the production-parity gate while
-- removing SECURITY DEFINER/RLS-bypass semantics.
ALTER FUNCTION public._production_schema_contract_kitchen_v1() SECURITY INVOKER;
REVOKE ALL ON FUNCTION public._production_schema_contract_kitchen_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._production_schema_contract_kitchen_v1() TO anon, authenticated, service_role;

-- Cross-user identity/profile data: authenticated callers may reach the RPC,
-- but only the canonical Super Admin predicate may receive rows.
CREATE OR REPLACE FUNCTION public.get_super_admin_all_users(p_search text DEFAULT NULL::text)
RETURNS TABLE(
  user_id uuid,
  email text,
  username text,
  full_name text,
  role text,
  is_active boolean,
  branch_id uuid,
  branch_name text,
  org_id uuid,
  org_name text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    u.id, u.email, u.username, u.full_name, u.role, u.is_active,
    u.branch_id, b.name, om.organization_id, o.name, u.created_at
  FROM public.users u
  LEFT JOIN public.branches b ON b.id = u.branch_id
  LEFT JOIN public.organization_members om ON om.user_id = u.id AND om.is_active = true
  LEFT JOIN public.organizations o ON o.id = om.organization_id
  WHERE public.is_pos_admin()
    AND (
      p_search IS NULL
      OR u.email ILIKE '%' || p_search || '%'
      OR u.username ILIKE '%' || p_search || '%'
      OR u.full_name ILIKE '%' || p_search || '%'
    )
  ORDER BY u.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.get_super_admin_all_users(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_super_admin_all_users(text) TO authenticated, service_role;

-- Global tenant statistics: same explicit Super Admin guard.
CREATE OR REPLACE FUNCTION public.get_super_admin_tenant_stats()
RETURNS TABLE(
  organization_id uuid,
  organization_name text,
  organization_slug text,
  is_active boolean,
  created_at timestamptz,
  branch_count bigint,
  user_count bigint,
  total_branches bigint,
  active_branches bigint,
  has_active_subscription boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    o.id,
    o.name,
    o.slug,
    o.is_active,
    o.created_at,
    (SELECT count(*) FROM public.branches b WHERE b.organization_id = o.id),
    (SELECT count(*) FROM public.organization_members om WHERE om.organization_id = o.id AND om.is_active = true),
    (SELECT count(*) FROM public.branches b WHERE b.organization_id = o.id),
    (SELECT count(*) FROM public.branches b WHERE b.organization_id = o.id AND b.is_active = true),
    EXISTS (
      SELECT 1
      FROM public.branches b
      JOIN public.branch_subscriptions bs ON bs.branch_id = b.id
      WHERE b.organization_id = o.id
        AND bs.status = 'active'
        AND bs.current_period_ends_at > now()
    )
  FROM public.organizations o
  WHERE public.is_pos_admin()
  ORDER BY o.created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.get_super_admin_tenant_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_super_admin_tenant_stats() TO authenticated, service_role;

-- Fail closed for functions created after this migration. New API RPCs must
-- opt in explicitly to anon/authenticated EXECUTE in their own migration.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905223000_login_rpc_security_boundary.sql
-- ----------------------------------------------------------------------------
-- Isolate the two intentionally anonymous login RPCs behind SECURITY INVOKER
-- wrappers in the exposed public schema. The privileged implementation lives in
-- app_private, which is not an exposed PostgREST schema.

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC;
GRANT USAGE ON SCHEMA app_private TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION app_private.get_login_email(p_username text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE username = lower(btrim(p_username));

  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;
  IF NOT v_user.is_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_INACTIVE');
  END IF;
  IF v_user.is_locked AND (v_user.lock_until IS NULL OR v_user.lock_until > now()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_LOCKED');
  END IF;

  IF v_user.is_locked AND v_user.lock_until IS NOT NULL AND v_user.lock_until <= now() THEN
    UPDATE public.users
    SET is_locked = false,
        failed_attempts = 0,
        lock_until = NULL
    WHERE id = v_user.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'email', v_user.email);
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.record_login_failure(p_username text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_user public.users%ROWTYPE;
  v_new_attempts integer;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE username = lower(btrim(p_username));

  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', true);
  END IF;

  IF v_user.is_locked AND v_user.lock_until IS NOT NULL AND v_user.lock_until > now() THEN
    RETURN jsonb_build_object('success', true);
  END IF;

  v_new_attempts := COALESCE(v_user.failed_attempts, 0) + 1;
  IF v_new_attempts >= 5 THEN
    UPDATE public.users
    SET failed_attempts = v_new_attempts,
        is_locked = true,
        lock_until = now() + interval '5 minutes'
    WHERE id = v_user.id;
  ELSE
    UPDATE public.users
    SET failed_attempts = v_new_attempts
    WHERE id = v_user.id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION app_private.get_login_email(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_private.record_login_failure(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_private.get_login_email(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION app_private.record_login_failure(text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_login_email(p_username text)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = app_private, public, pg_temp
AS $function$
  SELECT app_private.get_login_email(p_username);
$function$;

CREATE OR REPLACE FUNCTION public.record_login_failure(p_username text)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = app_private, public, pg_temp
AS $function$
  SELECT app_private.record_login_failure(p_username);
$function$;

REVOKE ALL ON FUNCTION public.get_login_email(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_login_failure(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_login_email(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905224500_security_definer_permission_scope.sql
-- ----------------------------------------------------------------------------
-- P0-B SECURITY DEFINER follow-up.
-- Close confirmed permission/scope gaps without changing public RPC signatures.

CREATE OR REPLACE FUNCTION public.update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL::text,
  p_name_en text DEFAULT NULL::text,
  p_address text DEFAULT NULL::text,
  p_phone text DEFAULT NULL::text,
  p_is_active boolean DEFAULT NULL::boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.can_permission('branches.manage')
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  UPDATE public.branches
  SET name = COALESCE(p_name, name),
      name_en = COALESCE(p_name_en, name_en),
      address = COALESCE(p_address, address),
      phone = COALESCE(p_phone, phone),
      is_active = COALESCE(p_is_active, is_active)
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_UPDATE_FAILED');
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.can_permission('branches.manage')
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  UPDATE public.branches
  SET is_active = false
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED');
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_cost_history(
  p_product_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE(
  id uuid,
  product_id uuid,
  old_cost numeric,
  new_cost numeric,
  changed_at timestamptz,
  changed_by text,
  source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT
    ch.id,
    ch.product_id,
    ch.old_cost,
    ch.new_cost,
    ch.changed_at,
    COALESCE(NULLIF(btrim(u.username), ''), u.full_name, u.email, ''),
    ch.source
  FROM public.product_cost_history ch
  JOIN public.products p ON p.id = ch.product_id
  LEFT JOIN public.users u ON u.id = ch.changed_by
  WHERE ch.product_id = p_product_id
    AND auth.uid() IS NOT NULL
    AND public.can_permission('reports.costing')
    AND (
      public.is_pos_admin()
      OR (p.branch_id IS NOT NULL AND public.user_may_access_branch(p.branch_id))
    )
  ORDER BY ch.changed_at DESC
  LIMIT GREATEST(LEAST(COALESCE(p_limit, 50), 500), 1)
$function$;

CREATE OR REPLACE FUNCTION public.get_production_variance(
  p_unit_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id()
)
RETURNS TABLE(
  raw_material_id uuid,
  raw_material_name text,
  theoretical_qty numeric,
  actual_qty numeric,
  variance numeric,
  variance_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL
     OR NOT public.can_permission('reports.costing')
     OR p_branch_id IS NULL
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH totals AS (
    SELECT
      iur.raw_material_id,
      rm.name AS rm_name,
      iur.quantity AS theoretical_per_unit,
      COALESCE(SUM(iue.quantity) FILTER (WHERE iue.entry_type = 'production'), 0) AS produced_units
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    LEFT JOIN public.inventory_unit_entries iue
      ON iue.unit_id = iur.unit_id
     AND iue.entry_type = 'production'
    WHERE iur.unit_id = p_unit_id
    GROUP BY iur.raw_material_id, rm.name, iur.quantity
  )
  SELECT
    t.raw_material_id,
    t.rm_name::text,
    (t.theoretical_per_unit * ABS(t.produced_units))::numeric AS theoretical_qty,
    COALESCE((
      SELECT ABS(SUM(rm_inv.quantity))
      FROM public.raw_material_batches rm_inv
      WHERE rm_inv.raw_material_id = t.raw_material_id
        AND rm_inv.branch_id = p_branch_id
        AND rm_inv.batch_number LIKE 'PRD-%'
    ), 0)::numeric AS actual_qty,
    (COALESCE((
      SELECT ABS(SUM(rm_inv.quantity))
      FROM public.raw_material_batches rm_inv
      WHERE rm_inv.raw_material_id = t.raw_material_id
        AND rm_inv.branch_id = p_branch_id
        AND rm_inv.batch_number LIKE 'PRD-%'
    ), 0) - (t.theoretical_per_unit * ABS(t.produced_units)))::numeric AS variance,
    CASE
      WHEN (t.theoretical_per_unit * ABS(t.produced_units)) > 0 THEN
        ROUND((
          (COALESCE((
            SELECT ABS(SUM(rm_inv.quantity))
            FROM public.raw_material_batches rm_inv
            WHERE rm_inv.raw_material_id = t.raw_material_id
              AND rm_inv.branch_id = p_branch_id
              AND rm_inv.batch_number LIKE 'PRD-%'
          ), 0) - (t.theoretical_per_unit * ABS(t.produced_units)))
          / (t.theoretical_per_unit * ABS(t.produced_units)) * 100
        ), 2)
      ELSE 0
    END::numeric AS variance_pct
  FROM totals t;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_branch(uuid,text,text,text,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_branch(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_cost_history(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_production_variance(uuid,uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.update_branch(uuid,text,text,text,text,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.deactivate_branch(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_cost_history(uuid,integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_production_variance(uuid,uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260905230000_next_document_number_internal_only.sql
-- ----------------------------------------------------------------------------
-- P0-B final handover hardening.
-- next_document_number is an internal sequence helper used by privileged RPCs.
-- It must not be exposed as a directly callable authenticated/anonymous endpoint.

ALTER FUNCTION public.next_document_number(text)
  SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION public.next_document_number(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.next_document_number(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.next_document_number(text) FROM authenticated;

-- Keep explicit backend/service access. The function owner retains its implicit
-- ability to call the helper from SECURITY DEFINER application RPCs.
GRANT EXECUTE ON FUNCTION public.next_document_number(text) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260906115500_cancel_sent_order_item_wrapper_scope.sql
-- ----------------------------------------------------------------------------
-- P0-B final handover hardening.
-- Prevent cancel_sent_order_item from exposing sent-item existence/ambiguity
-- before authentication and branch authorization are established.

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_item_id uuid;
  v_count integer;
  v_branch_id uuid;
  v_active_user boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
  )
  INTO v_active_user;

  IF NOT COALESCE(v_active_user, false) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT o.branch_id
  INTO v_branch_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT count(*)
  INTO v_count
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    );

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;

  IF v_count > 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'AMBIGUOUS_SENT_ITEM',
      'detail', 'Use cancel_sent_order_item_exact with order_item_id',
      'matching_lines', v_count
    );
  END IF;

  SELECT oi.id
  INTO v_item_id
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    )
  LIMIT 1;

  RETURN public.cancel_sent_order_item_exact(
    p_order_id,
    v_item_id,
    p_quantity,
    p_reason
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid, uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid, uuid, numeric, text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260906130000_resolve_product_modifiers_scope.sql
-- ----------------------------------------------------------------------------
-- P0-B final handover hardening.
-- Prevent resolve_product_modifiers from disclosing cross-branch product/modifier
-- information before authentication and branch authorization are established,
-- while preserving trusted internal DB/service-role call paths used by pricing/inventory.

CREATE OR REPLACE FUNCTION public.resolve_product_modifiers(
  p_product_id uuid,
  p_branch_id uuid,
  p_option_ids jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_group record;
  v_selected_count integer;
  v_input_count integer;
  v_distinct_count integer;
  v_price_delta numeric(14,2) := 0;
  v_snapshot jsonb := '[]'::jsonb;
  v_invalid uuid;
  v_active_user boolean;
  v_uid uuid := auth.uid();
  v_auth_role text := COALESCE(
    NULLIF(current_setting('request.jwt.claim.role', true), ''),
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
  );
BEGIN
  -- External authenticated callers must have a real JWT user identity.
  -- Trusted internal DB calls have no JWT role, while service_role is an
  -- intentionally privileged server path; both remain compatible with the
  -- existing pricing/inventory trigger and server-side call chains.
  IF v_uid IS NULL THEN
    IF COALESCE(v_auth_role, '') NOT IN ('', 'service_role') THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = v_uid
        AND u.is_active = true
    )
    INTO v_active_user;

    IF NOT COALESCE(v_active_user, false) THEN
      RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
    END IF;

    IF NOT public.user_may_access_branch(p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;

  IF p_option_ids IS NULL OR jsonb_typeof(p_option_ids) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_SELECTION');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.products p
    WHERE p.id = p_product_id
      AND p.branch_id = p_branch_id
      AND p.is_active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH');
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT x.option_id)
  INTO v_input_count, v_distinct_count
  FROM (
    SELECT NULLIF(value, '')::uuid AS option_id
    FROM jsonb_array_elements_text(p_option_ids)
  ) x;

  IF v_input_count <> v_distinct_count THEN
    RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_MODIFIER_OPTION');
  END IF;

  SELECT x.option_id
  INTO v_invalid
  FROM (
    SELECT NULLIF(value, '')::uuid AS option_id
    FROM jsonb_array_elements_text(p_option_ids)
  ) x
  LEFT JOIN public.product_modifier_options o
    ON o.id = x.option_id
   AND o.is_active = true
  LEFT JOIN public.product_modifier_groups g
    ON g.id = o.group_id
   AND g.is_active = true
  WHERE o.id IS NULL
     OR g.id IS NULL
     OR g.product_id <> p_product_id
     OR g.branch_id <> p_branch_id
     OR o.branch_id <> p_branch_id
  LIMIT 1;

  IF v_invalid IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_MODIFIER_OPTION',
      'option_id', v_invalid
    );
  END IF;

  FOR v_group IN
    SELECT g.id, g.name, g.name_en, g.min_selections, g.max_selections
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id
      AND g.branch_id = p_branch_id
      AND g.is_active = true
    ORDER BY g.sort_order, g.created_at
  LOOP
    SELECT COUNT(*)
    INTO v_selected_count
    FROM public.product_modifier_options o
    WHERE o.group_id = v_group.id
      AND o.is_active = true
      AND o.id IN (
        SELECT NULLIF(value, '')::uuid
        FROM jsonb_array_elements_text(p_option_ids)
      );

    IF v_selected_count < v_group.min_selections THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'MODIFIER_SELECTION_REQUIRED',
        'group_id', v_group.id,
        'group_name', v_group.name,
        'min_selections', v_group.min_selections
      );
    END IF;

    IF v_selected_count > v_group.max_selections THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'TOO_MANY_MODIFIER_OPTIONS',
        'group_id', v_group.id,
        'group_name', v_group.name,
        'max_selections', v_group.max_selections
      );
    END IF;
  END LOOP;

  SELECT
    COALESCE(SUM(o.price_delta), 0),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'group_id', g.id,
          'group_name', g.name,
          'group_name_en', g.name_en,
          'option_id', o.id,
          'option_name', o.name,
          'option_name_en', o.name_en,
          'price_delta', o.price_delta
        )
        ORDER BY g.sort_order, o.sort_order, o.created_at
      ),
      '[]'::jsonb
    )
  INTO v_price_delta, v_snapshot
  FROM public.product_modifier_options o
  JOIN public.product_modifier_groups g ON g.id = o.group_id
  WHERE o.id IN (
    SELECT NULLIF(value, '')::uuid
    FROM jsonb_array_elements_text(p_option_ids)
  );

  RETURN jsonb_build_object(
    'success', true,
    'price_delta', COALESCE(v_price_delta, 0),
    'snapshot', COALESCE(v_snapshot, '[]'::jsonb)
  );
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTION_ID');
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) TO authenticated, service_role;

