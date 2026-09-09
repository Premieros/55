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
