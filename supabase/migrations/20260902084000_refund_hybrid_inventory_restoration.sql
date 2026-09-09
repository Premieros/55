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
