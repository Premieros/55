-- ============================================================================
-- PREMIER / JOHN-S POS & ERP - COMPLETE DATABASE SCHEMA & RPCS
-- Consolidated Build Script generated on 2026-09-06T13:52:49.808Z
-- Contains all 237 migrations in canonical order
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902083000_grant_service_role_internal_rpcs.sql
-- ----------------------------------------------------------------------------
-- Internal/server callers must retain access after the public/anon deny-by-default hardening.
-- This does not reopen any RPC to anon or authenticated users.

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO service_role, postgres',
      r.nspname,
      r.proname,
      r.args
    );
  END LOOP;
END
$do$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902084000_refund_hybrid_inventory_restoration.sql
-- ----------------------------------------------------------------------------
-- Refunds must reverse the same inventory path used by the sale.
-- The legacy refund path only restored finished-product inventory_ledger rows.
-- Hybrid sales can instead consume inventory_units and/or direct raw materials,
-- so restoring a generic product batch created phantom stock while leaving the
-- actually consumed unit/raw stock reduced.

CREATE OR REPLACE FUNCTION public._restore_refund_hybrid_inventory(
  p_sale_id uuid,
  p_product_id uuid,
  p_refund_qty numeric,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link record;
  v_recipe_id uuid;
  v_yield numeric(14,6) := 1;
  v_desired numeric(14,6);
  v_consumed numeric(14,6);
  v_restored numeric(14,6);
  v_to_restore numeric(14,6);
  v_unit_cost numeric(18,6);
  v_res jsonb;
  v_handled boolean := false;
  v_units_restored numeric(14,6) := 0;
  v_raws_restored numeric(14,6) := 0;
  v_batch_number text;
BEGIN
  IF p_sale_id IS NULL OR p_product_id IS NULL OR p_refund_qty IS NULL OR p_refund_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PARAMS');
  END IF;

  -- Restore explicit inventory-unit components. Sale consumption is recorded in
  -- inventory_unit_entries with reference_type='sale' and reference_id=sale id.
  FOR v_link IN
    SELECT pul.unit_id, pul.quantity
    FROM public.product_unit_links pul
    JOIN public.inventory_units iu ON iu.id = pul.unit_id
    WHERE pul.product_id = p_product_id
      AND iu.branch_id = p_branch_id
      AND iu.is_active = true
    ORDER BY pul.unit_id
  LOOP
    SELECT COALESCE(-SUM(iue.quantity) FILTER (WHERE iue.quantity < 0), 0),
           COALESCE(SUM(iue.quantity) FILTER (
             WHERE iue.quantity > 0 AND iue.entry_type = 'refund'
           ), 0),
           COALESCE(
             SUM((-iue.quantity) * COALESCE(iue.unit_cost, 0)) FILTER (WHERE iue.quantity < 0)
             / NULLIF(SUM(-iue.quantity) FILTER (WHERE iue.quantity < 0), 0),
             iu.cost_price,
             0
           )
      INTO v_consumed, v_restored, v_unit_cost
    FROM public.inventory_units iu
    LEFT JOIN public.inventory_unit_entries iue
      ON iue.unit_id = iu.id
     AND iue.branch_id = p_branch_id
     AND iue.warehouse_id = p_warehouse_id
     AND iue.reference_type = 'sale'
     AND iue.reference_id = p_sale_id
    WHERE iu.id = v_link.unit_id
    GROUP BY iu.cost_price;

    IF COALESCE(v_consumed, 0) > 0 THEN
      v_handled := true;
      v_desired := p_refund_qty * v_link.quantity;
      v_to_restore := LEAST(v_desired, GREATEST(v_consumed - COALESCE(v_restored, 0), 0));

      IF v_to_restore > 0 THEN
        v_batch_number := 'RF-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);

        INSERT INTO public.inventory_unit_batches(
          unit_id, branch_id, warehouse_id, batch_number, quantity, unit_cost, production_date
        ) VALUES (
          v_link.unit_id, p_branch_id, p_warehouse_id, v_batch_number,
          v_to_restore, COALESCE(v_unit_cost, 0), CURRENT_DATE
        );

        INSERT INTO public.inventory_unit_entries(
          unit_id, branch_id, warehouse_id, quantity, unit_cost,
          entry_type, reference_type, reference_id, reference_number,
          batch_number, created_by
        ) VALUES (
          v_link.unit_id, p_branch_id, p_warehouse_id, v_to_restore,
          COALESCE(v_unit_cost, 0), 'refund', 'sale', p_sale_id,
          p_reference_number, v_batch_number, auth.uid()
        );

        v_units_restored := v_units_restored + v_to_restore;
      END IF;
    END IF;
  END LOOP;

  -- Restore direct raw-material recipe consumption. Use the same recipe
  -- interpretation as deduct_sale_unit_inventory and cap restoration by the
  -- actual negative sale ledger, minus prior refund restoration, so repeated or
  -- partial refunds can never over-credit stock.
  SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
    INTO v_recipe_id, v_yield
  FROM public.recipes r
  WHERE r.product_id = p_product_id
    AND r.branch_id = p_branch_id
    AND COALESCE(r.is_active, true) = true
  ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
  LIMIT 1;

  IF v_recipe_id IS NOT NULL THEN
    FOR v_link IN
      SELECT ri.raw_material_id,
             ri.quantity / v_yield AS quantity_per_sale
      FROM public.recipe_items ri
      JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
      WHERE ri.recipe_id = v_recipe_id
        AND NOT EXISTS (
          SELECT 1
          FROM public.product_unit_links pul
          JOIN public.inventory_units iu ON iu.id = pul.unit_id
          WHERE pul.product_id = p_product_id
            AND iu.branch_id = p_branch_id
            AND iu.is_active = true
            AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
                regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
        )
      ORDER BY ri.raw_material_id
    LOOP
      SELECT COALESCE(-SUM(l.quantity) FILTER (WHERE l.quantity < 0), 0),
             COALESCE(SUM(l.quantity) FILTER (
               WHERE l.quantity > 0 AND l.entry_type = 'refund'
             ), 0),
             COALESCE(
               SUM((-l.quantity) * COALESCE(l.unit_cost, 0)) FILTER (WHERE l.quantity < 0)
               / NULLIF(SUM(-l.quantity) FILTER (WHERE l.quantity < 0), 0),
               0
             )
        INTO v_consumed, v_restored, v_unit_cost
      FROM public.inventory_ledger l
      WHERE l.raw_material_id = v_link.raw_material_id
        AND l.branch_id = p_branch_id
        AND l.reference_type = 'sale'
        AND l.reference_id = p_sale_id;

      IF COALESCE(v_consumed, 0) > 0 THEN
        v_handled := true;
        v_desired := p_refund_qty * v_link.quantity_per_sale;
        v_to_restore := LEAST(v_desired, GREATEST(v_consumed - COALESCE(v_restored, 0), 0));

        IF v_to_restore > 0 THEN
          v_res := public._raw_add(
            v_link.raw_material_id,
            p_branch_id,
            v_to_restore,
            COALESCE(v_unit_cost, 0),
            'RF-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
            CURRENT_DATE,
            NULL,
            'refund',
            'sale',
            p_sale_id,
            p_reference_number,
            auth.uid()
          );

          IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
            RETURN v_res;
          END IF;

          v_raws_restored := v_raws_restored + v_to_restore;
        END IF;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'handled', v_handled,
    'units_restored', v_units_restored,
    'raw_materials_restored', v_raws_restored
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', 'HYBRID_REFUND_RESTORE_FAILED',
    'detail', SQLERRM
  );
END;
$$;

REVOKE ALL ON FUNCTION public._restore_refund_hybrid_inventory(uuid, uuid, numeric, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._restore_refund_hybrid_inventory(uuid, uuid, numeric, uuid, uuid, text)
  TO service_role, postgres;

-- Patch the canonical refund function so hybrid restoration is attempted first.
-- Only when the original sale has no recorded hybrid consumption do we retain
-- the legacy finished-product inventory restoration path.
DO $migration$
DECLARE
  v_oid oid;
  v_def text;
  v_start integer;
  v_end integer;
  v_old text;
  v_new text;
  v_end_marker text := E'    END LOOP;\n\n    -- Update header: full refund flips the status, otherwise accumulate refunded_amount';
BEGIN
  SELECT p.oid
    INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'process_refund'
    AND p.oid::regprocedure::text = 'process_refund(uuid,jsonb,text)';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'process_refund(uuid,jsonb,text) not found';
  END IF;

  v_def := pg_get_functiondef(v_oid);

  IF position('_restore_refund_hybrid_inventory' in v_def) = 0 THEN
    v_start := position('      -- Restore stock to the warehouses the sale deducted from (FIFO restore as new batch)' in v_def);
    v_end := position(v_end_marker in v_def);

    IF v_start = 0 OR v_end = 0 OR v_end <= v_start THEN
      RAISE EXCEPTION 'process_refund inventory restoration block markers not found';
    END IF;

    v_old := substring(v_def FROM v_start FOR v_end - v_start);
    v_new := $block$      -- Reverse the actual inventory path used by modern hybrid sales first.
      v_res := public._restore_refund_hybrid_inventory(
        p_sale_id,
        v_item.product_id,
        v_req_qty,
        v_sale.branch_id,
        COALESCE(v_sale.warehouse_id, v_fallback_wh),
        v_sale.invoice_number
      );
      IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
        RETURN v_res;
      END IF;

      -- Legacy/ready-product sales are still restored from product inventory.
      -- Do not create a phantom product batch when the sale actually consumed
      -- inventory units and/or raw materials.
      IF COALESCE((v_res->>'handled')::boolean, false) IS NOT TRUE THEN
        v_remaining := v_req_qty;
        SELECT COALESCE(l.unit_cost, p.cost_price, 0) INTO v_last_cost
        FROM products p LEFT JOIN inventory_ledger l
          ON l.product_id = p.id AND l.quantity < 0 AND l.reference_type = 'sale'
             AND l.reference_id = p_sale_id
        WHERE p.id = v_item.product_id
        ORDER BY l.id DESC NULLS LAST LIMIT 1;

        FOR v_ld IN
          SELECT l.warehouse_id, l.batch_number, l.unit_cost, -l.quantity AS debited
          FROM inventory_ledger l
          WHERE l.product_id = v_item.product_id AND l.reference_type = 'sale'
            AND l.reference_id = p_sale_id AND l.quantity < 0
          ORDER BY l.id ASC
        LOOP
          IF v_remaining <= 0 THEN EXIT; END IF;
          v_back := LEAST(COALESCE(v_ld.debited, 0), v_remaining);
          IF v_back <= 0 OR v_ld.warehouse_id IS NULL THEN CONTINUE; END IF;
          v_res := public._product_inv_add(v_item.product_id, v_ld.warehouse_id, v_sale.branch_id, v_back,
            COALESCE(v_ld.unit_cost, v_last_cost),
            'R-' || COALESCE(v_ld.batch_number, 'RETURN'), NULL, NULL,
            'refund', 'refund', p_sale_id, NULL, auth.uid());
          IF NOT (v_res->>'success')::boolean THEN
            RETURN v_res;
          END IF;
          v_remaining := v_remaining - v_back;
        END LOOP;

        IF v_remaining > 0 AND v_fallback_wh IS NOT NULL THEN
          v_res := public._product_inv_add(v_item.product_id, v_fallback_wh, v_sale.branch_id, v_remaining,
            v_last_cost, 'R-RETURN', NULL, NULL, 'refund', 'refund', p_sale_id, NULL, auth.uid());
          IF NOT (v_res->>'success')::boolean THEN
            RETURN v_res;
          END IF;
        END IF;
      END IF;
$block$;

    v_def := overlay(v_def placing v_new from v_start for length(v_old));
    v_def := replace(v_def, 'SET search_path TO ''public'', ''pg_temp'', ''pg_temp''', 'SET search_path TO public, pg_temp');
    EXECUTE v_def;
  END IF;
END
$migration$;

REVOKE ALL ON FUNCTION public.process_refund(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_refund(uuid, jsonb, text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902085000_product_modifiers_inventory.sql
-- ----------------------------------------------------------------------------
-- Product modifiers / variants with server-authoritative pricing and inventory effects.
-- Examples: Single/Double, extra cheese, no onion. KDS remains snapshot-only;
-- inventory is still deducted exactly once at sale completion.

CREATE TABLE IF NOT EXISTS public.product_modifier_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_en text,
  min_selections integer NOT NULL DEFAULT 0 CHECK (min_selections >= 0),
  max_selections integer NOT NULL DEFAULT 1 CHECK (max_selections > 0),
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_modifier_groups_selection_bounds CHECK (max_selections >= min_selections)
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_groups_product
  ON public.product_modifier_groups(product_id, is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_product_modifier_groups_branch
  ON public.product_modifier_groups(branch_id);

CREATE TABLE IF NOT EXISTS public.product_modifier_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  group_id uuid NOT NULL REFERENCES public.product_modifier_groups(id) ON DELETE CASCADE,
  name text NOT NULL,
  name_en text,
  price_delta numeric(14,2) NOT NULL DEFAULT 0,
  is_default boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_options_group
  ON public.product_modifier_options(group_id, is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_product_modifier_options_branch
  ON public.product_modifier_options(branch_id);

CREATE TABLE IF NOT EXISTS public.product_modifier_inventory_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  option_id uuid NOT NULL REFERENCES public.product_modifier_options(id) ON DELETE CASCADE,
  target_type text NOT NULL CHECK (target_type IN ('raw_material', 'inventory_unit')),
  raw_material_id uuid REFERENCES public.raw_materials(id) ON DELETE CASCADE,
  inventory_unit_id uuid REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  quantity_delta numeric(14,6) NOT NULL CHECK (quantity_delta <> 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_modifier_effect_target CHECK (
    (target_type = 'raw_material' AND raw_material_id IS NOT NULL AND inventory_unit_id IS NULL)
    OR
    (target_type = 'inventory_unit' AND inventory_unit_id IS NOT NULL AND raw_material_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_option
  ON public.product_modifier_inventory_effects(option_id);
CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_raw
  ON public.product_modifier_inventory_effects(raw_material_id) WHERE raw_material_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_product_modifier_effects_unit
  ON public.product_modifier_inventory_effects(inventory_unit_id) WHERE inventory_unit_id IS NOT NULL;

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS modifier_option_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  ADD COLUMN IF NOT EXISTS modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.sale_items
  ADD COLUMN IF NOT EXISTS modifier_option_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  ADD COLUMN IF NOT EXISTS modifiers_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.product_modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_inventory_effects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_modifier_groups_branch_select ON public.product_modifier_groups;
CREATE POLICY product_modifier_groups_branch_select ON public.product_modifier_groups
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS product_modifier_options_branch_select ON public.product_modifier_options;
CREATE POLICY product_modifier_options_branch_select ON public.product_modifier_options
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS product_modifier_effects_branch_select ON public.product_modifier_inventory_effects;
CREATE POLICY product_modifier_effects_branch_select ON public.product_modifier_inventory_effects
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

REVOKE ALL ON public.product_modifier_groups FROM anon;
REVOKE ALL ON public.product_modifier_options FROM anon;
REVOKE ALL ON public.product_modifier_inventory_effects FROM anon;
GRANT SELECT ON public.product_modifier_groups TO authenticated;
GRANT SELECT ON public.product_modifier_options TO authenticated;
GRANT SELECT ON public.product_modifier_inventory_effects TO authenticated;
GRANT ALL ON public.product_modifier_groups TO service_role;
GRANT ALL ON public.product_modifier_options TO service_role;
GRANT ALL ON public.product_modifier_inventory_effects TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_product_modifiers(
  p_product_id uuid,
  p_branch_id uuid,
  p_option_ids jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group record;
  v_selected_count integer;
  v_input_count integer;
  v_distinct_count integer;
  v_price_delta numeric(14,2) := 0;
  v_snapshot jsonb := '[]'::jsonb;
  v_invalid uuid;
BEGIN
  IF p_option_ids IS NULL OR jsonb_typeof(p_option_ids) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_SELECTION');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = p_product_id AND p.branch_id = p_branch_id AND p.is_active = true
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
  SELECT x.option_id INTO v_invalid
  FROM (
    SELECT NULLIF(value, '')::uuid AS option_id
    FROM jsonb_array_elements_text(p_option_ids)
  ) x
  LEFT JOIN public.product_modifier_options o ON o.id = x.option_id AND o.is_active = true
  LEFT JOIN public.product_modifier_groups g ON g.id = o.group_id AND g.is_active = true
  WHERE o.id IS NULL OR g.id IS NULL OR g.product_id <> p_product_id
    OR g.branch_id <> p_branch_id OR o.branch_id <> p_branch_id
  LIMIT 1;
  IF v_invalid IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTION', 'option_id', v_invalid);
  END IF;
  FOR v_group IN
    SELECT g.id, g.name, g.name_en, g.min_selections, g.max_selections
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id
      AND g.branch_id = p_branch_id
      AND g.is_active = true
    ORDER BY g.sort_order, g.created_at
  LOOP
    SELECT COUNT(*) INTO v_selected_count
    FROM public.product_modifier_options o
    WHERE o.group_id = v_group.id
      AND o.is_active = true
      AND o.id IN (
        SELECT NULLIF(value, '')::uuid FROM jsonb_array_elements_text(p_option_ids)
      );
    IF v_selected_count < v_group.min_selections THEN
      RETURN jsonb_build_object(
        'success', false, 'error', 'MODIFIER_SELECTION_REQUIRED',
        'group_id', v_group.id, 'group_name', v_group.name,
        'min_selections', v_group.min_selections
      );
    END IF;
    IF v_selected_count > v_group.max_selections THEN
      RETURN jsonb_build_object(
        'success', false, 'error', 'TOO_MANY_MODIFIER_OPTIONS',
        'group_id', v_group.id, 'group_name', v_group.name,
        'max_selections', v_group.max_selections
      );
    END IF;
  END LOOP;
  SELECT COALESCE(SUM(o.price_delta), 0),
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'group_id', g.id,
             'group_name', g.name,
             'group_name_en', g.name_en,
             'option_id', o.id,
             'option_name', o.name,
             'option_name_en', o.name_en,
             'price_delta', o.price_delta
           ) ORDER BY g.sort_order, o.sort_order, o.created_at
         ), '[]'::jsonb)
    INTO v_price_delta, v_snapshot
  FROM public.product_modifier_options o
  JOIN public.product_modifier_groups g ON g.id = o.group_id
  WHERE o.id IN (
    SELECT NULLIF(value, '')::uuid FROM jsonb_array_elements_text(p_option_ids)
  );
  RETURN jsonb_build_object(
    'success', true,
    'price_delta', COALESCE(v_price_delta, 0),
    'snapshot', COALESCE(v_snapshot, '[]'::jsonb)
  );
EXCEPTION WHEN invalid_text_representation THEN
  RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTION_ID');
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_product_modifiers(uuid, uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_product_modifiers(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_groups jsonb;
BEGIN
  SELECT p.branch_id INTO v_branch_id FROM public.products p WHERE p.id = p_product_id AND p.is_active = true;
  IF v_branch_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_branch_id) THEN RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH'); END IF;
  SELECT COALESCE(jsonb_agg(group_row ORDER BY (group_row->>'sort_order')::integer), '[]'::jsonb)
    INTO v_groups
  FROM (
    SELECT jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'name_en', g.name_en,
      'min_selections', g.min_selections,
      'max_selections', g.max_selections,
      'sort_order', g.sort_order,
      'options', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', o.id,
          'name', o.name,
          'name_en', o.name_en,
          'price_delta', o.price_delta,
          'is_default', o.is_default,
          'sort_order', o.sort_order
        ) ORDER BY o.sort_order, o.created_at)
        FROM public.product_modifier_options o
        WHERE o.group_id = g.id AND o.is_active = true
      ), '[]'::jsonb)
    ) AS group_row
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id AND g.is_active = true
  ) q;
  RETURN jsonb_build_object('success', true, 'groups', COALESCE(v_groups, '[]'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_modifiers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_modifiers(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.save_product_modifiers(p_product_id uuid, p_groups jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_role text;
  v_group jsonb;
  v_option jsonb;
  v_effect jsonb;
  v_group_id uuid;
  v_option_id uuid;
  v_target_id uuid;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG');
  END IF;
  SELECT p.branch_id INTO v_branch_id FROM public.products p WHERE p.id = p_product_id;
  IF v_branch_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND'); END IF;
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager') OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;
  DELETE FROM public.product_modifier_groups WHERE product_id = p_product_id AND branch_id = v_branch_id;
  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    IF COALESCE(NULLIF(btrim(v_group->>'name'), ''), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_GROUP_NAME_REQUIRED');
    END IF;
    IF COALESCE((v_group->>'min_selections')::integer, 0) < 0
       OR COALESCE((v_group->>'max_selections')::integer, 1) < GREATEST(COALESCE((v_group->>'min_selections')::integer, 0), 1) THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;
    INSERT INTO public.product_modifier_groups(
      branch_id, product_id, name, name_en, min_selections, max_selections, sort_order, is_active
    ) VALUES (
      v_branch_id, p_product_id, btrim(v_group->>'name'), NULLIF(btrim(v_group->>'name_en'), ''),
      COALESCE((v_group->>'min_selections')::integer, 0),
      COALESCE((v_group->>'max_selections')::integer, 1),
      COALESCE((v_group->>'sort_order')::integer, 0), true
    ) RETURNING id INTO v_group_id;
    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      IF COALESCE(NULLIF(btrim(v_option->>'name'), ''), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_OPTION_NAME_REQUIRED');
      END IF;
      INSERT INTO public.product_modifier_options(
        branch_id, group_id, name, name_en, price_delta, is_default, sort_order, is_active
      ) VALUES (
        v_branch_id, v_group_id, btrim(v_option->>'name'), NULLIF(btrim(v_option->>'name_en'), ''),
        COALESCE((v_option->>'price_delta')::numeric, 0),
        COALESCE((v_option->>'is_default')::boolean, false),
        COALESCE((v_option->>'sort_order')::integer, 0), true
      ) RETURNING id INTO v_option_id;
      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        IF v_target_id IS NULL OR COALESCE((v_effect->>'quantity_delta')::numeric, 0) = 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;
        IF v_effect->>'target_type' = 'raw_material' THEN
          IF NOT EXISTS (SELECT 1 FROM public.raw_materials WHERE id = v_target_id AND branch_id = v_branch_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
          INSERT INTO public.product_modifier_inventory_effects(branch_id, option_id, target_type, raw_material_id, quantity_delta)
          VALUES (v_branch_id, v_option_id, 'raw_material', v_target_id, (v_effect->>'quantity_delta')::numeric);
        ELSIF v_effect->>'target_type' = 'inventory_unit' THEN
          IF NOT EXISTS (SELECT 1 FROM public.inventory_units WHERE id = v_target_id AND branch_id = v_branch_id) THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVENTORY_UNIT_NOT_IN_BRANCH');
          END IF;
          INSERT INTO public.product_modifier_inventory_effects(branch_id, option_id, target_type, inventory_unit_id, quantity_delta)
          VALUES (v_branch_id, v_option_id, 'inventory_unit', v_target_id, (v_effect->>'quantity_delta')::numeric);
        ELSE
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_TARGET_TYPE');
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'SAVE_MODIFIERS_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_modifiers(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_modifiers(uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deduct_sale_inventory_with_modifiers(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item jsonb; v_product_id uuid; v_quantity numeric(14,4); v_link record; v_effect record; v_batch record;
  v_need numeric(14,6); v_take numeric(14,6); v_available numeric(14,6);
  v_total_cost numeric(18,4):=0; v_units jsonb:='[]'::jsonb; v_raws jsonb:='[]'::jsonb; v_ready jsonb:='[]'::jsonb;
  v_user_branch uuid; v_recipe_id uuid; v_yield numeric(14,6); v_res jsonb; v_mod jsonb;
  v_recipe_component_count integer; v_link_count integer;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN
    RETURN jsonb_build_object('success',true,'units_deducted','[]'::jsonb,'raw_materials_deducted','[]'::jsonb,'ready_products_deducted','[]'::jsonb,'errors','[]'::jsonb);
  END IF;
  SELECT branch_id INTO v_user_branch FROM public.users WHERE id=auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch<>p_branch_id THEN
    RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH');
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(unit_id uuid PRIMARY KEY,unit_name text,unit_type text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(raw_material_id uuid PRIMARY KEY,raw_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(product_id uuid PRIMARY KEY,product_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need; TRUNCATE pg_temp.sale_raw_need; TRUNCATE pg_temp.sale_ready_need;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id:=(v_item->>'product_id')::uuid;
    v_quantity:=COALESCE((v_item->>'quantity')::numeric,0);
    IF v_quantity<=0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY','product_id',v_product_id); END IF;
    IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product_id AND p.branch_id=p_branch_id AND p.is_active=true) THEN
      RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id);
    END IF;
    v_mod := public.resolve_product_modifiers(v_product_id, p_branch_id, COALESCE(v_item->'modifier_option_ids','[]'::jsonb));
    IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;
    SELECT COUNT(*) INTO v_link_count
    FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
    WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true;
    FOR v_link IN
      SELECT pul.unit_id,pul.quantity,iu.name AS unit_name,iu.unit_type
      FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
      WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true
    LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty)
      VALUES(v_link.unit_id,v_link.unit_name,v_link.unit_type,v_quantity*v_link.quantity)
      ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
    END LOOP;
    SELECT r.id,COALESCE(NULLIF(r.yield_quantity,0),1) INTO v_recipe_id,v_yield
    FROM public.recipes r
    WHERE r.product_id=v_product_id AND r.branch_id=p_branch_id AND COALESCE(r.is_active,true)=true
    ORDER BY COALESCE(r.version,1) DESC,r.created_at DESC LIMIT 1;
    v_recipe_component_count:=0;
    IF v_recipe_id IS NOT NULL THEN
      FOR v_link IN
        SELECT ri.raw_material_id,rm.name AS raw_name,ri.quantity/v_yield AS quantity_per_sale
        FROM public.recipe_items ri JOIN public.raw_materials rm ON rm.id=ri.raw_material_id
        WHERE ri.recipe_id=v_recipe_id
          AND NOT EXISTS(
            SELECT 1 FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id
            WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true
              AND regexp_replace(lower(btrim(iu.name)),'[ .]+$','','g')=regexp_replace(lower(btrim(rm.name)),'[ .]+$','','g')
          )
      LOOP
        v_recipe_component_count:=v_recipe_component_count+1;
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty)
        VALUES(v_link.raw_material_id,v_link.raw_name,v_quantity*v_link.quantity_per_sale)
        ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      END LOOP;
    END IF;
    IF v_link_count=0 AND v_recipe_component_count=0 THEN
      INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty)
      SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id
      ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty;
    END IF;
    FOR v_effect IN
      SELECT e.target_type,e.raw_material_id,e.inventory_unit_id,e.quantity_delta,
             rm.name AS raw_name,iu.name AS unit_name,iu.unit_type
      FROM public.product_modifier_inventory_effects e
      JOIN public.product_modifier_options o ON o.id=e.option_id AND o.is_active=true
      JOIN public.product_modifier_groups g ON g.id=o.group_id AND g.is_active=true
      LEFT JOIN public.raw_materials rm ON rm.id=e.raw_material_id
      LEFT JOIN public.inventory_units iu ON iu.id=e.inventory_unit_id
      WHERE g.product_id=v_product_id AND g.branch_id=p_branch_id
        AND o.id IN (SELECT NULLIF(value,'')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->'modifier_option_ids','[]'::jsonb)))
    LOOP
      IF v_effect.target_type='raw_material' THEN
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty)
        VALUES(v_effect.raw_material_id,v_effect.raw_name,v_quantity*v_effect.quantity_delta)
        ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      ELSE
        INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty)
        VALUES(v_effect.inventory_unit_id,v_effect.unit_name,v_effect.unit_type,v_quantity*v_effect.quantity_delta)
        ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
      END IF;
    END LOOP;
    v_recipe_id:=NULL; v_yield:=NULL;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_temp.sale_unit_need WHERE required_qty < 0)
     OR EXISTS (SELECT 1 FROM pg_temp.sale_raw_need WHERE required_qty < 0) THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_MODIFIER_INVENTORY_EFFECT','detail','Modifier removal exceeds the base component quantity.');
  END IF;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 AND unit_type='manufactured' ORDER BY unit_id LOOP
    PERFORM public._ensure_inventory_unit_stock(v_link.unit_id, v_link.required_qty, p_warehouse_id, p_branch_id, 0);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 ORDER BY unit_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_unit_batches
    WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',v_link.unit_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty>0 ORDER BY raw_material_id LOOP
    SELECT COALESCE(quantity,0) INTO v_available FROM public.raw_material_inventory
    WHERE raw_material_id=v_link.raw_material_id AND branch_id=p_branch_id;
    v_available:=COALESCE(v_available,0);
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',v_link.raw_material_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty>0 ORDER BY product_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_batches
    WHERE product_id=v_link.product_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',v_link.product_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE required_qty>0 ORDER BY unit_id LOOP
    v_need:=v_link.required_qty;
    FOR v_batch IN SELECT id,quantity,unit_cost,batch_number FROM public.inventory_unit_batches
      WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id AND quantity>0
      ORDER BY created_at,id FOR UPDATE
    LOOP
      EXIT WHEN v_need<=0; v_take:=LEAST(v_need,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,reference_type,reference_id,reference_number,batch_number,created_by)
      VALUES(v_link.unit_id,p_branch_id,p_warehouse_id,-v_take,v_batch.unit_cost,'sale','sale',p_reference_id,p_reference_number,v_batch.batch_number,auth.uid());
      v_need:=v_need-v_take; v_total_cost:=v_total_cost+(v_take*COALESCE(v_batch.unit_cost,0));
    END LOOP;
    v_units:=v_units||jsonb_build_object('unit_id',v_link.unit_id,'unit_name',v_link.unit_name,'unit_type',v_link.unit_type,'quantity',v_link.required_qty);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need WHERE required_qty>0 ORDER BY raw_material_id LOOP
    v_res:=public._raw_remove_fifo(v_link.raw_material_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',v_link.raw_material_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_raws:=v_raws||jsonb_build_object('raw_material_id',v_link.raw_material_id,'raw_name',v_link.raw_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need WHERE required_qty>0 ORDER BY product_id LOOP
    v_res:=public._product_inv_remove_fifo(v_link.product_id,p_warehouse_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',v_link.product_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_ready:=v_ready||jsonb_build_object('product_id',v_link.product_id,'product_name',v_link.product_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  RETURN jsonb_build_object('success',true,'units_deducted',v_units,'raw_materials_deducted',v_raws,'ready_products_deducted',v_ready,'total_cost',v_total_cost,'errors','[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','SALE_INVENTORY_DEDUCTION_FAILED','detail',SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) TO service_role, postgres;

CREATE OR REPLACE FUNCTION public._price_order_item_modifiers()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_base_price numeric(14,2);
  v_mod jsonb;
BEGIN
  SELECT o.branch_id INTO v_branch_id FROM public.orders o WHERE o.id=NEW.order_id;
  SELECT p.sale_price INTO v_base_price FROM public.products p
  WHERE p.id=NEW.product_id AND p.branch_id=v_branch_id AND p.is_active=true;
  IF v_base_price IS NULL THEN RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH'; END IF;
  v_mod:=public.resolve_product_modifiers(NEW.product_id,v_branch_id,to_jsonb(COALESCE(NEW.modifier_option_ids,'{}'::uuid[])));
  IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'MODIFIER_VALIDATION_FAILED: %',COALESCE(v_mod->>'error','unknown');
  END IF;
  NEW.modifiers_snapshot:=COALESCE(v_mod->'snapshot','[]'::jsonb);
  NEW.unit_price:=GREATEST(COALESCE(v_base_price,0)+COALESCE((v_mod->>'price_delta')::numeric,0),0);
  NEW.discount_amount:=LEAST(GREATEST(COALESCE(NEW.discount_amount,0),0),NEW.quantity*NEW.unit_price);
  NEW.total:=ROUND(NEW.quantity*NEW.unit_price-NEW.discount_amount,2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_item_modifier_price ON public.order_items;
CREATE TRIGGER trg_order_item_modifier_price
BEFORE INSERT OR UPDATE OF product_id, quantity, modifier_option_ids, discount_amount
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._price_order_item_modifiers();

DO $patch_orders$
DECLARE v_oid oid; v_def text;
BEGIN
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='create_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,uuid)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifier_option_ids' in v_def)=0 THEN
    v_def:=replace(v_def,
      'discount_amount, bonus_quantity, total, notes)',
      'discount_amount, bonus_quantity, total, modifier_option_ids, notes)');
    v_def:=replace(v_def,
      E'COALESCE((v_item->>''total'')::numeric, 0),\n        NULLIF(v_item->>''notes'', ''''))',
      E'COALESCE((v_item->>''total'')::numeric, 0),\n        ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb))),\n        NULLIF(v_item->>''notes'', ''''))');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='update_order(uuid,text,uuid,uuid,integer,text,jsonb,numeric,numeric,text,numeric,numeric,text)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifier_option_ids' in v_def)=0 THEN
    v_def:=replace(v_def,
      'AND oi.unit_price = COALESCE((v_item->>''unit_price'')::numeric, oi.unit_price)',
      'AND oi.modifier_option_ids = ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb)))');
    v_def:=replace(v_def,
      'discount_amount, bonus_quantity, total, notes)',
      'discount_amount, bonus_quantity, total, modifier_option_ids, notes)');
    v_def:=replace(v_def,
      E'COALESCE((v_item->>''total'')::numeric, 0),\n          NULLIF(v_item->>''notes'', ''''))',
      E'COALESCE((v_item->>''total'')::numeric, 0),\n          ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'', ''[]''::jsonb))),\n          NULLIF(v_item->>''notes'', ''''))');
    EXECUTE v_def;
  END IF;
END
$patch_orders$;

DO $patch_sale$
DECLARE v_oid oid; v_def text;
BEGIN
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='process_sale'
    AND p.oid::regprocedure::text LIKE 'process_sale(text,uuid,%';
  v_def:=pg_get_functiondef(v_oid);
  IF position('resolve_product_modifiers' in v_def)=0 THEN
    v_def:=replace(v_def,'  v_price numeric;',E'  v_price numeric;\n  v_mod jsonb;');
    v_def:=replace(v_def,
      E'    v_price := COALESCE(v_price,0);\n    v_line_discount :=',
      E'    v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n    IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n    v_price := GREATEST(COALESCE(v_price,0)+COALESCE((v_mod->>''price_delta'')::numeric,0),0);\n    v_line_discount :=');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='_process_sale_core';
  v_def:=pg_get_functiondef(v_oid);
  IF position('deduct_sale_inventory_with_modifiers' in v_def)=0 THEN
    v_def:=replace(v_def,'  v_res jsonb;',E'  v_res jsonb;\n  v_mod jsonb;');
    v_def:=replace(v_def,
      E'      SELECT COALESCE(sale_price, 0) INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_discount_amount :=',
      E'      SELECT COALESCE(sale_price, 0) INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n      IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n      v_unit_price := GREATEST(v_unit_price+COALESCE((v_mod->>''price_delta'')::numeric,0),0);\n      v_discount_amount :=');
    v_def:=replace(v_def,
      E'      SELECT sale_price INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_unit_price := COALESCE(v_unit_price, 0);',
      E'      SELECT sale_price INTO v_unit_price FROM products WHERE id = v_product_id;\n      v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb));\n      IF COALESCE((v_mod->>''success'')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;\n      v_unit_price := GREATEST(COALESCE(v_unit_price,0)+COALESCE((v_mod->>''price_delta'')::numeric,0),0);');
    v_def:=replace(v_def,
      'INSERT INTO sale_items (sale_id, product_id, unit_name, quantity, unit_price, discount_amount, bonus_quantity, total)',
      'INSERT INTO sale_items (sale_id, product_id, unit_name, quantity, unit_price, discount_amount, bonus_quantity, total, modifier_option_ids, modifiers_snapshot)');
    v_def:=replace(v_def,
      'v_quantity, v_unit_price, v_discount_amount, v_bonus_quantity, v_item_total);',
      E'v_quantity, v_unit_price, v_discount_amount, v_bonus_quantity, v_item_total,\n        ARRAY(SELECT NULLIF(value, '''')::uuid FROM jsonb_array_elements_text(COALESCE(v_item->''modifier_option_ids'',''[]''::jsonb))),\n        COALESCE(v_mod->''snapshot'',''[]''::jsonb));');
    v_def:=replace(v_def,'public.deduct_sale_unit_inventory(','public.deduct_sale_inventory_with_modifiers(');
    EXECUTE v_def;
  END IF;
  SELECT p.oid INTO v_oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.oid::regprocedure::text='send_to_kitchen(uuid,uuid)';
  v_def:=pg_get_functiondef(v_oid);
  IF position('modifiers_snapshot' in v_def)=0 THEN
    v_def:=replace(v_def,
      '''notes'', oi.notes',
      E'''notes'', oi.notes,\n        ''modifiers'', oi.modifiers_snapshot');
    EXECUTE v_def;
  END IF;
END
$patch_sale$;

REVOKE ALL ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text) TO service_role, postgres;

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902086000_modifier_sale_item_inventory_snapshot.sql
-- ----------------------------------------------------------------------------
-- Persist the exact inventory quantities consumed by each sale item.
-- This makes refunds historically correct even when a product modifier/recipe
-- is changed after the original sale, and disambiguates two configured lines
-- of the same product inside one invoice.

CREATE TABLE IF NOT EXISTS public.sale_item_inventory_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_item_id uuid NOT NULL REFERENCES public.sale_items(id) ON DELETE CASCADE,
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  target_type text NOT NULL CHECK (target_type IN ('inventory_unit', 'raw_material', 'product')),
  target_id uuid NOT NULL,
  quantity numeric(14,6) NOT NULL CHECK (quantity > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sale_item_id, target_type, target_id)
);

CREATE INDEX IF NOT EXISTS idx_sale_item_inventory_effects_sale
  ON public.sale_item_inventory_effects(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_item_inventory_effects_branch
  ON public.sale_item_inventory_effects(branch_id);
CREATE INDEX IF NOT EXISTS idx_sale_item_inventory_effects_target
  ON public.sale_item_inventory_effects(target_type, target_id);

ALTER TABLE public.sale_item_inventory_effects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sale_item_inventory_effects_branch_select ON public.sale_item_inventory_effects;
CREATE POLICY sale_item_inventory_effects_branch_select
ON public.sale_item_inventory_effects
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

REVOKE ALL ON public.sale_item_inventory_effects FROM anon;
GRANT SELECT ON public.sale_item_inventory_effects TO authenticated;
GRANT ALL ON public.sale_item_inventory_effects TO service_role;

-- Patch the core sale function created/hardened by prior migrations so it keeps
-- the sale_item id and persists the exact quantities returned by the inventory
-- executor. No inventory write is moved to KDS; this remains inside sale commit.
DO $patch_sale_effect_snapshot$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_process_sale_core'
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION '_process_sale_core not found';
  END IF;

  v_def := pg_get_functiondef(v_oid);

  IF position('v_sale_item_id uuid' in v_def) = 0 THEN
    v_def := replace(v_def, '  v_sale_id uuid;', E'  v_sale_id uuid;\n  v_sale_item_id uuid;');
  END IF;

  IF position('sale_item_inventory_effects' in v_def) = 0 THEN
    -- The modifier migration appends the snapshot columns as the final values.
    IF position('COALESCE(v_mod->''snapshot'',''[]''::jsonb));' in v_def) = 0 THEN
      RAISE EXCEPTION '_process_sale_core modifier sale_item insert marker not found';
    END IF;

    v_def := replace(
      v_def,
      'COALESCE(v_mod->''snapshot'',''[]''::jsonb));',
      'COALESCE(v_mod->''snapshot'',''[]''::jsonb)) RETURNING id INTO v_sale_item_id;'
    );

    v_def := replace(
      v_def,
      '      v_cogs_total := v_cogs_total + COALESCE((v_res->>''total_cost'')::numeric, 0);',
      $block$      INSERT INTO public.sale_item_inventory_effects(
        sale_item_id, sale_id, branch_id, warehouse_id, target_type, target_id, quantity
      )
      SELECT v_sale_item_id, v_sale_id, p_branch_id, p_warehouse_id,
             'inventory_unit', (e->>'unit_id')::uuid, (e->>'quantity')::numeric
      FROM jsonb_array_elements(COALESCE(v_res->'units_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0
      ON CONFLICT (sale_item_id, target_type, target_id)
      DO UPDATE SET quantity = public.sale_item_inventory_effects.quantity + EXCLUDED.quantity;

      INSERT INTO public.sale_item_inventory_effects(
        sale_item_id, sale_id, branch_id, warehouse_id, target_type, target_id, quantity
      )
      SELECT v_sale_item_id, v_sale_id, p_branch_id, p_warehouse_id,
             'raw_material', (e->>'raw_material_id')::uuid, (e->>'quantity')::numeric
      FROM jsonb_array_elements(COALESCE(v_res->'raw_materials_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0
      ON CONFLICT (sale_item_id, target_type, target_id)
      DO UPDATE SET quantity = public.sale_item_inventory_effects.quantity + EXCLUDED.quantity;

      INSERT INTO public.sale_item_inventory_effects(
        sale_item_id, sale_id, branch_id, warehouse_id, target_type, target_id, quantity
      )
      SELECT v_sale_item_id, v_sale_id, p_branch_id, p_warehouse_id,
             'product', (e->>'product_id')::uuid, (e->>'quantity')::numeric
      FROM jsonb_array_elements(COALESCE(v_res->'ready_products_deducted', '[]'::jsonb)) e
      WHERE COALESCE((e->>'quantity')::numeric, 0) > 0
      ON CONFLICT (sale_item_id, target_type, target_id)
      DO UPDATE SET quantity = public.sale_item_inventory_effects.quantity + EXCLUDED.quantity;

      v_cogs_total := v_cogs_total + COALESCE((v_res->>'total_cost')::numeric, 0);$block$
    );

    EXECUTE v_def;
  END IF;
END
$patch_sale_effect_snapshot$;

-- Exact modern refund helper. If a sale predates inventory snapshots it delegates
-- to the legacy hybrid restore function from migration 0840.
CREATE OR REPLACE FUNCTION public._restore_refund_hybrid_inventory(
  p_sale_item_id uuid,
  p_sale_id uuid,
  p_product_id uuid,
  p_refund_qty numeric,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item_qty numeric(14,6);
  v_effect record;
  v_restore_qty numeric(14,6);
  v_unit_cost numeric(18,6);
  v_batch_number text;
  v_res jsonb;
  v_handled boolean := false;
  v_units_restored numeric(14,6) := 0;
  v_raws_restored numeric(14,6) := 0;
  v_products_restored numeric(14,6) := 0;
BEGIN
  SELECT quantity INTO v_item_qty
  FROM public.sale_items
  WHERE id = p_sale_item_id AND sale_id = p_sale_id AND product_id = p_product_id;

  IF v_item_qty IS NULL OR v_item_qty <= 0 OR p_refund_qty IS NULL OR p_refund_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_REFUND_ITEM');
  END IF;

  IF EXISTS (SELECT 1 FROM public.sale_item_inventory_effects WHERE sale_item_id = p_sale_item_id) THEN
    v_handled := true;

    FOR v_effect IN
      SELECT * FROM public.sale_item_inventory_effects
      WHERE sale_item_id = p_sale_item_id
      ORDER BY target_type, target_id
    LOOP
      v_restore_qty := ROUND(v_effect.quantity * p_refund_qty / v_item_qty, 6);
      IF v_restore_qty <= 0 THEN CONTINUE; END IF;

      IF v_effect.target_type = 'inventory_unit' THEN
        SELECT COALESCE(
          SUM((-iue.quantity) * COALESCE(iue.unit_cost, 0)) FILTER (WHERE iue.quantity < 0)
          / NULLIF(SUM(-iue.quantity) FILTER (WHERE iue.quantity < 0), 0),
          iu.cost_price,
          0
        ) INTO v_unit_cost
        FROM public.inventory_units iu
        LEFT JOIN public.inventory_unit_entries iue
          ON iue.unit_id = iu.id
         AND iue.branch_id = p_branch_id
         AND iue.warehouse_id = COALESCE(v_effect.warehouse_id, p_warehouse_id)
         AND iue.reference_type = 'sale'
         AND iue.reference_id = p_sale_id
        WHERE iu.id = v_effect.target_id
        GROUP BY iu.cost_price;

        v_batch_number := 'RF-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
        INSERT INTO public.inventory_unit_batches(
          unit_id, branch_id, warehouse_id, batch_number, quantity, unit_cost, production_date
        ) VALUES (
          v_effect.target_id, p_branch_id, COALESCE(v_effect.warehouse_id, p_warehouse_id),
          v_batch_number, v_restore_qty, COALESCE(v_unit_cost, 0), CURRENT_DATE
        );
        INSERT INTO public.inventory_unit_entries(
          unit_id, branch_id, warehouse_id, quantity, unit_cost,
          entry_type, reference_type, reference_id, reference_number,
          batch_number, created_by
        ) VALUES (
          v_effect.target_id, p_branch_id, COALESCE(v_effect.warehouse_id, p_warehouse_id),
          v_restore_qty, COALESCE(v_unit_cost, 0), 'refund', 'sale', p_sale_id,
          p_reference_number, v_batch_number, auth.uid()
        );
        v_units_restored := v_units_restored + v_restore_qty;

      ELSIF v_effect.target_type = 'raw_material' THEN
        SELECT COALESCE(
          SUM((-l.quantity) * COALESCE(l.unit_cost, 0)) FILTER (WHERE l.quantity < 0)
          / NULLIF(SUM(-l.quantity) FILTER (WHERE l.quantity < 0), 0),
          0
        ) INTO v_unit_cost
        FROM public.inventory_ledger l
        WHERE l.raw_material_id = v_effect.target_id
          AND l.branch_id = p_branch_id
          AND l.reference_type = 'sale'
          AND l.reference_id = p_sale_id;

        v_res := public._raw_add(
          v_effect.target_id, p_branch_id, v_restore_qty, COALESCE(v_unit_cost, 0),
          'RF-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
          CURRENT_DATE, NULL, 'refund', 'sale', p_sale_id,
          p_reference_number, auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN RETURN v_res; END IF;
        v_raws_restored := v_raws_restored + v_restore_qty;

      ELSIF v_effect.target_type = 'product' THEN
        SELECT COALESCE(
          SUM((-l.quantity) * COALESCE(l.unit_cost, 0)) FILTER (WHERE l.quantity < 0)
          / NULLIF(SUM(-l.quantity) FILTER (WHERE l.quantity < 0), 0),
          p.cost_price,
          0
        ) INTO v_unit_cost
        FROM public.products p
        LEFT JOIN public.inventory_ledger l
          ON l.product_id = p.id
         AND l.branch_id = p_branch_id
         AND l.reference_type = 'sale'
         AND l.reference_id = p_sale_id
        WHERE p.id = v_effect.target_id
        GROUP BY p.cost_price;

        v_res := public._product_inv_add(
          v_effect.target_id,
          COALESCE(v_effect.warehouse_id, p_warehouse_id),
          p_branch_id,
          v_restore_qty,
          COALESCE(v_unit_cost, 0),
          'RF-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
          NULL, NULL, 'refund', 'sale', p_sale_id, p_reference_number, auth.uid()
        );
        IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN RETURN v_res; END IF;
        v_products_restored := v_products_restored + v_restore_qty;
      END IF;
    END LOOP;

    RETURN jsonb_build_object(
      'success', true,
      'handled', true,
      'units_restored', v_units_restored,
      'raw_materials_restored', v_raws_restored,
      'products_restored', v_products_restored
    );
  END IF;

  -- Legacy sale: preserve the already-tested 0840 behavior.
  RETURN public._restore_refund_hybrid_inventory(
    p_sale_id, p_product_id, p_refund_qty, p_branch_id, p_warehouse_id, p_reference_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public._restore_refund_hybrid_inventory(uuid,uuid,uuid,numeric,uuid,uuid,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._restore_refund_hybrid_inventory(uuid,uuid,uuid,numeric,uuid,uuid,text)
  TO service_role, postgres;

-- Point the canonical refund flow at the line-aware helper. The surrounding
-- legacy fallback remains unchanged and still handles pre-snapshot sales.
DO $patch_refund_line_helper$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := E'public._restore_refund_hybrid_inventory(\n        p_sale_id,\n        v_item.product_id,';
  v_new text := E'public._restore_refund_hybrid_inventory(\n        v_item.id,\n        p_sale_id,\n        v_item.product_id,';
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid::regprocedure::text = 'process_refund(uuid,jsonb,text)';

  IF v_oid IS NULL THEN RAISE EXCEPTION 'process_refund(uuid,jsonb,text) not found'; END IF;
  v_def := pg_get_functiondef(v_oid);

  IF position('_restore_refund_hybrid_inventory(\n        v_item.id' in v_def) = 0 THEN
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund hybrid helper marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
    EXECUTE v_def;
  END IF;
END
$patch_refund_line_helper$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902121500_product_modifiers_atomic_security_hardening.sql
-- ----------------------------------------------------------------------------
-- Harden modifier administration before production rollout.
-- 1) Validate the complete configuration before deleting/replacing anything.
-- 2) Keep modifier inventory effects server-internal; POS clients only need the
--    public modifier catalog returned by get_product_modifiers().

REVOKE SELECT ON public.product_modifier_inventory_effects FROM authenticated;

CREATE OR REPLACE FUNCTION public.save_product_modifiers(p_product_id uuid, p_groups jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_role text;
  v_group jsonb;
  v_option jsonb;
  v_effect jsonb;
  v_group_id uuid;
  v_option_id uuid;
  v_target_id uuid;
  v_min integer;
  v_max integer;
  v_option_count integer;
  v_default_count integer;
  v_delta numeric;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG');
  END IF;

  SELECT p.branch_id
    INTO v_branch_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- Validation pass. No persistent mutation is allowed before this pass ends.
  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    IF jsonb_typeof(v_group) <> 'object'
       OR COALESCE(NULLIF(btrim(v_group->>'name'), ''), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_GROUP_NAME_REQUIRED');
    END IF;

    v_min := COALESCE((v_group->>'min_selections')::integer, 0);
    v_max := COALESCE((v_group->>'max_selections')::integer, 1);

    IF v_min < 0 OR v_max < 1 OR v_max < v_min THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;

    IF v_group ? 'options' AND jsonb_typeof(v_group->'options') <> 'array' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_OPTIONS');
    END IF;

    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE COALESCE((opt->>'is_default')::boolean, false))
      INTO v_option_count, v_default_count
    FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb)) AS options(opt);

    IF v_min > v_option_count OR v_max > GREATEST(v_option_count, 1) THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_GROUP_BOUNDS');
    END IF;

    IF v_default_count > v_max THEN
      RETURN jsonb_build_object('success', false, 'error', 'TOO_MANY_DEFAULT_MODIFIER_OPTIONS');
    END IF;

    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_option) <> 'object'
         OR COALESCE(NULLIF(btrim(v_option->>'name'), ''), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'MODIFIER_OPTION_NAME_REQUIRED');
      END IF;

      -- Force numeric/boolean validation before any DELETE/INSERT below.
      PERFORM COALESCE((v_option->>'price_delta')::numeric, 0);
      PERFORM COALESCE((v_option->>'is_default')::boolean, false);
      PERFORM COALESCE((v_option->>'sort_order')::integer, 0);

      IF v_option ? 'inventory_effects'
         AND jsonb_typeof(v_option->'inventory_effects') <> 'array' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
      END IF;

      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        IF jsonb_typeof(v_effect) <> 'object' THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;

        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        v_delta := COALESCE((v_effect->>'quantity_delta')::numeric, 0);

        IF v_target_id IS NULL OR v_delta = 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_INVENTORY_EFFECT');
        END IF;

        IF v_effect->>'target_type' = 'raw_material' THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.raw_materials
            WHERE id = v_target_id AND branch_id = v_branch_id
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
        ELSIF v_effect->>'target_type' = 'inventory_unit' THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.inventory_units
            WHERE id = v_target_id AND branch_id = v_branch_id
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVENTORY_UNIT_NOT_IN_BRANCH');
          END IF;
        ELSE
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_TARGET_TYPE');
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- Mutation pass starts only after the entire payload is known-valid.
  DELETE FROM public.product_modifier_groups
  WHERE product_id = p_product_id AND branch_id = v_branch_id;

  FOR v_group IN SELECT * FROM jsonb_array_elements(p_groups)
  LOOP
    INSERT INTO public.product_modifier_groups(
      branch_id, product_id, name, name_en,
      min_selections, max_selections, sort_order, is_active
    ) VALUES (
      v_branch_id,
      p_product_id,
      btrim(v_group->>'name'),
      NULLIF(btrim(v_group->>'name_en'), ''),
      COALESCE((v_group->>'min_selections')::integer, 0),
      COALESCE((v_group->>'max_selections')::integer, 1),
      COALESCE((v_group->>'sort_order')::integer, 0),
      true
    ) RETURNING id INTO v_group_id;

    FOR v_option IN SELECT * FROM jsonb_array_elements(COALESCE(v_group->'options', '[]'::jsonb))
    LOOP
      INSERT INTO public.product_modifier_options(
        branch_id, group_id, name, name_en,
        price_delta, is_default, sort_order, is_active
      ) VALUES (
        v_branch_id,
        v_group_id,
        btrim(v_option->>'name'),
        NULLIF(btrim(v_option->>'name_en'), ''),
        COALESCE((v_option->>'price_delta')::numeric, 0),
        COALESCE((v_option->>'is_default')::boolean, false),
        COALESCE((v_option->>'sort_order')::integer, 0),
        true
      ) RETURNING id INTO v_option_id;

      FOR v_effect IN SELECT * FROM jsonb_array_elements(COALESCE(v_option->'inventory_effects', '[]'::jsonb))
      LOOP
        v_target_id := NULLIF(v_effect->>'target_id', '')::uuid;
        v_delta := (v_effect->>'quantity_delta')::numeric;

        IF v_effect->>'target_type' = 'raw_material' THEN
          INSERT INTO public.product_modifier_inventory_effects(
            branch_id, option_id, target_type, raw_material_id, quantity_delta
          ) VALUES (
            v_branch_id, v_option_id, 'raw_material', v_target_id, v_delta
          );
        ELSE
          INSERT INTO public.product_modifier_inventory_effects(
            branch_id, option_id, target_type, inventory_unit_id, quantity_delta
          ) VALUES (
            v_branch_id, v_option_id, 'inventory_unit', v_target_id, v_delta
          );
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODIFIER_CONFIG_VALUE');
  WHEN OTHERS THEN
    -- Because this block has an EXCEPTION handler, PostgreSQL rolls back all
    -- persistent statements executed inside the block before entering here.
    RETURN jsonb_build_object('success', false, 'error', 'SAVE_MODIFIERS_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.save_product_modifiers(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_modifiers(uuid, jsonb) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902130000_product_modifier_branch_consistency.sql
-- ----------------------------------------------------------------------------
-- Enforce branch consistency for modifier definitions at the database layer.
-- RPC validation remains the normal write path, but these triggers prevent
-- cross-branch configuration even if a future privileged writer bypasses it.

CREATE OR REPLACE FUNCTION public._enforce_modifier_group_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product_branch uuid;
BEGIN
  SELECT branch_id INTO v_product_branch
  FROM public.products
  WHERE id = NEW.product_id;

  IF v_product_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_PRODUCT_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_product_branch THEN
    RAISE EXCEPTION 'MODIFIER_GROUP_BRANCH_MISMATCH';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._enforce_modifier_option_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group_branch uuid;
BEGIN
  SELECT branch_id INTO v_group_branch
  FROM public.product_modifier_groups
  WHERE id = NEW.group_id;

  IF v_group_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_GROUP_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_group_branch THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_BRANCH_MISMATCH';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._enforce_modifier_effect_branch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_option_branch uuid;
  v_target_branch uuid;
BEGIN
  SELECT branch_id INTO v_option_branch
  FROM public.product_modifier_options
  WHERE id = NEW.option_id;

  IF v_option_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_option_branch THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_BRANCH_MISMATCH';
  END IF;

  IF NEW.target_type = 'raw_material' THEN
    SELECT branch_id INTO v_target_branch
    FROM public.raw_materials
    WHERE id = NEW.raw_material_id;
  ELSIF NEW.target_type = 'inventory_unit' THEN
    SELECT branch_id INTO v_target_branch
    FROM public.inventory_units
    WHERE id = NEW.inventory_unit_id;
  ELSE
    RAISE EXCEPTION 'INVALID_MODIFIER_TARGET_TYPE';
  END IF;

  IF v_target_branch IS NULL THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_TARGET_NOT_FOUND';
  END IF;
  IF NEW.branch_id <> v_target_branch THEN
    RAISE EXCEPTION 'MODIFIER_EFFECT_TARGET_BRANCH_MISMATCH';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_modifier_group_branch_consistency ON public.product_modifier_groups;
CREATE TRIGGER trg_modifier_group_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, product_id
ON public.product_modifier_groups
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_group_branch();

DROP TRIGGER IF EXISTS trg_modifier_option_branch_consistency ON public.product_modifier_options;
CREATE TRIGGER trg_modifier_option_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, group_id
ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_option_branch();

DROP TRIGGER IF EXISTS trg_modifier_effect_branch_consistency ON public.product_modifier_inventory_effects;
CREATE TRIGGER trg_modifier_effect_branch_consistency
BEFORE INSERT OR UPDATE OF branch_id, option_id, target_type, raw_material_id, inventory_unit_id
ON public.product_modifier_inventory_effects
FOR EACH ROW EXECUTE FUNCTION public._enforce_modifier_effect_branch();

-- Validate any existing rows before considering the migration successful.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_groups g
    JOIN public.products p ON p.id = g.product_id
    WHERE g.branch_id <> p.branch_id
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_GROUP_BRANCH_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_options o
    JOIN public.product_modifier_groups g ON g.id = o.group_id
    WHERE o.branch_id <> g.branch_id
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_OPTION_BRANCH_MISMATCH';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_modifier_inventory_effects e
    JOIN public.product_modifier_options o ON o.id = e.option_id
    LEFT JOIN public.raw_materials rm ON rm.id = e.raw_material_id
    LEFT JOIN public.inventory_units iu ON iu.id = e.inventory_unit_id
    WHERE e.branch_id <> o.branch_id
       OR (e.target_type = 'raw_material' AND (rm.id IS NULL OR rm.branch_id <> e.branch_id))
       OR (e.target_type = 'inventory_unit' AND (iu.id IS NULL OR iu.branch_id <> e.branch_id))
  ) THEN
    RAISE EXCEPTION 'EXISTING_MODIFIER_EFFECT_BRANCH_MISMATCH';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._enforce_modifier_group_branch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_modifier_option_branch() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_modifier_effect_branch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_group_branch() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_option_branch() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._enforce_modifier_effect_branch() TO service_role, postgres;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902132000_cancel_sent_item_exact_line.sql
-- ----------------------------------------------------------------------------
-- Cancel an exact sent order-item line. This removes the product-id ambiguity
-- when the same product appears more than once with different modifiers.
-- KDS remains state-only: this function never mutates inventory.

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item_exact(
  p_order_id uuid,
  p_order_item_id uuid,
  p_quantity numeric,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_product_name text;
  v_request public.approval_requests%ROWTYPE;
  v_request_result jsonb;
  v_new_qty numeric(14,4);
  v_new_discount numeric(14,4);
  v_new_total numeric(14,4);
  v_subtotal numeric(14,4);
  v_total numeric(14,4);
  v_note text;
  v_privileged boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;
  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.status NOT IN ('open', 'held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;
  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT oi.* INTO v_item
  FROM public.order_items oi
  WHERE oi.id = p_order_item_id
    AND oi.order_id = p_order_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    )
  FOR UPDATE;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;

  IF p_quantity > v_item.quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'VOID_QUANTITY_EXCEEDS_SENT',
      'available_quantity', v_item.quantity
    );
  END IF;

  SELECT name INTO v_product_name FROM public.products WHERE id = v_item.product_id;
  v_product_name := COALESCE(v_product_name, 'Unknown product');
  v_privileged := public.is_pos_admin() OR public.can_permission('approvals.review');

  IF NOT v_privileged THEN
    SELECT * INTO v_request
    FROM public.approval_requests ar
    WHERE ar.requester_id = auth.uid()
      AND ar.branch_id = v_order.branch_id
      AND ar.action_type = 'cancel_sent_item'
      AND ar.entity_type = 'order_item'
      AND ar.entity_id = v_item.id
      AND ar.status = 'approved'
      AND ar.expires_at > now()
      AND ar.payload->>'order_id' = p_order_id::text
      AND ar.payload->>'order_item_id' = v_item.id::text
      AND abs(COALESCE((ar.payload->>'quantity')::numeric, -1) - p_quantity) < 0.0001
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      v_request_result := public.request_manager_approval(
        'cancel_sent_item',
        'order_item',
        v_item.id,
        jsonb_build_object(
          'order_id', p_order_id,
          'order_item_id', v_item.id,
          'product_id', v_item.product_id,
          'product_name', v_product_name,
          'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
          'modifiers_snapshot', COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
          'quantity', p_quantity
        ),
        trim(p_reason)
      );

      RETURN jsonb_build_object(
        'success', false,
        'error', 'MANAGER_APPROVAL_REQUIRED',
        'action', 'cancel_sent_item',
        'request_id', v_request_result->>'request_id',
        'status', COALESCE(v_request_result->>'status', 'pending')
      );
    END IF;

    v_request_result := public.consume_manager_approval(
      v_request.id,
      'cancel_sent_item',
      v_item.id
    );
    IF COALESCE((v_request_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN COALESCE(v_request_result, jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED'));
    END IF;
  END IF;

  PERFORM set_config('app.approved_sent_item_void', '1', true);
  v_new_qty := v_item.quantity - p_quantity;

  IF v_new_qty <= 0 THEN
    DELETE FROM public.order_items WHERE id = v_item.id;
  ELSE
    v_new_discount := CASE
      WHEN v_item.quantity > 0 THEN round((v_item.discount_amount * v_new_qty / v_item.quantity)::numeric, 4)
      ELSE 0
    END;
    v_new_total := round((v_new_qty * v_item.unit_price - v_new_discount)::numeric, 4);
    UPDATE public.order_items
    SET quantity = v_new_qty,
        discount_amount = v_new_discount,
        total = GREATEST(v_new_total, 0)
    WHERE id = v_item.id;
  END IF;

  SELECT COALESCE(sum(quantity * unit_price), 0)
  INTO v_subtotal
  FROM public.order_items
  WHERE order_id = p_order_id;

  v_total := GREATEST(
    v_subtotal - COALESCE(v_order.discount_amount, 0) + COALESCE(v_order.tax_amount, 0),
    0
  );

  v_note := format(
    '[Kitchen void: %s x %s - %s]',
    trim(to_char(p_quantity, 'FM999999990.####')),
    v_product_name,
    trim(p_reason)
  );

  UPDATE public.orders
  SET subtotal = v_subtotal,
      total = v_total,
      notes = concat_ws(E'\n', NULLIF(notes, ''), v_note),
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.order_kitchen_voids(
    branch_id, order_id, order_item_id, product_id, product_name, unit_name,
    quantity, reason, voided_by, approval_request_id
  ) VALUES (
    v_order.branch_id, p_order_id, v_item.id, v_item.product_id,
    v_product_name, COALESCE(v_item.unit_name, 'piece'), p_quantity,
    trim(p_reason), auth.uid(), CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'SENT_ITEM_VOIDED', 'order_item', v_item.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'order_item_id', v_item.id,
      'product_id', v_item.product_id,
      'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
      'quantity', p_quantity,
      'reason', trim(p_reason),
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
      'inventory_changed', false
    ),
    v_order.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'order_item_id', v_item.id,
    'product_id', v_item.product_id,
    'voided_quantity', p_quantity,
    'remaining_quantity', GREATEST(v_new_qty, 0),
    'inventory_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item_exact(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item_exact(uuid,uuid,numeric,text) TO authenticated, service_role;

-- Keep the legacy product-targeted RPC executable during the UI cutover so
-- existing deployed clients do not break. New code must use the exact-line RPC.
REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902133000_modifier_open_order_immutability.sql
-- ----------------------------------------------------------------------------
-- Modifier option ids are persisted on open/held order items and are resolved
-- again at sale completion. Prevent catalogue edits from deleting or moving an
-- option that is still referenced by an editable order, otherwise a valid
-- open order could become unsellable or resolve to a different configuration.

CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.status IN ('open', 'held')
      AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
  ) THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_modifier_option_open_order_delete ON public.product_modifier_options;
CREATE TRIGGER trg_protect_modifier_option_open_order_delete
BEFORE DELETE ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._protect_modifier_option_open_order_reference();

-- Moving an option to another group or branch changes its meaning just as much
-- as deleting it, so protect identity-changing updates as well.
CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (NEW.group_id, NEW.branch_id) IS DISTINCT FROM (OLD.group_id, OLD.branch_id)
     AND EXISTS (
       SELECT 1
       FROM public.order_items oi
       JOIN public.orders o ON o.id = oi.order_id
       WHERE o.status IN ('open', 'held')
         AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
     )
  THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_modifier_option_open_order_update ON public.product_modifier_options;
CREATE TRIGGER trg_protect_modifier_option_open_order_update
BEFORE UPDATE OF group_id, branch_id ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._protect_modifier_option_open_order_update();

REVOKE ALL ON FUNCTION public._protect_modifier_option_open_order_reference() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._protect_modifier_option_open_order_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._protect_modifier_option_open_order_reference() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._protect_modifier_option_open_order_update() TO service_role, postgres;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902134000_legacy_sent_void_ambiguity_guard.sql
-- ----------------------------------------------------------------------------
-- Safety guard for older deployed clients that still call the product-targeted
-- cancel_sent_order_item RPC. If more than one sent order-item line exists for
-- the same product (for example Burger Single + Burger Double), never guess.
-- Force the client to use cancel_sent_order_item_exact instead.

CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_product_name text;
  v_request public.approval_requests%ROWTYPE;
  v_request_result jsonb;
  v_new_qty numeric(14,4);
  v_new_discount numeric(14,4);
  v_new_total numeric(14,4);
  v_subtotal numeric(14,4);
  v_total numeric(14,4);
  v_note text;
  v_privileged boolean := false;
  v_matching_lines integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = auth.uid() AND is_active = true;
  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF v_order.status NOT IN ('open', 'held') THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE');
  END IF;
  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT count(*) INTO v_matching_lines
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = oi.id);

  IF v_matching_lines = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;
  IF v_matching_lines > 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'AMBIGUOUS_SENT_ITEM',
      'detail', 'Use cancel_sent_order_item_exact with order_item_id',
      'matching_lines', v_matching_lines
    );
  END IF;

  SELECT oi.* INTO v_item
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = oi.id)
  LIMIT 1
  FOR UPDATE;

  IF p_quantity > v_item.quantity THEN
    RETURN jsonb_build_object('success', false, 'error', 'VOID_QUANTITY_EXCEEDS_SENT', 'available_quantity', v_item.quantity);
  END IF;

  SELECT name INTO v_product_name FROM public.products WHERE id = p_product_id;
  v_product_name := COALESCE(v_product_name, 'Unknown product');
  v_privileged := public.is_pos_admin() OR public.can_permission('approvals.review');

  IF NOT v_privileged THEN
    SELECT * INTO v_request
    FROM public.approval_requests ar
    WHERE ar.requester_id = auth.uid()
      AND ar.branch_id = v_order.branch_id
      AND ar.action_type = 'cancel_sent_item'
      AND ar.entity_type = 'order_item'
      AND ar.entity_id = v_item.id
      AND ar.status = 'approved'
      AND ar.expires_at > now()
      AND ar.payload->>'order_id' = p_order_id::text
      AND ar.payload->>'product_id' = p_product_id::text
      AND abs(COALESCE((ar.payload->>'quantity')::numeric, -1) - p_quantity) < 0.0001
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      v_request_result := public.request_manager_approval(
        'cancel_sent_item', 'order_item', v_item.id,
        jsonb_build_object(
          'order_id', p_order_id,
          'order_item_id', v_item.id,
          'product_id', p_product_id,
          'product_name', v_product_name,
          'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
          'modifiers_snapshot', COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
          'quantity', p_quantity
        ),
        trim(p_reason)
      );
      RETURN jsonb_build_object(
        'success', false, 'error', 'MANAGER_APPROVAL_REQUIRED',
        'action', 'cancel_sent_item',
        'request_id', v_request_result->>'request_id',
        'status', COALESCE(v_request_result->>'status', 'pending')
      );
    END IF;

    v_request_result := public.consume_manager_approval(v_request.id, 'cancel_sent_item', v_item.id);
    IF COALESCE((v_request_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN COALESCE(v_request_result, jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED'));
    END IF;
  END IF;

  PERFORM set_config('app.approved_sent_item_void', '1', true);
  v_new_qty := v_item.quantity - p_quantity;
  IF v_new_qty <= 0 THEN
    DELETE FROM public.order_items WHERE id = v_item.id;
  ELSE
    v_new_discount := CASE WHEN v_item.quantity > 0 THEN round((v_item.discount_amount * v_new_qty / v_item.quantity)::numeric, 4) ELSE 0 END;
    v_new_total := round((v_new_qty * v_item.unit_price - v_new_discount)::numeric, 4);
    UPDATE public.order_items
    SET quantity = v_new_qty, discount_amount = v_new_discount, total = GREATEST(v_new_total, 0)
    WHERE id = v_item.id;
  END IF;

  SELECT COALESCE(sum(quantity * unit_price), 0) INTO v_subtotal
  FROM public.order_items WHERE order_id = p_order_id;
  v_total := GREATEST(v_subtotal - COALESCE(v_order.discount_amount, 0) + COALESCE(v_order.tax_amount, 0), 0);
  v_note := format('[Kitchen void: %s x %s - %s]', trim(to_char(p_quantity, 'FM999999990.####')), v_product_name, trim(p_reason));

  UPDATE public.orders
  SET subtotal = v_subtotal, total = v_total,
      notes = concat_ws(E'\n', NULLIF(notes, ''), v_note), updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.order_kitchen_voids(
    branch_id, order_id, order_item_id, product_id, product_name, unit_name,
    quantity, reason, voided_by, approval_request_id
  ) VALUES (
    v_order.branch_id, p_order_id, v_item.id, p_product_id, v_product_name,
    COALESCE(v_item.unit_name, 'piece'), p_quantity, trim(p_reason), auth.uid(),
    CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'SENT_ITEM_VOIDED', 'order_item', v_item.id,
    jsonb_build_object(
      'order_id', p_order_id, 'order_item_id', v_item.id, 'product_id', p_product_id,
      'modifier_option_ids', COALESCE(v_item.modifier_option_ids, ARRAY[]::uuid[]),
      'quantity', p_quantity, 'reason', trim(p_reason),
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
      'inventory_changed', false
    ),
    v_order.branch_id
  );

  RETURN jsonb_build_object(
    'success', true, 'order_id', p_order_id, 'order_item_id', v_item.id,
    'product_id', p_product_id, 'voided_quantity', p_quantity,
    'remaining_quantity', GREATEST(v_new_qty, 0), 'inventory_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902135000_lock_sent_order_item_mutation_guard.sql
-- ----------------------------------------------------------------------------
-- Keep the sent-order-item mutation guard internal.
-- Public clients must use cancel_sent_order_item / cancel_sent_order_item_exact,
-- which enforce branch access, approval rules, audit logging, and exact-line targeting.

REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902140000_product_modifier_admin_editor_rpc.sql
-- ----------------------------------------------------------------------------
-- Secure administration read surface for product modifiers.
-- The POS catalog continues to use get_product_modifiers(), which never exposes
-- inventory effects. This RPC is intentionally restricted to privileged roles
-- and returns the editable configuration only for products in accessible branches.

CREATE OR REPLACE FUNCTION public.get_product_modifiers_admin(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_role text;
  v_groups jsonb;
BEGIN
  SELECT branch_id INTO v_branch_id
  FROM public.products
  WHERE id = p_product_id;

  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT COALESCE(jsonb_agg(group_json ORDER BY sort_order, id), '[]'::jsonb)
  INTO v_groups
  FROM (
    SELECT
      g.id,
      g.sort_order,
      jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'name_en', g.name_en,
        'min_selections', g.min_selections,
        'max_selections', g.max_selections,
        'sort_order', g.sort_order,
        'options', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', o.id,
              'name', o.name,
              'name_en', o.name_en,
              'price_delta', o.price_delta,
              'is_default', o.is_default,
              'sort_order', o.sort_order,
              'inventory_effects', COALESCE((
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'target_type', e.target_type,
                    'target_id', CASE
                      WHEN e.target_type = 'raw_material' THEN e.raw_material_id
                      ELSE e.inventory_unit_id
                    END,
                    'quantity_delta', e.quantity_delta
                  ) ORDER BY e.id
                )
                FROM public.product_modifier_inventory_effects e
                WHERE e.option_id = o.id
              ), '[]'::jsonb)
            ) ORDER BY o.sort_order, o.id
          )
          FROM public.product_modifier_options o
          WHERE o.group_id = g.id AND o.is_active = true
        ), '[]'::jsonb)
      ) AS group_json
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id
      AND g.branch_id = v_branch_id
      AND g.is_active = true
  ) q;

  RETURN jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'branch_id', v_branch_id,
    'groups', v_groups
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_modifiers_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_modifiers_admin(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902141000_fix_order_modifier_authoritative_pricing.sql
-- ----------------------------------------------------------------------------
-- Fix trigger ordering regression between the P2 base-price trigger and the
-- modifier-price trigger. PostgreSQL executes same-timing triggers by name, so
-- trg_order_items_authoritative_price could overwrite the modifier-aware price
-- back to the base product price. Consolidate pricing into one authoritative
-- trigger and remove the redundant modifier trigger.

CREATE OR REPLACE FUNCTION public._reprice_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_base_price numeric(14,2);
  v_mod jsonb;
BEGIN
  SELECT o.branch_id INTO v_branch_id
  FROM public.orders o
  WHERE o.id = NEW.order_id;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT p.sale_price INTO v_base_price
  FROM public.products p
  WHERE p.id = NEW.product_id
    AND p.branch_id = v_branch_id
    AND p.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH';
  END IF;
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  v_mod := public.resolve_product_modifiers(
    NEW.product_id,
    v_branch_id,
    to_jsonb(COALESCE(NEW.modifier_option_ids, '{}'::uuid[]))
  );
  IF COALESCE((v_mod->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'MODIFIER_VALIDATION_FAILED: %', COALESCE(v_mod->>'error', 'unknown');
  END IF;

  NEW.modifiers_snapshot := COALESCE(v_mod->'snapshot', '[]'::jsonb);
  NEW.unit_price := ROUND(
    GREATEST(COALESCE(v_base_price, 0) + COALESCE((v_mod->>'price_delta')::numeric, 0), 0),
    2
  );
  NEW.discount_amount := ROUND(
    LEAST(GREATEST(COALESCE(NEW.discount_amount, 0), 0), NEW.quantity * NEW.unit_price),
    2
  );
  NEW.bonus_quantity := GREATEST(COALESCE(NEW.bonus_quantity, 0), 0);
  NEW.total := ROUND(NEW.quantity * NEW.unit_price - NEW.discount_amount, 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_item_modifier_price ON public.order_items;
DROP TRIGGER IF EXISTS trg_order_items_authoritative_price ON public.order_items;
CREATE TRIGGER trg_order_items_authoritative_price
BEFORE INSERT OR UPDATE OF product_id, quantity, unit_price, discount_amount, bonus_quantity, total, modifier_option_ids
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._reprice_order_item();

REVOKE ALL ON FUNCTION public._reprice_order_item() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._reprice_order_item() TO service_role, postgres;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902143000_accounting_kds_station_assignments.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902143500_kds_queue_legacy_compat.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902144000_kds_empty_legacy_order_compat.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902180000_financial_visibility_sales.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902183000_financial_visibility_related_reads.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902184500_financial_visibility_reporting_invoker.sql
-- ----------------------------------------------------------------------------
-- Financial Visibility Policy — phase 3
--
-- Read/report RPCs must execute with caller privileges so the restrictive RLS
-- policies added by the previous phases are effective inside reports as well.
-- This allowlist intentionally excludes every operational/posting/mutation RPC.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'get_journals',
        'get_general_ledger',
        'get_trial_balance',
        'get_trial_balance_summary',
        'get_income_statement',
        'get_balance_sheet',
        'get_ar_aging',
        'get_ap_aging',
        'get_aging_summary',
        'get_cash_flow',
        'get_party_statement',
        'get_treasury_balances',
        'get_bank_reconciliation'
      ]::text[])
  LOOP
    EXECUTE format('ALTER FUNCTION %s SECURITY INVOKER', r.fn);
  END LOOP;
END
$$;

-- Keep the report surface executable only by the roles it already serves.
-- Changing SECURITY mode does not change grants; this block merely ensures
-- PUBLIC/anon cannot gain access through an old broad grant while authenticated
-- callers keep the existing application contract.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'get_journals',
        'get_general_ledger',
        'get_trial_balance',
        'get_trial_balance_summary',
        'get_income_statement',
        'get_balance_sheet',
        'get_ar_aging',
        'get_ap_aging',
        'get_aging_summary',
        'get_cash_flow',
        'get_party_statement',
        'get_treasury_balances',
        'get_bank_reconciliation'
      ]::text[])
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.fn);
  END LOOP;
END
$$;

COMMENT ON SCHEMA private IS
  'Internal helpers. Financial visibility helpers are read-side predicates and are not public RPC APIs.';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902190000_financial_visibility_order_history.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902222000_financial_visibility_admin_controls.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902222500_kitchen_station_editor_context.sql
-- ----------------------------------------------------------------------------
-- Kitchen station editor context
--
-- The existing assignment model is already branch-aware. This RPC exposes the
-- branch, users, and product categories needed by the editor in one guarded
-- read so the UI does not depend on the global header branch selector or direct
-- cross-table reads.

CREATE OR REPLACE FUNCTION public.get_kitchen_station_editor_context(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_branch jsonb;
  v_users jsonb;
  v_categories jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR p_branch_id IS NULL
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT jsonb_build_object('id', b.id, 'name', b.name)
    INTO v_branch
  FROM public.branches b
  WHERE b.id = p_branch_id;

  IF v_branch IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', u.id,
        'full_name', u.full_name,
        'email', u.email,
        'role', u.role
      ) ORDER BY COALESCE(NULLIF(u.full_name, ''), u.email), u.id
    ),
    '[]'::jsonb
  )
  INTO v_users
  FROM public.users u
  WHERE u.branch_id = p_branch_id
    AND u.is_active = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'name_en', c.name_en,
        'kitchen_station_id', c.kitchen_station_id
      ) ORDER BY c.name, c.id
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM public.categories c
  WHERE c.branch_id = p_branch_id;

  RETURN jsonb_build_object(
    'success', true,
    'branch', v_branch,
    'users', v_users,
    'categories', v_categories
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_station_editor_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_station_editor_context(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_kitchen_station_editor_context(uuid) IS
  'Branch-scoped kitchen station editor context: branch, active users, and product categories. No write side effects.';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902234000_branch_hard_delete.sql
-- ----------------------------------------------------------------------------
-- Hard-delete a branch and every public row directly linked to it.
-- Branch deletion is an explicit destructive admin operation; do not use for soft disable.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT tc.table_schema, tc.table_name, tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.constraint_schema = kcu.constraint_schema
    JOIN information_schema.referential_constraints rc
      ON rc.constraint_name = tc.constraint_name
     AND rc.constraint_schema = tc.constraint_schema
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name
     AND ccu.constraint_schema = tc.constraint_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = 'public'
      AND ccu.table_schema = 'public'
      AND ccu.table_name = 'branches'
      AND kcu.column_name = 'branch_id'
      AND rc.delete_rule <> 'CASCADE'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', r.table_schema, r.table_name, r.constraint_name);
    EXECUTE format(
      'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE',
      r.table_schema, r.table_name, r.constraint_name
    );
  END LOOP;
END $$;

-- Preserve the normal safety guards, but do not let them block rows that are
-- being removed only because their parent branch itself is being deleted.
CREATE OR REPLACE FUNCTION public.protect_system_accounts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.is_system THEN
    IF OLD.branch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED: % (%)', OLD.code, OLD.name;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.is_system THEN
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.account_type IS DISTINCT FROM OLD.account_type THEN
      RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED: % (%)', OLD.code, OLD.name;
    END IF;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    NEW.name := btrim(NEW.name);
    IF NEW.name = '' THEN RAISE EXCEPTION 'ACCOUNT_NAME_REQUIRED'; END IF;
    NEW.code := upper(btrim(NEW.code));
    IF NEW.code = '' THEN RAISE EXCEPTION 'ACCOUNT_CODE_REQUIRED'; END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_table_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.branch_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
    RETURN OLD;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = OLD.id AND status IN ('open', 'held')
  ) THEN
    RAISE EXCEPTION 'Cannot delete a table with open orders.';
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.branch_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = OLD.branch_id) THEN
    RETURN OLD;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.status IN ('open', 'held')
      AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
  ) THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_user_branch uuid;
  v_org uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT role, branch_id
    INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF v_role NOT IN ('super_admin', 'owner') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

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

  IF v_role = 'owner' AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  DELETE FROM public.branches WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'organization_id', v_org);
EXCEPTION WHEN foreign_key_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DELETE_BLOCKED', 'detail', SQLERRM);
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902234500_costing_sales_summary_rls.sql
-- ----------------------------------------------------------------------------
-- Costing sales reads must obey the same row visibility policy as sales/history.

ALTER FUNCTION public.get_order_margin(uuid, date, date) SECURITY INVOKER;
ALTER FUNCTION public.get_order_margin(uuid, date, date) SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION public.get_order_margin(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_order_margin(uuid, date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_order_margin(uuid, date, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_costing_sales_summary(
  p_branch_id uuid DEFAULT NULL,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
WITH scoped_sales AS (
  SELECT
    s.id,
    GREATEST(COALESCE(s.total, 0) - COALESCE(s.tax_amount, 0), 0)::numeric AS net_sales
  FROM public.sales s
  WHERE (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    AND (p_from IS NULL OR s.created_at::date >= p_from)
    AND (p_to IS NULL OR s.created_at::date <= p_to)
    AND COALESCE(s.status, '') NOT IN ('returned', 'cancelled')
), sale_costs AS (
  SELECT
    il.reference_id AS sale_id,
    GREATEST(COALESCE(-SUM(il.total_cost), 0), 0)::numeric AS cogs
  FROM public.inventory_ledger il
  JOIN scoped_sales ss ON ss.id = il.reference_id
  WHERE il.entry_type = 'sale'
    AND il.reference_type = 'sale'
  GROUP BY il.reference_id
), totals AS (
  SELECT
    COUNT(*)::integer AS sales_count,
    ROUND(COALESCE(SUM(ss.net_sales), 0), 2) AS net_sales,
    ROUND(COALESCE(SUM(sc.cogs), 0), 2) AS cogs
  FROM scoped_sales ss
  LEFT JOIN sale_costs sc ON sc.sale_id = ss.id
)
SELECT jsonb_build_object(
  'sales_count', sales_count,
  'net_sales', net_sales,
  'cogs', cogs,
  'ratio', CASE WHEN net_sales > 0 THEN ROUND(cogs * 100.0 / net_sales, 2) ELSE 0 END
)
FROM totals;
$$;

REVOKE ALL ON FUNCTION public.get_costing_sales_summary(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_costing_sales_summary(uuid, date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_costing_sales_summary(uuid, date, date) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903080000_fix_branch_hard_delete_acceptance.sql
-- ----------------------------------------------------------------------------
-- Production acceptance exposed two gaps in the original branch hard delete:
-- 1) journal_entry_lines.account_id can block chart_of_accounts cascade ordering.
-- 2) deleting public.users does not remove their Supabase Auth identities.
-- Keep the operation explicit, protected and atomic.

CREATE OR REPLACE FUNCTION public.delete_branch_cascade(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_user_branch uuid;
  v_org uuid;
  v_user_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_auth integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT role, branch_id
    INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active = true;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF v_role NOT IN ('super_admin', 'owner') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

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

  IF v_role = 'owner' AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[])
    INTO v_user_ids
  FROM public.users
  WHERE branch_id = p_branch_id;

  -- Delete accounting roots first. Their lines cascade from journal_entries,
  -- preventing chart_of_accounts from being deleted while still referenced.
  DELETE FROM public.journal_entries WHERE branch_id = p_branch_id;

  -- Direct branch-owned rows use ON DELETE CASCADE (enforced by the previous
  -- hard-delete migration), including public.users.
  DELETE FROM public.branches WHERE id = p_branch_id;

  -- Public profile deletion alone must not leave login identities behind.
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

REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_branch_cascade(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_branch_cascade(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903083000_production_acceptance_regressions.sql
-- ----------------------------------------------------------------------------
-- Fix regressions proven by the real Production acceptance branch on 2026-09-03.

-- 1) Floor-plan managers must be able to manage dining areas in their branch.
DROP POLICY IF EXISTS auth_insert_dining_areas ON public.dining_areas;
CREATE POLICY auth_insert_dining_areas ON public.dining_areas
FOR INSERT TO authenticated
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_update_dining_areas ON public.dining_areas;
CREATE POLICY auth_update_dining_areas ON public.dining_areas
FOR UPDATE TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
)
WITH CHECK (
  public.is_platform_admin()
  OR (public.can_permission('floor_plan.manage') AND public.user_may_access_branch(branch_id))
);

-- 2) Direct table reads must honor the same permission model as navigation/UI.
DROP POLICY IF EXISTS auth_select_products ON public.products;
CREATE POLICY auth_select_products ON public.products
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('products.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_purchases ON public.purchases;
CREATE POLICY auth_select_purchases ON public.purchases
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('purchases.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_sales ON public.sales;
CREATE POLICY auth_select_sales ON public.sales
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('sales.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_users ON public.users;
CREATE POLICY auth_select_users ON public.users
FOR SELECT TO authenticated
USING (
  id = auth.uid()
  OR public.is_platform_admin()
  OR (public.can_permission('users.view') AND public.user_may_access_branch(branch_id))
);

DROP POLICY IF EXISTS auth_select_audit_log ON public.audit_log;
CREATE POLICY auth_select_audit_log ON public.audit_log
FOR SELECT TO authenticated
USING (
  public.is_platform_admin()
  OR (public.can_permission('audit.view') AND public.user_may_access_branch(branch_id))
);

-- 3) The paid state of a linked order must follow the authoritative sale row.
-- Keep the existing process_sale validation/pricing flow and only synchronize
-- the linked order after the core transaction succeeds.
CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_customer_id uuid,
  p_salesperson_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_discount_type text,
  p_tax_amount numeric,
  p_bonus_amount numeric,
  p_total numeric,
  p_paid_amount numeric,
  p_payment_method text,
  p_status text,
  p_items jsonb,
  p_shift_id uuid DEFAULT NULL::uuid,
  p_order_type text DEFAULT 'takeaway'::text,
  p_table_id uuid DEFAULT NULL::uuid,
  p_order_id uuid DEFAULT NULL::uuid,
  p_guest_count integer DEFAULT NULL::integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_req_id uuid;
  v_result jsonb;
  v_email text;
  v_item jsonb;
  v_product_id uuid;
  v_qty numeric;
  v_price numeric;
  v_mod jsonb;
  v_line_discount numeric;
  v_server_subtotal numeric(14,2) := 0;
  v_sale_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',false,'error','EMPTY_CART'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := NULLIF(v_item->>'product_id','')::uuid;
    v_qty := COALESCE((v_item->>'quantity')::numeric,0);
    IF v_product_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','INVALID_PRODUCT'); END IF;
    IF v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY'); END IF;
    SELECT sale_price INTO v_price FROM public.products
    WHERE id=v_product_id AND branch_id=p_branch_id AND is_active=true;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;
    v_mod := public.resolve_product_modifiers(v_product_id,p_branch_id,COALESCE(v_item->'modifier_option_ids','[]'::jsonb));
    IF COALESCE((v_mod->>'success')::boolean,false) IS NOT TRUE THEN RETURN v_mod; END IF;
    v_price := GREATEST(COALESCE(v_price,0)+COALESCE((v_mod->>'price_delta')::numeric,0),0);
    v_line_discount := ROUND(LEAST(GREATEST(COALESCE((v_item->>'discount_amount')::numeric,0),0),v_qty*v_price),2);
    IF v_line_discount > 0 AND NOT can_permission('pos.discount') THEN
      RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount','scope','line');
    END IF;
    v_server_subtotal := v_server_subtotal + ROUND(v_qty*v_price-v_line_discount,2);
  END LOOP;
  v_server_subtotal := ROUND(v_server_subtotal,2);

  IF COALESCE(p_discount_amount,0)>0 AND NOT can_permission('pos.discount') THEN
    SELECT id INTO v_req_id FROM public.approval_requests
    WHERE requester_id=auth.uid() AND branch_id=p_branch_id AND action_type='discount'
      AND status='approved' AND expires_at>now()
      AND (entity_id IS NULL OR entity_id IS NOT DISTINCT FROM p_order_id)
      AND COALESCE(payload->>'discount_type','amount')=COALESCE(p_discount_type,'amount')
      AND abs(COALESCE((payload->>'discount_amount')::numeric,-1)-p_discount_amount)<0.0001
      AND abs(COALESCE((payload->>'subtotal')::numeric,-1)-v_server_subtotal)<0.0001
    ORDER BY decided_at DESC NULLS LAST,created_at DESC LIMIT 1 FOR UPDATE;
    IF v_req_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req_id;
    SELECT email INTO v_email FROM public.users WHERE id=auth.uid();
    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),v_email,'APPROVAL_CONSUMED','approval_request',v_req_id,
      jsonb_build_object('action_type','discount','discount_amount',p_discount_amount,'discount_type',p_discount_type,
        'server_subtotal',v_server_subtotal,'order_id',p_order_id),p_branch_id);
  END IF;

  v_result:=public._process_sale_core(
    p_invoice_number,p_branch_id,p_warehouse_id,p_customer_id,p_salesperson_id,
    v_server_subtotal,p_discount_amount,p_discount_type,0,p_bonus_amount,0,p_paid_amount,
    p_payment_method,p_status,p_items,p_shift_id,p_order_type,p_table_id,p_order_id,p_guest_count);

  IF p_order_id IS NOT NULL AND COALESCE((v_result->>'success')::boolean,false) IS TRUE THEN
    v_sale_id := NULLIF(v_result->>'sale_id','')::uuid;
    UPDATE public.orders o
    SET payment_status = CASE
          WHEN s.total > 0 AND s.paid_amount >= s.total THEN 'paid'
          WHEN s.paid_amount > 0 THEN 'partial'
          ELSE 'unpaid'
        END,
        payment_at = CASE WHEN s.paid_amount > 0 THEN now() ELSE NULL END,
        updated_at = now()
    FROM public.sales s
    WHERE o.id = p_order_id
      AND o.branch_id = p_branch_id
      AND s.id = v_sale_id;
  END IF;

  RETURN v_result;
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903084000_preserve_financial_visibility_contract.sql
-- ----------------------------------------------------------------------------
-- Preserve the established financial-visibility and audit-read contracts while
-- keeping the other Production acceptance fixes from 20260903083000.
--
-- Purchases are intentionally controlled in two layers:
--   1) branch isolation here;
--   2) the existing RESTRICTIVE financial_visibility_purchases policy, which
--      keeps recent history visible and applies the stable historical subset.
-- Adding purchases.view to the permissive branch policy would suppress that
-- established visibility model entirely for roles such as cashier.
DROP POLICY IF EXISTS auth_select_purchases ON public.purchases;
CREATE POLICY auth_select_purchases ON public.purchases
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

-- Direct audit rows remain branch-isolated as established by the RLS contract.
-- Privileged audit exploration is separately permission-gated by get_audit_trail.
DROP POLICY IF EXISTS auth_select_audit_log ON public.audit_log;
CREATE POLICY auth_select_audit_log ON public.audit_log
FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903090000_default_50_dining_tables.sql
-- ----------------------------------------------------------------------------
-- Provision a clean baseline of 50 dining tables for every branch.
-- Existing custom tables are preserved, and users may add more than 50.

CREATE OR REPLACE FUNCTION private.ensure_default_dining_tables(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_area_id uuid;
  v_i integer;
  v_name text;
  v_layout jsonb;
BEGIN
  IF p_branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN;
  END IF;

  SELECT id INTO v_area_id
  FROM public.dining_areas
  WHERE branch_id = p_branch_id
  ORDER BY sort_order, created_at, id
  LIMIT 1;

  IF v_area_id IS NULL THEN
    INSERT INTO public.dining_areas (branch_id, name, sort_order, is_demo)
    VALUES (p_branch_id, 'الصالة الرئيسية', 0, false)
    RETURNING id INTO v_area_id;
  END IF;

  FOR v_i IN 1..50 LOOP
    v_name := 'طاولة ' || lpad(v_i::text, 2, '0');
    v_layout := jsonb_build_object(
      'x', 20 + ((v_i - 1) % 10) * 130,
      'y', 20 + ((v_i - 1) / 10) * 100,
      'w', 110,
      'h', 70
    );

    IF EXISTS (
      SELECT 1
      FROM public.dining_tables
      WHERE branch_id = p_branch_id
        AND name = v_name
    ) THEN
      UPDATE public.dining_tables
      SET is_active = true,
          area_id = COALESCE(area_id, v_area_id),
          updated_at = now()
      WHERE branch_id = p_branch_id
        AND name = v_name;
    ELSE
      INSERT INTO public.dining_tables (
        branch_id,
        area_id,
        name,
        capacity,
        status,
        shape,
        layout,
        is_active,
        is_demo
      ) VALUES (
        p_branch_id,
        v_area_id,
        v_name,
        4,
        'vacant',
        'rect',
        v_layout,
        true,
        false
      );
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION private.provision_default_dining_tables_on_branch_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM private.ensure_default_dining_tables(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provision_default_dining_tables ON public.branches;
CREATE TRIGGER trg_provision_default_dining_tables
AFTER INSERT ON public.branches
FOR EACH ROW
EXECUTE FUNCTION private.provision_default_dining_tables_on_branch_insert();

-- Backfill the baseline for all existing active branches without touching
-- custom tables beyond the numbered default set.
DO $$
DECLARE
  v_branch record;
BEGIN
  FOR v_branch IN SELECT id FROM public.branches WHERE is_active = true LOOP
    PERFORM private.ensure_default_dining_tables(v_branch.id);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION private.ensure_default_dining_tables(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.provision_default_dining_tables_on_branch_insert() FROM PUBLIC, anon, authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903100000_product_image_storage.sql
-- ----------------------------------------------------------------------------
-- Product photos are stored in a dedicated public-read bucket.
-- Object mutation remains authenticated, permission-aware, and branch-scoped.
-- The storage schema exists on Supabase but not in the lightweight CI Postgres image,
-- so the migration intentionally no-ops there while application tests still compile/run.

DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage schema unavailable; skipping product image bucket setup';
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES (
    'product-images',
    'product-images',
    true,
    5242880,
    ARRAY['image/jpeg','image/png','image/webp','image/gif','image/avif']::text[]
  )
  ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

  EXECUTE 'DROP POLICY IF EXISTS product_images_insert_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_update_manage ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS product_images_delete_manage ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY product_images_insert_manage
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_update_manage
    ON storage.objects
    FOR UPDATE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
    WITH CHECK (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY product_images_delete_manage
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'product-images'
      AND public.can_permission('products.manage')
      AND public.user_may_access_branch(((storage.foldername(name))[1])::uuid)
    )
  $policy$;
END
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903104500_transfer_unsent_order_item.sql
-- ----------------------------------------------------------------------------
-- Move one exact, unsent order line between dine-in tables without touching KDS or inventory.
-- Sent lines are intentionally blocked: kitchen snapshots remain immutable and inventory is still sale-only.

CREATE OR REPLACE FUNCTION public.transfer_order_item_to_table(
  p_order_id uuid,
  p_order_item_id uuid,
  p_target_table_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_target public.dining_tables%ROWTYPE;
  v_target_order_id uuid;
  v_target_order_number text;
  v_number jsonb;
  v_new_item_id uuid;
  v_remaining integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND status IN ('open', 'held')
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF v_order.table_id IS NULL OR v_order.order_type <> 'dine_in' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SOURCE_NOT_DINE_IN');
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_order_item_id
    AND order_id = p_order_id
  FOR UPDATE;

  IF v_item.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEM_NOT_FOUND');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_kitchen_sends s
    WHERE s.order_item_id = p_order_item_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'ITEM_ALREADY_SENT',
      'detail', 'Sent kitchen lines cannot be transferred between orders.'
    );
  END IF;

  SELECT * INTO v_target
  FROM public.dining_tables
  WHERE id = p_target_table_id
    AND branch_id = v_order.branch_id
    AND is_active = true
  FOR UPDATE;

  IF v_target.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_NOT_FOUND');
  END IF;

  IF v_target.id = v_order.table_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'SAME_TABLE');
  END IF;

  SELECT id, order_number
    INTO v_target_order_id, v_target_order_number
  FROM public.orders
  WHERE table_id = p_target_table_id
    AND branch_id = v_order.branch_id
    AND status IN ('open', 'held')
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE;

  IF v_target_order_id IS NULL THEN
    v_number := public.next_document_number('order');
    IF COALESCE((v_number->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('success', false, 'error', 'NUMBERING_FAILED', 'detail', v_number->>'error');
    END IF;

    v_target_order_number := v_number->>'number';

    INSERT INTO public.orders (
      order_number, branch_id, order_type, status, table_id, customer_id,
      cashier_id, guest_count, notes, subtotal, discount_amount, discount_type,
      tax_amount, total
    )
    VALUES (
      v_target_order_number,
      v_order.branch_id,
      'dine_in',
      'open',
      p_target_table_id,
      v_order.customer_id,
      COALESCE(v_order.cashier_id, v_uid),
      NULL,
      NULL,
      0, 0, 'amount', 0, 0
    )
    RETURNING id INTO v_target_order_id;
  END IF;

  INSERT INTO public.order_items (
    order_id, product_id, unit_name, quantity, unit_price, discount_amount,
    bonus_quantity, total, modifier_option_ids, modifiers_snapshot, notes
  )
  VALUES (
    v_target_order_id,
    v_item.product_id,
    v_item.unit_name,
    v_item.quantity,
    v_item.unit_price,
    v_item.discount_amount,
    v_item.bonus_quantity,
    v_item.total,
    COALESCE(v_item.modifier_option_ids, '{}'::uuid[]),
    COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
    v_item.notes
  )
  RETURNING id INTO v_new_item_id;

  -- Deleting the unsent source line invokes the existing authoritative totals sync.
  DELETE FROM public.order_items WHERE id = p_order_item_id;

  UPDATE public.dining_tables
  SET status = 'occupied', updated_at = now()
  WHERE id = p_target_table_id;

  SELECT count(*) INTO v_remaining
  FROM public.order_items
  WHERE order_id = p_order_id;

  IF v_remaining = 0 THEN
    UPDATE public.orders
    SET status = 'cancelled', updated_at = now()
    WHERE id = p_order_id;

    IF NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = v_order.table_id
        AND status IN ('open', 'held')
        AND id <> p_order_id
    ) THEN
      UPDATE public.dining_tables
      SET status = 'vacant', updated_at = now()
      WHERE id = v_order.table_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'source_order_id', p_order_id,
    'target_order_id', v_target_order_id,
    'target_order_number', v_target_order_number,
    'new_order_item_id', v_new_item_id,
    'source_order_empty', v_remaining = 0,
    'inventory_changed', false,
    'kds_changed', false
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_order_item_to_table(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_order_item_to_table(uuid, uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903113000_split_payment_accounting.sql
-- ----------------------------------------------------------------------------
-- True split tender support for POS sales.
-- Inventory remains owned by _process_sale_core and is therefore deducted once.
-- Split tender rows are private accounting metadata used to reconcile shift and refund postings.

CREATE TABLE IF NOT EXISTS public.sale_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  payment_method text NOT NULL CHECK (payment_method IN ('cash', 'card', 'transfer')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  refunded_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0 AND refunded_amount <= amount),
  created_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sale_payments_sale_id ON public.sale_payments(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_payments_branch_id ON public.sale_payments(branch_id);

ALTER TABLE public.sale_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sale_payments FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.sale_payments TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.process_sale_split(
  p_invoice_number text,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_customer_id uuid,
  p_salesperson_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_discount_type text,
  p_tax_amount numeric,
  p_bonus_amount numeric,
  p_total numeric,
  p_payments jsonb,
  p_status text,
  p_items jsonb,
  p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',
  p_table_id uuid DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_guest_count integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_payment jsonb;
  v_method text;
  v_amount numeric(14,2);
  v_requested_total numeric(14,2) := 0;
  v_method_count integer := 0;
  v_core jsonb;
  v_sale_id uuid;
  v_sale_total numeric(14,2);
  v_sale_entry uuid;
  v_cash_account uuid;
  v_bank_account uuid;
BEGIN
  BEGIN
    IF auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) < 2 THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_REQUIRES_MULTIPLE_PAYMENTS');
    END IF;

    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_method := lower(trim(COALESCE(v_payment->>'payment_method', '')));
      v_amount := round(COALESCE((v_payment->>'amount')::numeric, 0), 2);
      IF v_method NOT IN ('cash', 'card', 'transfer') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYMENT_METHOD', 'payment_method', v_method);
      END IF;
      IF v_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYMENT_AMOUNT', 'payment_method', v_method);
      END IF;
      v_requested_total := v_requested_total + v_amount;
    END LOOP;

    SELECT count(DISTINCT lower(trim(value->>'payment_method')))
      INTO v_method_count
    FROM jsonb_array_elements(p_payments);
    IF v_method_count < 2 THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_REQUIRES_MULTIPLE_METHODS');
    END IF;

    -- The existing sale core remains the single stock/write boundary.
    -- Use a temporary cash collection, then replace only the collection-side accounting below.
    v_core := public._process_sale_core(
      p_invoice_number,
      p_branch_id,
      p_warehouse_id,
      p_customer_id,
      p_salesperson_id,
      p_subtotal,
      p_discount_amount,
      p_discount_type,
      p_tax_amount,
      p_bonus_amount,
      p_total,
      v_requested_total,
      'cash',
      p_status,
      p_items,
      p_shift_id,
      p_order_type,
      p_table_id,
      p_order_id,
      p_guest_count
    );

    IF COALESCE((v_core->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_core;
    END IF;

    v_sale_id := (v_core->>'sale_id')::uuid;
    SELECT total INTO v_sale_total FROM public.sales WHERE id = v_sale_id FOR UPDATE;

    IF round(COALESCE(v_sale_total, 0), 2) <> round(v_requested_total, 2) THEN
      RAISE EXCEPTION 'SPLIT_PAYMENT_TOTAL_MISMATCH: expected %, got %', v_sale_total, v_requested_total;
    END IF;

    INSERT INTO public.sale_payments(sale_id, branch_id, payment_method, amount, created_by)
    SELECT
      v_sale_id,
      p_branch_id,
      lower(trim(value->>'payment_method')),
      round((value->>'amount')::numeric, 2),
      auth.uid()
    FROM jsonb_array_elements(p_payments);

    UPDATE public.sales
    SET payment_method = 'split', paid_amount = v_sale_total
    WHERE id = v_sale_id;

    -- Replace the one temporary shift collection with one row per tender.
    IF p_shift_id IS NOT NULL THEN
      DELETE FROM public.shift_operations
      WHERE shift_id = p_shift_id
        AND operation_type = 'sale'
        AND reference_type = 'sale'
        AND reference_id = v_sale_id;

      INSERT INTO public.shift_operations(
        shift_id, operation_type, amount, payment_method, reference_type, reference_id, created_by
      )
      SELECT
        p_shift_id,
        'sale',
        round((value->>'amount')::numeric, 2),
        lower(trim(value->>'payment_method')),
        'sale',
        v_sale_id,
        auth.uid()
      FROM jsonb_array_elements(p_payments);
    END IF;

    -- Rewrite only collection debit lines. Revenue/VAT/discount/COGS remain exactly as core posted them.
    SELECT id INTO v_sale_entry
    FROM public.journal_entries
    WHERE branch_id = p_branch_id
      AND reference_type = 'sale'
      AND reference_id = v_sale_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_sale_entry IS NULL THEN
      RAISE EXCEPTION 'SPLIT_SALE_JOURNAL_NOT_FOUND';
    END IF;

    v_cash_account := public.resolve_account_key(p_branch_id, 'cash');
    v_bank_account := public.resolve_account_key(p_branch_id, 'bank');

    DELETE FROM public.journal_entry_lines
    WHERE journal_entry_id = v_sale_entry
      AND account_id IN (v_cash_account, v_bank_account)
      AND debit > 0;

    INSERT INTO public.journal_entry_lines(journal_entry_id, account_id, debit, credit, note)
    SELECT
      v_sale_entry,
      CASE WHEN lower(trim(value->>'payment_method')) = 'cash' THEN v_cash_account ELSE v_bank_account END,
      round((value->>'amount')::numeric, 2),
      0,
      p_invoice_number || ' · ' || lower(trim(value->>'payment_method'))
    FROM jsonb_array_elements(p_payments);

    RETURN v_core || jsonb_build_object(
      'split', true,
      'payment_count', jsonb_array_length(p_payments),
      'paid_amount', v_sale_total
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated, service_role;

-- Preserve the exact, already-hardened refund/stock-restoration implementation as an internal core.
ALTER FUNCTION public.process_refund(uuid, jsonb, text) RENAME TO _process_refund_single_core;
REVOKE ALL ON FUNCTION public._process_refund_single_core(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._process_refund_single_core(uuid, jsonb, text) TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.process_refund(
  p_sale_id uuid,
  p_items jsonb DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_has_split boolean := false;
  v_result jsonb;
  v_refund_total numeric(14,2);
  v_sale record;
  v_refund_entry uuid;
  v_cash_account uuid;
  v_bank_account uuid;
  v_remaining_total numeric(14,2);
  v_allocated numeric(14,2) := 0;
  v_left numeric(14,2);
  v_row record;
  v_part numeric(14,2);
  v_last_payment uuid;
  v_shift_id uuid;
BEGIN
  BEGIN
    IF p_sale_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SALE');
    END IF;

    SELECT EXISTS(SELECT 1 FROM public.sale_payments WHERE sale_id = p_sale_id)
      INTO v_has_split;

    IF NOT v_has_split THEN
      RETURN public._process_refund_single_core(p_sale_id, p_items, p_reason);
    END IF;

    SELECT id, branch_id, invoice_number
      INTO v_sale
    FROM public.sales
    WHERE id = p_sale_id
    FOR UPDATE;
    IF v_sale.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'SALE_NOT_FOUND');
    END IF;

    -- Run the exact existing refund core first. It owns approval, exact inventory restoration,
    -- sale-item refund state, and the non-collection reversal lines.
    v_result := public._process_refund_single_core(p_sale_id, p_items, p_reason);
    IF COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_result;
    END IF;

    v_refund_total := round(COALESCE((v_result->>'refunded_amount')::numeric, 0), 2);
    IF v_refund_total <= 0 THEN
      RETURN v_result;
    END IF;

    -- Lock the tender rows before computing their remaining refundable balance.
    PERFORM 1
    FROM public.sale_payments
    WHERE sale_id = p_sale_id
    FOR UPDATE;

    SELECT round(COALESCE(sum(amount - refunded_amount), 0), 2)
      INTO v_remaining_total
    FROM public.sale_payments
    WHERE sale_id = p_sale_id;

    IF v_refund_total > v_remaining_total THEN
      RAISE EXCEPTION 'SPLIT_REFUND_EXCEEDS_REMAINING_TENDERS: refund %, remaining %', v_refund_total, v_remaining_total;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.split_refund_alloc(
      payment_id uuid PRIMARY KEY,
      payment_method text NOT NULL,
      amount numeric(14,2) NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.split_refund_alloc;

    -- Pro-rate the refund across remaining tenders; the final tender absorbs rounding cents.
    SELECT id INTO v_last_payment
    FROM public.sale_payments
    WHERE sale_id = p_sale_id AND amount > refunded_amount
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    FOR v_row IN
      SELECT id, payment_method, amount - refunded_amount AS remaining
      FROM public.sale_payments
      WHERE sale_id = p_sale_id AND amount > refunded_amount
      ORDER BY created_at, id
    LOOP
      IF v_row.id = v_last_payment THEN CONTINUE; END IF;
      v_part := LEAST(
        round(v_refund_total * v_row.remaining / NULLIF(v_remaining_total, 0), 2),
        v_row.remaining,
        v_refund_total - v_allocated
      );
      IF v_part > 0 THEN
        INSERT INTO pg_temp.split_refund_alloc(payment_id, payment_method, amount)
        VALUES (v_row.id, v_row.payment_method, v_part);
        v_allocated := v_allocated + v_part;
      END IF;
    END LOOP;

    v_left := round(v_refund_total - v_allocated, 2);
    IF v_left > 0 THEN
      SELECT id, payment_method, amount - refunded_amount AS remaining
        INTO v_row
      FROM public.sale_payments
      WHERE id = v_last_payment;
      IF v_row.id IS NULL OR v_left > v_row.remaining THEN
        RAISE EXCEPTION 'SPLIT_REFUND_ALLOCATION_FAILED';
      END IF;
      INSERT INTO pg_temp.split_refund_alloc(payment_id, payment_method, amount)
      VALUES (v_row.id, v_row.payment_method, v_left)
      ON CONFLICT (payment_id) DO UPDATE SET amount = pg_temp.split_refund_alloc.amount + EXCLUDED.amount;
    END IF;

    UPDATE public.sale_payments sp
    SET refunded_amount = sp.refunded_amount + a.amount
    FROM pg_temp.split_refund_alloc a
    WHERE sp.id = a.payment_id;

    -- Replace the core's single refund drawer row with exact tender rows.
    SELECT id INTO v_shift_id
    FROM public.shifts
    WHERE cashier_id = auth.uid() AND branch_id = v_sale.branch_id AND status = 'open'
    ORDER BY opened_at DESC LIMIT 1;

    IF v_shift_id IS NOT NULL THEN
      DELETE FROM public.shift_operations
      WHERE shift_id = v_shift_id
        AND operation_type = 'refund'
        AND reference_type = 'refund'
        AND reference_id = p_sale_id;

      INSERT INTO public.shift_operations(
        shift_id, operation_type, amount, payment_method, reference_type, reference_id, created_by
      )
      SELECT v_shift_id, 'refund', amount, payment_method, 'refund', p_sale_id, auth.uid()
      FROM pg_temp.split_refund_alloc;
    END IF;

    -- The core created a balanced reversal with a single collection credit.
    -- Replace only cash/bank collection credits with the split tender allocation.
    SELECT id INTO v_refund_entry
    FROM public.journal_entries
    WHERE branch_id = v_sale.branch_id
      AND reference_type = 'refund'
      AND reference_number = v_sale.invoice_number
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    IF v_refund_entry IS NULL THEN
      RAISE EXCEPTION 'SPLIT_REFUND_JOURNAL_NOT_FOUND';
    END IF;

    v_cash_account := public.resolve_account_key(v_sale.branch_id, 'cash');
    v_bank_account := public.resolve_account_key(v_sale.branch_id, 'bank');

    DELETE FROM public.journal_entry_lines
    WHERE journal_entry_id = v_refund_entry
      AND account_id IN (v_cash_account, v_bank_account)
      AND credit > 0;

    INSERT INTO public.journal_entry_lines(journal_entry_id, account_id, debit, credit, note)
    SELECT
      v_refund_entry,
      CASE WHEN payment_method = 'cash' THEN v_cash_account ELSE v_bank_account END,
      0,
      amount,
      'مرتجع ' || v_sale.invoice_number || ' · ' || payment_method
    FROM pg_temp.split_refund_alloc;

    RETURN v_result || jsonb_build_object('split_refund', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.process_refund(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_refund(uuid, jsonb, text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903120000_pos_structural_actions_manager_approval.sql
-- ----------------------------------------------------------------------------
-- POS structural actions: split items/orders, merge orders and transfer tables.
-- These actions never deduct/restore inventory and never create kitchen sends.
-- Cashiers request manager approval; privileged managers execute directly.

ALTER TABLE public.approval_requests
  DROP CONSTRAINT IF EXISTS approval_requests_action_type_check;
ALTER TABLE public.approval_requests
  ADD CONSTRAINT approval_requests_action_type_check
  CHECK (action_type IN (
    'discount','reprint','void_order','cancel_sent_item','refund','open_drawer',
    'change_payment_method','force_close_shift','split_order','merge_order','transfer_order'
  ));

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_req_id uuid;
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF p_action_type NOT IN (
    'discount','reprint','void_order','cancel_sent_item','refund','open_drawer',
    'change_payment_method','force_close_shift','split_order','merge_order','transfer_order'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT id INTO v_req_id
  FROM public.approval_requests
  WHERE requester_id = auth.uid()
    AND branch_id = v_user.branch_id
    AND action_type = p_action_type
    AND entity_type = p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id
    AND payload = v_payload
    AND status = 'pending'
    AND expires_at > now()
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_req_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'request_id', v_req_id, 'status', 'pending', 'duplicate', true);
  END IF;

  INSERT INTO public.approval_requests(
    branch_id, requester_id, action_type, entity_type, entity_id, payload, reason
  ) VALUES (
    v_user.branch_id, auth.uid(), p_action_type, p_entity_type, p_entity_id, v_payload, trim(p_reason)
  ) RETURNING id INTO v_req_id;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'APPROVAL_REQUESTED', 'approval_request', v_req_id,
    jsonb_build_object(
      'action_type', p_action_type,
      'entity_type', p_entity_type,
      'target_id', p_entity_id,
      'reason', trim(p_reason),
      'payload', v_payload
    ),
    v_user.branch_id
  );

  RETURN jsonb_build_object('success', true, 'request_id', v_req_id, 'status', 'pending');
END;
$$;

CREATE OR REPLACE FUNCTION public._recalc_open_order_totals(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_subtotal numeric(14,4);
BEGIN
  SELECT COALESCE(sum(quantity * unit_price), 0)
    INTO v_subtotal
  FROM public.order_items
  WHERE order_id = p_order_id;

  UPDATE public.orders
  SET subtotal = v_subtotal,
      total = GREATEST(v_subtotal - COALESCE(discount_amount, 0) + COALESCE(tax_amount, 0), 0),
      updated_at = now()
  WHERE id = p_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION public._create_structural_target_order(
  p_source public.orders,
  p_target_kind text,
  p_target_table_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_id uuid;
  v_target public.dining_tables%ROWTYPE;
  v_number jsonb;
  v_order_number text;
BEGIN
  IF p_target_kind = 'table' THEN
    SELECT * INTO v_target
    FROM public.dining_tables
    WHERE id = p_target_table_id
      AND branch_id = p_source.branch_id
      AND is_active = true
    FOR UPDATE;

    IF v_target.id IS NULL THEN
      RAISE EXCEPTION 'TARGET_TABLE_NOT_FOUND';
    END IF;

    SELECT id INTO v_target_id
    FROM public.orders
    WHERE branch_id = p_source.branch_id
      AND table_id = p_target_table_id
      AND status IN ('open','held')
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_target_id IS NOT NULL THEN
      RETURN v_target_id;
    END IF;
  ELSIF p_target_kind <> 'quick' THEN
    RAISE EXCEPTION 'INVALID_TARGET_KIND';
  END IF;

  v_number := public.next_document_number('order');
  IF COALESCE((v_number->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'NUMBERING_FAILED: %', COALESCE(v_number->>'error', 'unknown');
  END IF;
  v_order_number := v_number->>'number';

  INSERT INTO public.orders(
    order_number, branch_id, order_type, status, table_id, customer_id,
    cashier_id, guest_count, notes, subtotal, discount_amount, discount_type,
    tax_amount, total
  ) VALUES (
    v_order_number,
    p_source.branch_id,
    CASE WHEN p_target_kind = 'table' THEN 'dine_in' ELSE 'takeaway' END,
    'open',
    CASE WHEN p_target_kind = 'table' THEN p_target_table_id ELSE NULL END,
    p_source.customer_id,
    COALESCE(p_source.cashier_id, auth.uid()),
    NULL,
    NULL,
    0, 0, 'amount', 0, 0
  ) RETURNING id INTO v_target_id;

  IF p_target_kind = 'table' THEN
    UPDATE public.dining_tables
    SET status = 'occupied', updated_at = now()
    WHERE id = p_target_table_id;
  END IF;

  RETURN v_target_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.perform_pos_order_action(
  p_action_type text,
  p_order_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_target_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_request public.approval_requests%ROWTYPE;
  v_request_result jsonb;
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_privileged boolean := false;
  v_target_id uuid;
  v_target_table_id uuid;
  v_target_kind text;
  v_item_id uuid;
  v_qty numeric(14,4);
  v_ratio numeric(18,8);
  v_moved_discount numeric(14,4);
  v_moved_bonus numeric(14,4);
  v_moved_total numeric(14,4);
  v_source_order_discount numeric(14,4);
  v_source_tax numeric(14,4);
  v_order_ratio numeric(18,8);
  v_old_subtotal numeric(14,4);
  v_remaining integer;
  v_source_table_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  IF p_action_type NOT IN ('split_order','merge_order','transfer_order') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;
  IF v_user.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND status IN ('open','held')
  FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;
  IF NOT public.user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  v_privileged := public.is_pos_admin() OR public.can_permission('approvals.review');

  IF NOT v_privileged THEN
    SELECT * INTO v_request
    FROM public.approval_requests ar
    WHERE ar.requester_id = auth.uid()
      AND ar.branch_id = v_order.branch_id
      AND ar.action_type = p_action_type
      AND ar.entity_type = 'order'
      AND ar.entity_id = p_order_id
      AND ar.payload = v_payload
      AND ar.status = 'approved'
      AND ar.expires_at > now()
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_request.id IS NULL THEN
      v_request_result := public.request_manager_approval(
        p_action_type,
        'order',
        p_order_id,
        v_payload,
        trim(p_reason)
      );
      RETURN jsonb_build_object(
        'success', false,
        'error', 'MANAGER_APPROVAL_REQUIRED',
        'action', p_action_type,
        'request_id', v_request_result->>'request_id',
        'status', COALESCE(v_request_result->>'status', 'pending')
      );
    END IF;

    v_request_result := public.consume_manager_approval(v_request.id, p_action_type, p_order_id);
    IF COALESCE((v_request_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN COALESCE(v_request_result, jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED'));
    END IF;
  END IF;

  IF p_action_type = 'split_order' THEN
    BEGIN
      v_item_id := NULLIF(v_payload->>'order_item_id', '')::uuid;
      v_qty := NULLIF(v_payload->>'quantity', '')::numeric;
      v_target_kind := lower(COALESCE(v_payload->>'target_kind', ''));
      v_target_table_id := NULLIF(v_payload->>'target_table_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYLOAD');
    END;

    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty <= 0 OR v_target_kind NOT IN ('quick','table') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYLOAD');
    END IF;
    IF v_target_kind = 'table' AND v_target_table_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_REQUIRED');
    END IF;

    SELECT * INTO v_item
    FROM public.order_items
    WHERE id = v_item_id AND order_id = p_order_id
    FOR UPDATE;
    IF v_item.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_ITEM_NOT_FOUND');
    END IF;
    IF v_qty > v_item.quantity THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_QUANTITY_EXCEEDS_LINE', 'available_quantity', v_item.quantity);
    END IF;

    -- Sent snapshots are immutable. Do not fake a KDS transfer.
    IF EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = v_item.id) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ITEM_ALREADY_SENT',
        'detail', 'Sent kitchen lines remain attached to their original order snapshot.'
      );
    END IF;

    v_target_id := public._create_structural_target_order(v_order, v_target_kind, v_target_table_id);
    IF v_target_id = p_order_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'SAME_ORDER');
    END IF;

    SELECT * INTO v_target_order FROM public.orders WHERE id = v_target_id FOR UPDATE;

    v_ratio := v_qty / NULLIF(v_item.quantity, 0);
    v_moved_discount := round(COALESCE(v_item.discount_amount, 0) * v_ratio, 4);
    v_moved_bonus := round(COALESCE(v_item.bonus_quantity, 0) * v_ratio, 4);
    v_moved_total := round(COALESCE(v_item.total, v_item.quantity * v_item.unit_price) * v_ratio, 4);

    v_old_subtotal := GREATEST(COALESCE(v_order.subtotal, 0), 0);
    v_order_ratio := CASE WHEN v_old_subtotal > 0
      THEN LEAST(1, GREATEST(0, (v_qty * v_item.unit_price) / v_old_subtotal))
      ELSE 0 END;
    v_source_order_discount := round(COALESCE(v_order.discount_amount, 0) * v_order_ratio, 4);
    v_source_tax := round(COALESCE(v_order.tax_amount, 0) * v_order_ratio, 4);

    IF v_qty = v_item.quantity THEN
      UPDATE public.order_items SET order_id = v_target_id WHERE id = v_item.id;
    ELSE
      UPDATE public.order_items
      SET quantity = quantity - v_qty,
          discount_amount = GREATEST(COALESCE(discount_amount,0) - v_moved_discount, 0),
          bonus_quantity = GREATEST(COALESCE(bonus_quantity,0) - v_moved_bonus, 0),
          total = GREATEST(COALESCE(total,0) - v_moved_total, 0)
      WHERE id = v_item.id;

      INSERT INTO public.order_items(
        order_id, product_id, unit_name, quantity, unit_price, discount_amount,
        bonus_quantity, total, modifier_option_ids, modifiers_snapshot, notes
      ) VALUES (
        v_target_id, v_item.product_id, v_item.unit_name, v_qty, v_item.unit_price,
        v_moved_discount, v_moved_bonus, v_moved_total,
        COALESCE(v_item.modifier_option_ids, '{}'::uuid[]),
        COALESCE(v_item.modifiers_snapshot, '[]'::jsonb),
        v_item.notes
      );
    END IF;

    UPDATE public.orders
    SET discount_amount = GREATEST(COALESCE(discount_amount,0) - v_source_order_discount, 0),
        tax_amount = GREATEST(COALESCE(tax_amount,0) - v_source_tax, 0)
    WHERE id = p_order_id;
    UPDATE public.orders
    SET discount_amount = COALESCE(discount_amount,0) + v_source_order_discount,
        tax_amount = COALESCE(tax_amount,0) + v_source_tax
    WHERE id = v_target_id;

    PERFORM public._recalc_open_order_totals(p_order_id);
    PERFORM public._recalc_open_order_totals(v_target_id);

    SELECT count(*) INTO v_remaining FROM public.order_items WHERE order_id = p_order_id;
    IF v_remaining = 0 THEN
      v_source_table_id := v_order.table_id;
      UPDATE public.orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
      IF v_source_table_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.orders
        WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
      ) THEN
        UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
      END IF;
    END IF;

    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(
      auth.uid(), v_user.email, 'POS_ORDER_SPLIT', 'order', p_order_id,
      jsonb_build_object(
        'order_item_id', v_item_id,
        'quantity', v_qty,
        'target_order_id', v_target_id,
        'target_kind', v_target_kind,
        'target_table_id', v_target_table_id,
        'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
        'inventory_changed', false,
        'kds_changed', false
      ),
      v_order.branch_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'action', 'split_order',
      'source_order_id', p_order_id,
      'target_order_id', v_target_id,
      'inventory_changed', false,
      'kds_changed', false,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
    );
  END IF;

  IF p_action_type = 'merge_order' THEN
    BEGIN
      v_target_id := NULLIF(v_payload->>'target_order_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MERGE_PAYLOAD');
    END;

    IF v_target_id IS NULL OR v_target_id = p_order_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_MERGE_TARGET');
    END IF;

    SELECT * INTO v_target_order
    FROM public.orders
    WHERE id = v_target_id
      AND branch_id = v_order.branch_id
      AND status IN ('open','held')
    FOR UPDATE;
    IF v_target_order.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'TARGET_ORDER_NOT_FOUND');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.order_kitchen_sends s
      JOIN public.order_items oi ON oi.id = s.order_item_id
      WHERE oi.order_id = p_order_id
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'SOURCE_HAS_SENT_ITEMS',
        'detail', 'Sent kitchen lines cannot be re-parented during merge.'
      );
    END IF;

    UPDATE public.order_items SET order_id = v_target_id WHERE order_id = p_order_id;
    UPDATE public.orders
    SET discount_amount = COALESCE(discount_amount,0) + COALESCE(v_order.discount_amount,0),
        tax_amount = COALESCE(tax_amount,0) + COALESCE(v_order.tax_amount,0)
    WHERE id = v_target_id;
    PERFORM public._recalc_open_order_totals(v_target_id);

    v_source_table_id := v_order.table_id;
    UPDATE public.orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
    IF v_source_table_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
    ) THEN
      UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
    END IF;

    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(
      auth.uid(), v_user.email, 'POS_ORDER_MERGED', 'order', p_order_id,
      jsonb_build_object(
        'target_order_id', v_target_id,
        'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
        'inventory_changed', false,
        'kds_changed', false
      ),
      v_order.branch_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'action', 'merge_order',
      'source_order_id', p_order_id,
      'target_order_id', v_target_id,
      'inventory_changed', false,
      'kds_changed', false,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
    );
  END IF;

  -- transfer_order: move the whole dine-in order to a vacant table. KDS remains on the same order id.
  BEGIN
    v_target_table_id := NULLIF(v_payload->>'target_table_id', '')::uuid;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TRANSFER_PAYLOAD');
  END;

  IF v_order.order_type <> 'dine_in' OR v_order.table_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SOURCE_NOT_DINE_IN');
  END IF;
  IF v_target_table_id IS NULL OR v_target_table_id = v_order.table_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TARGET_TABLE');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dining_tables
    WHERE id = v_target_table_id AND branch_id = v_order.branch_id AND is_active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_NOT_FOUND');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = v_target_table_id AND branch_id = v_order.branch_id
      AND status IN ('open','held') AND id <> p_order_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_TABLE_OCCUPIED', 'detail', 'Use merge for an occupied target table.');
  END IF;

  v_source_table_id := v_order.table_id;
  UPDATE public.orders SET table_id = v_target_table_id, updated_at = now() WHERE id = p_order_id;
  UPDATE public.dining_tables SET status = 'occupied', updated_at = now() WHERE id = v_target_table_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders
    WHERE table_id = v_source_table_id AND status IN ('open','held') AND id <> p_order_id
  ) THEN
    UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_source_table_id;
  END IF;

  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(
    auth.uid(), v_user.email, 'POS_ORDER_TRANSFERRED', 'order', p_order_id,
    jsonb_build_object(
      'from_table_id', v_source_table_id,
      'target_table_id', v_target_table_id,
      'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END,
      'inventory_changed', false,
      'kds_changed', false
    ),
    v_order.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'action', 'transfer_order',
    'order_id', p_order_id,
    'from_table_id', v_source_table_id,
    'target_table_id', v_target_table_id,
    'inventory_changed', false,
    'kds_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public._recalc_open_order_totals(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._create_structural_target_order(public.orders,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._recalc_open_order_totals(uuid) TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._create_structural_target_order(public.orders,text,uuid) TO service_role, postgres;

REVOKE ALL ON FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903171000_pos_granular_permissions.sql
-- ----------------------------------------------------------------------------
-- Granular POS permissions and server-side enforcement.
-- UI visibility is not a security boundary; these triggers protect the
-- authoritative mutation tables even when SECURITY DEFINER RPCs are called
-- directly.

CREATE OR REPLACE FUNCTION public._append_role_permission(p_permissions jsonb, p_permission text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN COALESCE(p_permissions, '[]'::jsonb) ? p_permission THEN COALESCE(p_permissions, '[]'::jsonb)
    ELSE COALESCE(p_permissions, '[]'::jsonb) || jsonb_build_array(p_permission)
  END;
$$;

UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(
                public._append_role_permission(
                  public._append_role_permission(
                    public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
                    'pos.send_kitchen'),
                  'pos.kds_view'),
                'pos.print_kitchen'),
              'pos.pay'),
            'pos.void'),
          'pos.cancel_order'),
        'pos.refund'),
      'pos.transfer_order'),
    'pos.split_order'),
  'pos.change_branch')
WHERE role IN ('super_admin', 'owner');

UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(
                public._append_role_permission(
                  public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
                  'pos.send_kitchen'),
                'pos.kds_view'),
              'pos.print_kitchen'),
            'pos.pay'),
          'pos.void'),
        'pos.cancel_order'),
      'pos.refund'),
    'pos.transfer_order'),
  'pos.split_order')
WHERE role = 'branch_manager';

-- Cashier baseline preserves the existing manager-approval workflows:
-- split/transfer/sent-item void may be initiated, but their authoritative RPCs
-- still require manager approval. Direct manager authority stays absent.
UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
              'pos.send_kitchen'),
            'pos.kds_view'),
          'pos.print_kitchen'),
        'pos.pay'),
      'pos.void'),
    'pos.transfer_order'),
  'pos.split_order')
WHERE role = 'cashier';

-- Remove legacy direct-authority permissions from cashier so discount, price
-- override and receipt reprint use their manager-approval paths by default.
UPDATE public.roles
SET permissions = COALESCE(permissions, '[]'::jsonb)
  - 'pos.discount'
  - 'pos.change_price'
  - 'pos.reprint'
  - 'pos.cancel_order'
  - 'pos.refund'
  - 'pos.change_branch'
WHERE role = 'cashier';

-- Kitchen staff need KDS visibility without POS selling rights.
UPDATE public.roles
SET permissions = public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.kds_view')
WHERE role = 'kitchen';

DROP FUNCTION public._append_role_permission(jsonb, text);

CREATE OR REPLACE FUNCTION public.enforce_pos_permission_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
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

    -- Kitchen workers may update ONLY kitchen workflow fields. Comparing the
    -- remaining row as jsonb prevents smuggling sale/order changes through the
    -- KDS exception.
    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
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

DROP TRIGGER IF EXISTS trg_pos_permission_orders ON public.orders;
CREATE TRIGGER trg_pos_permission_orders
BEFORE INSERT OR UPDATE OR DELETE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_order_items ON public.order_items;
CREATE TRIGGER trg_pos_permission_order_items
BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_kitchen_sends ON public.order_kitchen_sends;
CREATE TRIGGER trg_pos_permission_kitchen_sends
BEFORE INSERT OR UPDATE OR DELETE ON public.order_kitchen_sends
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_sales ON public.sales;
CREATE TRIGGER trg_pos_permission_sales
BEFORE INSERT ON public.sales
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903172000_kds_authoritative_sent_quantity.sql
-- ----------------------------------------------------------------------------
-- KDS must represent what has actually been sent to the kitchen, not the
-- mutable current cart quantity. Preserve item-level cooking notes and enforce
-- KDS permission at the authoritative RPC boundary.
CREATE OR REPLACE FUNCTION public.get_kitchen_queue(
  p_station text DEFAULT NULL::text,
  p_branch_id uuid DEFAULT get_branch_id()
)
RETURNS TABLE(
  order_id uuid,
  order_number text,
  table_number integer,
  station text,
  kitchen_status text,
  guest_count integer,
  notes text,
  created_at timestamp with time zone,
  items jsonb,
  elapsed_seconds integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_has_assignments boolean;
  v_main_station_id uuid;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  IF p_branch_id IS NULL
     OR (NOT v_is_service_role AND NOT public.user_may_access_branch(p_branch_id))
     OR (NOT v_is_service_role AND NOT public.can_permission('pos.kds_view')) THEN
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
      oks.sent_quantity AS quantity,
      oi.notes AS item_notes,
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
      AND COALESCE(oks.sent_quantity, 0) > 0
  ), legacy_empty_orders AS (
    SELECT
      o.id AS oid,
      o.order_number AS onumber,
      o.kitchen_status AS kstatus,
      o.guest_count AS guests,
      o.notes AS onotes,
      COALESCE(o.kitchen_sent_at, o.created_at) AS queue_at,
      NULL::uuid AS item_id,
      NULL::numeric AS quantity,
      NULL::text AS item_notes,
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
        'notes', ai.item_notes,
        'modifiers', COALESCE(ai.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY ai.item_id) FILTER (WHERE ai.item_id IS NOT NULL),
      '[]'::jsonb
    ),
    GREATEST(EXTRACT(EPOCH FROM (now() - MIN(ai.queue_at)))::integer, 0)
  FROM allowed_items ai
  GROUP BY ai.oid, ai.onumber, ai.station_code, ai.kstatus, ai.guests, ai.onotes
  ORDER BY MIN(ai.queue_at), ai.onumber, ai.station_code;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_kitchen_stations(p_branch_id uuid DEFAULT get_branch_id())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_has_assignments boolean;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN '[]'::jsonb; END IF;
  IF NOT public.user_may_access_branch(p_branch_id)
     OR NOT public.can_permission('pos.kds_view') THEN
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
$function$;

CREATE OR REPLACE FUNCTION public.set_kitchen_status(p_order_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_branch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
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

  IF NOT public.user_may_access_branch(v_branch_id)
     OR NOT public.can_permission('pos.kds_view') THEN
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903173000_fix_kds_permission_regressions.sql
-- ----------------------------------------------------------------------------
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


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903174000_harden_send_to_kitchen_permission.sql
-- ----------------------------------------------------------------------------
-- Keep POS sending and KDS management as separate capabilities.
-- send_to_kitchen is the authoritative SECURITY DEFINER boundary, while direct
-- writes to order_kitchen_sends remain protected by RLS. Avoid a nested trigger
-- permission check inside the SECURITY DEFINER RPC.

DROP TRIGGER IF EXISTS trg_pos_permission_kitchen_sends ON public.order_kitchen_sends;

DROP POLICY IF EXISTS "auth_select_order_kitchen_sends" ON public.order_kitchen_sends;
CREATE POLICY "auth_select_order_kitchen_sends"
ON public.order_kitchen_sends FOR SELECT TO authenticated
USING (
  is_pos_admin()
  OR (
    branch_id = get_branch_id()
    AND (can_permission('pos.send_kitchen') OR can_permission('pos.kds_view'))
  )
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends"
ON public.order_kitchen_sends FOR INSERT TO authenticated
WITH CHECK (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends_upd" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends_upd"
ON public.order_kitchen_sends FOR UPDATE TO authenticated
USING (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
)
WITH CHECK (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

DROP POLICY IF EXISTS "auth_write_order_kitchen_sends_del" ON public.order_kitchen_sends;
CREATE POLICY "auth_write_order_kitchen_sends_del"
ON public.order_kitchen_sends FOR DELETE TO authenticated
USING (
  is_pos_admin()
  OR (branch_id = get_branch_id() AND can_permission('pos.send_kitchen'))
);

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
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  BEGIN
    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders WHERE id = p_order_id;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    END IF;

    IF NOT v_is_service_role THEN
      IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
      END IF;

      SELECT branch_id INTO v_user_branch
      FROM public.users
      WHERE id = auth.uid() AND is_active = true;

      IF NOT is_pos_admin()
         AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;

      IF NOT is_pos_admin() AND NOT can_permission('pos.send_kitchen') THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'PERMISSION_DENIED',
          'detail', 'pos.send_kitchen'
        );
      END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

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
        'notes', oi.notes,
        'modifiers', COALESCE(oi.modifiers_snapshot, '[]'::jsonb)
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
    RETURN jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_FAILED',
      'detail', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903180000_kitchen_station_printer_routing.sql
-- ----------------------------------------------------------------------------
-- Browser POS printer routing: keep physical printer names local to the Windows
-- terminal, but return the authoritative KDS station for each delta sent by
-- send_to_kitchen. No inventory/accounting semantics change.

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
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  BEGIN
    SELECT branch_id, status, order_number, table_id, order_type, guest_count
      INTO v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count
    FROM public.orders
    WHERE id = p_order_id;

    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    END IF;

    IF v_table_id IS NOT NULL THEN
      SELECT name INTO v_table_name
      FROM public.dining_tables
      WHERE id = v_table_id AND branch_id = v_branch_id;
    END IF;

    IF NOT v_is_service_role THEN
      IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
      END IF;

      SELECT branch_id INTO v_user_branch
      FROM public.users
      WHERE id = auth.uid() AND is_active = true;

      IF NOT is_pos_admin()
         AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;

      IF NOT is_pos_admin() AND NOT can_permission('pos.send_kitchen') THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'PERMISSION_DENIED',
          'detail', 'pos.send_kitchen'
        );
      END IF;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

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
        'station_code', COALESCE(ks.code, 'main'),
        'quantity', k.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', COALESCE(oi.modifiers_snapshot, '[]'::jsonb)
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM _kns_delta k
      JOIN public.order_items oi ON oi.id = k.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id
      LEFT JOIN public.categories c
        ON c.id = p.category_id AND c.branch_id = v_branch_id
      LEFT JOIN public.kitchen_stations ks
        ON ks.id = c.kitchen_station_id AND ks.is_active = true;
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
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_FAILED',
      'detail', SQLERRM
    );
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903192401_fix_direct_branch_read_access.sql
-- ----------------------------------------------------------------------------
-- Ensure every authenticated user can read their directly assigned branch,
-- even when that branch belongs to an organization.
-- Cross-branch visibility remains limited to platform admins or organization membership.

drop policy if exists auth_select_branches on public.branches;

create policy auth_select_branches
on public.branches
for select
to authenticated
using (
  is_platform_admin()
  or id = get_branch_id()
  or organization_id in (select user_organization_ids())
);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903194958_fix_stock_count_counted_quantity_type.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_stock_count(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_count_type text,
  p_notes text DEFAULT NULL::text,
  p_items jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count_id uuid;
  v_number text;
  v_item jsonb;
  v_product_id uuid;
  v_system_qty numeric(14,4);
  v_unit_cost numeric(12,2);
  v_user_branch uuid;
  v_rows integer := 0;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Creating stock counts requires the inventory.manage permission.');
    END IF;
    IF p_branch_id IS NULL OR p_warehouse_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_WAREHOUSE');
    END IF;
    IF p_count_type IS NULL OR p_count_type NOT IN ('full', 'partial', 'cycle') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_COUNT_TYPE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id = p_warehouse_id AND branch_id = p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_IN_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    v_number := (public.next_document_number('stock_count')->>'number')::text;

    INSERT INTO public.stock_counts (count_number, branch_id, warehouse_id, status, count_type, notes, created_by)
    VALUES (v_number, p_branch_id, p_warehouse_id, 'draft', p_count_type, p_notes, auth.uid())
    RETURNING id INTO v_count_id;

    IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        v_product_id := (v_item->>'product_id')::uuid;
        IF v_product_id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM', 'item', v_item);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_product_id) THEN
          RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND', 'product_id', v_product_id);
        END IF;

        SELECT COALESCE(i.quantity, 0), COALESCE(p.cost_price, 0)
        INTO v_system_qty, v_unit_cost
        FROM public.products p
        LEFT JOIN public.inventory i
          ON i.product_id = p.id AND i.warehouse_id = p_warehouse_id
        WHERE p.id = v_product_id;

        SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
        INTO v_unit_cost
        FROM public.inventory_batches b
        WHERE b.product_id = v_product_id AND b.warehouse_id = p_warehouse_id AND b.quantity > 0;
        IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

        INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
        VALUES (
          v_count_id,
          v_product_id,
          COALESCE(v_system_qty, 0),
          COALESCE(NULLIF(v_item->>'counted_quantity', '')::numeric, v_system_qty),
          v_unit_cost,
          NULLIF((v_item->>'reason')::text, '')
        );
        v_rows := v_rows + 1;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true, 'stock_count_id', v_count_id,
      'count_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903195000_purchase_delete_permission.sql
-- ----------------------------------------------------------------------------
-- Dedicated permission for hard-deleting unposted purchase drafts/cancellations.
-- Completed/posted purchases remain protected and require reversal/return.

UPDATE public.roles
SET permissions = CASE
  WHEN permissions ? 'purchases.delete' THEN permissions
  ELSE permissions || jsonb_build_array('purchases.delete')
END,
updated_at = now()
WHERE role IN ('super_admin', 'owner', 'branch_manager');

CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_purchase public.purchases%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_purchase
  FROM public.purchases
  WHERE id = p_purchase_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_purchase.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.can_permission('purchases.delete') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED', 'detail', 'purchases.delete permission is required.');
  END IF;

  IF v_purchase.status NOT IN ('draft','cancelled') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_REVERSAL_REQUIRED',
      'detail', 'Completed, approved, submitted, partial or returned purchases cannot be hard-deleted; reverse/return them first.'
    );
  END IF;

  IF EXISTS (
       SELECT 1 FROM public.inventory_ledger
       WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
     )
     OR EXISTS (
       SELECT 1 FROM public.journal_entries
       WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_HAS_POSTINGS',
      'detail', 'Purchase has inventory/accounting postings and cannot be hard-deleted.'
    );
  END IF;

  DELETE FROM public.purchases WHERE id = p_purchase_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (
    auth.uid(), 'delete', 'purchase', p_purchase_id,
    jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),
    v_purchase.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'invoice_number', v_purchase.invoice_number
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_unposted_purchase_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.status = 'cancelled'
     AND OLD.status IN ('draft','submitted')
     AND public.can_permission('purchases.delete')
     AND NOT EXISTS (
       SELECT 1 FROM public.inventory_ledger
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.journal_entries
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     ) THEN
    DELETE FROM public.purchases WHERE id = NEW.id;
    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903195419_enforce_stock_count_product_branch.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_stock_count(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_count_type text,
  p_notes text DEFAULT NULL::text,
  p_items jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count_id uuid;
  v_number text;
  v_item jsonb;
  v_product_id uuid;
  v_system_qty numeric(14,4);
  v_unit_cost numeric(12,2);
  v_user_branch uuid;
  v_rows integer := 0;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Creating stock counts requires the inventory.manage permission.');
    END IF;
    IF p_branch_id IS NULL OR p_warehouse_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_WAREHOUSE');
    END IF;
    IF p_count_type IS NULL OR p_count_type NOT IN ('full', 'partial', 'cycle') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_COUNT_TYPE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id = p_warehouse_id AND branch_id = p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_NOT_IN_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    v_number := (public.next_document_number('stock_count')->>'number')::text;

    INSERT INTO public.stock_counts (count_number, branch_id, warehouse_id, status, count_type, notes, created_by)
    VALUES (v_number, p_branch_id, p_warehouse_id, 'draft', p_count_type, p_notes, auth.uid())
    RETURNING id INTO v_count_id;

    IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        v_product_id := (v_item->>'product_id')::uuid;
        IF v_product_id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_ITEM', 'item', v_item);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_product_id) THEN
          RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND', 'product_id', v_product_id);
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public.products
          WHERE id = v_product_id AND branch_id = p_branch_id
        ) THEN
          RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
        END IF;

        SELECT COALESCE(i.quantity, 0), COALESCE(p.cost_price, 0)
        INTO v_system_qty, v_unit_cost
        FROM public.products p
        LEFT JOIN public.inventory i
          ON i.product_id = p.id AND i.warehouse_id = p_warehouse_id
        WHERE p.id = v_product_id;

        SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
        INTO v_unit_cost
        FROM public.inventory_batches b
        WHERE b.product_id = v_product_id AND b.warehouse_id = p_warehouse_id AND b.quantity > 0;
        IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

        INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
        VALUES (
          v_count_id,
          v_product_id,
          COALESCE(v_system_qty, 0),
          COALESCE(NULLIF(v_item->>'counted_quantity', '')::numeric, v_system_qty),
          v_unit_cost,
          NULLIF((v_item->>'reason')::text, '')
        );
        v_rows := v_rows + 1;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true, 'stock_count_id', v_count_id,
      'count_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903195602_enforce_add_stock_count_item_product_branch.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_stock_count_item(
  p_stock_count_id uuid,
  p_product_id uuid,
  p_counted_quantity numeric DEFAULT NULL::numeric,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
  v_system_qty numeric(14,4);
  v_unit_cost numeric(12,2);
  v_user_branch uuid;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_count FROM public.stock_counts WHERE id = p_stock_count_id FOR UPDATE;
    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;
    IF v_count.status <> 'draft' THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_DRAFT', 'status', v_count.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.products
      WHERE id = p_product_id AND branch_id = v_count.branch_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', p_product_id);
    END IF;

    SELECT COALESCE(i.quantity, 0) INTO v_system_qty
    FROM public.products p
    LEFT JOIN public.inventory i
      ON i.product_id = p.id AND i.warehouse_id = v_count.warehouse_id
    WHERE p.id = p_product_id;
    IF v_system_qty IS NULL THEN v_system_qty := 0; END IF;

    v_unit_cost := COALESCE((SELECT cost_price FROM public.products WHERE id = p_product_id), 0);
    SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
    INTO v_unit_cost
    FROM public.inventory_batches b
    WHERE b.product_id = p_product_id AND b.warehouse_id = v_count.warehouse_id AND b.quantity > 0;
    IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

    INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
    VALUES (p_stock_count_id, p_product_id, v_system_qty,
      COALESCE(p_counted_quantity, v_system_qty), v_unit_cost, p_reason)
    ON CONFLICT (stock_count_id, product_id) DO UPDATE
      SET counted_quantity = EXCLUDED.counted_quantity,
          unit_cost = EXCLUDED.unit_cost,
          reason = EXCLUDED.reason;

    RETURN jsonb_build_object('success', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903201500_prefer_ready_product_stock_in_pos.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_product_availability(p_product_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_quantity numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_recipe_id uuid;
  v_yield numeric := 1;
  v_link_count integer := 0;
  v_direct_raw_count integer := 0;
  v_row record;
  v_delta numeric;
  v_available numeric;
  v_remaining_stock numeric;
  v_cover numeric;
  v_shortage numeric;
  v_unit_type text;
  v_iter integer := 0;
  v_ready numeric;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = p_product_id AND p.branch_id = p_branch_id AND p.is_active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH');
  END IF;

  SELECT COALESCE(SUM(ib.quantity), 0)
  INTO v_ready
  FROM public.inventory_batches ib
  WHERE ib.product_id = p_product_id
    AND ib.branch_id = p_branch_id
    AND ib.warehouse_id = p_warehouse_id
    AND ib.quantity > 0;

  IF v_ready >= p_quantity THEN
    RETURN jsonb_build_object(
      'success', true,
      'required', p_quantity,
      'available', v_ready,
      'mode', 'ready_product'
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.avail_raw_need(
    raw_material_id uuid PRIMARY KEY,
    required_qty numeric NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.avail_unit_need(
    unit_id uuid PRIMARY KEY,
    required_qty numeric NOT NULL DEFAULT 0,
    processed_qty numeric NOT NULL DEFAULT 0,
    stock_used numeric NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.avail_raw_need;
  TRUNCATE pg_temp.avail_unit_need;

  INSERT INTO pg_temp.avail_unit_need(unit_id, required_qty)
  SELECT pul.unit_id, p_quantity * pul.quantity
  FROM public.product_unit_links pul
  JOIN public.inventory_units iu ON iu.id = pul.unit_id
  WHERE pul.product_id = p_product_id
    AND iu.branch_id = p_branch_id
    AND iu.is_active = true
  ON CONFLICT(unit_id) DO UPDATE
  SET required_qty = pg_temp.avail_unit_need.required_qty + EXCLUDED.required_qty;
  GET DIAGNOSTICS v_link_count = ROW_COUNT;

  SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
  INTO v_recipe_id, v_yield
  FROM public.recipes r
  WHERE r.product_id = p_product_id
    AND r.branch_id = p_branch_id
    AND COALESCE(r.is_active, true) = true
  ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
  LIMIT 1;

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO pg_temp.avail_raw_need(raw_material_id, required_qty)
    SELECT ri.raw_material_id, p_quantity * (ri.quantity / v_yield)
    FROM public.recipe_items ri
    JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
    WHERE ri.recipe_id = v_recipe_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.product_unit_links pul
        JOIN public.inventory_units iu ON iu.id = pul.unit_id
        WHERE pul.product_id = p_product_id
          AND iu.branch_id = p_branch_id
          AND iu.is_active = true
          AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
              regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
      )
    ON CONFLICT(raw_material_id) DO UPDATE
    SET required_qty = pg_temp.avail_raw_need.required_qty + EXCLUDED.required_qty;
    GET DIAGNOSTICS v_direct_raw_count = ROW_COUNT;
  END IF;

  IF v_link_count = 0 AND v_direct_raw_count = 0 THEN
    RETURN jsonb_build_object(
      'success', v_ready >= p_quantity,
      'error', CASE WHEN v_ready >= p_quantity THEN NULL ELSE 'INSUFFICIENT_PRODUCT_STOCK' END,
      'required', p_quantity,
      'available', v_ready,
      'mode', 'ready_product'
    );
  END IF;

  LOOP
    SELECT * INTO v_row
    FROM pg_temp.avail_unit_need
    WHERE required_qty > processed_qty + 0.0000001
    ORDER BY unit_id
    LIMIT 1;
    EXIT WHEN NOT FOUND;

    v_iter := v_iter + 1;
    IF v_iter > 1000 THEN
      RETURN jsonb_build_object('success', false, 'error', 'UNIT_RECIPE_CYCLE_OR_TOO_DEEP');
    END IF;

    v_delta := v_row.required_qty - v_row.processed_qty;
    SELECT iu.unit_type INTO v_unit_type
    FROM public.inventory_units iu
    WHERE iu.id = v_row.unit_id AND iu.branch_id = p_branch_id AND iu.is_active = true;
    IF v_unit_type IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVENTORY_UNIT_NOT_AVAILABLE', 'unit_id', v_row.unit_id);
    END IF;

    SELECT COALESCE(SUM(iub.quantity), 0)
    INTO v_available
    FROM public.inventory_unit_batches iub
    WHERE iub.unit_id = v_row.unit_id
      AND iub.branch_id = p_branch_id
      AND iub.warehouse_id = p_warehouse_id
      AND iub.quantity > 0;

    v_remaining_stock := GREATEST(v_available - v_row.stock_used, 0);
    v_cover := LEAST(v_delta, v_remaining_stock);
    v_shortage := GREATEST(v_delta - v_cover, 0);

    UPDATE pg_temp.avail_unit_need
    SET processed_qty = processed_qty + v_delta,
        stock_used = stock_used + v_cover
    WHERE unit_id = v_row.unit_id;

    IF v_shortage > 0 THEN
      IF v_unit_type <> 'manufactured' THEN
        RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_UNIT_STOCK', 'unit_id', v_row.unit_id, 'required', v_row.required_qty, 'available', v_available);
      END IF;

      IF NOT EXISTS (SELECT 1 FROM public.inventory_unit_recipes WHERE unit_id = v_row.unit_id)
         AND NOT EXISTS (SELECT 1 FROM public.inventory_unit_recipe_units WHERE unit_id = v_row.unit_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'MANUFACTURED_UNIT_HAS_NO_RECIPE', 'unit_id', v_row.unit_id);
      END IF;

      INSERT INTO pg_temp.avail_raw_need(raw_material_id, required_qty)
      SELECT iur.raw_material_id,
             v_shortage * iur.quantity * (1 + COALESCE(iur.wastage_percent, 0) / 100.0)
      FROM public.inventory_unit_recipes iur
      WHERE iur.unit_id = v_row.unit_id
      ON CONFLICT(raw_material_id) DO UPDATE
      SET required_qty = pg_temp.avail_raw_need.required_qty + EXCLUDED.required_qty;

      INSERT INTO pg_temp.avail_unit_need(unit_id, required_qty)
      SELECT iuru.component_unit_id,
             v_shortage * iuru.quantity * (1 + COALESCE(iuru.wastage_percent, 0) / 100.0)
      FROM public.inventory_unit_recipe_units iuru
      WHERE iuru.unit_id = v_row.unit_id
      ON CONFLICT(unit_id) DO UPDATE
      SET required_qty = pg_temp.avail_unit_need.required_qty + EXCLUDED.required_qty;
    END IF;
  END LOOP;

  FOR v_row IN SELECT * FROM pg_temp.avail_raw_need ORDER BY raw_material_id LOOP
    SELECT COALESCE(rmi.quantity, 0)
    INTO v_available
    FROM public.raw_material_inventory rmi
    WHERE rmi.raw_material_id = v_row.raw_material_id AND rmi.branch_id = p_branch_id;
    v_available := COALESCE(v_available, 0);
    IF v_available + 0.0000001 < v_row.required_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
        'raw_material_id', v_row.raw_material_id,
        'required', v_row.required_qty,
        'available', v_available
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'mode', 'recipe', 'quantity', p_quantity);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(p_branch_id uuid, p_warehouse_id uuid, p_items jsonb, p_reference_id uuid DEFAULT NULL::uuid, p_reference_number text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_item jsonb; v_product_id uuid; v_quantity numeric(14,4); v_link record; v_batch record; v_need numeric(14,6); v_take numeric(14,6); v_available numeric(14,6);
  v_total_cost numeric(18,4):=0; v_units jsonb:='[]'::jsonb; v_raws jsonb:='[]'::jsonb; v_ready jsonb:='[]'::jsonb; v_user_branch uuid; v_recipe_id uuid; v_yield numeric(14,6); v_res jsonb; v_recipe_component_count integer; v_link_count integer;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',true,'units_deducted','[]'::jsonb,'raw_materials_deducted','[]'::jsonb,'ready_products_deducted','[]'::jsonb,'errors','[]'::jsonb); END IF;
  SELECT branch_id INTO v_user_branch FROM public.users WHERE id=auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch<>p_branch_id THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need(unit_id uuid PRIMARY KEY,unit_name text,unit_type text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_raw_need(raw_material_id uuid PRIMARY KEY,raw_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_ready_need(product_id uuid PRIMARY KEY,product_name text,required_qty numeric(14,6) NOT NULL) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need; TRUNCATE pg_temp.sale_raw_need; TRUNCATE pg_temp.sale_ready_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id:=(v_item->>'product_id')::uuid; v_quantity:=COALESCE((v_item->>'quantity')::numeric,0);
    IF v_quantity<=0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY','product_id',v_product_id); END IF;
    IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=v_product_id AND p.branch_id=p_branch_id AND p.is_active=true) THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;

    v_res := public.check_product_availability(v_product_id, p_branch_id, p_warehouse_id, v_quantity);
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN RETURN v_res; END IF;

    IF COALESCE(v_res->>'mode', '') = 'ready_product' THEN
      INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty)
      SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id
      ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty;
      CONTINUE;
    END IF;

    SELECT COUNT(*) INTO v_link_count FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true;
    FOR v_link IN SELECT pul.unit_id,pul.quantity,iu.name AS unit_name,iu.unit_type FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id,unit_name,unit_type,required_qty) VALUES(v_link.unit_id,v_link.unit_name,v_link.unit_type,v_quantity*v_link.quantity) ON CONFLICT(unit_id) DO UPDATE SET required_qty=pg_temp.sale_unit_need.required_qty+EXCLUDED.required_qty;
    END LOOP;
    SELECT r.id,COALESCE(NULLIF(r.yield_quantity,0),1) INTO v_recipe_id,v_yield FROM public.recipes r WHERE r.product_id=v_product_id AND r.branch_id=p_branch_id AND COALESCE(r.is_active,true)=true ORDER BY COALESCE(r.version,1) DESC,r.created_at DESC LIMIT 1;
    v_recipe_component_count:=0;
    IF v_recipe_id IS NOT NULL THEN
      FOR v_link IN SELECT ri.raw_material_id,rm.name AS raw_name,ri.quantity/v_yield AS quantity_per_sale FROM public.recipe_items ri JOIN public.raw_materials rm ON rm.id=ri.raw_material_id WHERE ri.recipe_id=v_recipe_id AND NOT EXISTS(SELECT 1 FROM public.product_unit_links pul JOIN public.inventory_units iu ON iu.id=pul.unit_id WHERE pul.product_id=v_product_id AND iu.branch_id=p_branch_id AND iu.is_active=true AND regexp_replace(lower(btrim(iu.name)),'[ .]+$','','g')=regexp_replace(lower(btrim(rm.name)),'[ .]+$','','g')) LOOP
        v_recipe_component_count:=v_recipe_component_count+1;
        INSERT INTO pg_temp.sale_raw_need(raw_material_id,raw_name,required_qty) VALUES(v_link.raw_material_id,v_link.raw_name,v_quantity*v_link.quantity_per_sale) ON CONFLICT(raw_material_id) DO UPDATE SET required_qty=pg_temp.sale_raw_need.required_qty+EXCLUDED.required_qty;
      END LOOP;
    END IF;
    IF v_link_count=0 AND v_recipe_component_count=0 THEN INSERT INTO pg_temp.sale_ready_need(product_id,product_name,required_qty) SELECT p.id,p.name,v_quantity FROM public.products p WHERE p.id=v_product_id ON CONFLICT(product_id) DO UPDATE SET required_qty=pg_temp.sale_ready_need.required_qty+EXCLUDED.required_qty; END IF;
    v_recipe_id:=NULL; v_yield:=NULL;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need WHERE unit_type='manufactured' ORDER BY unit_id LOOP
    PERFORM public._ensure_inventory_unit_stock(v_link.unit_id, v_link.required_qty, p_warehouse_id, p_branch_id, 0);
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_unit_batches WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%',v_link.unit_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id LOOP
    SELECT COALESCE(quantity,0) INTO v_available FROM public.raw_material_inventory WHERE raw_material_id=v_link.raw_material_id AND branch_id=p_branch_id; v_available:=COALESCE(v_available,0);
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% available=%',v_link.raw_material_id,v_link.required_qty,v_available; END IF;
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id LOOP
    SELECT COALESCE(SUM(quantity),0) INTO v_available FROM public.inventory_batches WHERE product_id=v_link.product_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id;
    IF v_available<v_link.required_qty THEN RAISE EXCEPTION 'INSUFFICIENT_PRODUCT_STOCK product=% required=% available=%',v_link.product_id,v_link.required_qty,v_available; END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id LOOP
    v_need:=v_link.required_qty;
    FOR v_batch IN SELECT id,quantity,unit_cost,batch_number FROM public.inventory_unit_batches WHERE unit_id=v_link.unit_id AND branch_id=p_branch_id AND warehouse_id=p_warehouse_id AND quantity>0 ORDER BY created_at,id FOR UPDATE LOOP
      EXIT WHEN v_need<=0; v_take:=LEAST(v_need,v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity=quantity-v_take WHERE id=v_batch.id;
      INSERT INTO public.inventory_unit_entries(unit_id,branch_id,warehouse_id,quantity,unit_cost,entry_type,reference_type,reference_id,reference_number,batch_number,created_by) VALUES(v_link.unit_id,p_branch_id,p_warehouse_id,-v_take,v_batch.unit_cost,'sale','sale',p_reference_id,p_reference_number,v_batch.batch_number,auth.uid());
      v_need:=v_need-v_take; v_total_cost:=v_total_cost+(v_take*COALESCE(v_batch.unit_cost,0));
    END LOOP;
    v_units:=v_units||jsonb_build_object('unit_id',v_link.unit_id,'unit_name',v_link.unit_name,'unit_type',v_link.unit_type,'quantity',v_link.required_qty);
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id LOOP
    v_res:=public._raw_remove_fifo(v_link.raw_material_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'RAW_STOCK_CHANGED_DURING_SALE raw_material=% shortage=%',v_link.raw_material_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_raws:=v_raws||jsonb_build_object('raw_material_id',v_link.raw_material_id,'raw_name',v_link.raw_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id LOOP
    v_res:=public._product_inv_remove_fifo(v_link.product_id,p_warehouse_id,p_branch_id,v_link.required_qty,'sale','sale',p_reference_id,p_reference_number,auth.uid());
    IF COALESCE((v_res->>'shortage')::numeric,0)>0 THEN RAISE EXCEPTION 'PRODUCT_STOCK_CHANGED_DURING_SALE product=% shortage=%',v_link.product_id,v_res->>'shortage'; END IF;
    v_total_cost:=v_total_cost+COALESCE((v_res->>'total_cost')::numeric,0);
    v_ready:=v_ready||jsonb_build_object('product_id',v_link.product_id,'product_name',v_link.product_name,'quantity',v_link.required_qty,'total_cost',COALESCE((v_res->>'total_cost')::numeric,0));
  END LOOP;
  RETURN jsonb_build_object('success',true,'units_deducted',v_units,'raw_materials_deducted',v_raws,'ready_products_deducted',v_ready,'total_cost',v_total_cost,'errors','[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success',false,'error','SALE_INVENTORY_DEDUCTION_FAILED','detail',SQLERRM);
END;
$function$;

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903210614_fix_kitchen_send_order_state.sql
-- ----------------------------------------------------------------------------
create or replace function public.send_to_kitchen(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_item record;
  v_sent numeric;
  v_delta numeric;
  v_items_sent int := 0;
  v_all_sent boolean := true;
  v_uid uuid := auth.uid();
  v_first_sent_at timestamptz;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  end if;

  if not public.user_may_access_branch(v_order.branch_id) then
    return jsonb_build_object('success', false, 'error', 'BRANCH_DENIED');
  end if;

  if not (public.is_platform_admin()
          or public.has_permission('pos.sell')
          or public.has_permission('pos.manage_orders')
          or public.has_permission('pos.kds')
          or public.has_permission('pos.manage_kds')) then
    return jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  end if;

  if v_order.status in ('completed','cancelled') or coalesce(v_order.payment_status,'unpaid') = 'void' then
    return jsonb_build_object('success', false, 'error', 'ORDER_CLOSED');
  end if;

  for v_item in
    select oi.id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
    order by oi.created_at, oi.id
  loop
    select coalesce(oks.sent_quantity,0)
      into v_sent
    from public.order_kitchen_sends oks
    where oks.order_item_id = v_item.id;

    v_delta := greatest(coalesce(v_item.quantity,0) - coalesce(v_sent,0), 0);

    if v_delta > 0 then
      insert into public.order_kitchen_sends(order_id, order_item_id, sent_quantity, sent_at, sent_by)
      values (p_order_id, v_item.id, v_delta, now(), v_uid)
      on conflict (order_item_id)
      do update set
        sent_quantity = public.order_kitchen_sends.sent_quantity + excluded.sent_quantity,
        sent_at = excluded.sent_at,
        sent_by = excluded.sent_by;

      v_items_sent := v_items_sent + 1;
    end if;

    select coalesce(oks.sent_quantity,0)
      into v_sent
    from public.order_kitchen_sends oks
    where oks.order_item_id = v_item.id;

    if coalesce(v_sent,0) < coalesce(v_item.quantity,0) then
      v_all_sent := false;
    end if;
  end loop;

  select min(oks.sent_at)
    into v_first_sent_at
  from public.order_kitchen_sends oks
  where oks.order_id = p_order_id;

  if v_first_sent_at is not null then
    update public.orders
    set
      kitchen_status = case
        when kitchen_status = 'pending' then 'sent'
        else kitchen_status
      end,
      kitchen_sent_at = coalesce(kitchen_sent_at, v_first_sent_at)
    where id = p_order_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'items_sent', v_items_sent,
    'all_sent', v_all_sent
  );
end;
$function$;

update public.orders o
set
  kitchen_status = 'sent',
  kitchen_sent_at = coalesce(o.kitchen_sent_at, s.first_sent_at)
from (
  select order_id, min(sent_at) as first_sent_at
  from public.order_kitchen_sends
  group by order_id
) s
where o.id = s.order_id
  and o.kitchen_status = 'pending'
  and o.status not in ('completed','cancelled');


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903210747_fix_active_kitchen_send_order_state.sql
-- ----------------------------------------------------------------------------
create or replace function public.send_to_kitchen(p_order_id uuid, p_sent_by uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_branch_id uuid;
  v_status text;
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := coalesce(current_setting('role', true), '') = 'service_role';
  v_first_sent_at timestamptz;
begin
  begin
    select branch_id, status, order_number, table_id, order_type, guest_count
      into v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count
    from public.orders
    where id = p_order_id;

    if v_branch_id is null then
      return jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    end if;

    if v_status not in ('open', 'held') then
      return jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    end if;

    if v_table_id is not null then
      select name into v_table_name
      from public.dining_tables
      where id = v_table_id and branch_id = v_branch_id;
    end if;

    if not v_is_service_role then
      if auth.uid() is null then
        return jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
      end if;

      select branch_id into v_user_branch
      from public.users
      where id = auth.uid() and is_active = true;

      if not is_pos_admin()
         and coalesce(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id then
        return jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      end if;

      if not is_pos_admin() and not can_permission('pos.send_kitchen') then
        return jsonb_build_object(
          'success', false,
          'error', 'PERMISSION_DENIED',
          'detail', 'pos.send_kitchen'
        );
      end if;
    end if;

    create temp table if not exists _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) on commit drop;
    truncate _kns_delta;

    with candidates as (
      select
        oi.id as order_item_id,
        oi.quantity as target_quantity,
        oi.quantity - coalesce(s.sent_quantity, 0) as delta_quantity
      from public.order_items oi
      left join public.order_kitchen_sends s on s.order_item_id = oi.id
      where oi.order_id = p_order_id
        and oi.quantity > coalesce(s.sent_quantity, 0)
    ), upserted as (
      insert into public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      select
        v_branch_id,
        p_order_id,
        c.order_item_id,
        now(),
        coalesce(p_sent_by, auth.uid()),
        c.target_quantity
      from candidates c
      on conflict (order_item_id) do update
      set sent_quantity = excluded.sent_quantity,
          sent_at = now(),
          sent_by = excluded.sent_by
      where public.order_kitchen_sends.sent_quantity < excluded.sent_quantity
      returning id, order_item_id
    )
    insert into _kns_delta(order_item_id, send_id, delta_quantity)
    select u.order_item_id, u.id, c.delta_quantity
    from upserted u
    join candidates c on c.order_item_id = u.order_item_id;

    select count(*) into v_count from _kns_delta;

    if v_count > 0 then
      select coalesce(jsonb_agg(jsonb_build_object(
        'send_id', k.send_id,
        'order_item_id', k.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'station_code', coalesce(ks.code, 'main'),
        'quantity', k.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', coalesce(oi.modifiers_snapshot, '[]'::jsonb)
      ) order by oi.created_at), '[]'::jsonb)
      into v_sent_items
      from _kns_delta k
      join public.order_items oi on oi.id = k.order_item_id
      left join public.products p on p.id = oi.product_id
      left join public.categories c
        on c.id = p.category_id and c.branch_id = v_branch_id
      left join public.kitchen_stations ks
        on ks.id = c.kitchen_station_id and ks.is_active = true;
    end if;

    select not exists (
      select 1
      from public.order_items oi
      left join public.order_kitchen_sends s on s.order_item_id = oi.id
      where oi.order_id = p_order_id
        and oi.quantity > coalesce(s.sent_quantity, 0)
    ) into v_all_sent;

    select min(s.sent_at)
      into v_first_sent_at
    from public.order_kitchen_sends s
    where s.order_id = p_order_id;

    if v_first_sent_at is not null then
      update public.orders
      set
        kitchen_status = case
          when kitchen_status = 'pending' then 'sent'
          else kitchen_status
        end,
        kitchen_sent_at = coalesce(kitchen_sent_at, v_first_sent_at)
      where id = p_order_id;
    end if;

    return jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent
    );
  exception when others then
    return jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_FAILED',
      'detail', sqlerrm
    );
  end;
end;
$function$;

update public.orders o
set
  kitchen_status = 'sent',
  kitchen_sent_at = coalesce(o.kitchen_sent_at, s.first_sent_at)
from (
  select order_id, min(sent_at) as first_sent_at
  from public.order_kitchen_sends
  group by order_id
) s
where o.id = s.order_id
  and o.kitchen_status = 'pending'
  and o.status not in ('completed','cancelled');


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903211500_allow_delete_fully_returned_purchase.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_purchase public.purchases%ROWTYPE;
  v_is_fully_returned boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_purchase
  FROM public.purchases
  WHERE id = p_purchase_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_purchase.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.can_permission('purchases.delete') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED', 'detail', 'purchases.delete permission is required.');
  END IF;

  IF v_purchase.status = 'returned' THEN
    SELECT COALESCE(bool_and(COALESCE(returned_quantity, 0) >= quantity), false)
      INTO v_is_fully_returned
    FROM public.purchase_items
    WHERE purchase_id = p_purchase_id;

    IF NOT v_is_fully_returned OR COALESCE(v_purchase.returned_amount, 0) < COALESCE(v_purchase.total, 0) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FULLY_RETURNED', 'detail', 'Only fully returned purchases can be deleted.');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.supplier_payments WHERE purchase_id = p_purchase_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_HAS_SUPPLIER_PAYMENTS', 'detail', 'Purchase has supplier payments and cannot be deleted.');
    END IF;

    -- Inventory/accounting reversal records are intentionally preserved for audit.
    DELETE FROM public.purchases WHERE id = p_purchase_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
    VALUES (
      auth.uid(),
      'delete',
      'purchase',
      p_purchase_id,
      jsonb_build_object(
        'invoice_number', v_purchase.invoice_number,
        'status', v_purchase.status,
        'fully_returned', true,
        'preserved_reversal_audit', true
      ),
      v_purchase.branch_id
    );

    RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id, 'invoice_number', v_purchase.invoice_number, 'deleted_after_full_return', true);
  END IF;

  IF v_purchase.status NOT IN ('draft','cancelled') THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_REVERSAL_REQUIRED', 'detail', 'Completed, approved, submitted or partial purchases must be reversed/returned before deletion.');
  END IF;

  IF EXISTS (SELECT 1 FROM public.inventory_ledger WHERE reference_type = 'purchase' AND reference_id = p_purchase_id)
     OR EXISTS (SELECT 1 FROM public.journal_entries WHERE reference_type = 'purchase' AND reference_id = p_purchase_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_HAS_POSTINGS', 'detail', 'Purchase has inventory/accounting postings and cannot be hard-deleted before reversal.');
  END IF;

  DELETE FROM public.purchases WHERE id = p_purchase_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (auth.uid(),'delete','purchase',p_purchase_id,jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),v_purchase.branch_id);

  RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id, 'invoice_number', v_purchase.invoice_number);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903215500_safe_purchase_invoice_delete.sql
-- ----------------------------------------------------------------------------
-- Safe purchase invoice deletion.
-- Only non-posted invoices may be physically deleted. Completed/received invoices
-- must go through the existing return/reversal workflow so inventory and accounting
-- history cannot be silently removed.

CREATE OR REPLACE FUNCTION public.delete_purchase_invoice(p_purchase_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase public.purchases%ROWTYPE;
  v_role text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  END IF;

  SELECT * INTO v_purchase
  FROM public.purchases
  WHERE id = p_purchase_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF NOT public.user_may_access_branch(v_purchase.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF NOT public.can_permission('purchases.manage')
     AND v_role NOT IN ('super_admin','owner','branch_manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  IF v_purchase.status NOT IN ('draft','cancelled') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_REVERSAL_REQUIRED',
      'detail', 'Completed, approved, submitted, partial or returned purchases cannot be hard-deleted; reverse/return them first.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventory_ledger
    WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
  ) OR EXISTS (
    SELECT 1 FROM public.journal_entries
    WHERE reference_type = 'purchase' AND reference_id = p_purchase_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PURCHASE_HAS_POSTINGS',
      'detail', 'Purchase has inventory/accounting postings and cannot be hard-deleted.'
    );
  END IF;

  DELETE FROM public.purchases WHERE id = p_purchase_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details, branch_id)
  VALUES (
    auth.uid(),
    'delete',
    'purchase',
    p_purchase_id,
    jsonb_build_object('invoice_number', v_purchase.invoice_number, 'status', v_purchase.status),
    v_purchase.branch_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'invoice_number', v_purchase.invoice_number
  );
END;
$$;

REVOKE ALL ON FUNCTION public.delete_purchase_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_purchase_invoice(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260903220500_delete_unposted_purchase_on_cancel.sql
-- ----------------------------------------------------------------------------
-- Make the existing cancel action behave as a real delete for unposted purchase invoices.
-- This avoids requiring a new frontend button immediately while preserving accounting safety.

CREATE OR REPLACE FUNCTION public.delete_unposted_purchase_on_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'cancelled'
     AND OLD.status IN ('draft','submitted')
     AND NOT EXISTS (
       SELECT 1 FROM public.inventory_ledger
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.journal_entries
       WHERE reference_type = 'purchase' AND reference_id = NEW.id
     ) THEN
    DELETE FROM public.purchases WHERE id = NEW.id;
    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_unposted_purchase_on_cancel ON public.purchases;
CREATE TRIGGER trg_delete_unposted_purchase_on_cancel
AFTER UPDATE OF status ON public.purchases
FOR EACH ROW
WHEN (NEW.status = 'cancelled')
EXECUTE FUNCTION public.delete_unposted_purchase_on_cancel();


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260904002000_fix_kitchen_send_overload_ambiguity.sql
-- ----------------------------------------------------------------------------
-- Resolve ambiguous one-argument calls to send_to_kitchen.
--
-- The canonical RPC is public.send_to_kitchen(uuid, uuid default null), which
-- already supports both one-argument and two-argument callers. Keeping the
-- legacy public.send_to_kitchen(uuid) overload makes PostgreSQL unable to
-- choose a best candidate for calls such as send_to_kitchen($1).
--
-- Remove only the redundant legacy overload. Do not change the canonical
-- function body, permissions, RLS behavior, or kitchen send semantics.

drop function if exists public.send_to_kitchen(uuid);

