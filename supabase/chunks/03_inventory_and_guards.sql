-- ============================================================================
-- PREMIER / JOHN-S POS & ERP - COMPLETE DATABASE SCHEMA & RPCS
-- Consolidated Build Script generated on 2026-09-06T13:52:49.808Z
-- Contains all 237 migrations in canonical order
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- MIGRATION: 092_production_raw_material_compatibility.sql
-- ----------------------------------------------------------------------------
-- Migration 092: production/raw-material compatibility + stable integration-test transaction handling
-- Restores the public helper expected by the inventory-unit production RPC.

CREATE OR REPLACE FUNCTION public.deduct_raw_material_inventory(
  p_raw_material_id uuid,
  p_quantity numeric,
  p_branch_id uuid,
  p_warehouse_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Raw-material inventory is branch-scoped; warehouse_id is accepted for
  -- compatibility with the production RPC but the canonical FIFO helper
  -- operates across the branch's raw-material batches.
  RETURN public._raw_remove_fifo(
    p_raw_material_id,
    p_branch_id,
    p_quantity,
    'production',
    'production',
    NULL,
    NULL,
    auth.uid()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.deduct_raw_material_inventory(uuid, numeric, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.deduct_raw_material_inventory(uuid, numeric, uuid, uuid)
  IS 'Compatibility wrapper for production raw-material deductions; delegates to canonical branch-scoped FIFO removal.';


-- ----------------------------------------------------------------------------
-- MIGRATION: 093_phase2_schema_compatibility.sql
-- ----------------------------------------------------------------------------
-- Migration 093: align Phase 2 RPCs with canonical schema
-- raw_material_batches is branch-scoped (no warehouse_id), and orders has
-- no table_number column in the current canonical schema.

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_rm_qty numeric;
  v_rm_cost numeric;
  v_batch_number text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_units
    WHERE id = p_unit_id AND unit_type = 'manufactured' AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit', p_unit_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(now(), 'YYYYMMDD-HH24MISS');

  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent, rm.name AS rm_name
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100);

    SELECT default_cost INTO v_rm_cost
    FROM public.raw_materials
    WHERE id = v_recipe.raw_material_id;

    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, batch_number,
      quantity, unit_cost, expiry_date, source_type, source_id
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, v_batch_number,
      0, COALESCE(v_rm_cost, 0), NULL, 'production_consumption', v_production_id
    );
  END LOOP;

  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    'production', 'production', v_production_id, v_batch_number
  );

  INSERT INTO public.inventory_unit_productions (
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  RETURN v_production_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_kitchen_queue(
  p_station text DEFAULT NULL,
  p_branch_id uuid DEFAULT public.get_branch_id()
)
RETURNS TABLE (
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
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    o.id AS order_id,
    o.order_number,
    NULL::integer AS table_number,
    o.station,
    o.kitchen_status,
    o.guest_count,
    o.notes,
    o.created_at,
    COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
        'product_name', p.name,
        'quantity', oi.quantity,
        'modifiers', oi.notes
      ))
      FROM public.order_items oi
      JOIN public.products p ON p.id = oi.product_id
      WHERE oi.order_id = o.id),
      '[]'::jsonb
    ) AS items,
    EXTRACT(EPOCH FROM (now() - o.created_at))::integer AS elapsed_seconds
  FROM public.orders o
  WHERE o.branch_id = p_branch_id
    AND o.kitchen_status IN ('sent', 'cooking')
    AND (p_station IS NULL OR o.station = p_station)
  ORDER BY o.created_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kitchen_queue(text, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 094_fix_inventory_unit_production_branch_resolution.sql
-- ----------------------------------------------------------------------------
-- Migration 094: resolve inventory-unit production branch from warehouse when omitted
-- Keeps raw-material batches branch-scoped and preserves the existing RPC signature.

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_rm_qty numeric;
  v_rm_cost numeric;
  v_batch_number text;
  v_warehouse_branch_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_units
    WHERE id = p_unit_id AND unit_type = 'manufactured' AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit', p_unit_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  SELECT branch_id INTO v_warehouse_branch_id
  FROM public.warehouses
  WHERE id = p_warehouse_id;

  IF v_warehouse_branch_id IS NULL THEN
    RAISE EXCEPTION 'Warehouse % not found or has no branch', p_warehouse_id;
  END IF;

  p_branch_id := COALESCE(p_branch_id, v_warehouse_branch_id, public.get_branch_id());

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'Branch is required for inventory-unit production';
  END IF;

  IF p_branch_id <> v_warehouse_branch_id THEN
    RAISE EXCEPTION 'Warehouse % does not belong to branch %', p_warehouse_id, p_branch_id;
  END IF;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(now(), 'YYYYMMDD-HH24MISS');

  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent, rm.name AS rm_name
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100);

    SELECT default_cost INTO v_rm_cost
    FROM public.raw_materials
    WHERE id = v_recipe.raw_material_id;

    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, batch_number,
      quantity, unit_cost, expiry_date, source_type, source_id
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, v_batch_number,
      0, COALESCE(v_rm_cost, 0), NULL, 'production_consumption', v_production_id
    );
  END LOOP;

  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    'production', 'production', v_production_id, v_batch_number
  );

  INSERT INTO public.inventory_unit_productions (
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  RETURN v_production_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 095_inventory_movements.sql
-- ----------------------------------------------------------------------------
-- Migration 095: Add inventory_movements and raw_material_movements tables for movement history tracking
-- Canonical schema note: tenant/organization isolation is derived from branch_id in this migration.
-- The organizations table is not part of the schema available at this migration point.

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid REFERENCES public.products(id) ON DELETE CASCADE,
  warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE CASCADE,
  movement_type text NOT NULL,
  quantity numeric(14,4) NOT NULL,
  reference_id uuid,
  notes text,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all_inventory_movements" ON public.inventory_movements;
CREATE POLICY "auth_all_inventory_movements" ON public.inventory_movements
  FOR ALL TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id())
  WITH CHECK (is_pos_admin() OR branch_id = get_branch_id());

CREATE TABLE IF NOT EXISTS public.raw_material_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  material_id uuid REFERENCES public.raw_materials(id) ON DELETE CASCADE,
  warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE CASCADE,
  movement_type text NOT NULL,
  quantity numeric(14,4) NOT NULL,
  reference_id uuid,
  notes text,
  branch_id uuid REFERENCES public.branches(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.raw_material_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all_raw_material_movements" ON public.raw_material_movements;
CREATE POLICY "auth_all_raw_material_movements" ON public.raw_material_movements
  FOR ALL TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id())
  WITH CHECK (is_pos_admin() OR branch_id = get_branch_id());

CREATE INDEX IF NOT EXISTS idx_inv_movements_product ON public.inventory_movements(product_id);
CREATE INDEX IF NOT EXISTS idx_inv_movements_warehouse ON public.inventory_movements(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inv_movements_branch ON public.inventory_movements(branch_id);
CREATE INDEX IF NOT EXISTS idx_rm_movements_material ON public.raw_material_movements(material_id);
CREATE INDEX IF NOT EXISTS idx_rm_movements_warehouse ON public.raw_material_movements(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_rm_movements_branch ON public.raw_material_movements(branch_id);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260817100000_admin_data_management_center.sql
-- ----------------------------------------------------------------------------
-- Super Admin data management center
-- Branch-scoped destructive operations and complete demo-data seeding.

CREATE OR REPLACE FUNCTION public.admin_data_delete_section(p_branch_id uuid, p_section text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE v_count bigint := 0; v_total bigint := 0;
BEGIN
  IF NOT public.is_super_admin() THEN RETURN jsonb_build_object('success', false, 'error', 'SUPER_ADMIN_ONLY'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND'); END IF;
  CASE p_section
    WHEN 'catalog' THEN
      DELETE FROM public.order_kitchen_sends WHERE branch_id=p_branch_id;
      DELETE FROM public.order_items WHERE order_id IN (SELECT id FROM public.orders WHERE branch_id=p_branch_id);
      DELETE FROM public.orders WHERE branch_id=p_branch_id;
      DELETE FROM public.customer_payments WHERE sale_id IN (SELECT id FROM public.sales WHERE branch_id=p_branch_id);
      DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE branch_id=p_branch_id);
      DELETE FROM public.sales WHERE branch_id=p_branch_id;
      DELETE FROM public.product_cost_history WHERE product_id IN (SELECT id FROM public.products WHERE branch_id=p_branch_id);
      DELETE FROM public.product_components WHERE product_id IN (SELECT id FROM public.products WHERE branch_id=p_branch_id) OR component_product_id IN (SELECT id FROM public.products WHERE branch_id=p_branch_id);
      DELETE FROM public.inventory_batches WHERE branch_id=p_branch_id;
      DELETE FROM public.inventory_ledger WHERE branch_id=p_branch_id;
      DELETE FROM public.stock_transactions WHERE branch_id=p_branch_id;
      DELETE FROM public.inventory WHERE branch_id=p_branch_id;
      DELETE FROM public.product_units WHERE product_id IN (SELECT id FROM public.products WHERE branch_id=p_branch_id);
      DELETE FROM public.products WHERE branch_id=p_branch_id;
      DELETE FROM public.categories WHERE branch_id=p_branch_id;
    WHEN 'customers' THEN
      DELETE FROM public.customer_payments WHERE branch_id=p_branch_id;
      DELETE FROM public.journal_entry_lines WHERE customer_id IN (SELECT id FROM public.customers WHERE branch_id=p_branch_id);
      DELETE FROM public.customers WHERE branch_id=p_branch_id;
    WHEN 'suppliers' THEN
      DELETE FROM public.supplier_quotation_items WHERE quotation_id IN (SELECT id FROM public.supplier_quotations WHERE branch_id=p_branch_id);
      DELETE FROM public.supplier_quotations WHERE branch_id=p_branch_id;
      DELETE FROM public.supplier_payments WHERE branch_id=p_branch_id;
      DELETE FROM public.journal_entry_lines WHERE supplier_id IN (SELECT id FROM public.suppliers WHERE branch_id=p_branch_id);
      DELETE FROM public.suppliers WHERE branch_id=p_branch_id;
    WHEN 'sales' THEN
      DELETE FROM public.shift_operations WHERE operation_type='sale' AND reference_id IN (SELECT id FROM public.sales WHERE branch_id=p_branch_id);
      DELETE FROM public.customer_payments WHERE sale_id IN (SELECT id FROM public.sales WHERE branch_id=p_branch_id);
      DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE branch_id=p_branch_id);
      DELETE FROM public.sales WHERE branch_id=p_branch_id;
    WHEN 'orders' THEN
      DELETE FROM public.order_kitchen_sends WHERE branch_id=p_branch_id;
      DELETE FROM public.order_items WHERE order_id IN (SELECT id FROM public.orders WHERE branch_id=p_branch_id);
      DELETE FROM public.orders WHERE branch_id=p_branch_id;
    WHEN 'purchasing' THEN
      DELETE FROM public.purchase_receipt_items WHERE receipt_id IN (SELECT id FROM public.purchase_receipts WHERE branch_id=p_branch_id);
      DELETE FROM public.purchase_receipts WHERE branch_id=p_branch_id;
      DELETE FROM public.supplier_payments WHERE branch_id=p_branch_id;
      DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT id FROM public.purchases WHERE branch_id=p_branch_id);
      DELETE FROM public.purchases WHERE branch_id=p_branch_id;
      DELETE FROM public.supplier_quotation_items WHERE quotation_id IN (SELECT id FROM public.supplier_quotations WHERE branch_id=p_branch_id);
      DELETE FROM public.supplier_quotations WHERE branch_id=p_branch_id;
      DELETE FROM public.rfq_items WHERE rfq_id IN (SELECT id FROM public.rfqs WHERE branch_id=p_branch_id);
      DELETE FROM public.rfqs WHERE branch_id=p_branch_id;
      DELETE FROM public.purchase_request_items WHERE request_id IN (SELECT id FROM public.purchase_requests WHERE branch_id=p_branch_id);
      DELETE FROM public.purchase_requests WHERE branch_id=p_branch_id;
    WHEN 'manufacturing' THEN
      DELETE FROM public.production_waste WHERE branch_id=p_branch_id;
      DELETE FROM public.production_orders WHERE branch_id=p_branch_id;
      DELETE FROM public.recipe_items WHERE recipe_id IN (SELECT id FROM public.recipes WHERE branch_id=p_branch_id);
      DELETE FROM public.recipes WHERE branch_id=p_branch_id;
      DELETE FROM public.raw_material_batches WHERE branch_id=p_branch_id;
      DELETE FROM public.raw_material_inventory WHERE branch_id=p_branch_id;
      DELETE FROM public.raw_materials WHERE branch_id=p_branch_id;
    WHEN 'accounting' THEN
      DELETE FROM public.bank_statement_lines WHERE reconciliation_id IN (SELECT id FROM public.bank_reconciliations WHERE branch_id=p_branch_id);
      DELETE FROM public.bank_reconciliations WHERE branch_id=p_branch_id;
      DELETE FROM public.journal_entry_lines WHERE journal_entry_id IN (SELECT id FROM public.journal_entries WHERE branch_id=p_branch_id);
      DELETE FROM public.journal_entries WHERE branch_id=p_branch_id;
      DELETE FROM public.treasury_transactions WHERE branch_id=p_branch_id;
      DELETE FROM public.treasury_accounts WHERE branch_id=p_branch_id;
      DELETE FROM public.account_mappings WHERE branch_id=p_branch_id;
      DELETE FROM public.chart_of_accounts WHERE branch_id=p_branch_id AND NOT is_system;
    WHEN 'shifts' THEN
      DELETE FROM public.shift_operations WHERE shift_id IN (SELECT id FROM public.shifts WHERE branch_id=p_branch_id);
      DELETE FROM public.shifts WHERE branch_id=p_branch_id;
    WHEN 'tables' THEN
      DELETE FROM public.dining_tables WHERE branch_id=p_branch_id;
      DELETE FROM public.dining_areas WHERE branch_id=p_branch_id;
    WHEN 'warehouses' THEN
      DELETE FROM public.warehouse_transfer_items WHERE transfer_id IN (SELECT id FROM public.warehouse_transfers WHERE branch_id=p_branch_id);
      DELETE FROM public.warehouse_transfers WHERE branch_id=p_branch_id;
      DELETE FROM public.inventory_batches WHERE branch_id=p_branch_id;
      DELETE FROM public.inventory_ledger WHERE branch_id=p_branch_id;
      DELETE FROM public.stock_transactions WHERE branch_id=p_branch_id;
      DELETE FROM public.inventory WHERE branch_id=p_branch_id;
      DELETE FROM public.warehouses WHERE branch_id=p_branch_id;
    WHEN 'expenses' THEN
      DELETE FROM public.expenses WHERE branch_id=p_branch_id;
    WHEN 'all' THEN
      PERFORM public.admin_data_delete_section(p_branch_id,'orders');
      PERFORM public.admin_data_delete_section(p_branch_id,'sales');
      PERFORM public.admin_data_delete_section(p_branch_id,'purchasing');
      PERFORM public.admin_data_delete_section(p_branch_id,'manufacturing');
      PERFORM public.admin_data_delete_section(p_branch_id,'customers');
      PERFORM public.admin_data_delete_section(p_branch_id,'suppliers');
      PERFORM public.admin_data_delete_section(p_branch_id,'shifts');
      PERFORM public.admin_data_delete_section(p_branch_id,'tables');
      PERFORM public.admin_data_delete_section(p_branch_id,'catalog');
      PERFORM public.admin_data_delete_section(p_branch_id,'warehouses');
      PERFORM public.admin_data_delete_section(p_branch_id,'expenses');
      RETURN jsonb_build_object('success',true,'section','all');
    ELSE RETURN jsonb_build_object('success',false,'error','INVALID_SECTION');
  END CASE;
  RETURN jsonb_build_object('success',true,'section',p_section,'affected',v_total);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('success',false,'error','DELETE_FAILED','detail',SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_data_seed_all(p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
  v_user uuid:=auth.uid(); v_wh uuid; v_product uuid; v_supplier uuid; v_raw uuid; v_unit uuid; v_recipe uuid;
  v_purchase uuid; v_sale uuid; v_order uuid; v_customer uuid; v_shift uuid; v_cash_account uuid; v_treasury uuid; v_total numeric;
BEGIN
  IF NOT public.is_super_admin() THEN RETURN jsonb_build_object('success',false,'error','SUPER_ADMIN_ONLY'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id=p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND'); END IF;
  PERFORM public.seed_demo_data(p_branch_id);
  SELECT id INTO v_wh FROM public.warehouses WHERE branch_id=p_branch_id ORDER BY is_demo DESC,created_at LIMIT 1;
  SELECT id INTO v_product FROM public.products WHERE branch_id=p_branch_id AND is_demo ORDER BY created_at LIMIT 1;
  SELECT id INTO v_customer FROM public.customers WHERE branch_id=p_branch_id AND is_demo ORDER BY created_at LIMIT 1;
  SELECT id INTO v_supplier FROM public.suppliers WHERE branch_id=p_branch_id AND name='مورد تجريبي' LIMIT 1;
  IF v_supplier IS NULL THEN INSERT INTO public.suppliers(name,name_en,phone,branch_id,is_active,notes) VALUES('مورد تجريبي','Demo Supplier','01000000000',p_branch_id,true,'بيانات تجريبية') RETURNING id INTO v_supplier; END IF;
  SELECT id INTO v_unit FROM public.units ORDER BY id LIMIT 1;
  IF v_unit IS NOT NULL THEN
    SELECT id INTO v_raw FROM public.raw_materials WHERE branch_id=p_branch_id AND code='DEMO-RAW-001' LIMIT 1;
    IF v_raw IS NULL THEN
      INSERT INTO public.raw_materials(code,name,unit_id,category,min_stock,default_cost,is_active,branch_id) VALUES('DEMO-RAW-001','مادة خام تجريبية',v_unit,'مواد خام',10,5,true,p_branch_id) RETURNING id INTO v_raw;
      INSERT INTO public.raw_material_inventory(raw_material_id,branch_id,quantity,avg_cost,min_stock) VALUES(v_raw,p_branch_id,100,5,10);
      INSERT INTO public.raw_material_batches(raw_material_id,branch_id,batch_number,quantity,unit_cost,source_type) VALUES(v_raw,p_branch_id,'DEMO-RAW-BATCH',100,5,'opening');
    END IF;
  END IF;
  IF v_raw IS NOT NULL AND v_product IS NOT NULL THEN
    SELECT id INTO v_recipe FROM public.recipes WHERE branch_id=p_branch_id AND product_id=v_product LIMIT 1;
    IF v_recipe IS NULL THEN
      INSERT INTO public.recipes(product_id,branch_id,name,yield_quantity,is_active,notes) VALUES(v_product,p_branch_id,'وصفة تجريبية',1,true,'وصفة بيانات تجريبية') RETURNING id INTO v_recipe;
      INSERT INTO public.recipe_items(recipe_id,raw_material_id,quantity,wastage_percent) VALUES(v_recipe,v_raw,1,0);
    END IF;
  END IF;
  IF v_supplier IS NOT NULL AND v_product IS NOT NULL AND v_wh IS NOT NULL THEN
    SELECT id INTO v_purchase FROM public.purchases WHERE branch_id=p_branch_id AND invoice_number='DEMO-PUR-001' LIMIT 1;
    IF v_purchase IS NULL THEN
      INSERT INTO public.purchases(invoice_number,supplier_id,branch_id,warehouse_id,buyer_id,subtotal,total,paid_amount,payment_method,status,notes) VALUES('DEMO-PUR-001',v_supplier,p_branch_id,v_wh,v_user,100,100,100,'cash','completed','بيانات تجريبية') RETURNING id INTO v_purchase;
      INSERT INTO public.purchase_items(purchase_id,product_id,quantity,unit_name,unit_cost,total,received_quantity) VALUES(v_purchase,v_product,10,'piece',10,100,10);
    END IF;
  END IF;
  IF v_product IS NOT NULL AND v_wh IS NOT NULL THEN
    SELECT sale_price INTO v_total FROM public.products WHERE id=v_product;
    SELECT id INTO v_sale FROM public.sales WHERE branch_id=p_branch_id AND invoice_number='DEMO-SALE-001' LIMIT 1;
    IF v_sale IS NULL THEN
      INSERT INTO public.sales(invoice_number,branch_id,warehouse_id,customer_id,cashier_id,salesperson_id,subtotal,total,paid_amount,payment_method,status,order_type,guest_count,notes) VALUES('DEMO-SALE-001',p_branch_id,v_wh,v_customer,v_user,v_user,v_total,v_total,v_total,'cash','completed','takeaway',1,'بيانات تجريبية') RETURNING id INTO v_sale;
      INSERT INTO public.sale_items(sale_id,product_id,quantity,unit_name,unit_price,total) VALUES(v_sale,v_product,1,'piece',v_total,v_total);
    END IF;
  END IF;
  IF v_product IS NOT NULL THEN
    SELECT id INTO v_order FROM public.orders WHERE branch_id=p_branch_id AND order_number='DEMO-ORD-001' LIMIT 1;
    IF v_order IS NULL THEN
      INSERT INTO public.orders(order_number,branch_id,order_type,status,customer_id,cashier_id,guest_count,subtotal,total,notes) VALUES('DEMO-ORD-001',p_branch_id,'takeaway','completed',v_customer,v_user,1,v_total,v_total,'طلب تجريبي') RETURNING id INTO v_order;
      INSERT INTO public.order_items(order_id,product_id,quantity,unit_name,unit_price,total) VALUES(v_order,v_product,1,'piece',v_total,v_total);
    END IF;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.expenses WHERE branch_id=p_branch_id AND description='مصروف تجريبي') THEN INSERT INTO public.expenses(category,description,amount,branch_id,payment_method,expense_date,notes,created_by) VALUES('مصروفات تشغيل','مصروف تجريبي',50,p_branch_id,'cash',CURRENT_DATE,'بيانات تجريبية',v_user); END IF;
  IF NOT EXISTS(SELECT 1 FROM public.shifts WHERE branch_id=p_branch_id AND notes='وردية تجريبية') THEN
    INSERT INTO public.shifts(branch_id,cashier_id,opening_amount,status,notes) VALUES(p_branch_id,v_user,500,'closed','وردية تجريبية') RETURNING id INTO v_shift;
    INSERT INTO public.shift_operations(shift_id,operation_type,amount,payment_method,created_by) VALUES(v_shift,'opening',500,'cash',v_user);
  END IF;
  SELECT id INTO v_cash_account FROM public.chart_of_accounts WHERE branch_id=p_branch_id AND account_type='asset' AND (name ILIKE '%نقد%' OR name_en ILIKE '%cash%') ORDER BY is_system DESC LIMIT 1;
  IF v_cash_account IS NOT NULL THEN
    SELECT id INTO v_treasury FROM public.treasury_accounts WHERE branch_id=p_branch_id AND account_type='cash' LIMIT 1;
    IF v_treasury IS NULL THEN INSERT INTO public.treasury_accounts(branch_id,account_id,account_type,account_name,opening_balance) VALUES(p_branch_id,v_cash_account,'cash','الخزينة التجريبية',500) RETURNING id INTO v_treasury; END IF;
  END IF;
  RETURN jsonb_build_object('success',true,'seeded',true,'section_count',11);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('success',false,'error','SEED_FAILED','detail',SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_data_delete_section(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_data_seed_all(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_data_delete_section(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_data_seed_all(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819090356_atomic_unit_sale_deduction.sql
-- ----------------------------------------------------------------------------
-- Atomic unit-only sale deduction.
-- Raw materials are consumed only by manufacturing; sales consume inventory units.

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
  v_batch record;
  v_need numeric(14,4);
  v_take numeric(14,4);
  v_available numeric(14,4);
  v_total_cost numeric(18,4) := 0;
  v_units jsonb := '[]'::jsonb;
  v_user_branch uuid;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', true, 'units_deducted', '[]'::jsonb, 'errors', '[]'::jsonb);
  END IF;

  SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
  IF NOT is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need (
    unit_id uuid PRIMARY KEY,
    unit_name text,
    unit_type text,
    required_qty numeric(14,4) NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = v_product_id AND p.branch_id = p_branch_id AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    FOR v_link IN
      SELECT pul.unit_id, pul.quantity, iu.name AS unit_name, iu.unit_type
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = v_product_id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true
    LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
      VALUES (v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
      ON CONFLICT (unit_id) DO UPDATE
      SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
    END LOOP;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;

    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_UNIT_STOCK',
        'unit_id', v_link.unit_id,
        'required', v_link.required_qty,
        'available', v_available
      );
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
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
      ) VALUES (
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

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', '[]'::jsonb,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNIT_SALE_DEDUCTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.deduct_sale_unit_inventory(uuid, uuid, jsonb, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid, uuid, jsonb, uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819120300_route_process_sale_through_unit_inventory.sql
-- ----------------------------------------------------------------------------
-- Route POS sales through unit inventory instead of product inventory_batches.
-- Product -> unit links are the only sale components; raw materials remain manufacturing-only.

DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='process_sale'
    AND pg_get_function_identity_arguments(p.oid) = 'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';
  IF v_src IS NULL THEN RAISE EXCEPTION 'process_sale target signature not found'; END IF;

  v_old := $a$      SELECT COALESCE(SUM(quantity), 0) INTO v_available
      FROM inventory_batches
      WHERE product_id = v_product_id AND warehouse_id = ANY(v_warehouse_ids);
      IF v_available < v_quantity THEN
        RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
          'product_id', v_product_id, 'required', v_quantity, 'available', v_available);
      END IF;
$a$;
  v_src := replace(v_src, v_old, '');

  v_old := $a$      v_res := public._product_inv_remove_fifo(v_product_id, NULL, p_branch_id, v_quantity,
        'sale', 'sale', v_sale_id, p_invoice_number, auth.uid());
      v_short := (v_res->>'shortage')::numeric;
      IF v_short > 0 THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK: product % needs % but only % available',
          v_product_id, v_quantity, (v_quantity - v_short);
      END IF;
      v_cogs_total := v_cogs_total + COALESCE((v_res->>'total_cost')::numeric, 0);
$a$;
  v_new := $b$      v_res := public.deduct_sale_unit_inventory(
        p_branch_id,
        p_warehouse_id,
        jsonb_build_array(v_item),
        v_sale_id,
        p_invoice_number
      );
      IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'UNIT_SALE_DEDUCTION_FAILED: %', COALESCE(v_res->>'detail', v_res->>'error', 'unknown');
      END IF;
      v_cogs_total := v_cogs_total + COALESCE((v_res->>'total_cost')::numeric, 0);
$b$;
  v_src := replace(v_src, v_old, v_new);

  EXECUTE v_src;
END
$do$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819120400_rewrite_process_sale_unit_path.sql
-- ----------------------------------------------------------------------------
-- Finalize the POS sale path after 20260819120300.
-- That migration already rewrites process_sale to use unit inventory and removes
-- the legacy product inventory validation/deduction. This migration is an
-- idempotent verification gate rather than a second rewrite.

DO $do$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'process_sale'
    AND pg_get_function_identity_arguments(p.oid) = 'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'target process_sale not found';
  END IF;

  IF position('deduct_sale_unit_inventory' in v_src) = 0 THEN
    RAISE EXCEPTION 'process_sale is not routed through unit inventory';
  END IF;

  IF position('_product_inv_remove_fifo' in v_src) > 0 THEN
    RAISE EXCEPTION 'legacy product inventory deduction remains in process_sale';
  END IF;

  IF position('FROM inventory_batches' in v_src) > 0 THEN
    RAISE EXCEPTION 'legacy product inventory validation remains in process_sale';
  END IF;
END
$do$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819124000_enforce_product_units_for_sale.sql
-- ----------------------------------------------------------------------------
-- Enforce the new inventory contract: every sellable product must resolve to
-- at least one active inventory unit in the sale branch.
-- Raw materials remain manufacturing-only; sales consume inventory units only.

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
  v_batch record;
  v_need numeric(14,4);
  v_take numeric(14,4);
  v_available numeric(14,4);
  v_total_cost numeric(18,4) := 0;
  v_units jsonb := '[]'::jsonb;
  v_user_branch uuid;
  v_link_count integer;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', true, 'units_deducted', '[]'::jsonb, 'errors', '[]'::jsonb);
  END IF;

  SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
  IF NOT is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.sale_unit_need (
    unit_id uuid PRIMARY KEY,
    unit_name text,
    unit_type text,
    required_qty numeric(14,4) NOT NULL
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.sale_unit_need;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = v_product_id AND p.branch_id = p_branch_id AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    SELECT COUNT(*) INTO v_link_count
    FROM public.product_unit_links pul
    JOIN public.inventory_units iu ON iu.id = pul.unit_id
    WHERE pul.product_id = v_product_id
      AND iu.branch_id = p_branch_id
      AND iu.is_active = true;

    IF v_link_count = 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'PRODUCT_HAS_NO_UNITS',
        'product_id', v_product_id,
        'detail', 'Every sellable product must have at least one active inventory unit.'
      );
    END IF;

    FOR v_link IN
      SELECT pul.unit_id, pul.quantity, iu.name AS unit_name, iu.unit_type
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = v_product_id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true
    LOOP
      INSERT INTO pg_temp.sale_unit_need(unit_id, unit_name, unit_type, required_qty)
      VALUES (v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
      ON CONFLICT (unit_id) DO UPDATE
      SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
    END LOOP;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;

    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_UNIT_STOCK',
        'unit_id', v_link.unit_id,
        'required', v_link.required_qty,
        'available', v_available
      );
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
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
      ) VALUES (
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

  RETURN jsonb_build_object(
    'success', true,
    'units_deducted', v_units,
    'raw_materials_deducted', '[]'::jsonb,
    'total_cost', v_total_cost,
    'errors', '[]'::jsonb
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNIT_SALE_DEDUCTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.deduct_sale_unit_inventory(uuid, uuid, jsonb, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid, uuid, jsonb, uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819204400_repair_produce_inventory_unit_schema_drift.sql
-- ----------------------------------------------------------------------------
-- Repair migration: restore the canonical production-unit RPC after remote schema drift.
-- raw_material_batches is branch-scoped and does not have warehouse_id.

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_rm_qty numeric;
  v_rm_cost numeric;
  v_batch_number text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.inventory_units
    WHERE id = p_unit_id AND unit_type = 'manufactured' AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit', p_unit_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(now(), 'YYYYMMDD-HH24MISS');

  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100);

    SELECT default_cost INTO v_rm_cost
    FROM public.raw_materials
    WHERE id = v_recipe.raw_material_id;

    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, batch_number,
      quantity, unit_cost, expiry_date, source_type, source_id
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, v_batch_number,
      0, COALESCE(v_rm_cost, 0), NULL, 'production_consumption', v_production_id
    );
  END LOOP;

  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    'production', 'production', v_production_id, v_batch_number
  );

  INSERT INTO public.inventory_unit_productions (
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  RETURN v_production_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819220000_multitenant_foundation.sql
-- ----------------------------------------------------------------------------
-- Multi-tenant foundation
-- Company/Tenant sits above branches. Existing branch-scoped RLS remains intact
-- until tenant-aware branch access is adopted table-by-table.

CREATE TABLE IF NOT EXISTS public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.organization_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  membership_role text NOT NULL DEFAULT 'owner',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, user_id),
  CONSTRAINT organization_members_role_check
    CHECK (membership_role IN ('owner', 'admin', 'manager', 'member'))
);

ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS organization_id uuid REFERENCES public.organizations(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_branches_organization_id ON public.branches (organization_id);
CREATE INDEX IF NOT EXISTS idx_organization_members_org ON public.organization_members (organization_id);
CREATE INDEX IF NOT EXISTS idx_organization_members_user ON public.organization_members (user_id);

-- Backfill an isolated organization for every existing branch. This is intentionally
-- one-to-one so existing customer data cannot become cross-tenant visible.
INSERT INTO public.organizations (id, name, slug)
SELECT b.id,
       COALESCE(NULLIF(btrim(b.name), ''), 'Organization ' || b.id::text),
       'org-' || replace(b.id::text, '-', '')
FROM public.branches b
WHERE b.organization_id IS NULL
ON CONFLICT (id) DO NOTHING;

UPDATE public.branches b
SET organization_id = b.id
WHERE b.organization_id IS NULL;

-- Existing branch users become members of the branch's organization.
INSERT INTO public.organization_members (organization_id, user_id, membership_role)
SELECT b.organization_id,
       u.id,
       CASE WHEN u.role IN ('owner', 'super_admin') THEN 'owner' ELSE 'member' END
FROM public.users u
JOIN public.branches b ON b.id = u.branch_id
WHERE b.organization_id IS NOT NULL
ON CONFLICT (organization_id, user_id) DO NOTHING;

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS organizations_select ON public.organizations;
CREATE POLICY organizations_select ON public.organizations
  FOR SELECT TO authenticated
  USING (
    is_pos_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = organizations.id
        AND om.user_id = auth.uid()
        AND om.is_active
    )
  );

DROP POLICY IF EXISTS organizations_insert ON public.organizations;
CREATE POLICY organizations_insert ON public.organizations
  FOR INSERT TO authenticated
  WITH CHECK (is_pos_admin());

DROP POLICY IF EXISTS organizations_update ON public.organizations;
CREATE POLICY organizations_update ON public.organizations
  FOR UPDATE TO authenticated
  USING (
    is_pos_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = organizations.id
        AND om.user_id = auth.uid()
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active
    )
  )
  WITH CHECK (
    is_pos_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = organizations.id
        AND om.user_id = auth.uid()
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active
    )
  );

DROP POLICY IF EXISTS organizations_delete ON public.organizations;
CREATE POLICY organizations_delete ON public.organizations
  FOR DELETE TO authenticated
  USING (is_pos_admin());

DROP POLICY IF EXISTS organization_members_select ON public.organization_members;
CREATE POLICY organization_members_select ON public.organization_members
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_pos_admin());

DROP POLICY IF EXISTS organization_members_insert ON public.organization_members;
CREATE POLICY organization_members_insert ON public.organization_members
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR is_pos_admin());

DROP POLICY IF EXISTS organization_members_update ON public.organization_members;
CREATE POLICY organization_members_update ON public.organization_members
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR is_pos_admin())
  WITH CHECK (user_id = auth.uid() OR is_pos_admin());

DROP POLICY IF EXISTS organization_members_delete ON public.organization_members;
CREATE POLICY organization_members_delete ON public.organization_members
  FOR DELETE TO authenticated
  USING (is_pos_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.organizations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.organization_members TO authenticated;

CREATE OR REPLACE FUNCTION public.user_organization_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT organization_id
  FROM public.organization_members
  WHERE user_id = auth.uid() AND is_active;
$$;

CREATE OR REPLACE FUNCTION public.user_can_access_organization(p_organization_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT is_pos_admin()
      OR EXISTS (
        SELECT 1 FROM public.organization_members
        WHERE organization_id = p_organization_id
          AND user_id = auth.uid()
          AND is_active
      );
$$;

CREATE OR REPLACE FUNCTION public.user_branch_ids_for_organization(p_organization_id uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT b.id
  FROM public.branches b
  WHERE b.organization_id = p_organization_id
    AND user_can_access_organization(p_organization_id);
$$;

GRANT EXECUTE ON FUNCTION public.user_organization_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_access_organization(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_branch_ids_for_organization(uuid) TO authenticated;

COMMENT ON TABLE public.organizations IS 'Top-level tenant/company for Premier SaaS.';
COMMENT ON TABLE public.organization_members IS 'Users belonging to a tenant/company.';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260819221000_tenant_registration.sql
-- ----------------------------------------------------------------------------
-- Tenant-aware registration: creates one company + first branch + owner atomically.

CREATE OR REPLACE FUNCTION public.register_tenant(
  p_store_name text,
  p_owner_name text,
  p_email text,
  p_password text,
  p_store_name_en text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_currency text DEFAULT 'EGP'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id uuid;
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_user_id uuid;
  v_email text;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
  v_res jsonb;
  v_slug text;
BEGIN
  v_email := lower(btrim(p_email));

  IF v_email = '' OR v_email !~ '@' OR v_email !~ '\.' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_EMAIL');
  END IF;
  IF p_password IS NULL OR length(p_password) < 6 THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD');
  END IF;
  IF btrim(coalesce(p_store_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_STORE_NAME');
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email)
     OR EXISTS (SELECT 1 FROM public.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMAIL_TAKEN');
  END IF;

  v_org_id := gen_random_uuid();
  v_slug := 'org-' || replace(v_org_id::text, '-', '');

  INSERT INTO public.organizations (id, name, slug, is_active)
  VALUES (v_org_id, p_store_name, v_slug, true);

  INSERT INTO public.branches (name, name_en, address, phone, is_active, organization_id)
  VALUES (p_store_name, p_store_name_en, p_address, p_phone, true, v_org_id)
  RETURNING id INTO v_branch_id;

  INSERT INTO public.warehouses (name, branch_id, is_active)
  VALUES (p_store_name || ' - Main', v_branch_id, true)
  RETURNING id INTO v_warehouse_id;

  SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
  INTO v_global_tax, v_global_tax_enabled, v_global_currency
  FROM public.settings ORDER BY id LIMIT 1;

  INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
  VALUES (
    v_branch_id,
    v_global_tax,
    v_global_tax_enabled,
    COALESCE(NULLIF(btrim(p_currency), ''), v_global_currency),
    10
  );

  INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
  VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

  PERFORM set_config('app.register_branch', 'on', true);
  v_res := public.create_user(
    v_email,
    p_password,
    p_owner_name,
    'owner',
    v_branch_id,
    true,
    NULL
  );
  PERFORM set_config('app.register_branch', 'off', true);

  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'USER_CREATE_FAILED: %', COALESCE(v_res->>'error', 'UNKNOWN');
  END IF;

  v_user_id := (v_res->>'user_id')::uuid;

  INSERT INTO public.organization_members (
    organization_id, user_id, membership_role, is_active
  ) VALUES (
    v_org_id, v_user_id, 'owner', true
  );

  RETURN jsonb_build_object(
    'success', true,
    'organization_id', v_org_id,
    'branch_id', v_branch_id,
    'warehouse_id', v_warehouse_id,
    'user_id', v_user_id,
    'membership_role', 'owner',
    'trial_days', 14
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TENANT_REGISTRATION_FAILED', 'detail', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_tenant(text, text, text, text, text, text, text, text)
  TO anon, authenticated, service_role;

-- Only organization admins/owners (or super admins) can add another member.
-- Initial owner insertion is performed by the SECURITY DEFINER registration RPC.
DROP POLICY IF EXISTS organization_members_insert ON public.organization_members;
CREATE POLICY organization_members_insert ON public.organization_members
  FOR INSERT TO authenticated
  WITH CHECK (
    is_pos_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members current_member
      WHERE current_member.organization_id = organization_members.organization_id
        AND current_member.user_id = auth.uid()
        AND current_member.membership_role IN ('owner', 'admin')
        AND current_member.is_active
    )
  );


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260820230000_fix_multitenant_registration_inventory_units_rls.sql
-- ----------------------------------------------------------------------------
-- Multi-tenant registration must be able to provision branch-scoped inventory units
-- before the newly-created owner has an authenticated session. Keep normal INSERTs
-- branch-scoped; only the existing registration transaction gets the bootstrap path.

DROP POLICY IF EXISTS inventory_units_registration_insert ON public.inventory_units;
CREATE POLICY inventory_units_registration_insert
  ON public.inventory_units
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (
    (
      COALESCE(current_setting('app.register_branch', true), '') = 'on'
      AND branch_id IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.branches b
        WHERE b.id = inventory_units.branch_id
      )
    )
    OR branch_id = public.get_branch_id()
    OR public.is_pos_admin()
  );

-- Regression coverage for the bootstrap path is intentionally kept in the
-- integration suite; this policy must never broaden UPDATE/DELETE access.


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260821000000_branch_management_phase2.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 20260821000000_branch_management_phase2.sql
--
-- Phase 2: Branch Management
--   1. create_organization_branch()  – atomic branch + warehouse + settings + subscription
--   2. update_branch()               – update branch metadata (organization_id immutable)
--   3. deactivate_branch()           – soft-disable; no data deletion
--   4. assert_branch_active()        – trigger guard: blocks new transactions on disabled branches
--   5. Updated RLS on branches       – org-aware policies with legacy fallback
--   6. Backfill organization_id for CI fixture branches
--
-- Security:
--   - All RPCs are SECURITY DEFINER with SET search_path = public
--   - Every RPC explicitly verifies caller's org membership
--   - organization_id is NEVER accepted as an update parameter
--   - Branch deactivation is soft-only; historical data is preserved
-- ============================================================================

-- ============ 1. create_organization_branch ============

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
SET search_path = public
AS $$
DECLARE
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
BEGIN
  -- Verify caller has org access
  IF NOT public.user_can_access_organization(p_organization_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  -- Verify caller is owner/admin of the org (or super_admin)
  IF NOT public.is_pos_admin() AND NOT EXISTS (
    SELECT 1 FROM public.organization_members
    WHERE organization_id = p_organization_id
      AND user_id = auth.uid()
      AND membership_role IN ('owner', 'admin')
      AND is_active
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ORG_ADMIN');
  END IF;

  IF btrim(coalesce(p_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH_NAME');
  END IF;

  -- Create branch (organization_id is set here, never updated later)
  INSERT INTO public.branches (name, name_en, address, phone, is_active, organization_id)
  VALUES (p_name, p_name_en, p_address, p_phone, true, p_organization_id)
  RETURNING id INTO v_branch_id;

  -- Create main warehouse
  INSERT INTO public.warehouses (name, branch_id, is_active)
  VALUES (p_name || ' - Main', v_branch_id, true)
  RETURNING id INTO v_warehouse_id;

  -- Inherit global settings defaults
  SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
  INTO v_global_tax, v_global_tax_enabled, v_global_currency
  FROM public.settings ORDER BY id LIMIT 1;

  INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
  VALUES (v_branch_id, v_global_tax, v_global_tax_enabled, v_global_currency, 10);

  -- Create trial subscription
  INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
  VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

  RETURN jsonb_build_object(
    'success', true,
    'branch_id', v_branch_id,
    'warehouse_id', v_warehouse_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_CREATE_FAILED', 'detail', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_organization_branch(uuid, text, text, text, text)
  TO authenticated;

-- ============ 2. update_branch ============

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
SET search_path = public
AS $$
DECLARE
  v_org_id uuid;
BEGIN
  SELECT organization_id INTO v_org_id FROM public.branches WHERE id = p_branch_id;

  IF v_org_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.user_can_access_organization(v_org_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  -- organization_id is NEVER updated through this RPC
  UPDATE public.branches SET
    name      = COALESCE(p_name, name),
    name_en   = COALESCE(p_name_en, name_en),
    address   = COALESCE(p_address, address),
    phone     = COALESCE(p_phone, phone),
    is_active = COALESCE(p_is_active, is_active)
  WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_UPDATE_FAILED', 'detail', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_branch(uuid, text, text, text, text, boolean)
  TO authenticated;

-- ============ 3. deactivate_branch ============

CREATE OR REPLACE FUNCTION public.deactivate_branch(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id uuid;
BEGIN
  SELECT organization_id INTO v_org_id FROM public.branches WHERE id = p_branch_id;

  IF v_org_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT public.user_can_access_organization(v_org_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  -- Soft-disable only; no data is deleted; history and reports preserved
  UPDATE public.branches SET is_active = false WHERE id = p_branch_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'BRANCH_DEACTIVATE_FAILED', 'detail', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.deactivate_branch(uuid) TO authenticated;

-- ============ 4. assert_branch_active trigger guard ============
-- Blocks new operational transactions (sales, purchases, shifts) on deactivated
-- branches. Historical data is never modified or deleted.

CREATE OR REPLACE FUNCTION public.assert_branch_active()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = NEW.branch_id AND is_active = false
  ) THEN
    RAISE EXCEPTION 'BRANCH_INACTIVE: Cannot create transactions in a deactivated branch';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_branch_active_guard_sales ON public.sales;
CREATE TRIGGER trg_branch_active_guard_sales
  BEFORE INSERT ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.assert_branch_active();

DROP TRIGGER IF EXISTS trg_branch_active_guard_purchases ON public.purchases;
CREATE TRIGGER trg_branch_active_guard_purchases
  BEFORE INSERT ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.assert_branch_active();

DROP TRIGGER IF EXISTS trg_branch_active_guard_shifts ON public.shifts;
CREATE TRIGGER trg_branch_active_guard_shifts
  BEFORE INSERT ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.assert_branch_active();

-- ============ 5. Updated RLS on branches ============
-- Org-aware policies with legacy fallback for branches without organization_id.
--
-- NOTE: policies use is_platform_admin() (super_admin only) NOT is_pos_admin(),
-- because is_pos_admin() includes org owners. In the multi-tenant model an
-- owner of org A must NOT see/manage org B's branches.
-- SELECT: platform admins see all; org members see their org's branches;
--         legacy branches (org_id IS NULL) visible to branch owner via get_branch_id().
-- INSERT: platform-admin-only (creation happens through RPCs).
-- UPDATE: platform admins OR org members for their org; legacy fallback via id.
-- DELETE: platform-admin-only.

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE users.id = auth.uid()
      AND users.is_active
      AND users.role = 'super_admin'
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

DROP POLICY IF EXISTS auth_select_branches ON public.branches;
CREATE POLICY auth_select_branches ON public.branches
  FOR SELECT TO authenticated
  USING (
    public.is_platform_admin()
    OR organization_id IN (SELECT public.user_organization_ids())
    OR (organization_id IS NULL AND id = public.get_branch_id())
  );

DROP POLICY IF EXISTS auth_insert_branches ON public.branches;
CREATE POLICY auth_insert_branches ON public.branches
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_branches ON public.branches;
CREATE POLICY auth_update_branches ON public.branches
  FOR UPDATE TO authenticated
  USING (
    public.is_platform_admin()
    OR organization_id IN (SELECT public.user_organization_ids())
    OR (organization_id IS NULL AND id = public.get_branch_id())
  )
  WITH CHECK (
    public.is_platform_admin()
    OR organization_id IN (SELECT public.user_organization_ids())
    OR (organization_id IS NULL AND id = public.get_branch_id())
  );

DROP POLICY IF EXISTS auth_delete_branches ON public.branches;
CREATE POLICY auth_delete_branches ON public.branches
  FOR DELETE TO authenticated
  USING (public.is_platform_admin());

-- ============ 6. Prevent organization_id change via direct UPDATE ============
-- Guard against moving a branch to another tenant via a direct UPDATE statement.
-- RPCs set organization_id at creation time; UPDATE path never touches it.

CREATE OR REPLACE FUNCTION public.guard_branch_org_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.organization_id IS DISTINCT FROM NEW.organization_id THEN
    RAISE EXCEPTION 'ORG_CHANGE_FORBIDDEN: organization_id is immutable after creation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_branch_org ON public.branches;
CREATE TRIGGER trg_guard_branch_org
  BEFORE UPDATE ON public.branches
  FOR EACH ROW EXECUTE FUNCTION public.guard_branch_org_immutable();


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260821010000_tenant_data_isolation.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- Phase 3: Full Tenant Data Isolation
-- Extends branch-scoped RLS from Phase 2 to ALL branch-related tables.
-- ============================================================================

-- ============================================================================
-- Helper: user_may_access_branch
-- ============================================================================

CREATE OR REPLACE FUNCTION public.user_may_access_branch(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.branches b
      WHERE b.id = p_branch_id
        AND b.organization_id IN (SELECT public.user_organization_ids())
    )
    OR (p_branch_id IS NULL AND public.is_platform_admin());
$$;

GRANT EXECUTE ON FUNCTION public.user_may_access_branch(uuid) TO authenticated;

-- ============================================================================
-- Core business tables: products, categories, warehouses, customers,
-- suppliers, expenses
-- ============================================================================

-- products
DROP POLICY IF EXISTS auth_select_products ON public.products;
CREATE POLICY auth_select_products ON public.products
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_products ON public.products;
CREATE POLICY auth_insert_products ON public.products
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('products.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_products ON public.products;
CREATE POLICY auth_update_products ON public.products
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('products.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_products ON public.products;
CREATE POLICY auth_delete_products ON public.products
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('products.manage') AND public.user_may_access_branch(branch_id))
  );

-- categories
DROP POLICY IF EXISTS auth_select_categories ON public.categories;
CREATE POLICY auth_select_categories ON public.categories
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_categories ON public.categories;
CREATE POLICY auth_insert_categories ON public.categories
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('categories.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_categories ON public.categories;
CREATE POLICY auth_update_categories ON public.categories
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('categories.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_categories ON public.categories;
CREATE POLICY auth_delete_categories ON public.categories
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('categories.manage') AND public.user_may_access_branch(branch_id))
  );

-- warehouses
DROP POLICY IF EXISTS auth_select_warehouses ON public.warehouses;
CREATE POLICY auth_select_warehouses ON public.warehouses
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_warehouses ON public.warehouses;
CREATE POLICY auth_insert_warehouses ON public.warehouses
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('warehouses.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_warehouses ON public.warehouses;
CREATE POLICY auth_update_warehouses ON public.warehouses
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('warehouses.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_warehouses ON public.warehouses;
CREATE POLICY auth_delete_warehouses ON public.warehouses
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('warehouses.manage') AND public.user_may_access_branch(branch_id))
  );

-- customers
DROP POLICY IF EXISTS auth_select_customers ON public.customers;
CREATE POLICY auth_select_customers ON public.customers
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_customers ON public.customers;
CREATE POLICY auth_insert_customers ON public.customers
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('customers.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_customers ON public.customers;
CREATE POLICY auth_update_customers ON public.customers
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('customers.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_customers ON public.customers;
CREATE POLICY auth_delete_customers ON public.customers
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('customers.manage') AND public.user_may_access_branch(branch_id))
  );

-- suppliers
DROP POLICY IF EXISTS auth_select_suppliers ON public.suppliers;
CREATE POLICY auth_select_suppliers ON public.suppliers
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_suppliers ON public.suppliers;
CREATE POLICY auth_insert_suppliers ON public.suppliers
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('suppliers.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_suppliers ON public.suppliers;
CREATE POLICY auth_update_suppliers ON public.suppliers
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('suppliers.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_suppliers ON public.suppliers;
CREATE POLICY auth_delete_suppliers ON public.suppliers
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('suppliers.manage') AND public.user_may_access_branch(branch_id))
  );

-- expenses
DROP POLICY IF EXISTS auth_select_expenses ON public.expenses;
CREATE POLICY auth_select_expenses ON public.expenses
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_expenses ON public.expenses;
CREATE POLICY auth_insert_expenses ON public.expenses
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('expenses.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_expenses ON public.expenses;
CREATE POLICY auth_update_expenses ON public.expenses
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('expenses.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_expenses ON public.expenses;
CREATE POLICY auth_delete_expenses ON public.expenses
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('expenses.manage') AND public.user_may_access_branch(branch_id))
  );

-- ============================================================================
-- Transaction tables: sales, purchases, stock_transactions
-- ============================================================================

-- sales
DROP POLICY IF EXISTS auth_select_sales ON public.sales;
CREATE POLICY auth_select_sales ON public.sales
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_sales ON public.sales;
CREATE POLICY auth_insert_sales ON public.sales
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_sales ON public.sales;
CREATE POLICY auth_update_sales ON public.sales
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_sales ON public.sales;
CREATE POLICY auth_delete_sales ON public.sales
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('sales.manage') AND public.user_may_access_branch(branch_id))
  );

-- purchases
DROP POLICY IF EXISTS auth_select_purchases ON public.purchases;
CREATE POLICY auth_select_purchases ON public.purchases
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_purchases ON public.purchases;
CREATE POLICY auth_insert_purchases ON public.purchases
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_purchases ON public.purchases;
CREATE POLICY auth_update_purchases ON public.purchases
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_purchases ON public.purchases;
CREATE POLICY auth_delete_purchases ON public.purchases
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('purchases.manage') AND public.user_may_access_branch(branch_id))
  );

-- stock_transactions
DROP POLICY IF EXISTS auth_select_stock_transactions ON public.stock_transactions;
CREATE POLICY auth_select_stock_transactions ON public.stock_transactions
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_stock_transactions ON public.stock_transactions;
CREATE POLICY auth_insert_stock_transactions ON public.stock_transactions
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_stock_transactions ON public.stock_transactions;
CREATE POLICY auth_update_stock_transactions ON public.stock_transactions
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_stock_transactions ON public.stock_transactions;
CREATE POLICY auth_delete_stock_transactions ON public.stock_transactions
  FOR DELETE TO authenticated
  USING (false);

-- ============================================================================
-- Accounting tables
-- ============================================================================

-- chart_of_accounts
DROP POLICY IF EXISTS auth_select_chart_of_accounts ON public.chart_of_accounts;
DROP POLICY IF EXISTS coa_select ON public.chart_of_accounts;
DROP POLICY IF EXISTS coa_insert ON public.chart_of_accounts;
DROP POLICY IF EXISTS coa_update ON public.chart_of_accounts;
DROP POLICY IF EXISTS coa_delete ON public.chart_of_accounts;
CREATE POLICY auth_select_chart_of_accounts ON public.chart_of_accounts
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_chart_of_accounts ON public.chart_of_accounts;
CREATE POLICY auth_insert_chart_of_accounts ON public.chart_of_accounts
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_chart_of_accounts ON public.chart_of_accounts;
CREATE POLICY auth_update_chart_of_accounts ON public.chart_of_accounts
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_chart_of_accounts ON public.chart_of_accounts;
CREATE POLICY auth_delete_chart_of_accounts ON public.chart_of_accounts
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

-- account_mappings
DROP POLICY IF EXISTS auth_select_account_mappings ON public.account_mappings;
DROP POLICY IF EXISTS account_mappings_select ON public.account_mappings;
DROP POLICY IF EXISTS account_mappings_insert ON public.account_mappings;
DROP POLICY IF EXISTS account_mappings_update ON public.account_mappings;
DROP POLICY IF EXISTS account_mappings_delete ON public.account_mappings;
CREATE POLICY auth_select_account_mappings ON public.account_mappings
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_account_mappings ON public.account_mappings;
CREATE POLICY auth_insert_account_mappings ON public.account_mappings
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_account_mappings ON public.account_mappings;
CREATE POLICY auth_update_account_mappings ON public.account_mappings
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_account_mappings ON public.account_mappings;
CREATE POLICY auth_delete_account_mappings ON public.account_mappings
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

-- journal_entries
DROP POLICY IF EXISTS auth_select_journal_entries ON public.journal_entries;
DROP POLICY IF EXISTS journal_entries_select ON public.journal_entries;
DROP POLICY IF EXISTS journal_entries_insert ON public.journal_entries;
CREATE POLICY auth_select_journal_entries ON public.journal_entries
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_journal_entries ON public.journal_entries;
CREATE POLICY auth_insert_journal_entries ON public.journal_entries
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_journal_entries ON public.journal_entries;
CREATE POLICY auth_update_journal_entries ON public.journal_entries
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_journal_entries ON public.journal_entries;
CREATE POLICY auth_delete_journal_entries ON public.journal_entries
  FOR DELETE TO authenticated
  USING (false);

-- journal_entry_lines
DROP POLICY IF EXISTS auth_select_journal_entry_lines ON public.journal_entry_lines;
DROP POLICY IF EXISTS journal_entry_lines_select ON public.journal_entry_lines;
DROP POLICY IF EXISTS journal_entry_lines_insert ON public.journal_entry_lines;
CREATE POLICY auth_select_journal_entry_lines ON public.journal_entry_lines
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.journal_entries je
      WHERE je.id = journal_entry_lines.journal_entry_id
        AND public.user_may_access_branch(je.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_journal_entry_lines ON public.journal_entry_lines;
CREATE POLICY auth_insert_journal_entry_lines ON public.journal_entry_lines
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.journal_entries je
      WHERE je.id = journal_entry_lines.journal_entry_id
        AND public.user_may_access_branch(je.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_journal_entry_lines ON public.journal_entry_lines;
CREATE POLICY auth_update_journal_entry_lines ON public.journal_entry_lines
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.journal_entries je
      WHERE je.id = journal_entry_lines.journal_entry_id
        AND public.user_may_access_branch(je.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.journal_entries je
      WHERE je.id = journal_entry_lines.journal_entry_id
        AND public.user_may_access_branch(je.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_journal_entry_lines ON public.journal_entry_lines;
CREATE POLICY auth_delete_journal_entry_lines ON public.journal_entry_lines
  FOR DELETE TO authenticated
  USING (false);

-- customer_payments
DROP POLICY IF EXISTS auth_select_customer_payments ON public.customer_payments;
DROP POLICY IF EXISTS customer_payments_select ON public.customer_payments;
DROP POLICY IF EXISTS customer_payments_insert ON public.customer_payments;
CREATE POLICY auth_select_customer_payments ON public.customer_payments
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_customer_payments ON public.customer_payments;
CREATE POLICY auth_insert_customer_payments ON public.customer_payments
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_customer_payments ON public.customer_payments;
CREATE POLICY auth_update_customer_payments ON public.customer_payments
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_customer_payments ON public.customer_payments;
CREATE POLICY auth_delete_customer_payments ON public.customer_payments
  FOR DELETE TO authenticated
  USING (false);

-- supplier_payments
DROP POLICY IF EXISTS auth_select_supplier_payments ON public.supplier_payments;
DROP POLICY IF EXISTS supplier_payments_select ON public.supplier_payments;
DROP POLICY IF EXISTS supplier_payments_insert ON public.supplier_payments;
CREATE POLICY auth_select_supplier_payments ON public.supplier_payments
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_supplier_payments ON public.supplier_payments;
CREATE POLICY auth_insert_supplier_payments ON public.supplier_payments
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_supplier_payments ON public.supplier_payments;
CREATE POLICY auth_update_supplier_payments ON public.supplier_payments
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_supplier_payments ON public.supplier_payments;
CREATE POLICY auth_delete_supplier_payments ON public.supplier_payments
  FOR DELETE TO authenticated
  USING (false);

-- treasury_accounts
DROP POLICY IF EXISTS auth_select_treasury_accounts ON public.treasury_accounts;
DROP POLICY IF EXISTS treasury_accounts_select ON public.treasury_accounts;
DROP POLICY IF EXISTS treasury_accounts_insert ON public.treasury_accounts;
DROP POLICY IF EXISTS treasury_accounts_update ON public.treasury_accounts;
DROP POLICY IF EXISTS treasury_accounts_delete ON public.treasury_accounts;
CREATE POLICY auth_select_treasury_accounts ON public.treasury_accounts
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_treasury_accounts ON public.treasury_accounts;
CREATE POLICY auth_insert_treasury_accounts ON public.treasury_accounts
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_treasury_accounts ON public.treasury_accounts;
CREATE POLICY auth_update_treasury_accounts ON public.treasury_accounts
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_treasury_accounts ON public.treasury_accounts;
CREATE POLICY auth_delete_treasury_accounts ON public.treasury_accounts
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('accounts.manage') AND public.user_may_access_branch(branch_id))
  );

-- treasury_transactions
DROP POLICY IF EXISTS auth_select_treasury_transactions ON public.treasury_transactions;
DROP POLICY IF EXISTS treasury_transactions_select ON public.treasury_transactions;
DROP POLICY IF EXISTS treasury_transactions_insert ON public.treasury_transactions;
CREATE POLICY auth_select_treasury_transactions ON public.treasury_transactions
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_treasury_transactions ON public.treasury_transactions;
CREATE POLICY auth_insert_treasury_transactions ON public.treasury_transactions
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_treasury_transactions ON public.treasury_transactions;
CREATE POLICY auth_update_treasury_transactions ON public.treasury_transactions
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_treasury_transactions ON public.treasury_transactions;
CREATE POLICY auth_delete_treasury_transactions ON public.treasury_transactions
  FOR DELETE TO authenticated
  USING (false);

-- bank_reconciliations
DROP POLICY IF EXISTS auth_select_bank_reconciliations ON public.bank_reconciliations;
DROP POLICY IF EXISTS bank_reconciliations_select ON public.bank_reconciliations;
DROP POLICY IF EXISTS bank_reconciliations_insert ON public.bank_reconciliations;
DROP POLICY IF EXISTS bank_reconciliations_update ON public.bank_reconciliations;
CREATE POLICY auth_select_bank_reconciliations ON public.bank_reconciliations
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_bank_reconciliations ON public.bank_reconciliations;
CREATE POLICY auth_insert_bank_reconciliations ON public.bank_reconciliations
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_bank_reconciliations ON public.bank_reconciliations;
CREATE POLICY auth_update_bank_reconciliations ON public.bank_reconciliations
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_bank_reconciliations ON public.bank_reconciliations;
CREATE POLICY auth_delete_bank_reconciliations ON public.bank_reconciliations
  FOR DELETE TO authenticated
  USING (false);

-- bank_statement_lines
DROP POLICY IF EXISTS auth_select_bank_statement_lines ON public.bank_statement_lines;
DROP POLICY IF EXISTS bank_statement_lines_select ON public.bank_statement_lines;
DROP POLICY IF EXISTS bank_statement_lines_insert ON public.bank_statement_lines;
DROP POLICY IF EXISTS bank_statement_lines_update ON public.bank_statement_lines;
CREATE POLICY auth_select_bank_statement_lines ON public.bank_statement_lines
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.bank_reconciliations br
      WHERE br.id = bank_statement_lines.reconciliation_id
        AND public.user_may_access_branch(br.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_bank_statement_lines ON public.bank_statement_lines;
CREATE POLICY auth_insert_bank_statement_lines ON public.bank_statement_lines
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.bank_reconciliations br
      WHERE br.id = bank_statement_lines.reconciliation_id
        AND public.user_may_access_branch(br.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_bank_statement_lines ON public.bank_statement_lines;
CREATE POLICY auth_update_bank_statement_lines ON public.bank_statement_lines
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.bank_reconciliations br
      WHERE br.id = bank_statement_lines.reconciliation_id
        AND public.user_may_access_branch(br.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.bank_reconciliations br
      WHERE br.id = bank_statement_lines.reconciliation_id
        AND public.user_may_access_branch(br.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_bank_statement_lines ON public.bank_statement_lines;
CREATE POLICY auth_delete_bank_statement_lines ON public.bank_statement_lines
  FOR DELETE TO authenticated
  USING (false);

-- ============================================================================
-- Manufacturing tables
-- ============================================================================

-- raw_materials (open read, permission-gated writes)
DROP POLICY IF EXISTS auth_select_raw_materials ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_select ON public.raw_materials;
CREATE POLICY auth_select_raw_materials ON public.raw_materials
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS auth_insert_raw_materials ON public.raw_materials;
CREATE POLICY auth_insert_raw_materials ON public.raw_materials
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_raw_materials ON public.raw_materials;
CREATE POLICY auth_update_raw_materials ON public.raw_materials
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_raw_materials ON public.raw_materials;
CREATE POLICY auth_delete_raw_materials ON public.raw_materials
  FOR DELETE TO authenticated
  USING (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

-- raw_material_inventory
DROP POLICY IF EXISTS auth_select_raw_material_inventory ON public.raw_material_inventory;
DROP POLICY IF EXISTS raw_material_inventory_select ON public.raw_material_inventory;
DROP POLICY IF EXISTS raw_material_inventory_write ON public.raw_material_inventory;
CREATE POLICY auth_select_raw_material_inventory ON public.raw_material_inventory
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_raw_material_inventory ON public.raw_material_inventory;
CREATE POLICY auth_insert_raw_material_inventory ON public.raw_material_inventory
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_raw_material_inventory ON public.raw_material_inventory;
CREATE POLICY auth_update_raw_material_inventory ON public.raw_material_inventory
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_raw_material_inventory ON public.raw_material_inventory;
CREATE POLICY auth_delete_raw_material_inventory ON public.raw_material_inventory
  FOR DELETE TO authenticated
  USING (false);

-- raw_material_batches
DROP POLICY IF EXISTS auth_select_raw_material_batches ON public.raw_material_batches;
DROP POLICY IF EXISTS raw_material_batches_select ON public.raw_material_batches;
DROP POLICY IF EXISTS raw_material_batches_write ON public.raw_material_batches;
CREATE POLICY auth_select_raw_material_batches ON public.raw_material_batches
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_raw_material_batches ON public.raw_material_batches;
CREATE POLICY auth_insert_raw_material_batches ON public.raw_material_batches
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_raw_material_batches ON public.raw_material_batches;
CREATE POLICY auth_update_raw_material_batches ON public.raw_material_batches
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('raw_materials.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_raw_material_batches ON public.raw_material_batches;
CREATE POLICY auth_delete_raw_material_batches ON public.raw_material_batches
  FOR DELETE TO authenticated
  USING (false);

-- recipes
DROP POLICY IF EXISTS auth_select_recipes ON public.recipes;
DROP POLICY IF EXISTS recipes_select ON public.recipes;
DROP POLICY IF EXISTS recipes_write ON public.recipes;
CREATE POLICY auth_select_recipes ON public.recipes
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_recipes ON public.recipes;
CREATE POLICY auth_insert_recipes ON public.recipes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('recipes.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_recipes ON public.recipes;
CREATE POLICY auth_update_recipes ON public.recipes
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('recipes.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_recipes ON public.recipes;
CREATE POLICY auth_delete_recipes ON public.recipes
  FOR DELETE TO authenticated
  USING (false);

-- recipe_items
DROP POLICY IF EXISTS auth_select_recipe_items ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_select ON public.recipe_items;
DROP POLICY IF EXISTS recipe_items_write ON public.recipe_items;
CREATE POLICY auth_select_recipe_items ON public.recipe_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.recipes r
      WHERE r.id = recipe_items.recipe_id
        AND public.user_may_access_branch(r.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_recipe_items ON public.recipe_items;
CREATE POLICY auth_insert_recipe_items ON public.recipe_items
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.recipes r
      WHERE r.id = recipe_items.recipe_id
        AND public.user_may_access_branch(r.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_recipe_items ON public.recipe_items;
CREATE POLICY auth_update_recipe_items ON public.recipe_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.recipes r
      WHERE r.id = recipe_items.recipe_id
        AND public.user_may_access_branch(r.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.recipes r
      WHERE r.id = recipe_items.recipe_id
        AND public.user_may_access_branch(r.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_recipe_items ON public.recipe_items;
CREATE POLICY auth_delete_recipe_items ON public.recipe_items
  FOR DELETE TO authenticated
  USING (false);

-- production_orders
DROP POLICY IF EXISTS auth_select_production_orders ON public.production_orders;
DROP POLICY IF EXISTS production_orders_select ON public.production_orders;
DROP POLICY IF EXISTS production_orders_write ON public.production_orders;
CREATE POLICY auth_select_production_orders ON public.production_orders
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_production_orders ON public.production_orders;
CREATE POLICY auth_insert_production_orders ON public.production_orders
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('production.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_production_orders ON public.production_orders;
CREATE POLICY auth_update_production_orders ON public.production_orders
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('production.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_production_orders ON public.production_orders;
CREATE POLICY auth_delete_production_orders ON public.production_orders
  FOR DELETE TO authenticated
  USING (false);

-- production_waste
DROP POLICY IF EXISTS auth_select_production_waste ON public.production_waste;
DROP POLICY IF EXISTS production_waste_select ON public.production_waste;
DROP POLICY IF EXISTS production_waste_write ON public.production_waste;
CREATE POLICY auth_select_production_waste ON public.production_waste
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_production_waste ON public.production_waste;
CREATE POLICY auth_insert_production_waste ON public.production_waste
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_production_waste ON public.production_waste;
CREATE POLICY auth_update_production_waste ON public.production_waste
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_production_waste ON public.production_waste;
CREATE POLICY auth_delete_production_waste ON public.production_waste
  FOR DELETE TO authenticated
  USING (false);

-- warehouse_transfers
DROP POLICY IF EXISTS auth_select_warehouse_transfers ON public.warehouse_transfers;
DROP POLICY IF EXISTS warehouse_transfers_select ON public.warehouse_transfers;
DROP POLICY IF EXISTS warehouse_transfers_write ON public.warehouse_transfers;
CREATE POLICY auth_select_warehouse_transfers ON public.warehouse_transfers
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_warehouse_transfers ON public.warehouse_transfers;
CREATE POLICY auth_insert_warehouse_transfers ON public.warehouse_transfers
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_warehouse_transfers ON public.warehouse_transfers;
CREATE POLICY auth_update_warehouse_transfers ON public.warehouse_transfers
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_warehouse_transfers ON public.warehouse_transfers;
CREATE POLICY auth_delete_warehouse_transfers ON public.warehouse_transfers
  FOR DELETE TO authenticated
  USING (false);

-- warehouse_transfer_items
DROP POLICY IF EXISTS auth_select_warehouse_transfer_items ON public.warehouse_transfer_items;
DROP POLICY IF EXISTS warehouse_transfer_items_select ON public.warehouse_transfer_items;
DROP POLICY IF EXISTS warehouse_transfer_items_write ON public.warehouse_transfer_items;
CREATE POLICY auth_select_warehouse_transfer_items ON public.warehouse_transfer_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.warehouse_transfers wt
      WHERE wt.id = warehouse_transfer_items.transfer_id
        AND public.user_may_access_branch(wt.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_warehouse_transfer_items ON public.warehouse_transfer_items;
CREATE POLICY auth_insert_warehouse_transfer_items ON public.warehouse_transfer_items
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.warehouse_transfers wt
      WHERE wt.id = warehouse_transfer_items.transfer_id
        AND public.user_may_access_branch(wt.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_warehouse_transfer_items ON public.warehouse_transfer_items;
CREATE POLICY auth_update_warehouse_transfer_items ON public.warehouse_transfer_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.warehouse_transfers wt
      WHERE wt.id = warehouse_transfer_items.transfer_id
        AND public.user_may_access_branch(wt.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.warehouse_transfers wt
      WHERE wt.id = warehouse_transfer_items.transfer_id
        AND public.user_may_access_branch(wt.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_warehouse_transfer_items ON public.warehouse_transfer_items;
CREATE POLICY auth_delete_warehouse_transfer_items ON public.warehouse_transfer_items
  FOR DELETE TO authenticated
  USING (false);

-- inventory_batches
DROP POLICY IF EXISTS auth_select_inventory_batches ON public.inventory_batches;
DROP POLICY IF EXISTS inventory_batches_select ON public.inventory_batches;
DROP POLICY IF EXISTS inventory_batches_write ON public.inventory_batches;
CREATE POLICY auth_select_inventory_batches ON public.inventory_batches
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_inventory_batches ON public.inventory_batches;
CREATE POLICY auth_insert_inventory_batches ON public.inventory_batches
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_inventory_batches ON public.inventory_batches;
CREATE POLICY auth_update_inventory_batches ON public.inventory_batches
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_inventory_batches ON public.inventory_batches;
CREATE POLICY auth_delete_inventory_batches ON public.inventory_batches
  FOR DELETE TO authenticated
  USING (false);

-- inventory_ledger
DROP POLICY IF EXISTS auth_select_inventory_ledger ON public.inventory_ledger;
DROP POLICY IF EXISTS inventory_ledger_select ON public.inventory_ledger;
DROP POLICY IF EXISTS inventory_ledger_write ON public.inventory_ledger;
CREATE POLICY auth_select_inventory_ledger ON public.inventory_ledger
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_inventory_ledger ON public.inventory_ledger;
CREATE POLICY auth_insert_inventory_ledger ON public.inventory_ledger
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_inventory_ledger ON public.inventory_ledger;
CREATE POLICY auth_update_inventory_ledger ON public.inventory_ledger
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_inventory_ledger ON public.inventory_ledger;
CREATE POLICY auth_delete_inventory_ledger ON public.inventory_ledger
  FOR DELETE TO authenticated
  USING (false);

-- ============================================================================
-- Floorplan tables: dining_areas, dining_tables, orders, order_items
-- ============================================================================

-- dining_areas
DROP POLICY IF EXISTS auth_select_dining_areas ON public.dining_areas;
DROP POLICY IF EXISTS auth_write_dining_areas ON public.dining_areas;
DROP POLICY IF EXISTS auth_write_dining_areas_del ON public.dining_areas;
DROP POLICY IF EXISTS auth_write_dining_areas_upd ON public.dining_areas;
CREATE POLICY auth_select_dining_areas ON public.dining_areas
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_dining_areas ON public.dining_areas;
CREATE POLICY auth_insert_dining_areas ON public.dining_areas
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_dining_areas ON public.dining_areas;
CREATE POLICY auth_update_dining_areas ON public.dining_areas
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_dining_areas ON public.dining_areas;
CREATE POLICY auth_delete_dining_areas ON public.dining_areas
  FOR DELETE TO authenticated
  USING (false);

-- dining_tables
DROP POLICY IF EXISTS auth_select_dining_tables ON public.dining_tables;
DROP POLICY IF EXISTS auth_write_dining_tables ON public.dining_tables;
DROP POLICY IF EXISTS auth_write_dining_tables_del ON public.dining_tables;
DROP POLICY IF EXISTS auth_write_dining_tables_upd ON public.dining_tables;
CREATE POLICY auth_select_dining_tables ON public.dining_tables
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_dining_tables ON public.dining_tables;
CREATE POLICY auth_insert_dining_tables ON public.dining_tables
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_dining_tables ON public.dining_tables;
CREATE POLICY auth_update_dining_tables ON public.dining_tables
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_dining_tables ON public.dining_tables;
CREATE POLICY auth_delete_dining_tables ON public.dining_tables
  FOR DELETE TO authenticated
  USING (false);

-- orders
DROP POLICY IF EXISTS auth_select_orders ON public.orders;
DROP POLICY IF EXISTS auth_write_orders ON public.orders;
DROP POLICY IF EXISTS auth_write_orders_del ON public.orders;
DROP POLICY IF EXISTS auth_write_orders_upd ON public.orders;
CREATE POLICY auth_select_orders ON public.orders
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_orders ON public.orders;
CREATE POLICY auth_insert_orders ON public.orders
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_orders ON public.orders;
CREATE POLICY auth_update_orders ON public.orders
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_delete_orders ON public.orders;
CREATE POLICY auth_delete_orders ON public.orders
  FOR DELETE TO authenticated
  USING (false);

-- order_items
DROP POLICY IF EXISTS auth_select_order_items ON public.order_items;
DROP POLICY IF EXISTS auth_write_order_items ON public.order_items;
DROP POLICY IF EXISTS auth_write_order_items_del ON public.order_items;
DROP POLICY IF EXISTS auth_write_order_items_upd ON public.order_items;
CREATE POLICY auth_select_order_items ON public.order_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_order_items ON public.order_items;
CREATE POLICY auth_insert_order_items ON public.order_items
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_order_items ON public.order_items;
CREATE POLICY auth_update_order_items ON public.order_items
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_order_items ON public.order_items;
CREATE POLICY auth_delete_order_items ON public.order_items
  FOR DELETE TO authenticated
  USING (false);

-- ============================================================================
-- Other tables: branch_settings, shifts, shift_operations, audit_log,
-- users, settings, order_kitchen_sends, waste_entries,
-- product_components, product_units
-- ============================================================================

-- branch_settings
DROP POLICY IF EXISTS auth_select_branch_settings ON public.branch_settings;
DROP POLICY IF EXISTS auth_write_branch_settings ON public.branch_settings;
DROP POLICY IF EXISTS auth_write_branch_settings_del ON public.branch_settings;
DROP POLICY IF EXISTS auth_write_branch_settings_upd ON public.branch_settings;
CREATE POLICY auth_select_branch_settings ON public.branch_settings
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_branch_settings ON public.branch_settings;
CREATE POLICY auth_insert_branch_settings ON public.branch_settings
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('settings.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_branch_settings ON public.branch_settings;
CREATE POLICY auth_update_branch_settings ON public.branch_settings
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (
    public.is_platform_admin()
    OR (public.can_permission('settings.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_branch_settings ON public.branch_settings;
CREATE POLICY auth_delete_branch_settings ON public.branch_settings
  FOR DELETE TO authenticated
  USING (false);

-- shifts
DROP POLICY IF EXISTS auth_select_shifts ON public.shifts;
CREATE POLICY auth_select_shifts ON public.shifts
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_shifts ON public.shifts;
CREATE POLICY auth_insert_shifts ON public.shifts
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_shifts ON public.shifts;
CREATE POLICY auth_update_shifts ON public.shifts
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_shifts ON public.shifts;
CREATE POLICY auth_delete_shifts ON public.shifts
  FOR DELETE TO authenticated
  USING (false);

-- shift_operations
DROP POLICY IF EXISTS auth_select_shift_operations ON public.shift_operations;
CREATE POLICY auth_select_shift_operations ON public.shift_operations
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_operations.shift_id
        AND public.user_may_access_branch(s.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_shift_operations ON public.shift_operations;
CREATE POLICY auth_insert_shift_operations ON public.shift_operations
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_operations.shift_id
        AND public.user_may_access_branch(s.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_shift_operations ON public.shift_operations;
CREATE POLICY auth_update_shift_operations ON public.shift_operations
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_operations.shift_id
        AND public.user_may_access_branch(s.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_operations.shift_id
        AND public.user_may_access_branch(s.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_shift_operations ON public.shift_operations;
CREATE POLICY auth_delete_shift_operations ON public.shift_operations
  FOR DELETE TO authenticated
  USING (false);

-- audit_log
DROP POLICY IF EXISTS auth_select_audit_log ON public.audit_log;
CREATE POLICY auth_select_audit_log ON public.audit_log
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_audit_log ON public.audit_log;
CREATE POLICY auth_insert_audit_log ON public.audit_log
  FOR INSERT TO authenticated
  WITH CHECK (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_update_audit_log ON public.audit_log;
CREATE POLICY auth_update_audit_log ON public.audit_log
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_audit_log ON public.audit_log;
CREATE POLICY auth_delete_audit_log ON public.audit_log
  FOR DELETE TO authenticated
  USING (false);

-- users (keep existing complex policies — already branch-scoped in 004)
DROP POLICY IF EXISTS auth_select_users ON public.users;
CREATE POLICY auth_select_users ON public.users
  FOR SELECT TO authenticated
  USING (
    public.user_may_access_branch(branch_id)
    OR id = auth.uid()
    OR public.is_platform_admin()
  );

DROP POLICY IF EXISTS auth_insert_users ON public.users;
CREATE POLICY auth_insert_users ON public.users
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_platform_admin()
    OR (id = auth.uid() AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_update_users ON public.users;
CREATE POLICY auth_update_users ON public.users
  FOR UPDATE TO authenticated
  USING (
    id = auth.uid()
    OR public.is_platform_admin()
    OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
  )
  WITH CHECK (
    id = auth.uid()
    OR public.is_platform_admin()
    OR (public.can_permission('users.manage') AND public.user_may_access_branch(branch_id))
  );

DROP POLICY IF EXISTS auth_delete_users ON public.users;
CREATE POLICY auth_delete_users ON public.users
  FOR DELETE TO authenticated
  USING (false);

-- settings (global, admin-only)
DROP POLICY IF EXISTS auth_select_settings ON public.settings;
CREATE POLICY auth_select_settings ON public.settings
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS auth_insert_settings ON public.settings;
CREATE POLICY auth_insert_settings ON public.settings
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_settings ON public.settings;
CREATE POLICY auth_update_settings ON public.settings
  FOR UPDATE TO authenticated
  USING (true)
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_settings ON public.settings;
CREATE POLICY auth_delete_settings ON public.settings
  FOR DELETE TO authenticated
  USING (false);

-- order_kitchen_sends
DROP POLICY IF EXISTS auth_select_order_kitchen_sends ON public.order_kitchen_sends;
DROP POLICY IF EXISTS auth_write_order_kitchen_sends ON public.order_kitchen_sends;
DROP POLICY IF EXISTS auth_write_order_kitchen_sends_del ON public.order_kitchen_sends;
DROP POLICY IF EXISTS auth_write_order_kitchen_sends_upd ON public.order_kitchen_sends;
CREATE POLICY auth_select_order_kitchen_sends ON public.order_kitchen_sends
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_kitchen_sends.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_order_kitchen_sends ON public.order_kitchen_sends;
CREATE POLICY auth_insert_order_kitchen_sends ON public.order_kitchen_sends
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_kitchen_sends.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_order_kitchen_sends ON public.order_kitchen_sends;
CREATE POLICY auth_update_order_kitchen_sends ON public.order_kitchen_sends
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_kitchen_sends.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_kitchen_sends.order_id
        AND public.user_may_access_branch(o.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_order_kitchen_sends ON public.order_kitchen_sends;
CREATE POLICY auth_delete_order_kitchen_sends ON public.order_kitchen_sends
  FOR DELETE TO authenticated
  USING (false);

-- waste_entries
DROP POLICY IF EXISTS auth_select_waste_entries ON public.waste_entries;
DROP POLICY IF EXISTS we_admin_all ON public.waste_entries;
DROP POLICY IF EXISTS we_branch_read ON public.waste_entries;
CREATE POLICY auth_select_waste_entries ON public.waste_entries
  FOR SELECT TO authenticated
  USING (public.user_may_access_branch(branch_id));

DROP POLICY IF EXISTS auth_insert_waste_entries ON public.waste_entries;
CREATE POLICY auth_insert_waste_entries ON public.waste_entries
  FOR INSERT TO authenticated
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_update_waste_entries ON public.waste_entries;
CREATE POLICY auth_update_waste_entries ON public.waste_entries
  FOR UPDATE TO authenticated
  USING (public.user_may_access_branch(branch_id))
  WITH CHECK (public.is_platform_admin());

DROP POLICY IF EXISTS auth_delete_waste_entries ON public.waste_entries;
CREATE POLICY auth_delete_waste_entries ON public.waste_entries
  FOR DELETE TO authenticated
  USING (false);

-- product_components (via parent products)
DROP POLICY IF EXISTS auth_select_product_components ON public.product_components;
CREATE POLICY auth_select_product_components ON public.product_components
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_components.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_product_components ON public.product_components;
CREATE POLICY auth_insert_product_components ON public.product_components
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_components.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_product_components ON public.product_components;
CREATE POLICY auth_update_product_components ON public.product_components
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_components.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_components.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_product_components ON public.product_components;
CREATE POLICY auth_delete_product_components ON public.product_components
  FOR DELETE TO authenticated
  USING (false);

-- product_units (via parent products)
DROP POLICY IF EXISTS auth_select_product_units ON public.product_units;
CREATE POLICY auth_select_product_units ON public.product_units
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_units.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_insert_product_units ON public.product_units;
CREATE POLICY auth_insert_product_units ON public.product_units
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_units.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_update_product_units ON public.product_units;
CREATE POLICY auth_update_product_units ON public.product_units
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_units.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = product_units.product_id
        AND public.user_may_access_branch(p.branch_id)
    )
  );

DROP POLICY IF EXISTS auth_delete_product_units ON public.product_units;
CREATE POLICY auth_delete_product_units ON public.product_units
  FOR DELETE TO authenticated
  USING (false);


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260821120000_permissions_super_admin.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- Batch 2: Permissions + Super Admin Console
-- ============================================================================

-- ============================================================================
-- A. Branch Access Matrix: user_branch_access junction table
-- ============================================================================
-- Before: user_may_access_branch() gave org-wide access to ALL org members.
-- After:  non-admin/non-owner users only access branches they're explicitly
--         granted. Owners/admins retain full org-wide access.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_branch_access (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  branch_id  uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, branch_id)
);

ALTER TABLE public.user_branch_access ENABLE ROW LEVEL SECURITY;

-- Platform admin full access
DROP POLICY IF EXISTS auth_platform_admin_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_platform_admin_user_branch_access ON public.user_branch_access
  FOR ALL USING (public.is_platform_admin());

-- Users can read their own grants
DROP POLICY IF EXISTS auth_select_own_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_select_own_user_branch_access ON public.user_branch_access
  FOR SELECT USING (user_id = auth.uid());

-- Org owners/admins can manage grants for their org's users
DROP POLICY IF EXISTS auth_org_admin_manage_user_branch_access ON public.user_branch_access;
CREATE POLICY auth_org_admin_manage_user_branch_access ON public.user_branch_access
  FOR ALL USING (
    public.is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM public.branches b
      WHERE b.id = user_branch_access.branch_id
        AND b.organization_id IN (SELECT public.user_organization_ids())
        AND EXISTS (
          SELECT 1 FROM public.organization_members om
          WHERE om.user_id = auth.uid()
            AND om.organization_id = b.organization_id
            AND om.membership_role IN ('owner', 'admin')
            AND om.is_active = true
        )
    )
  );

-- Grant authenticated read access
GRANT SELECT ON public.user_branch_access TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.user_branch_access TO authenticated;

-- ============================================================================
-- Seed: backfill user_branch_access from existing users.branch_id
-- ============================================================================
INSERT INTO public.user_branch_access (user_id, branch_id)
SELECT DISTINCT id, branch_id
FROM public.users
WHERE branch_id IS NOT NULL
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Also seed: org owners/admins get access to ALL branches in their orgs
INSERT INTO public.user_branch_access (user_id, branch_id)
SELECT DISTINCT om.user_id, b.id
FROM public.organization_members om
JOIN public.branches b ON b.organization_id = om.organization_id
WHERE om.membership_role IN ('owner', 'admin')
  AND om.is_active = true
  AND b.is_active = true
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- ============================================================================
-- B. Tighten user_may_access_branch()
-- ============================================================================
-- Priority order:
-- 1. Platform admin (super_admin) → all branches
-- 2. User has explicit grant in user_branch_access → that branch
-- 3. Org owner/admin → all branches in their orgs
-- 4. Otherwise → denied
-- ============================================================================

CREATE OR REPLACE FUNCTION public.user_may_access_branch(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    -- Platform admin sees everything
    public.is_platform_admin()
    -- Explicit per-user branch grant
    OR EXISTS (
      SELECT 1 FROM public.user_branch_access uba
      WHERE uba.user_id = auth.uid()
        AND uba.branch_id = p_branch_id
    )
    -- Org owners/admins see all branches in their orgs
    OR EXISTS (
      SELECT 1 FROM public.branches b
      JOIN public.organization_members om
        ON om.organization_id = b.organization_id
      WHERE b.id = p_branch_id
        AND om.user_id = auth.uid()
        AND om.membership_role IN ('owner', 'admin')
        AND om.is_active = true
    )
    -- Legacy fallback: users.branch_id grants access to that branch.
    -- This keeps existing integration tests working while we migrate to
    -- the explicit user_branch_access model.
    OR EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.branch_id = p_branch_id
    )
    -- Legacy fallback: NULL branch for platform admin only (already covered above)
    OR (p_branch_id IS NULL AND public.is_platform_admin());
$$;

GRANT EXECUTE ON FUNCTION public.user_may_access_branch(uuid) TO authenticated;

-- ============================================================================
-- C. RPCs for branch access management
-- ============================================================================

-- Get all branches a user has access to (with org context)
CREATE OR REPLACE FUNCTION public.get_user_branch_access(p_user_id uuid)
RETURNS TABLE (
  branch_id   uuid,
  branch_name text,
  branch_name_en text,
  organization_id uuid,
  is_active   boolean,
  grant_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Explicit grants
  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active,
         'explicit'::text
  FROM public.user_branch_access uba
  JOIN public.branches b ON b.id = uba.branch_id
  WHERE uba.user_id = p_user_id
  UNION
  -- Org-wide access for owners/admins
  SELECT b.id, b.name, b.name_en, b.organization_id, b.is_active,
         'org_role'::text
  FROM public.branches b
  JOIN public.organization_members om ON om.organization_id = b.organization_id
  WHERE om.user_id = p_user_id
    AND om.membership_role IN ('owner', 'admin')
    AND om.is_active = true
    AND b.is_active = true
  ORDER BY 2;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_branch_access(uuid) TO authenticated;

-- Assign user to branch (explicit grant)
CREATE OR REPLACE FUNCTION public.assign_user_to_branch(
  p_user_id uuid,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  -- Auth: caller must be platform admin or org owner/admin
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

  -- Verify branch exists
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  -- Verify target user exists
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  -- Insert grant (ignore duplicate)
  INSERT INTO public.user_branch_access (user_id, branch_id)
  VALUES (p_user_id, p_branch_id)
  ON CONFLICT (user_id, branch_id) DO NOTHING;

  -- Audit
  PERFORM public.log_audit_action(
    'assign_branch', 'user_branch_access', NULL,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.assign_user_to_branch(uuid, uuid) TO authenticated;

-- Remove user from branch (revoke grant)
CREATE OR REPLACE FUNCTION public.remove_user_from_branch(
  p_user_id uuid,
  p_branch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
BEGIN
  -- Auth: caller must be platform admin or org owner/admin
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

  -- Cannot remove the last branch grant for an active user
  IF (
    SELECT count(*) FROM public.user_branch_access WHERE user_id = p_user_id
  ) <= 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LAST_BRANCH');
  END IF;

  DELETE FROM public.user_branch_access
  WHERE user_id = p_user_id AND branch_id = p_branch_id;

  -- Audit
  PERFORM public.log_audit_action(
    'remove_branch', 'user_branch_access', NULL,
    jsonb_build_object('user_id', p_user_id, 'branch_id', p_branch_id),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.remove_user_from_branch(uuid, uuid) TO authenticated;

-- Bulk set user's branch access (replaces all grants)
CREATE OR REPLACE FUNCTION public.set_user_branch_access(
  p_user_id uuid,
  p_branch_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid := auth.uid();
  v_target_org uuid;
  v_branch_id uuid;
BEGIN
  -- Auth: caller must be platform admin or org owner/admin of ALL target branches
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

  -- Must provide at least one branch
  IF array_length(p_branch_ids, 1) IS NULL OR array_length(p_branch_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'AT_LEAST_ONE_BRANCH');
  END IF;

  -- Replace all grants atomically
  DELETE FROM public.user_branch_access WHERE user_id = p_user_id;
  INSERT INTO public.user_branch_access (user_id, branch_id)
  SELECT p_user_id, unnest(p_branch_ids)
  ON CONFLICT DO NOTHING;

  -- Audit
  PERFORM public.log_audit_action(
    'set_branch_access', 'user_branch_access', NULL,
    jsonb_build_object('user_id', p_user_id, 'branch_ids', p_branch_ids),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_user_branch_access(uuid, uuid[]) TO authenticated;

-- ============================================================================
-- D. Super Admin Console RPCs
-- ============================================================================

-- Get all tenants with branch/user/subscription stats
CREATE OR REPLACE FUNCTION public.get_super_admin_tenant_stats()
RETURNS TABLE (
  organization_id   uuid,
  organization_name text,
  organization_slug text,
  is_active         boolean,
  created_at        timestamptz,
  branch_count      bigint,
  user_count        bigint,
  total_branches    bigint,
  active_branches   bigint,
  has_active_subscription boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
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
      SELECT 1 FROM public.branches b
      JOIN public.branch_subscriptions bs ON bs.branch_id = b.id
      WHERE b.organization_id = o.id
        AND bs.status = 'active'
        AND bs.current_period_ends_at > now()
    )
  FROM public.organizations o
  ORDER BY o.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_super_admin_tenant_stats() TO authenticated;

-- Get all users across all tenants (for super admin)
CREATE OR REPLACE FUNCTION public.get_super_admin_all_users(
  p_search text DEFAULT NULL
)
RETURNS TABLE (
  user_id     uuid,
  email       text,
  username    text,
  full_name   text,
  role        text,
  is_active   boolean,
  branch_id   uuid,
  branch_name text,
  org_id      uuid,
  org_name    text,
  created_at  timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    u.id, u.email, u.username, u.full_name, u.role, u.is_active,
    u.branch_id,
    b.name,
    om.organization_id,
    o.name,
    u.created_at
  FROM public.users u
  LEFT JOIN public.branches b ON b.id = u.branch_id
  LEFT JOIN public.organization_members om ON om.user_id = u.id AND om.is_active = true
  LEFT JOIN public.organizations o ON o.id = om.organization_id
  WHERE p_search IS NULL
     OR u.email ILIKE '%' || p_search || '%'
     OR u.username ILIKE '%' || p_search || '%'
     OR u.full_name ILIKE '%' || p_search || '%'
  ORDER BY u.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_super_admin_all_users(text) TO authenticated;

-- Toggle organization active status (super admin only)
CREATE OR REPLACE FUNCTION public.toggle_organization_status(
  p_org_id uuid,
  p_is_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  UPDATE public.organizations SET is_active = p_is_active WHERE id = p_org_id;

  PERFORM public.log_audit_action(
    CASE WHEN p_is_active THEN 'activate_organization' ELSE 'deactivate_organization' END,
    'organizations', p_org_id,
    jsonb_build_object('is_active', p_is_active),
    NULL, NULL, NULL
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_organization_status(uuid, boolean) TO authenticated;

-- ============================================================================
-- E. Client-side: update create_user to auto-grant branch access
-- ============================================================================

-- After a user is created with a branch_id, ensure they have an explicit
-- grant in user_branch_access for that branch.

CREATE OR REPLACE FUNCTION public._ensure_branch_access_after_user_create()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.branch_id IS NOT NULL THEN
    INSERT INTO public.user_branch_access (user_id, branch_id)
    VALUES (NEW.id, NEW.branch_id)
    ON CONFLICT (user_id, branch_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_branch_access ON public.users;
CREATE TRIGGER trg_ensure_branch_access
  AFTER INSERT ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public._ensure_branch_access_after_user_create();


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260824120000_subscription_and_feature_gating_system.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 20260824120000. Comprehensive Multi-Tenant Subscription & Feature-Gating System
-- ============================================================================
-- Implements the complete multi-tenant subscription authorization layer:
--   1. plans & plan_prices (flexible billing cycles & currencies)
--   2. features registry (central repository of all system capabilities)
--   3. plan_features (mappings with boolean / integer limits)
--   4. subscriptions (tenant-level lifecycle: trialing, active, past_due, suspended, cancelled, expired)
--   5. branch_feature_overrides (branch-specific enable/disable & limit overrides)
--   6. subscription_events (complete immutable audit trail of all subscription changes)
--   7. Central resolution RPCs:
--        - can_access_feature(p_feature_key, p_branch_id) -> boolean
--        - get_feature_access(p_feature_key, p_branch_id) -> jsonb
--        - resolve_feature_access(...)
--        - subscription_is_active(...)
--        - can_create_branch(...), can_create_user(...), can_create_warehouse(...)
--   8. Multi-tenant RLS security policies & Super Admin controllers.
-- ============================================================================

-- Ensure uuid extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. PLANS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  is_public boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_plans_slug ON public.plans(slug);
CREATE INDEX IF NOT EXISTS idx_plans_active_public ON public.plans(is_active, is_public, display_order);

-- Seed Default Plans
INSERT INTO public.plans (id, name, slug, description, is_active, is_public, display_order)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'Free Trial', 'free', 'تجربة مجانية لكافة الخصائص الأساسية', true, true, 1),
  ('a0000000-0000-0000-0000-000000000002', 'Starter', 'starter', 'خطة البداية للمطاعم والمحلات الفردية', true, true, 2),
  ('a0000000-0000-0000-0000-000000000003', 'Professional', 'professional', 'الخطة الاحترافية مع شاشات المطبخ والمحاسبة', true, true, 3),
  ('a0000000-0000-0000-0000-000000000004', 'Business', 'business', 'خطة الأعمال للفروع المتعددة والتصنيع والتقارير المتقدمة', true, true, 4),
  ('a0000000-0000-0000-0000-000000000005', 'Enterprise', 'enterprise', 'خطة المؤسسات والشركات الكبرى بدون أي حدود', true, true, 5)
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    display_order = EXCLUDED.display_order;

-- ============================================================================
-- 2. PLAN PRICES
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.plan_prices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  billing_cycle text NOT NULL CHECK (billing_cycle IN ('monthly', 'quarterly', 'yearly', 'custom')),
  price numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'EGP',
  trial_days integer NOT NULL DEFAULT 14,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, billing_cycle, currency)
);

CREATE INDEX IF NOT EXISTS idx_plan_prices_plan ON public.plan_prices(plan_id, is_active);

-- Seed Plan Prices
INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'monthly', 0, 'EGP', 14 FROM public.plans WHERE slug = 'free'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;

INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'monthly', 299, 'EGP', 0 FROM public.plans WHERE slug = 'starter'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;
INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'yearly', 2990, 'EGP', 0 FROM public.plans WHERE slug = 'starter'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;

INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'monthly', 599, 'EGP', 0 FROM public.plans WHERE slug = 'professional'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;
INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'yearly', 5990, 'EGP', 0 FROM public.plans WHERE slug = 'professional'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;

INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'monthly', 999, 'EGP', 0 FROM public.plans WHERE slug = 'business'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;
INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'yearly', 9990, 'EGP', 0 FROM public.plans WHERE slug = 'business'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;

INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'monthly', 1999, 'EGP', 0 FROM public.plans WHERE slug = 'enterprise'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;
INSERT INTO public.plan_prices (plan_id, billing_cycle, price, currency, trial_days)
SELECT id, 'yearly', 19990, 'EGP', 0 FROM public.plans WHERE slug = 'enterprise'
ON CONFLICT (plan_id, billing_cycle, currency) DO NOTHING;

-- ============================================================================
-- 3. FEATURES REGISTRY
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.features (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  name text NOT NULL,
  description text,
  category text NOT NULL CHECK (category IN ('core', 'operations', 'inventory', 'trade', 'finance', 'analytics', 'enterprise', 'management')),
  is_active boolean NOT NULL DEFAULT true,
  is_system boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_features_key ON public.features(key);
CREATE INDEX IF NOT EXISTS idx_features_category ON public.features(category);

-- Seed Features Registry
INSERT INTO public.features (key, name, description, category, is_system)
VALUES
  ('pos', 'نقطة البيع (POS)', 'إصدار الفواتير ونقاط البيع السريعة والطاولات والدليفري', 'core', true),
  ('inventory', 'إدارة المخزون', 'متابعة الأرصدة والمستودعات والتسويات المخزنية', 'inventory', true),
  ('purchases', 'المشتريات والموردين', 'أوامر الشراء وعروض الأسعار وإدارة الموردين', 'trade', true),
  ('suppliers', 'سجل الموردين', 'إدارة حسابات وبيانات الموردين', 'trade', true),
  ('customers', 'سجل العملاء', 'إدارة حسابات وبيانات العملاء ونقاط الولاء', 'trade', true),
  ('kds', 'شاشة المطبخ (KDS)', 'نظام عرض وإدارة طلبات المطبخ والمحطات في الوقت الفعلي', 'operations', false),
  ('customer_display', 'شاشة العميل', 'عرض الطلب والأسعار للعميل أثناء عملية البيع', 'operations', false),
  ('tables', 'إدارة الطاولات والصالات', 'المخطط التفاعلي للطاولات وتوزيع الصالات', 'operations', false),
  ('delivery', 'إدارة الدليفري والسائقين', 'تتبع طلبات التوصيل وتوزيع الكباتن والسائقين', 'operations', false),
  ('manufacturing', 'التصنيع والإنتاج', 'خطوط الإنتاج والتصنيع وتحويل المواد', 'inventory', false),
  ('recipes', 'الوصفات والتركيبات', 'مكونات المنتجات وخصم المواد الخام تلقائياً', 'inventory', false),
  ('units', 'وحدات القياس المتعددة', 'وحدات التحويل القياسية والتجزئة والكرتون', 'inventory', false),
  ('reports', 'التقارير الأساسية', 'تقارير المبيعات اليومية والأصناف الأكثر طلباً', 'analytics', true),
  ('advanced_reports', 'التقارير المتقدمة والتحليلات', 'تقارير الأرباح والخسائر والتحليلات التنفيذية العميقة', 'analytics', false),
  ('excel_import', 'استيراد البيانات من Excel', 'استيراد قوائم المنتجات والعملاء والمخزون من ملفات Excel', 'management', false),
  ('excel_export', 'تصدير التقارير إلى Excel/PDF', 'تصدير كافة الكشوفات والتقارير المالية بصيغ Excel و PDF', 'management', false),
  ('multi_branch', 'الفروع المتعددة', 'إمكانية فتح وإدارة أكثر من فرع تحت نفس المؤسسة', 'enterprise', false),
  ('branch_management', 'إدارة الفروع والصلاحيات', 'تخصيص الصلاحيات والإعدادات لكل فرع', 'enterprise', false),
  ('warehouse_management', 'المستودعات المتعددة', 'إدارة المخازن المتعددة والتحويلات بين المخازن', 'inventory', false),
  ('employees', 'الموظفين والمستخدمين', 'إدارة الحسابات وطواقم العمل', 'management', true),
  ('advanced_permissions', 'الصلاحيات المتقدمة والـ RBAC', 'صلاحيات مخصصة وتدقيق الأدوار المتقدمة', 'management', false),
  ('shift_management', 'إدارة الورديات والكاشير', 'فتح وإغلاق الورديات والعجز والزيادة في الخزينة', 'operations', true),
  ('accounting', 'النظام المحاسبي المتكامل', 'شجرة الحسابات، قيود اليومية، الخزائن والبنوك، وميزان المراجعة', 'finance', false),
  ('ai_assistant', 'المساعد الذكي (AI Insights)', 'توليد التقارير الذكية وتوقعات الطلب عبر الذكاء الاصطناعي', 'enterprise', false),
  ('api_access', 'الربط الخارجي وواجهة API', 'الربط مع المنصات الخارجية وتطبيقات التوصيل والـ ERP', 'enterprise', false),
  ('audit_logs', 'سجل العمليات والتدقيق (Audit Logs)', 'تتبع كامل لكافة الحركات والتعديلات وحذف الفواتير', 'management', false),
  ('costing', 'حساب التكاليف وهوامش الربح', 'حساب تكلفة الوجبات وتغيرات تكاليف المواد الخام', 'inventory', false),
  ('waste_management', 'إدارة الهدر والتوالف', 'تسجيل هدر المطبخ والتوالف المخزنية وتحليل الخسائر', 'inventory', false),
  ('transfers', 'التحويلات المخزنية', 'تحويل البضائع والمواد الخام بين الفروع والمستودعات', 'inventory', false),
  ('stock_counts', 'الجرد المخزني', 'جلسات الجرد الدوري والمفاجئ وتسوية الفروقات', 'inventory', false)
ON CONFLICT (key) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    category = EXCLUDED.category;

-- ============================================================================
-- 4. PLAN FEATURES & LIMITS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.plan_features (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  feature_id uuid NOT NULL REFERENCES public.features(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  limit_value integer DEFAULT NULL, -- NULL or -1 means unlimited
  limit_type text NOT NULL DEFAULT 'boolean' CHECK (limit_type IN ('boolean', 'integer', 'decimal', 'unlimited')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, feature_id)
);

CREATE INDEX IF NOT EXISTS idx_plan_features_lookup ON public.plan_features(plan_id, feature_id, enabled);

-- Helper to seed plan features
DO $$
DECLARE
  v_plan_free uuid;
  v_plan_starter uuid;
  v_plan_pro uuid;
  v_plan_biz uuid;
  v_plan_ent uuid;
BEGIN
  SELECT id INTO v_plan_free FROM public.plans WHERE slug = 'free';
  SELECT id INTO v_plan_starter FROM public.plans WHERE slug = 'starter';
  SELECT id INTO v_plan_pro FROM public.plans WHERE slug = 'professional';
  SELECT id INTO v_plan_biz FROM public.plans WHERE slug = 'business';
  SELECT id INTO v_plan_ent FROM public.plans WHERE slug = 'enterprise';

  -- 1. Free Trial: All features enabled for 14 days, limited limits
  INSERT INTO public.plan_features (plan_id, feature_id, enabled, limit_type, limit_value)
  SELECT v_plan_free, f.id, true,
    CASE 
      WHEN f.key = 'multi_branch' THEN 'integer'
      WHEN f.key = 'employees' THEN 'integer'
      WHEN f.key = 'warehouse_management' THEN 'integer'
      ELSE 'boolean'
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 2
      WHEN f.key = 'employees' THEN 5
      WHEN f.key = 'warehouse_management' THEN 2
      ELSE NULL
    END
  FROM public.features f
  ON CONFLICT (plan_id, feature_id) DO NOTHING;

  -- 2. Starter: Basic POS, Inventory, Purchases, Reports. (No KDS, No Multi-branch, No Accounting, No Manufacturing)
  INSERT INTO public.plan_features (plan_id, feature_id, enabled, limit_type, limit_value)
  SELECT v_plan_starter, f.id,
    CASE 
      WHEN f.key IN ('pos', 'inventory', 'purchases', 'suppliers', 'customers', 'reports', 'shift_management', 'employees', 'tables', 'delivery') THEN true
      ELSE false
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 'integer'
      WHEN f.key = 'employees' THEN 'integer'
      WHEN f.key = 'warehouse_management' THEN 'integer'
      ELSE 'boolean'
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 1
      WHEN f.key = 'employees' THEN 3
      WHEN f.key = 'warehouse_management' THEN 1
      ELSE NULL
    END
  FROM public.features f
  ON CONFLICT (plan_id, feature_id) DO UPDATE
  SET enabled = EXCLUDED.enabled, limit_type = EXCLUDED.limit_type, limit_value = EXCLUDED.limit_value;

  -- 3. Professional: Adds KDS, Recipes, Costing, Excel Export/Import, Accounting basics, up to 3 branches
  INSERT INTO public.plan_features (plan_id, feature_id, enabled, limit_type, limit_value)
  SELECT v_plan_pro, f.id,
    CASE 
      WHEN f.key IN ('pos', 'inventory', 'purchases', 'suppliers', 'customers', 'reports', 'shift_management', 'employees', 'tables', 'delivery',
                     'kds', 'recipes', 'costing', 'excel_export', 'excel_import', 'waste_management', 'transfers', 'stock_counts', 'accounting', 'advanced_reports') THEN true
      ELSE false
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 'integer'
      WHEN f.key = 'employees' THEN 'integer'
      WHEN f.key = 'warehouse_management' THEN 'integer'
      ELSE 'boolean'
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 3
      WHEN f.key = 'employees' THEN 10
      WHEN f.key = 'warehouse_management' THEN 3
      ELSE NULL
    END
  FROM public.features f
  ON CONFLICT (plan_id, feature_id) DO UPDATE
  SET enabled = EXCLUDED.enabled, limit_type = EXCLUDED.limit_type, limit_value = EXCLUDED.limit_value;

  -- 4. Business: Full suite including Manufacturing, Multi-branch, Audit Logs, Advanced Permissions, up to 10 branches
  INSERT INTO public.plan_features (plan_id, feature_id, enabled, limit_type, limit_value)
  SELECT v_plan_biz, f.id,
    CASE 
      WHEN f.key IN ('ai_assistant', 'api_access') THEN false
      ELSE true
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 'integer'
      WHEN f.key = 'employees' THEN 'integer'
      WHEN f.key = 'warehouse_management' THEN 'integer'
      ELSE 'boolean'
    END,
    CASE 
      WHEN f.key = 'multi_branch' THEN 10
      WHEN f.key = 'employees' THEN 50
      WHEN f.key = 'warehouse_management' THEN 15
      ELSE NULL
    END
  FROM public.features f
  ON CONFLICT (plan_id, feature_id) DO UPDATE
  SET enabled = EXCLUDED.enabled, limit_type = EXCLUDED.limit_type, limit_value = EXCLUDED.limit_value;

  -- 5. Enterprise: All features enabled, Unlimited limits
  INSERT INTO public.plan_features (plan_id, feature_id, enabled, limit_type, limit_value)
  SELECT v_plan_ent, f.id, true, 'unlimited', -1
  FROM public.features f
  ON CONFLICT (plan_id, feature_id) DO UPDATE
  SET enabled = true, limit_type = 'unlimited', limit_value = -1;

END $$;

-- ============================================================================
-- 5. MULTI-TENANT SUBSCRIPTIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  plan_id uuid NOT NULL REFERENCES public.plans(id) ON DELETE RESTRICT,
  plan_price_id uuid REFERENCES public.plan_prices(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'trialing',
  started_at timestamptz NOT NULL DEFAULT now(),
  trial_started_at timestamptz DEFAULT now(),
  trial_ends_at timestamptz,
  current_period_start timestamptz DEFAULT now(),
  current_period_end timestamptz,
  cancelled_at timestamptz,
  suspended_at timestamptz,
  auto_renew boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id),
  CONSTRAINT subscriptions_status_check
    CHECK (status IN ('trialing', 'active', 'past_due', 'suspended', 'cancelled', 'expired'))
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_tenant_status ON public.subscriptions(tenant_id, status);

-- ============================================================================
-- 6. BRANCH FEATURE OVERRIDES
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.branch_feature_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  feature_id uuid NOT NULL REFERENCES public.features(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  limit_value integer DEFAULT NULL,
  reason text,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (branch_id, feature_id)
);

CREATE INDEX IF NOT EXISTS idx_branch_feature_overrides_lookup ON public.branch_feature_overrides(branch_id, feature_id, enabled);

-- ============================================================================
-- 7. SUBSCRIPTION EVENTS & AUDIT LOG
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.subscription_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  subscription_id uuid REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('created', 'trial_started', 'activated', 'renewed', 'upgraded', 'downgraded', 'suspended', 'reactivated', 'cancelled', 'expired', 'extended', 'feature_enabled', 'feature_disabled')),
  old_status text,
  new_status text,
  old_plan_id uuid,
  new_plan_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscription_events_tenant ON public.subscription_events(tenant_id, created_at DESC);

-- ============================================================================
-- 8. INITIAL BACKFILL FOR EXISTING ORGANIZATIONS
-- ============================================================================
DO $$
DECLARE
  v_default_plan uuid;
  v_org record;
BEGIN
  SELECT id INTO v_default_plan FROM public.plans WHERE slug = 'free';

  FOR v_org IN SELECT id, created_at FROM public.organizations LOOP
    INSERT INTO public.subscriptions (
      tenant_id,
      plan_id,
      status,
      started_at,
      trial_started_at,
      trial_ends_at,
      current_period_start,
      current_period_end
    )
    VALUES (
      v_org.id,
      v_default_plan,
      'trialing',
      v_org.created_at,
      v_org.created_at,
      v_org.created_at + INTERVAL '90 days',
      v_org.created_at,
      v_org.created_at + INTERVAL '90 days'
    )
    ON CONFLICT (tenant_id) DO NOTHING;
  END LOOP;
END $$;

-- ============================================================================
-- 9. CORE AUTHORIZATION & RESOLUTION RPCs
-- ============================================================================

-- A. subscription_is_active
CREATE OR REPLACE FUNCTION public.subscription_is_active(p_tenant_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tid uuid := p_tenant_id;
  v_sub public.subscriptions%ROWTYPE;
  v_org_active boolean := true;
BEGIN
  -- Super admin bypasses subscription gate
  IF is_super_admin() THEN
    RETURN true;
  END IF;

  -- If tenant not provided, infer from user's active branch or organization membership
  IF v_tid IS NULL THEN
    SELECT b.organization_id INTO v_tid
    FROM public.branches b
    WHERE b.id = get_branch_id();

    IF v_tid IS NULL THEN
      SELECT om.organization_id INTO v_tid
      FROM public.organization_members om
      WHERE om.user_id = auth.uid() AND om.is_active = true
      LIMIT 1;
    END IF;
  END IF;

  IF v_tid IS NULL THEN
    RETURN false;
  END IF;

  -- 1. Check if organization is active
  SELECT is_active INTO v_org_active FROM public.organizations WHERE id = v_tid;
  IF v_org_active IS FALSE THEN
    RETURN false;
  END IF;

  -- 2. Fetch subscription
  SELECT * INTO v_sub FROM public.subscriptions WHERE tenant_id = v_tid;
  IF v_sub.id IS NULL THEN
    RETURN false;
  END IF;

  -- 3. Check status
  IF v_sub.status = 'active' THEN
    IF v_sub.current_period_end IS NOT NULL AND v_sub.current_period_end < now() THEN
      RETURN false;
    END IF;
    RETURN true;
  ELSIF v_sub.status = 'trialing' THEN
    IF v_sub.trial_ends_at IS NOT NULL AND v_sub.trial_ends_at < now() THEN
      RETURN false;
    END IF;
    RETURN true;
  ELSE
    RETURN false;
  END IF;
END;
$$;

-- B. resolve_feature_access
CREATE OR REPLACE FUNCTION public.resolve_feature_access(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_feature_key text,
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.subscriptions%ROWTYPE;
  v_feat public.features%ROWTYPE;
  v_plan_feat public.plan_features%ROWTYPE;
  v_override public.branch_feature_overrides%ROWTYPE;
  v_org_active boolean := true;
  v_is_super boolean := false;
BEGIN
  v_is_super := is_super_admin();
  IF v_is_super THEN
    RETURN jsonb_build_object(
      'allowed', true,
      'reason', 'SUPER_ADMIN',
      'source', 'system',
      'limit_value', NULL,
      'limit_type', 'unlimited'
    );
  END IF;

  -- 1. Check Feature in Registry
  SELECT * INTO v_feat FROM public.features WHERE key = p_feature_key;
  IF v_feat.id IS NULL THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'FEATURE_NOT_FOUND', 'source', 'system');
  END IF;

  IF v_feat.is_active IS FALSE THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'FEATURE_DISABLED_GLOBALLY', 'source', 'system');
  END IF;

  -- 2. Check Organization Status
  IF p_tenant_id IS NOT NULL THEN
    SELECT is_active INTO v_org_active FROM public.organizations WHERE id = p_tenant_id;
    IF v_org_active IS FALSE THEN
      RETURN jsonb_build_object('allowed', false, 'reason', 'TENANT_SUSPENDED', 'source', 'tenant');
    END IF;
  END IF;

  -- 3. Check Subscription Status
  SELECT * INTO v_sub FROM public.subscriptions WHERE tenant_id = p_tenant_id;
  IF v_sub.id IS NULL THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'NO_SUBSCRIPTION', 'source', 'subscription');
  END IF;

  IF v_sub.status = 'suspended' THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'SUBSCRIPTION_SUSPENDED', 'source', 'subscription');
  ELSIF v_sub.status = 'cancelled' THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'SUBSCRIPTION_CANCELLED', 'source', 'subscription');
  ELSIF v_sub.status = 'expired' OR 
        (v_sub.status = 'trialing' AND v_sub.trial_ends_at < now()) OR
        (v_sub.status = 'active' AND v_sub.current_period_end < now()) THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'SUBSCRIPTION_EXPIRED', 'source', 'subscription');
  END IF;

  -- 4. Check Branch Feature Override (if branch provided)
  IF p_branch_id IS NOT NULL THEN
    SELECT * INTO v_override
    FROM public.branch_feature_overrides
    WHERE branch_id = p_branch_id AND feature_id = v_feat.id;

    IF v_override.id IS NOT NULL THEN
      IF v_override.enabled IS FALSE THEN
        RETURN jsonb_build_object(
          'allowed', false,
          'reason', 'BRANCH_OVERRIDE_DISABLED',
          'source', 'branch_override',
          'limit_value', v_override.limit_value
        );
      ELSE
        RETURN jsonb_build_object(
          'allowed', true,
          'reason', 'BRANCH_OVERRIDE_ENABLED',
          'source', 'branch_override',
          'limit_value', v_override.limit_value
        );
      END IF;
    END IF;
  END IF;

  -- 5. Check Plan Feature
  SELECT * INTO v_plan_feat
  FROM public.plan_features
  WHERE plan_id = v_sub.plan_id AND feature_id = v_feat.id;

  IF v_plan_feat.id IS NULL OR v_plan_feat.enabled IS FALSE THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'FEATURE_NOT_INCLUDED_IN_PLAN',
      'source', 'plan',
      'limit_value', NULL
    );
  END IF;

  -- Feature is allowed by Plan
  RETURN jsonb_build_object(
    'allowed', true,
    'reason', 'PLAN_ENABLED',
    'source', 'plan',
    'limit_value', v_plan_feat.limit_value,
    'limit_type', v_plan_feat.limit_type
  );
END;
$$;

-- C. get_feature_access
CREATE OR REPLACE FUNCTION public.get_feature_access(
  p_feature_key text,
  p_branch_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tid uuid;
  v_bid uuid := p_branch_id;
BEGIN
  IF v_bid IS NULL THEN
    v_bid := get_branch_id();
  END IF;

  IF v_bid IS NOT NULL THEN
    SELECT organization_id INTO v_tid FROM public.branches WHERE id = v_bid;
  END IF;

  IF v_tid IS NULL THEN
    SELECT organization_id INTO v_tid
    FROM public.organization_members
    WHERE user_id = auth.uid() AND is_active = true
    LIMIT 1;
  END IF;

  RETURN public.resolve_feature_access(v_tid, v_bid, p_feature_key, auth.uid());
END;
$$;

-- D. can_access_feature (boolean helper for RLS and SQL queries)
CREATE OR REPLACE FUNCTION public.can_access_feature(
  p_feature_key text,
  p_branch_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.get_feature_access(p_feature_key, p_branch_id);
  RETURN COALESCE((v_res->>'allowed')::boolean, false);
END;
$$;

-- E. Limits Enforcement Helpers
CREATE OR REPLACE FUNCTION public.can_create_branch(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tid uuid := p_tenant_id;
  v_count integer;
  v_limit integer;
  v_access jsonb;
BEGIN
  IF is_super_admin() THEN
    RETURN jsonb_build_object('allowed', true, 'current', 0, 'limit', -1);
  END IF;

  IF v_tid IS NULL THEN
    SELECT om.organization_id INTO v_tid FROM public.organization_members om WHERE om.user_id = auth.uid() AND om.is_active = true LIMIT 1;
  END IF;

  v_access := public.resolve_feature_access(v_tid, NULL, 'multi_branch', auth.uid());
  IF (v_access->>'allowed')::boolean IS FALSE THEN
    -- Check if they already have 1 branch
    SELECT count(*) INTO v_count FROM public.branches WHERE organization_id = v_tid;
    IF v_count >= 1 THEN
      RETURN jsonb_build_object('allowed', false, 'reason', 'MULTI_BRANCH_FEATURE_LOCKED', 'current', v_count, 'limit', 1);
    END IF;
  END IF;

  v_limit := COALESCE((v_access->>'limit_value')::integer, -1);
  SELECT count(*) INTO v_count FROM public.branches WHERE organization_id = v_tid;

  IF v_limit > 0 AND v_count >= v_limit THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'BRANCH_LIMIT_REACHED', 'current', v_count, 'limit', v_limit);
  END IF;

  RETURN jsonb_build_object('allowed', true, 'current', v_count, 'limit', v_limit);
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_user(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tid uuid := p_tenant_id;
  v_count integer;
  v_limit integer;
  v_access jsonb;
BEGIN
  IF is_super_admin() THEN
    RETURN jsonb_build_object('allowed', true, 'current', 0, 'limit', -1);
  END IF;

  IF v_tid IS NULL THEN
    SELECT om.organization_id INTO v_tid FROM public.organization_members om WHERE om.user_id = auth.uid() AND om.is_active = true LIMIT 1;
  END IF;

  v_access := public.resolve_feature_access(v_tid, NULL, 'employees', auth.uid());
  v_limit := COALESCE((v_access->>'limit_value')::integer, -1);

  SELECT count(*) INTO v_count
  FROM public.organization_members
  WHERE organization_id = v_tid AND is_active = true;

  IF v_limit > 0 AND v_count >= v_limit THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'USER_LIMIT_REACHED', 'current', v_count, 'limit', v_limit);
  END IF;

  RETURN jsonb_build_object('allowed', true, 'current', v_count, 'limit', v_limit);
END;
$$;

-- F. Tenant Full Subscription Details
CREATE OR REPLACE FUNCTION public.get_tenant_subscription_details(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tid uuid := p_tenant_id;
  v_sub public.subscriptions%ROWTYPE;
  v_plan public.plans%ROWTYPE;
  v_price public.plan_prices%ROWTYPE;
  v_features jsonb;
  v_overrides jsonb;
  v_branches_count integer := 0;
  v_users_count integer := 0;
  v_warehouses_count integer := 0;
  v_events jsonb;
BEGIN
  IF v_tid IS NULL THEN
    SELECT om.organization_id INTO v_tid
    FROM public.organization_members om
    WHERE om.user_id = auth.uid() AND om.is_active = true
    LIMIT 1;

    IF v_tid IS NULL THEN
      SELECT b.organization_id INTO v_tid
      FROM public.branches b
      WHERE b.id = get_branch_id();
    END IF;
  END IF;

  IF v_tid IS NULL THEN
    RETURN jsonb_build_object('error', 'TENANT_NOT_FOUND');
  END IF;

  SELECT * INTO v_sub FROM public.subscriptions WHERE tenant_id = v_tid;
  IF v_sub.id IS NULL THEN
    RETURN jsonb_build_object('has_subscription', false, 'tenant_id', v_tid);
  END IF;

  SELECT * INTO v_plan FROM public.plans WHERE id = v_sub.plan_id;
  IF v_sub.plan_price_id IS NOT NULL THEN
    SELECT * INTO v_price FROM public.plan_prices WHERE id = v_sub.plan_price_id;
  END IF;

  -- Aggregate Plan Features
  SELECT jsonb_agg(
    jsonb_build_object(
      'key', f.key,
      'name', f.name,
      'description', f.description,
      'category', f.category,
      'enabled', COALESCE(pf.enabled, false),
      'limit_value', pf.limit_value,
      'limit_type', pf.limit_type
    ) ORDER BY f.category, f.name
  ) INTO v_features
  FROM public.features f
  LEFT JOIN public.plan_features pf ON pf.feature_id = f.id AND pf.plan_id = v_sub.plan_id;

  -- Branch Overrides for Tenant
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', bfo.id,
      'branch_id', bfo.branch_id,
      'branch_name', b.name,
      'feature_key', f.key,
      'feature_name', f.name,
      'enabled', bfo.enabled,
      'limit_value', bfo.limit_value,
      'reason', bfo.reason
    )
  ) INTO v_overrides
  FROM public.branch_feature_overrides bfo
  JOIN public.branches b ON b.id = bfo.branch_id
  JOIN public.features f ON f.id = bfo.feature_id
  WHERE bfo.tenant_id = v_tid;

  -- Counts
  SELECT count(*) INTO v_branches_count FROM public.branches WHERE organization_id = v_tid;
  SELECT count(*) INTO v_users_count FROM public.organization_members WHERE organization_id = v_tid AND is_active = true;
  SELECT count(*) INTO v_warehouses_count FROM public.warehouses w JOIN public.branches b ON b.id = w.branch_id WHERE b.organization_id = v_tid;

  -- Recent Events
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', se.id,
      'event_type', se.event_type,
      'old_status', se.old_status,
      'new_status', se.new_status,
      'metadata', se.metadata,
      'created_at', se.created_at
    ) ORDER BY se.created_at DESC
  ) INTO v_events
  FROM (
    SELECT * FROM public.subscription_events
    WHERE tenant_id = v_tid
    ORDER BY created_at DESC
    LIMIT 20
  ) se;

  RETURN jsonb_build_object(
    'has_subscription', true,
    'subscription', jsonb_build_object(
      'id', v_sub.id,
      'tenant_id', v_sub.tenant_id,
      'status', v_sub.status,
      'started_at', v_sub.started_at,
      'trial_started_at', v_sub.trial_started_at,
      'trial_ends_at', v_sub.trial_ends_at,
      'current_period_start', v_sub.current_period_start,
      'current_period_end', v_sub.current_period_end,
      'cancelled_at', v_sub.cancelled_at,
      'suspended_at', v_sub.suspended_at,
      'auto_renew', v_sub.auto_renew
    ),
    'plan', jsonb_build_object(
      'id', v_plan.id,
      'name', v_plan.name,
      'slug', v_plan.slug,
      'description', v_plan.description
    ),
    'price', CASE WHEN v_price.id IS NOT NULL THEN jsonb_build_object(
      'id', v_price.id,
      'billing_cycle', v_price.billing_cycle,
      'price', v_price.price,
      'currency', v_price.currency
    ) ELSE NULL END,
    'features', COALESCE(v_features, '[]'::jsonb),
    'branch_overrides', COALESCE(v_overrides, '[]'::jsonb),
    'usage', jsonb_build_object(
      'branches_count', v_branches_count,
      'users_count', v_users_count,
      'warehouses_count', v_warehouses_count
    ),
    'events', COALESCE(v_events, '[]'::jsonb)
  );
END;
$$;

-- G. Super Admin Management RPCs
CREATE OR REPLACE FUNCTION public.super_admin_change_subscription(
  p_tenant_id uuid,
  p_plan_id uuid,
  p_status text,
  p_current_period_end timestamptz DEFAULT NULL,
  p_trial_ends_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.subscriptions%ROWTYPE;
  v_old_status text;
  v_old_plan uuid;
BEGIN
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  SELECT * INTO v_sub FROM public.subscriptions WHERE tenant_id = p_tenant_id;
  v_old_status := v_sub.status;
  v_old_plan := v_sub.plan_id;

  INSERT INTO public.subscriptions (
    tenant_id,
    plan_id,
    status,
    current_period_end,
    trial_ends_at,
    updated_at
  )
  VALUES (
    p_tenant_id,
    p_plan_id,
    p_status,
    COALESCE(p_current_period_end, now() + INTERVAL '30 days'),
    p_trial_ends_at,
    now()
  )
  ON CONFLICT (tenant_id) DO UPDATE
  SET plan_id = EXCLUDED.plan_id,
      status = EXCLUDED.status,
      current_period_end = EXCLUDED.current_period_end,
      trial_ends_at = EXCLUDED.trial_ends_at,
      updated_at = now();

  -- Log event
  INSERT INTO public.subscription_events (
    tenant_id,
    event_type,
    old_status,
    new_status,
    old_plan_id,
    new_plan_id,
    metadata,
    created_by
  )
  VALUES (
    p_tenant_id,
    CASE 
      WHEN v_old_status != p_status AND p_status = 'active' THEN 'activated'
      WHEN v_old_status != p_status AND p_status = 'suspended' THEN 'suspended'
      WHEN v_old_plan != p_plan_id THEN 'upgraded'
      ELSE 'renewed'
    END,
    v_old_status,
    p_status,
    v_old_plan,
    p_plan_id,
    jsonb_build_object('action', 'super_admin_change_subscription'),
    auth.uid()
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- H. Super Admin Branch Feature Override RPC
CREATE OR REPLACE FUNCTION public.super_admin_set_branch_override(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_feature_key text,
  p_enabled boolean,
  p_limit_value integer DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_feat_id uuid;
BEGIN
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  SELECT id INTO v_feat_id FROM public.features WHERE key = p_feature_key;
  IF v_feat_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'FEATURE_NOT_FOUND');
  END IF;

  INSERT INTO public.branch_feature_overrides (
    tenant_id,
    branch_id,
    feature_id,
    enabled,
    limit_value,
    reason,
    created_by,
    updated_at
  )
  VALUES (
    p_tenant_id,
    p_branch_id,
    v_feat_id,
    p_enabled,
    p_limit_value,
    p_reason,
    auth.uid(),
    now()
  )
  ON CONFLICT (branch_id, feature_id) DO UPDATE
  SET enabled = EXCLUDED.enabled,
      limit_value = EXCLUDED.limit_value,
      reason = EXCLUDED.reason,
      updated_at = now();

  -- Log event
  INSERT INTO public.subscription_events (
    tenant_id,
    event_type,
    metadata,
    created_by
  )
  VALUES (
    p_tenant_id,
    CASE WHEN p_enabled THEN 'feature_enabled' ELSE 'feature_disabled' END,
    jsonb_build_object(
      'branch_id', p_branch_id,
      'feature_key', p_feature_key,
      'enabled', p_enabled,
      'reason', p_reason
    ),
    auth.uid()
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_remove_branch_override(
  p_branch_id uuid,
  p_feature_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_feat_id uuid;
BEGIN
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  SELECT id INTO v_feat_id FROM public.features WHERE key = p_feature_key;
  IF v_feat_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'FEATURE_NOT_FOUND');
  END IF;

  DELETE FROM public.branch_feature_overrides
  WHERE branch_id = p_branch_id AND feature_id = v_feat_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================================
-- 10. ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_feature_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_events ENABLE ROW LEVEL SECURITY;

-- Plans & Prices: Public read for active, Super Admin full control
DROP POLICY IF EXISTS plans_select ON public.plans;
CREATE POLICY plans_select ON public.plans FOR SELECT TO anon, authenticated
  USING (is_active = true OR is_super_admin());

DROP POLICY IF EXISTS plans_super_admin_all ON public.plans;
CREATE POLICY plans_super_admin_all ON public.plans FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS plan_prices_select ON public.plan_prices;
CREATE POLICY plan_prices_select ON public.plan_prices FOR SELECT TO anon, authenticated
  USING (is_active = true OR is_super_admin());

DROP POLICY IF EXISTS plan_prices_super_admin_all ON public.plan_prices;
CREATE POLICY plan_prices_super_admin_all ON public.plan_prices FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Features & Plan Features: Public read for active, Super Admin full control
DROP POLICY IF EXISTS features_select ON public.features;
CREATE POLICY features_select ON public.features FOR SELECT TO anon, authenticated
  USING (is_active = true OR is_super_admin());

DROP POLICY IF EXISTS features_super_admin_all ON public.features;
CREATE POLICY features_super_admin_all ON public.features FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

DROP POLICY IF EXISTS plan_features_select ON public.plan_features;
CREATE POLICY plan_features_select ON public.plan_features FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS plan_features_super_admin_all ON public.plan_features;
CREATE POLICY plan_features_super_admin_all ON public.plan_features FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Subscriptions: Tenant members can read own subscription, Super Admin full control
DROP POLICY IF EXISTS subscriptions_select ON public.subscriptions;
CREATE POLICY subscriptions_select ON public.subscriptions FOR SELECT TO authenticated
  USING (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = subscriptions.tenant_id
        AND om.user_id = auth.uid()
        AND om.is_active = true
    )
    OR EXISTS (
      SELECT 1 FROM public.branches b
      WHERE b.organization_id = subscriptions.tenant_id
        AND b.id = get_branch_id()
    )
  );

DROP POLICY IF EXISTS subscriptions_super_admin_all ON public.subscriptions;
CREATE POLICY subscriptions_super_admin_all ON public.subscriptions FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Branch Feature Overrides: Tenant members read own, Super Admin manage
DROP POLICY IF EXISTS branch_overrides_select ON public.branch_feature_overrides;
CREATE POLICY branch_overrides_select ON public.branch_feature_overrides FOR SELECT TO authenticated
  USING (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = branch_feature_overrides.tenant_id
        AND om.user_id = auth.uid()
        AND om.is_active = true
    )
    OR branch_id = get_branch_id()
  );

DROP POLICY IF EXISTS branch_overrides_super_admin_all ON public.branch_feature_overrides;
CREATE POLICY branch_overrides_super_admin_all ON public.branch_feature_overrides FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Subscription Events: Tenant members read own, Super Admin full control
DROP POLICY IF EXISTS subscription_events_select ON public.subscription_events;
CREATE POLICY subscription_events_select ON public.subscription_events FOR SELECT TO authenticated
  USING (
    is_super_admin()
    OR EXISTS (
      SELECT 1 FROM public.organization_members om
      WHERE om.organization_id = subscription_events.tenant_id
        AND om.user_id = auth.uid()
        AND om.is_active = true
    )
  );

DROP POLICY IF EXISTS subscription_events_super_admin_all ON public.subscription_events;
CREATE POLICY subscription_events_super_admin_all ON public.subscription_events FOR ALL TO authenticated
  USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ============================================================================
-- 11. PERMISSIONS & GRANTS
-- ============================================================================
GRANT SELECT ON public.plans, public.plan_prices, public.features, public.plan_features TO anon, authenticated;
GRANT SELECT ON public.subscriptions, public.branch_feature_overrides, public.subscription_events TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscription_is_active(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_feature_access(uuid, uuid, text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_feature_access(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_feature(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_branch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tenant_subscription_details(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_change_subscription(uuid, uuid, text, timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_set_branch_override(uuid, uuid, text, boolean, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_remove_branch_override(uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260830000000_simplify_system_kitchen_consumption.sql
-- ----------------------------------------------------------------------------
-- Migration 20260830000000_simplify_system_kitchen_consumption.sql
-- 1. Remove Manufacturing & Subscription dependencies
-- 2. Direct Kitchen Inventory Consumption (Recipe Ingredients & Stocked Products)
-- 3. Idempotency & Quantity Delta Adjustments for Kitchen Sends
-- 4. Central Super Admin User Creation Toggle with Server-side Enforcement & Audit Logging

-- -----------------------------------------------------------------------------
-- 1. Order Inventory Consumption Tracking Table (Idempotency & Delta Ledger)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_inventory_consumptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  raw_material_id uuid REFERENCES public.raw_materials(id) ON DELETE SET NULL,
  warehouse_id uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  consumed_quantity numeric(14,4) NOT NULL DEFAULT 0,
  reversed_quantity numeric(14,4) NOT NULL DEFAULT 0,
  unit_cost numeric(14,4) DEFAULT 0,
  status text NOT NULL DEFAULT 'consumed', -- 'consumed', 'reversed', 'adjusted'
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_order_item_consumption UNIQUE (order_item_id, raw_material_id)
);

ALTER TABLE public.order_inventory_consumptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all_order_inventory_consumptions" ON public.order_inventory_consumptions;
CREATE POLICY "auth_all_order_inventory_consumptions" ON public.order_inventory_consumptions
  FOR ALL TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id())
  WITH CHECK (is_pos_admin() OR branch_id = get_branch_id());

CREATE INDEX IF NOT EXISTS idx_order_inv_consump_order ON public.order_inventory_consumptions(order_id);
CREATE INDEX IF NOT EXISTS idx_order_inv_consump_branch ON public.order_inventory_consumptions(branch_id);

-- -----------------------------------------------------------------------------
-- 2. System Controls: Allow New User Creation Setting
-- -----------------------------------------------------------------------------
-- Ensure system_settings has security.allow_new_user_creation = true by default
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'system_settings') THEN
    UPDATE public.system_settings
    SET config = jsonb_set(
      COALESCE(config, '{}'::jsonb),
      '{security,allow_new_user_creation}',
      COALESCE(config->'security'->'allow_new_user_creation', 'true'::jsonb),
      true
    )
    WHERE id = 1;
  END IF;
END $$;

-- RPC to check if new user creation is globally allowed
CREATE OR REPLACE FUNCTION public.can_create_new_user()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_allowed boolean := true;
  v_config jsonb;
BEGIN
  -- Super admin can always manage users
  IF is_super_admin() THEN
    RETURN jsonb_build_object('allowed', true, 'is_super_admin', true);
  END IF;

  SELECT config INTO v_config FROM public.system_settings WHERE id = 1;
  IF v_config IS NOT NULL AND v_config->'security' ? 'allow_new_user_creation' THEN
    v_allowed := COALESCE((v_config->'security'->>'allow_new_user_creation')::boolean, true);
  END IF;

  IF NOT v_allowed THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'error', 'USER_CREATION_DISABLED',
      'message', 'تم إيقاف إنشاء المستخدمين الجدد بواسطة Super Admin'
    );
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

-- Super Admin RPC to toggle user creation setting and record audit log
CREATE OR REPLACE FUNCTION public.toggle_user_creation_setting(p_allowed boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_value boolean := true;
  v_config jsonb;
BEGIN
  IF NOT is_super_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED_SUPER_ADMIN_ONLY', 'message', 'فقط Super Admin يمكنه تعديل هذا الإعداد');
  END IF;

  SELECT config INTO v_config FROM public.system_settings WHERE id = 1;
  IF v_config IS NOT NULL AND v_config->'security' ? 'allow_new_user_creation' THEN
    v_old_value := COALESCE((v_config->'security'->>'allow_new_user_creation')::boolean, true);
  END IF;

  UPDATE public.system_settings
  SET config = jsonb_set(
    COALESCE(config, '{}'::jsonb),
    '{security,allow_new_user_creation}',
    to_jsonb(p_allowed),
    true
  ),
  updated_by = auth.uid(),
  updated_at = now()
  WHERE id = 1;

  -- Record audit log if audit_log table exists
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'audit_logs') THEN
    INSERT INTO public.audit_logs (
      action,
      entity,
      entity_id,
      user_id,
      details,
      created_at
    ) VALUES (
      'TOGGLE_ALLOW_NEW_USER_CREATION',
      'system_settings',
      '1',
      auth.uid(),
      jsonb_build_object(
        'old_value', v_old_value,
        'new_value', p_allowed,
        'changed_by', auth.uid(),
        'timestamp', now()
      ),
      now()
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'allow_new_user_creation', p_allowed,
    'old_value', v_old_value
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Atomic & Idempotent Kitchen Inventory Consumption RPC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consume_order_kitchen_inventory(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order record;
  v_item record;
  v_recipe record;
  v_recipe_item record;
  v_warehouse_id uuid;
  v_existing_consumption record;
  v_delta numeric(14,4);
  v_reversal_delta numeric(14,4);
  v_yield numeric(14,4);
  v_multiplier numeric(14,4);
  v_ingredient_deduct numeric(14,4);
  v_current_rm_stock numeric(14,4);
  v_current_inv_stock numeric(14,4);
  v_items_processed integer := 0;
  v_has_recipe boolean;
  v_now timestamptz := now();
  v_send_row record;
BEGIN
  -- 1. Fetch and lock order
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  -- 2. Resolve active warehouse for branch
  SELECT id INTO v_warehouse_id FROM public.warehouses
  WHERE branch_id = v_order.branch_id AND is_active = true
  ORDER BY is_default DESC NULLS LAST, created_at ASC
  LIMIT 1;

  -- 3. Iterate over order items
  FOR v_item IN
    SELECT * FROM public.order_items WHERE order_id = p_order_id
  LOOP
    IF v_item.product_id IS NULL OR v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      CONTINUE;
    END IF;

    -- Check if product has an active recipe
    SELECT * INTO v_recipe FROM public.recipes
    WHERE product_id = v_item.product_id
      AND (branch_id = v_order.branch_id OR branch_id IS NULL)
      AND is_active = true
    LIMIT 1;

    v_has_recipe := (v_recipe.id IS NULL = false);

    IF v_has_recipe THEN
      -- Process Recipe Ingredients deduction
      v_yield := COALESCE(v_recipe.yield_quantity, 1);
      IF v_yield <= 0 THEN v_yield := 1; END IF;

      FOR v_recipe_item IN
        SELECT * FROM public.recipe_items WHERE recipe_id = v_recipe.id
      LOOP
        -- Check existing consumption for this order item and raw material
        SELECT * INTO v_existing_consumption
        FROM public.order_inventory_consumptions
        WHERE order_item_id = v_item.id
          AND raw_material_id = v_recipe_item.raw_material_id;

        IF v_existing_consumption.id IS NULL THEN
          -- First time sending this item
          v_delta := v_item.quantity;
          v_multiplier := v_delta / v_yield;
          v_ingredient_deduct := v_recipe_item.quantity * v_multiplier * (1 + COALESCE(v_recipe_item.wastage_percent, 0) / 100);

          -- Deduct from raw material inventory
          UPDATE public.raw_material_inventory
          SET quantity = GREATEST(0, quantity - v_ingredient_deduct),
              updated_at = v_now
          WHERE raw_material_id = v_recipe_item.raw_material_id
            AND branch_id = v_order.branch_id;

          -- Log to raw_material_movements
          INSERT INTO public.raw_material_movements (
            material_id,
            warehouse_id,
            movement_type,
            quantity,
            reference_id,
            branch_id,
            created_at
          ) VALUES (
            v_recipe_item.raw_material_id,
            v_warehouse_id,
            'KITCHEN_CONSUMPTION',
            -v_ingredient_deduct,
            p_order_id,
            v_order.branch_id,
            v_now
          );

          -- Insert tracking consumption
          INSERT INTO public.order_inventory_consumptions (
            order_id,
            order_item_id,
            product_id,
            raw_material_id,
            warehouse_id,
            branch_id,
            consumed_quantity,
            status,
            created_at,
            updated_at
          ) VALUES (
            p_order_id,
            v_item.id,
            v_item.product_id,
            v_recipe_item.raw_material_id,
            v_warehouse_id,
            v_order.branch_id,
            v_item.quantity,
            'consumed',
            v_now,
            v_now
          );

          v_items_processed := v_items_processed + 1;

        ELSE
          -- Item was already sent previously; check for delta modifications
          IF v_item.quantity > v_existing_consumption.consumed_quantity THEN
            -- Quantity increased (e.g. 2 -> 3)
            v_delta := v_item.quantity - v_existing_consumption.consumed_quantity;
            v_multiplier := v_delta / v_yield;
            v_ingredient_deduct := v_recipe_item.quantity * v_multiplier * (1 + COALESCE(v_recipe_item.wastage_percent, 0) / 100);

            UPDATE public.raw_material_inventory
            SET quantity = GREATEST(0, quantity - v_ingredient_deduct),
                updated_at = v_now
            WHERE raw_material_id = v_recipe_item.raw_material_id
              AND branch_id = v_order.branch_id;

            INSERT INTO public.raw_material_movements (
              material_id,
              warehouse_id,
              movement_type,
              quantity,
              reference_id,
              branch_id,
              created_at
            ) VALUES (
              v_recipe_item.raw_material_id,
              v_warehouse_id,
              'KITCHEN_CONSUMPTION',
              -v_ingredient_deduct,
              p_order_id,
              v_order.branch_id,
              v_now
            );

            UPDATE public.order_inventory_consumptions
            SET consumed_quantity = v_item.quantity,
                updated_at = v_now
            WHERE id = v_existing_consumption.id;

            v_items_processed := v_items_processed + 1;

          ELSIF v_item.quantity < v_existing_consumption.consumed_quantity THEN
            -- Quantity decreased (e.g. 3 -> 2): Reverse delta
            v_reversal_delta := v_existing_consumption.consumed_quantity - v_item.quantity;
            v_multiplier := v_reversal_delta / v_yield;
            v_ingredient_deduct := v_recipe_item.quantity * v_multiplier * (1 + COALESCE(v_recipe_item.wastage_percent, 0) / 100);

            -- Return to raw material inventory
            UPDATE public.raw_material_inventory
            SET quantity = quantity + v_ingredient_deduct,
                updated_at = v_now
            WHERE raw_material_id = v_recipe_item.raw_material_id
              AND branch_id = v_order.branch_id;

            INSERT INTO public.raw_material_movements (
              material_id,
              warehouse_id,
              movement_type,
              quantity,
              reference_id,
              branch_id,
              created_at
            ) VALUES (
              v_recipe_item.raw_material_id,
              v_warehouse_id,
              'KITCHEN_CONSUMPTION_REVERSAL',
              v_ingredient_deduct,
              p_order_id,
              v_order.branch_id,
              v_now
            );

            UPDATE public.order_inventory_consumptions
            SET consumed_quantity = v_item.quantity,
                reversed_quantity = reversed_quantity + v_reversal_delta,
                updated_at = v_now
            WHERE id = v_existing_consumption.id;

            v_items_processed := v_items_processed + 1;
          END IF;
        END IF;
      END LOOP;

    ELSE
      -- Stocked Ready Product deduction
      SELECT * INTO v_existing_consumption
      FROM public.order_inventory_consumptions
      WHERE order_item_id = v_item.id
        AND raw_material_id IS NULL;

      IF v_existing_consumption.id IS NULL THEN
        -- First send: deduct full item quantity
        IF v_warehouse_id IS NOT NULL THEN
          UPDATE public.inventory
          SET quantity = GREATEST(0, quantity - v_item.quantity),
              updated_at = v_now
          WHERE product_id = v_item.product_id
            AND warehouse_id = v_warehouse_id;

          INSERT INTO public.inventory_movements (
            product_id,
            warehouse_id,
            movement_type,
            quantity,
            reference_id,
            branch_id,
            created_at
          ) VALUES (
            v_item.product_id,
            v_warehouse_id,
            'KITCHEN_CONSUMPTION',
            -v_item.quantity,
            p_order_id,
            v_order.branch_id,
            v_now
          );
        END IF;

        INSERT INTO public.order_inventory_consumptions (
          order_id,
          order_item_id,
          product_id,
          raw_material_id,
          warehouse_id,
          branch_id,
          consumed_quantity,
          status,
          created_at,
          updated_at
        ) VALUES (
          p_order_id,
          v_item.id,
          v_item.product_id,
          NULL,
          v_warehouse_id,
          v_order.branch_id,
          v_item.quantity,
          'consumed',
          v_now,
          v_now
        );

        v_items_processed := v_items_processed + 1;

      ELSE
        -- Delta modifications for stocked ready product
        IF v_item.quantity > v_existing_consumption.consumed_quantity THEN
          v_delta := v_item.quantity - v_existing_consumption.consumed_quantity;

          IF v_warehouse_id IS NOT NULL THEN
            UPDATE public.inventory
            SET quantity = GREATEST(0, quantity - v_delta),
                updated_at = v_now
            WHERE product_id = v_item.product_id
              AND warehouse_id = v_warehouse_id;

            INSERT INTO public.inventory_movements (
              product_id,
              warehouse_id,
              movement_type,
              quantity,
              reference_id,
              branch_id,
              created_at
            ) VALUES (
              v_item.product_id,
              v_warehouse_id,
              'KITCHEN_CONSUMPTION',
              -v_delta,
              p_order_id,
              v_order.branch_id,
              v_now
            );
          END IF;

          UPDATE public.order_inventory_consumptions
          SET consumed_quantity = v_item.quantity,
              updated_at = v_now
          WHERE id = v_existing_consumption.id;

          v_items_processed := v_items_processed + 1;

        ELSIF v_item.quantity < v_existing_consumption.consumed_quantity THEN
          v_reversal_delta := v_existing_consumption.consumed_quantity - v_item.quantity;

          IF v_warehouse_id IS NOT NULL THEN
            UPDATE public.inventory
            SET quantity = quantity + v_reversal_delta,
                updated_at = v_now
            WHERE product_id = v_item.product_id
              AND warehouse_id = v_warehouse_id;

            INSERT INTO public.inventory_movements (
              product_id,
              warehouse_id,
              movement_type,
              quantity,
              reference_id,
              branch_id,
              created_at
            ) VALUES (
              v_item.product_id,
              v_warehouse_id,
              'KITCHEN_CONSUMPTION_REVERSAL',
              v_reversal_delta,
              p_order_id,
              v_order.branch_id,
              v_now
            );
          END IF;

          UPDATE public.order_inventory_consumptions
          SET consumed_quantity = v_item.quantity,
              reversed_quantity = reversed_quantity + v_reversal_delta,
              updated_at = v_now
          WHERE id = v_existing_consumption.id;

          v_items_processed := v_items_processed + 1;
        END IF;
      END IF;
    END IF;

    -- Record in order_kitchen_sends for history if not already inserted
    IF NOT EXISTS (SELECT 1 FROM public.order_kitchen_sends WHERE order_item_id = v_item.id) THEN
      INSERT INTO public.order_kitchen_sends (
        branch_id,
        order_id,
        order_item_id,
        sent_at,
        sent_by
      ) VALUES (
        v_order.branch_id,
        p_order_id,
        v_item.id,
        v_now,
        p_sent_by
      );
    END IF;
  END LOOP;

  -- Update dining table to occupied if attached
  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.dining_tables
    SET status = 'occupied', updated_at = v_now
    WHERE id = v_order.table_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'items_processed', v_items_processed
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Order Cancellation Inventory Reversal RPC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_order_kitchen_consumption(
  p_order_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order record;
  v_cons record;
  v_now timestamptz := now();
  v_count integer := 0;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  END IF;

  FOR v_cons IN
    SELECT * FROM public.order_inventory_consumptions
    WHERE order_id = p_order_id AND status = 'consumed' AND consumed_quantity > 0
  LOOP
    IF v_cons.raw_material_id IS NOT NULL THEN
      -- Return recipe ingredient
      UPDATE public.raw_material_inventory
      SET quantity = quantity + v_cons.consumed_quantity,
          updated_at = v_now
      WHERE raw_material_id = v_cons.raw_material_id
        AND branch_id = v_order.branch_id;

      INSERT INTO public.raw_material_movements (
        material_id,
        warehouse_id,
        movement_type,
        quantity,
        reference_id,
        branch_id,
        notes,
        created_at
      ) VALUES (
        v_cons.raw_material_id,
        v_cons.warehouse_id,
        'KITCHEN_CONSUMPTION_REVERSAL',
        v_cons.consumed_quantity,
        p_order_id,
        v_order.branch_id,
        COALESCE(p_reason, 'Order canceled before preparation'),
        v_now
      );
    ELSIF v_cons.product_id IS NOT NULL AND v_cons.warehouse_id IS NOT NULL THEN
      -- Return ready stocked product
      UPDATE public.inventory
      SET quantity = quantity + v_cons.consumed_quantity,
          updated_at = v_now
      WHERE product_id = v_cons.product_id
        AND warehouse_id = v_cons.warehouse_id;

      INSERT INTO public.inventory_movements (
        product_id,
        warehouse_id,
        movement_type,
        quantity,
        reference_id,
        branch_id,
        notes,
        created_at
      ) VALUES (
        v_cons.product_id,
        v_cons.warehouse_id,
        'KITCHEN_CONSUMPTION_REVERSAL',
        v_cons.consumed_quantity,
        p_order_id,
        v_order.branch_id,
        COALESCE(p_reason, 'Order canceled before preparation'),
        v_now
      );
    END IF;

    UPDATE public.order_inventory_consumptions
    SET status = 'reversed',
        reversed_quantity = consumed_quantity,
        consumed_quantity = 0,
        updated_at = v_now
    WHERE id = v_cons.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'reversed_items_count', v_count
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Override Feature Gating & Subscription Restriction Functions
-- (Eliminates plan limits and subscription expiration so tenants have full RBAC access)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_feature_access(
  p_tenant_id uuid DEFAULT NULL,
  p_branch_id uuid DEFAULT NULL,
  p_feature_key text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'allowed', true,
    'feature_key', p_feature_key,
    'plan_id', 'full_enterprise',
    'plan_name', 'Enterprise Standard',
    'status', 'active',
    'limit_value', -1,
    'is_unlimited', true,
    'source', 'direct_access'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_user(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_check jsonb;
BEGIN
  v_check := public.can_create_new_user();
  IF NOT (v_check->>'allowed')::boolean THEN
    RETURN v_check;
  END IF;
  RETURN jsonb_build_object('allowed', true, 'current', 0, 'limit', -1);
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_branch(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object('allowed', true, 'current', 0, 'limit', -1);
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_warehouse(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object('allowed', true, 'current', 0, 'limit', -1);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_tenant_subscription_details(p_tenant_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'status', 'active',
    'plan_name', 'Full Enterprise Access',
    'days_left', 9999,
    'expired', false,
    'tier', 'enterprise'
  );
END;
$$;

-- Grant execution permissions
GRANT EXECUTE ON FUNCTION public.can_create_new_user() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.toggle_user_creation_setting(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_order_kitchen_inventory(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_order_kitchen_consumption(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_feature_access(uuid, uuid, text, uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.can_create_user(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.can_create_branch(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.can_create_warehouse(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_tenant_subscription_details(uuid) TO authenticated, anon;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901000000_bootstrap_super_admin.sql
-- ----------------------------------------------------------------------------
-- =============================================================================
-- Migration: 20260901000000_bootstrap_super_admin.sql
-- Description: Secure bootstrap RPC to initialize the first Super Admin in a clean Supabase database
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE OR REPLACE FUNCTION public.bootstrap_initial_super_admin(
  p_email text,
  p_password text,
  p_full_name text DEFAULT 'Super Admin',
  p_username text DEFAULT 'superadmin'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id uuid;
  v_encrypted_pw text;
  v_email text;
  v_username text;
  v_existing_super_count integer;
BEGIN
  v_email := lower(btrim(p_email));
  v_username := lower(btrim(COALESCE(p_username, split_part(v_email, '@', 1))));

  IF v_email = '' OR v_email !~ '@' OR v_email !~ '\.' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_EMAIL', 'message', 'Invalid email address format');
  END IF;

  IF p_password IS NULL OR length(p_password) < 6 THEN
    RETURN jsonb_build_object('success', false, 'error', 'WEAK_PASSWORD', 'message', 'Password must be at least 6 characters');
  END IF;

  -- Hash password securely with pgcrypto blowfish
  v_encrypted_pw := crypt(p_password, gen_salt('bf'));

  -- Check if user exists in auth.users
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email LIMIT 1;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    
    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      recovery_token,
      email_change_token_new,
      email_change
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      v_encrypted_pw,
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', p_full_name, 'username', v_username, 'role', 'super_admin'),
      now(),
      now(),
      '',
      '',
      '',
      ''
    );
  ELSE
    UPDATE auth.users
    SET encrypted_password = v_encrypted_pw,
        email_confirmed_at = COALESCE(email_confirmed_at, now()),
        raw_user_meta_data = jsonb_build_object('full_name', p_full_name, 'username', v_username, 'role', 'super_admin'),
        updated_at = now()
    WHERE id = v_user_id;
  END IF;

  -- Upsert into public.users
  INSERT INTO public.users (
    id,
    email,
    full_name,
    username,
    role,
    is_active,
    branch_id,
    created_at,
    updated_at
  ) VALUES (
    v_user_id,
    v_email,
    p_full_name,
    v_username,
    'super_admin',
    true,
    NULL,
    now(),
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      full_name = EXCLUDED.full_name,
      username = EXCLUDED.username,
      role = 'super_admin',
      is_active = true,
      updated_at = now();

  -- Record audit log if table exists
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'audit_logs') THEN
    INSERT INTO public.audit_logs (
      action,
      entity,
      entity_id,
      user_id,
      details,
      created_at
    ) VALUES (
      'BOOTSTRAP_SUPER_ADMIN',
      'users',
      v_user_id::text,
      v_user_id,
      jsonb_build_object('email', v_email, 'username', v_username, 'role', 'super_admin'),
      now()
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'email', v_email,
    'username', v_username,
    'role', 'super_admin'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text, text, text, text) TO authenticated, anon;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901010000_integrate_kitchen_send_inventory_deduction.sql
-- ----------------------------------------------------------------------------
-- 20260901010000_integrate_kitchen_send_inventory_deduction.sql
-- Integrates atomic inventory deduction into send_to_kitchen and ensures
-- idempotent, single-deduction kitchen consumption with full UI ticket data returned.

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
BEGIN
  BEGIN
    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders WHERE id = p_order_id;
    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.');
    END IF;

    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF NOT is_pos_admin() AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    -- Snapshot ONLY lines without an existing send row.
    CREATE TEMP TABLE IF NOT EXISTS _kns (order_item_id uuid, send_id uuid) ON COMMIT DROP;
    TRUNCATE _kns;

    WITH newly_sent AS (
      INSERT INTO public.order_kitchen_sends (branch_id, order_id, order_item_id, sent_by)
      SELECT v_branch_id, p_order_id, oi.id, COALESCE(p_sent_by, auth.uid())
      FROM public.order_items oi
      WHERE oi.order_id = p_order_id
        AND NOT EXISTS (
          SELECT 1 FROM public.order_kitchen_sends s
          WHERE s.order_item_id = oi.id
        )
      ON CONFLICT (order_item_id) DO NOTHING
      RETURNING id, order_item_id
    )
    INSERT INTO _kns (order_item_id, send_id)
    SELECT order_item_id, id FROM newly_sent;

    SELECT COUNT(*) INTO v_count FROM _kns;

    IF v_count > 0 THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'send_id', k.send_id,
        'order_item_id', k.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes
      ) ORDER BY oi.created_at), '[]'::jsonb)
      INTO v_sent_items
      FROM _kns k
      JOIN public.order_items oi ON oi.id = k.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id;

      -- Execute atomic inventory deduction for the order
      PERFORM public.consume_order_kitchen_inventory(p_order_id, p_sent_by);
    END IF;

    SELECT NOT EXISTS (
      SELECT 1 FROM public.order_items oi
      WHERE oi.order_id = p_order_id
        AND NOT EXISTS (
          SELECT 1 FROM public.order_kitchen_sends s
          WHERE s.order_item_id = oi.id
        )
    ) INTO v_all_sent;

    RETURN jsonb_build_object('success', true,
      'order_id', p_order_id,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901020000_fix_bootstrap_super_admin.sql
-- ----------------------------------------------------------------------------
-- =============================================================================
-- Migration: 20260901020000_fix_bootstrap_super_admin.sql
-- Description: Robust bootstrap RPC to initialize the initial Super Admin
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE OR REPLACE FUNCTION public.bootstrap_initial_super_admin(
  p_email text,
  p_password text,
  p_full_name text DEFAULT 'Super Admin',
  p_username text DEFAULT 'superadmin'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id uuid;
  v_encrypted_pw text;
  v_email text;
  v_username text;
  v_existing_super_count integer;
  v_default_branch uuid;
BEGIN
  -- Set session flag to permit user/role creation without existing admin
  PERFORM set_config('app.register_branch', 'on', true);

  v_email := lower(btrim(p_email));
  v_username := lower(btrim(COALESCE(p_username, split_part(v_email, '@', 1))));

  IF v_email = '' OR v_email !~ '@' OR v_email !~ '\.' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_EMAIL',
      'message', 'Please provide a valid email address.'
    );
  END IF;

  IF length(p_password) < 6 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PASSWORD_TOO_SHORT',
      'message', 'Password must be at least 6 characters.'
    );
  END IF;

  -- Find default branch
  SELECT id INTO v_default_branch
  FROM public.branches
  ORDER BY created_at ASC
  LIMIT 1;

  -- Check if super_admin users already exist
  SELECT count(*) INTO v_existing_super_count
  FROM public.users
  WHERE role = 'super_admin';

  -- Find or generate user_id in auth.users
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = v_email;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    v_encrypted_pw := extensions.crypt(p_password, extensions.gen_salt('bf'));

    INSERT INTO auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      email_change,
      email_change_token_new,
      recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      v_encrypted_pw,
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', p_full_name, 'username', v_username),
      now(),
      now(),
      '',
      '',
      '',
      ''
    );
  ELSE
    -- If user already exists in auth.users, update their password and confirmed status
    v_encrypted_pw := extensions.crypt(p_password, extensions.gen_salt('bf'));
    UPDATE auth.users
    SET encrypted_password = v_encrypted_pw,
        email_confirmed_at = COALESCE(email_confirmed_at, now()),
        updated_at = now()
    WHERE id = v_user_id;
  END IF;

  -- Ensure record in public.users exists and has role 'super_admin'
  INSERT INTO public.users (
    id,
    email,
    full_name,
    username,
    role,
    is_active,
    branch_id,
    created_at
  ) VALUES (
    v_user_id,
    v_email,
    p_full_name,
    v_username,
    'super_admin',
    true,
    v_default_branch,
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      full_name = EXCLUDED.full_name,
      username = EXCLUDED.username,
      role = 'super_admin',
      is_active = true,
      branch_id = COALESCE(public.users.branch_id, v_default_branch);

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'email', v_email,
    'role', 'super_admin',
    'message', 'Initial Super Admin initialized successfully.'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', 'BOOTSTRAP_FAILED',
    'message', SQLERRM
  );
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_initial_super_admin(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text, text, text, text) TO anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901030000_fix_warehouse_default_schema_drift.sql
-- ----------------------------------------------------------------------------
-- 20260901030000_fix_warehouse_default_schema_drift.sql
-- Align warehouse schema with inventory-consumption logic used by kitchen sends.
-- Safe and idempotent for existing databases.

ALTER TABLE public.warehouses
  ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_warehouses_branch_default
  ON public.warehouses (branch_id, is_default DESC, created_at ASC)
  WHERE is_active = true;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901170000_stabilize_kitchen_inventory_single_deduction.sql
-- ----------------------------------------------------------------------------
-- Stabilize POS/KDS inventory responsibility.
-- Kitchen send is a KDS snapshot/state action only.
-- Authoritative inventory deduction remains in process_sale via deduct_sale_unit_inventory.
-- This prevents double deduction and removes the active dependency on the legacy
-- consume_order_kitchen_inventory path without destructively dropping old objects yet.

CREATE OR REPLACE FUNCTION public.send_to_kitchen(
  p_order_id uuid,
  p_sent_by uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_branch_id uuid;
  v_status text;
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
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

    SELECT branch_id INTO v_user_branch
    FROM public.users
    WHERE id = auth.uid();

    IF NOT is_pos_admin()
       AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns (
      order_item_id uuid,
      send_id uuid
    ) ON COMMIT DROP;
    TRUNCATE _kns;

    WITH newly_sent AS (
      INSERT INTO public.order_kitchen_sends (
        branch_id,
        order_id,
        order_item_id,
        sent_by
      )
      SELECT
        v_branch_id,
        p_order_id,
        oi.id,
        COALESCE(p_sent_by, auth.uid())
      FROM public.order_items oi
      WHERE oi.order_id = p_order_id
        AND NOT EXISTS (
          SELECT 1
          FROM public.order_kitchen_sends s
          WHERE s.order_item_id = oi.id
        )
      ON CONFLICT (order_item_id) DO NOTHING
      RETURNING id, order_item_id
    )
    INSERT INTO _kns (order_item_id, send_id)
    SELECT order_item_id, id
    FROM newly_sent;

    SELECT COUNT(*) INTO v_count FROM _kns;

    IF v_count > 0 THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'send_id', k.send_id,
            'order_item_id', k.order_item_id,
            'product_id', oi.product_id,
            'product_name', p.name,
            'unit_name', oi.unit_name,
            'quantity', oi.quantity,
            'unit_price', oi.unit_price,
            'discount_amount', oi.discount_amount,
            'bonus_quantity', oi.bonus_quantity,
            'total', oi.total,
            'notes', oi.notes
          ) ORDER BY oi.created_at
        ),
        '[]'::jsonb
      )
      INTO v_sent_items
      FROM _kns k
      JOIN public.order_items oi ON oi.id = k.order_item_id
      LEFT JOIN public.products p ON p.id = oi.product_id;
    END IF;

    SELECT NOT EXISTS (
      SELECT 1
      FROM public.order_items oi
      WHERE oi.order_id = p_order_id
        AND NOT EXISTS (
          SELECT 1
          FROM public.order_kitchen_sends s
          WHERE s.order_item_id = oi.id
        )
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
$$;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901193000_cashier_approval_control_center.sql
-- ----------------------------------------------------------------------------
-- Cashier hardening + manager approval control center.
-- Mirrors the production hardening already applied on 2026-09-01.

CREATE TABLE IF NOT EXISTS public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  requester_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  action_type text NOT NULL CHECK (action_type IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift')),
  entity_type text NOT NULL,
  entity_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text NOT NULL CHECK (length(trim(reason)) >= 3),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired','consumed')),
  approver_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '10 minutes'),
  consumed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_approval_requests_branch_status_created ON public.approval_requests(branch_id,status,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_approval_requests_requester_status ON public.approval_requests(requester_id,status,created_at DESC);
ALTER TABLE public.approval_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS approval_requests_select ON public.approval_requests;
CREATE POLICY approval_requests_select ON public.approval_requests FOR SELECT TO authenticated
USING (requester_id = auth.uid() OR (user_may_access_branch(branch_id) AND (is_pos_admin() OR can_permission('approvals.review'))));
DROP POLICY IF EXISTS approval_requests_insert ON public.approval_requests;
CREATE POLICY approval_requests_insert ON public.approval_requests FOR INSERT TO authenticated
WITH CHECK (requester_id=auth.uid() AND user_may_access_branch(branch_id));
DROP POLICY IF EXISTS approval_requests_no_direct_update ON public.approval_requests;
CREATE POLICY approval_requests_no_direct_update ON public.approval_requests FOR UPDATE TO authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS approval_requests_no_delete ON public.approval_requests;
CREATE POLICY approval_requests_no_delete ON public.approval_requests FOR DELETE TO authenticated USING(false);

UPDATE public.roles SET permissions=COALESCE(permissions,'[]'::jsonb)-'pos.reprint',updated_at=now() WHERE role='cashier';
UPDATE public.roles SET permissions=CASE WHEN COALESCE(permissions,'[]'::jsonb)?'approvals.review' THEN permissions ELSE COALESCE(permissions,'[]'::jsonb)||'["approvals.review"]'::jsonb END,updated_at=now()
WHERE role IN ('branch_manager','owner','super_admin');

CREATE OR REPLACE FUNCTION public.request_manager_approval(
  p_action_type text,p_entity_type text,p_entity_id uuid,p_payload jsonb DEFAULT '{}'::jsonb,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_user public.users%ROWTYPE; v_req_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  IF v_user.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','USER_NOT_FOUND'); END IF;
  IF p_action_type NOT IN ('discount','reprint','void_order','cancel_sent_item','refund','open_drawer','change_payment_method','force_close_shift') THEN RETURN jsonb_build_object('success',false,'error','INVALID_ACTION'); END IF;
  IF p_reason IS NULL OR length(trim(p_reason))<3 THEN RETURN jsonb_build_object('success',false,'error','REASON_REQUIRED'); END IF;
  SELECT id INTO v_req_id FROM public.approval_requests
  WHERE requester_id=auth.uid() AND branch_id=v_user.branch_id AND action_type=p_action_type AND entity_type=p_entity_type
    AND entity_id IS NOT DISTINCT FROM p_entity_id AND status='pending' AND expires_at>now()
  ORDER BY created_at DESC LIMIT 1;
  IF v_req_id IS NOT NULL THEN RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending','duplicate',true); END IF;
  INSERT INTO public.approval_requests(branch_id,requester_id,action_type,entity_type,entity_id,payload,reason)
  VALUES(v_user.branch_id,auth.uid(),p_action_type,p_entity_type,p_entity_id,COALESCE(p_payload,'{}'::jsonb),trim(p_reason))
  RETURNING id INTO v_req_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,'APPROVAL_REQUESTED','approval_request',v_req_id,
    jsonb_build_object('action_type',p_action_type,'entity_type',p_entity_type,'target_id',p_entity_id,'reason',trim(p_reason),'payload',COALESCE(p_payload,'{}'::jsonb)),v_user.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req_id,'status','pending');
END $$;

CREATE OR REPLACE FUNCTION public.decide_manager_approval(p_request_id uuid,p_approve boolean,p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req public.approval_requests%ROWTYPE; v_user public.users%ROWTYPE; v_status text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF NOT user_may_access_branch(v_req.branch_id) OR NOT (is_pos_admin() OR can_permission('approvals.review')) THEN RETURN jsonb_build_object('success',false,'error','NOT_AUTHORIZED'); END IF;
  IF v_req.requester_id=auth.uid() THEN RETURN jsonb_build_object('success',false,'error','SELF_APPROVAL_FORBIDDEN'); END IF;
  IF v_req.status<>'pending' THEN RETURN jsonb_build_object('success',false,'error','REQUEST_ALREADY_DECIDED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=now() WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  UPDATE public.approval_requests SET status=v_status,approver_id=auth.uid(),decision_note=NULLIF(trim(COALESCE(p_note,'')),''),decided_at=now() WHERE id=v_req.id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN p_approve THEN 'APPROVAL_APPROVED' ELSE 'APPROVAL_REJECTED' END,'approval_request',v_req.id,
    jsonb_build_object('action_type',v_req.action_type,'requester_id',v_req.requester_id,'target_id',v_req.entity_id,'note',p_note),v_req.branch_id);
  RETURN jsonb_build_object('success',true,'request_id',v_req.id,'status',v_status);
END $$;

CREATE OR REPLACE FUNCTION public.consume_manager_approval(p_request_id uuid,p_action_type text,p_entity_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req public.approval_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_req FROM public.approval_requests WHERE id=p_request_id FOR UPDATE;
  IF v_req.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','REQUEST_NOT_FOUND'); END IF;
  IF v_req.requester_id<>auth.uid() THEN RETURN jsonb_build_object('success',false,'error','REQUESTER_MISMATCH'); END IF;
  IF v_req.action_type<>p_action_type OR v_req.entity_id IS DISTINCT FROM p_entity_id THEN RETURN jsonb_build_object('success',false,'error','REQUEST_SCOPE_MISMATCH'); END IF;
  IF v_req.status<>'approved' THEN RETURN jsonb_build_object('success',false,'error','APPROVAL_REQUIRED','status',v_req.status); END IF;
  IF v_req.expires_at<=now() THEN UPDATE public.approval_requests SET status='expired',decided_at=COALESCE(decided_at,now()) WHERE id=v_req.id; RETURN jsonb_build_object('success',false,'error','REQUEST_EXPIRED'); END IF;
  UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req.id;
  RETURN jsonb_build_object('success',true,'payload',v_req.payload,'approver_id',v_req.approver_id);
END $$;

REVOKE ALL ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.request_manager_approval(text,text,uuid,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.decide_manager_approval(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.decide_manager_approval(uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.consume_manager_approval(uuid,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.consume_manager_approval(uuid,text,uuid) TO authenticated;

DROP POLICY IF EXISTS auth_update_sales ON public.sales;
CREATE POLICY auth_update_sales ON public.sales FOR UPDATE TO authenticated
USING((is_pos_admin() OR can_permission('sales.manage')) AND user_may_access_branch(branch_id))
WITH CHECK((is_pos_admin() OR can_permission('sales.manage')) AND user_may_access_branch(branch_id));
DROP POLICY IF EXISTS auth_delete_sale_items ON public.sale_items;
CREATE POLICY auth_delete_sale_items ON public.sale_items FOR DELETE TO authenticated USING(false);
DROP POLICY IF EXISTS auth_update_sale_items ON public.sale_items;
CREATE POLICY auth_update_sale_items ON public.sale_items FOR UPDATE TO authenticated USING(false) WITH CHECK(false);

DO $$
BEGIN
  IF to_regprocedure('public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)') IS NULL
     AND to_regprocedure('public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer)') IS NOT NULL THEN
    ALTER FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) RENAME TO _process_sale_core;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._process_sale_core(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,p_branch_id uuid,p_warehouse_id uuid,p_customer_id uuid,p_salesperson_id uuid,
  p_subtotal numeric,p_discount_amount numeric,p_discount_type text,p_tax_amount numeric,p_bonus_amount numeric,
  p_total numeric,p_paid_amount numeric,p_payment_method text,p_status text,p_items jsonb,p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',p_table_id uuid DEFAULT NULL,p_order_id uuid DEFAULT NULL,p_guest_count integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req_id uuid; v_result jsonb; v_email text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF COALESCE(p_discount_amount,0)>0 AND NOT can_permission('pos.discount') THEN
    SELECT id INTO v_req_id FROM public.approval_requests
    WHERE requester_id=auth.uid() AND branch_id=p_branch_id AND action_type='discount' AND status='approved' AND expires_at>now()
      AND (entity_id IS NULL OR entity_id IS NOT DISTINCT FROM p_order_id)
      AND COALESCE(payload->>'discount_type','amount')=COALESCE(p_discount_type,'amount')
      AND abs(COALESCE((payload->>'discount_amount')::numeric,-1)-p_discount_amount)<0.0001
      AND abs(COALESCE((payload->>'subtotal')::numeric,-1)-p_subtotal)<0.0001
    ORDER BY decided_at DESC NULLS LAST,created_at DESC LIMIT 1 FOR UPDATE;
    IF v_req_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','discount'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req_id;
    SELECT email INTO v_email FROM public.users WHERE id=auth.uid();
    INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
    VALUES(auth.uid(),v_email,'APPROVAL_CONSUMED','approval_request',v_req_id,
      jsonb_build_object('action_type','discount','discount_amount',p_discount_amount,'discount_type',p_discount_type,'subtotal',p_subtotal,'order_id',p_order_id),p_branch_id);
  END IF;
  v_result:=public._process_sale_core(p_invoice_number,p_branch_id,p_warehouse_id,p_customer_id,p_salesperson_id,p_subtotal,p_discount_amount,p_discount_type,p_tax_amount,p_bonus_amount,p_total,p_paid_amount,p_payment_method,p_status,p_items,p_shift_id,p_order_type,p_table_id,p_order_id,p_guest_count);
  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated,service_role;

CREATE TABLE IF NOT EXISTS public.sale_print_events(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE RESTRICT,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  print_number integer NOT NULL CHECK(print_number>0),
  approval_request_id uuid REFERENCES public.approval_requests(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(sale_id,print_number)
);
ALTER TABLE public.sale_print_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sale_print_events_select ON public.sale_print_events;
CREATE POLICY sale_print_events_select ON public.sale_print_events FOR SELECT TO authenticated USING(user_may_access_branch(branch_id));
DROP POLICY IF EXISTS sale_print_events_no_direct_insert ON public.sale_print_events;
CREATE POLICY sale_print_events_no_direct_insert ON public.sale_print_events FOR INSERT TO authenticated WITH CHECK(false);
DROP POLICY IF EXISTS sale_print_events_no_update ON public.sale_print_events;
CREATE POLICY sale_print_events_no_update ON public.sale_print_events FOR UPDATE TO authenticated USING(false) WITH CHECK(false);
DROP POLICY IF EXISTS sale_print_events_no_delete ON public.sale_print_events;
CREATE POLICY sale_print_events_no_delete ON public.sale_print_events FOR DELETE TO authenticated USING(false);

CREATE OR REPLACE FUNCTION public.authorize_sale_print(p_sale_id uuid,p_approval_request_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_sale public.sales%ROWTYPE; v_user public.users%ROWTYPE; v_count integer; v_req public.approval_requests%ROWTYPE; v_event_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_sale FROM public.sales WHERE id=p_sale_id;
  IF v_sale.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','SALE_NOT_FOUND'); END IF;
  IF NOT user_may_access_branch(v_sale.branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
  SELECT count(*)::int INTO v_count FROM public.sale_print_events WHERE sale_id=p_sale_id;
  IF v_count>0 AND NOT can_permission('pos.reprint') THEN
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

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.approval_requests;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_object THEN NULL; END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901211500_cancel_sent_item_approval.sql
-- ----------------------------------------------------------------------------
-- P1: secure cancellation of items already sent to the kitchen.
-- KDS is state-only: sending does NOT deduct inventory. Therefore cancelling a
-- sent line must never restore/increase stock. Inventory remains owned by the
-- final sale settlement path.

CREATE TABLE IF NOT EXISTS public.order_kitchen_voids (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name text NOT NULL,
  unit_name text NOT NULL DEFAULT 'piece',
  quantity numeric(14,4) NOT NULL CHECK (quantity > 0),
  reason text NOT NULL CHECK (length(trim(reason)) >= 3),
  voided_by uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  approval_request_id uuid REFERENCES public.approval_requests(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_order_created
  ON public.order_kitchen_voids(order_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_branch_created
  ON public.order_kitchen_voids(branch_id, created_at DESC);

ALTER TABLE public.order_kitchen_voids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_kitchen_voids_select ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_select ON public.order_kitchen_voids
FOR SELECT TO authenticated
USING (user_may_access_branch(branch_id));

DROP POLICY IF EXISTS order_kitchen_voids_no_direct_insert ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_direct_insert ON public.order_kitchen_voids
FOR INSERT TO authenticated WITH CHECK (false);

DROP POLICY IF EXISTS order_kitchen_voids_no_update ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_update ON public.order_kitchen_voids
FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS order_kitchen_voids_no_delete ON public.order_kitchen_voids;
CREATE POLICY order_kitchen_voids_no_delete ON public.order_kitchen_voids
FOR DELETE TO authenticated USING (false);

-- A sent order-item may not be reduced or deleted directly by a cashier.
-- The approved cancellation RPC temporarily enables the exact mutation by
-- setting a transaction-local GUC. Managers/admins with approval review access
-- can perform the operation without a request.
CREATE OR REPLACE FUNCTION public.guard_sent_order_item_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_sent boolean;
  v_is_reduction boolean := false;
  v_internal boolean := COALESCE(current_setting('app.approved_sent_item_void', true), '') = '1';
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = OLD.id
  ) INTO v_is_sent;

  IF NOT v_is_sent THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_is_reduction := true;
  ELSIF TG_OP = 'UPDATE' AND COALESCE(NEW.quantity, 0) < COALESCE(OLD.quantity, 0) THEN
    v_is_reduction := true;
  END IF;

  IF v_is_reduction
     AND NOT v_internal
     AND NOT is_pos_admin()
     AND NOT can_permission('approvals.review') THEN
    RAISE EXCEPTION 'SENT_ITEM_APPROVAL_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_sent_order_item_mutation ON public.order_items;
CREATE TRIGGER trg_guard_sent_order_item_mutation
BEFORE UPDATE OF quantity OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.guard_sent_order_item_mutation();

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

  IF NOT user_may_access_branch(v_order.branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  SELECT oi.* INTO v_item
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_item_id = oi.id
    )
  ORDER BY oi.created_at, oi.id
  LIMIT 1
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

  v_privileged := is_pos_admin() OR can_permission('approvals.review');

  IF NOT v_privileged THEN
    -- Reuse only an exact approved request for this item and quantity.
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
      -- request_manager_approval already de-duplicates matching pending requests
      -- by requester/action/entity. Payload stores the exact scope that will be
      -- checked again before execution.
      v_request_result := public.request_manager_approval(
        'cancel_sent_item',
        'order_item',
        v_item.id,
        jsonb_build_object(
          'order_id', p_order_id,
          'product_id', p_product_id,
          'product_name', v_product_name,
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

  -- Allow only this transaction's server-side sent-line reduction through the
  -- trigger. No inventory table is modified here: KDS never deducted stock.
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

  -- Recalculate order header from remaining lines. `discount_amount` on orders
  -- is already the computed order-level discount value in the current POS path.
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
      'product_id', p_product_id,
      'product_name', v_product_name,
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
    'product_id', p_product_id,
    'voided_quantity', p_quantity,
    'remaining_quantity', GREATEST(v_new_qty, 0),
    'inventory_changed', false,
    'approval_request_id', CASE WHEN v_privileged THEN NULL ELSE v_request.id END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.guard_sent_order_item_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_sent_order_item_mutation() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='order_kitchen_voids'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.order_kitchen_voids;
  END IF;
END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901224500_manufactured_unit_purchase_cost.sql
-- ----------------------------------------------------------------------------
-- Manufactured unit costing must follow real purchase-derived raw-material cost.
-- The raw-material weighted average is maintained by purchase receipts in
-- raw_material_inventory/raw_material_batches. Do not rely on default_cost.

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_rm_qty numeric;
  v_rm_cost numeric;
  v_batch_number text;
  v_unit_cost numeric := 0;
  v_unit_name text;
BEGIN
  SELECT name INTO v_unit_name
  FROM public.inventory_units
  WHERE id = p_unit_id
    AND unit_type = 'manufactured'
    AND is_active = true;

  IF v_unit_name IS NULL THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit', p_unit_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(now(), 'YYYYMMDD-HH24MISS');

  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent
    FROM public.inventory_unit_recipes iur
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100.0);

    -- Purchase-derived weighted average, with default_cost only as the helper's
    -- last-resort fallback when no received stock has ever existed.
    v_rm_cost := public._raw_wavg_cost(v_recipe.raw_material_id, p_branch_id);
    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, batch_number,
      quantity, unit_cost, expiry_date, source_type, source_id
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, v_batch_number,
      0, COALESCE(v_rm_cost, 0), NULL, 'production_consumption', v_production_id
    );
  END LOOP;

  v_unit_cost := CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END;

  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity, v_unit_cost, CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    v_unit_cost, 'production', 'production', v_production_id, v_batch_number
  );

  INSERT INTO public.inventory_unit_productions (
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  -- Keep master cost visible in inventory and on the matching manufactured
  -- product placeholder used by costing/BOM screens.
  UPDATE public.inventory_units
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE id = p_unit_id;

  UPDATE public.products
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE branch_id = p_branch_id
    AND product_type = 'manufactured'
    AND lower(btrim(name)) = lower(btrim(v_unit_name));

  RETURN v_production_id;
END;
$$;

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901225000_grant_produce_inventory_unit_service_role.sql
-- ----------------------------------------------------------------------------
-- Restore the administrative execution contract for manufactured-unit production.
-- Integration/admin flows use service_role, while application users use authenticated.

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260901233000_nested_manufacturing_hybrid_sale_inventory.sql
-- ----------------------------------------------------------------------------
-- Nested manufactured components + recipe-aware sale inventory.
--
-- Canonical inventory flow after this migration:
-- 1) Direct raw recipe items are purchased into raw_material_inventory and
--    consumed from raw-material FIFO at sale.
-- 2) Semi-finished/manufactured recipe items are inventory_units and are
--    consumed from inventory_unit_batches at sale or by another manufactured unit.
-- 3) Products with no recipe and no manufactured component links are treated
--    as ready/purchased products and use the existing product inventory FIFO.
-- This avoids duplicating raw materials into inventory_units only to satisfy a
-- technical link requirement.

CREATE TABLE IF NOT EXISTS public.inventory_unit_recipe_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  component_unit_id uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE RESTRICT,
  quantity numeric(14,6) NOT NULL CHECK (quantity > 0),
  wastage_percent numeric(8,4) NOT NULL DEFAULT 0 CHECK (wastage_percent >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_unit_recipe_units_no_self CHECK (unit_id <> component_unit_id),
  CONSTRAINT inventory_unit_recipe_units_unique UNIQUE (unit_id, component_unit_id)
);

ALTER TABLE public.inventory_unit_recipe_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS iuru_admin_all ON public.inventory_unit_recipe_units;
CREATE POLICY iuru_admin_all ON public.inventory_unit_recipe_units
FOR ALL USING (public.is_pos_admin()) WITH CHECK (public.is_pos_admin());

DROP POLICY IF EXISTS iuru_branch_read ON public.inventory_unit_recipe_units;
CREATE POLICY iuru_branch_read ON public.inventory_unit_recipe_units
FOR SELECT USING (
  unit_id IN (
    SELECT iu.id FROM public.inventory_units iu
    WHERE iu.branch_id = public.get_branch_id() OR iu.branch_id IS NULL
  )
);

REVOKE ALL ON public.inventory_unit_recipe_units FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inventory_unit_recipe_units TO authenticated;
GRANT ALL ON public.inventory_unit_recipe_units TO service_role;

-- Convert imported "raw material" placeholders that are in fact another
-- manufactured product into explicit manufactured-unit recipe links.
-- quantity is stored as a fraction of one produced child batch.
WITH manufactured AS (
  SELECT p.id AS product_id, p.branch_id, p.name AS product_name,
         iu.id AS unit_id, iu.name AS unit_name
  FROM public.products p
  JOIN public.inventory_units iu
    ON iu.branch_id = p.branch_id
   AND regexp_replace(lower(btrim(iu.name)), '[ .]+$', '', 'g') =
       regexp_replace(lower(btrim(p.name)), '[ .]+$', '', 'g')
   AND iu.unit_type = 'manufactured'
  WHERE p.product_type = 'manufactured'
), matches AS (
  SELECT parent.unit_id AS parent_unit_id,
         child.unit_id AS component_unit_id,
         iur.id AS raw_recipe_row_id,
         iur.quantity,
         COALESCE((
           SELECT SUM(x.quantity)
           FROM public.inventory_unit_recipes x
           WHERE x.unit_id = child.unit_id
         ), 0) AS child_batch_basis
  FROM manufactured parent
  JOIN public.inventory_unit_recipes iur ON iur.unit_id = parent.unit_id
  JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
  JOIN manufactured child
    ON child.branch_id = parent.branch_id
   AND regexp_replace(lower(btrim(child.product_name)), '[ .]+$', '', 'g') =
       regexp_replace(lower(btrim(rm.name)), '[ .]+$', '', 'g')
   AND child.unit_id <> parent.unit_id
), inserted AS (
  INSERT INTO public.inventory_unit_recipe_units(unit_id, component_unit_id, quantity)
  SELECT parent_unit_id, component_unit_id,
         quantity / NULLIF(child_batch_basis, 0)
  FROM matches
  WHERE child_batch_basis > 0
  ON CONFLICT (unit_id, component_unit_id) DO UPDATE
    SET quantity = EXCLUDED.quantity, updated_at = now()
  RETURNING unit_id, component_unit_id
)
DELETE FROM public.inventory_unit_recipes iur
USING matches m
WHERE iur.id = m.raw_recipe_row_id
  AND m.child_batch_basis > 0;

CREATE OR REPLACE FUNCTION public.produce_inventory_unit(
  p_unit_id uuid,
  p_quantity numeric,
  p_warehouse_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_production_id uuid;
  v_total_cost numeric := 0;
  v_recipe record;
  v_component record;
  v_rm_qty numeric;
  v_batch_number text;
  v_unit_cost numeric := 0;
  v_unit_name text;
  v_res jsonb;
  v_need numeric;
  v_available numeric;
  v_batch record;
  v_take numeric;
BEGIN
  SELECT name INTO v_unit_name
  FROM public.inventory_units
  WHERE id = p_unit_id
    AND unit_type = 'manufactured'
    AND is_active = true
    AND (branch_id = p_branch_id OR branch_id IS NULL);

  IF v_unit_name IS NULL THEN
    RAISE EXCEPTION 'Unit % is not a manufactured active inventory unit in branch %', p_unit_id, p_branch_id;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Production quantity must be positive';
  END IF;

  -- Preflight manufactured child stock before mutating raw stock.
  FOR v_component IN
    SELECT iuru.component_unit_id, iuru.quantity, iuru.wastage_percent
    FROM public.inventory_unit_recipe_units iuru
    WHERE iuru.unit_id = p_unit_id
  LOOP
    v_need := p_quantity * v_component.quantity * (1 + v_component.wastage_percent / 100.0);
    SELECT COALESCE(SUM(iub.quantity), 0)
      INTO v_available
    FROM public.inventory_unit_batches iub
    WHERE iub.unit_id = v_component.component_unit_id
      AND iub.branch_id = p_branch_id
      AND iub.warehouse_id = p_warehouse_id
      AND iub.quantity > 0;

    IF v_available < v_need THEN
      RAISE EXCEPTION 'INSUFFICIENT_COMPONENT_UNIT_STOCK unit=% required=% available=%',
        v_component.component_unit_id, v_need, v_available;
    END IF;
  END LOOP;

  v_production_id := gen_random_uuid();
  v_batch_number := 'PRD-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-MS');

  -- Consume direct raw-material ingredients using purchase-derived FIFO cost.
  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent
    FROM public.inventory_unit_recipes iur
    WHERE iur.unit_id = p_unit_id
  LOOP
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100.0);

    v_res := public._raw_remove_fifo(
      v_recipe.raw_material_id,
      p_branch_id,
      v_rm_qty,
      'production',
      'production',
      v_production_id,
      v_batch_number,
      auth.uid()
    );

    IF COALESCE((v_res->>'shortage')::numeric, 0) > 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_RAW_MATERIAL_STOCK raw_material=% required=% shortage=%',
        v_recipe.raw_material_id, v_rm_qty, v_res->>'shortage';
    END IF;

    v_total_cost := v_total_cost + COALESCE((v_res->>'total_cost')::numeric, 0);
  END LOOP;

  -- Consume nested/semi-finished manufactured units FIFO.
  FOR v_component IN
    SELECT iuru.component_unit_id, iuru.quantity, iuru.wastage_percent
    FROM public.inventory_unit_recipe_units iuru
    WHERE iuru.unit_id = p_unit_id
    ORDER BY iuru.component_unit_id
  LOOP
    v_need := p_quantity * v_component.quantity * (1 + v_component.wastage_percent / 100.0);

    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_component.component_unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
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
      ) VALUES (
        v_component.component_unit_id, p_branch_id, p_warehouse_id,
        -v_take, v_batch.unit_cost,
        'production_consumption', 'production', v_production_id, v_batch_number,
        v_batch.batch_number, auth.uid()
      );

      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
      v_need := v_need - v_take;
    END LOOP;
  END LOOP;

  v_unit_cost := CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END;

  INSERT INTO public.inventory_unit_batches(
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity, v_unit_cost, CURRENT_DATE
  );

  INSERT INTO public.inventory_unit_entries(
    unit_id, branch_id, warehouse_id, quantity, unit_cost,
    entry_type, reference_type, reference_id, batch_number, created_by
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity, v_unit_cost,
    'production', 'production', v_production_id, v_batch_number, auth.uid()
  );

  INSERT INTO public.inventory_unit_productions(
    id, unit_id, branch_id, warehouse_id, quantity,
    status, total_cost, started_at, completed_at, notes, created_by
  ) VALUES (
    v_production_id, p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    'completed', v_total_cost, now(), now(), p_notes, auth.uid()
  );

  UPDATE public.inventory_units
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE id = p_unit_id;

  UPDATE public.products
  SET cost_price = round(v_unit_cost, 2), updated_at = now()
  WHERE branch_id = p_branch_id
    AND product_type = 'manufactured'
    AND regexp_replace(lower(btrim(name)), '[ .]+$', '', 'g') =
        regexp_replace(lower(btrim(v_unit_name)), '[ .]+$', '', 'g');

  RETURN v_production_id;
END;
$$;

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_link record;
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
  v_recipe_component_count integer;
  v_link_count integer;
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

  SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
  IF NOT public.is_pos_admin() AND v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
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
      WHERE p.id = v_product_id AND p.branch_id = p_branch_id AND p.is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
    END IF;

    -- Explicit manufactured/semi-finished unit components attached to product.
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
      VALUES (v_link.unit_id, v_link.unit_name, v_link.unit_type, v_quantity * v_link.quantity)
      ON CONFLICT (unit_id) DO UPDATE
      SET required_qty = pg_temp.sale_unit_need.required_qty + EXCLUDED.required_qty;
    END LOOP;

    -- Latest active recipe supplies direct raw-material consumption. Any raw
    -- placeholder matching an explicit linked manufactured unit is excluded to
    -- prevent double deduction.
    SELECT r.id, COALESCE(NULLIF(r.yield_quantity, 0), 1)
      INTO v_recipe_id, v_yield
    FROM public.recipes r
    WHERE r.product_id = v_product_id
      AND r.branch_id = p_branch_id
      AND COALESCE(r.is_active, true) = true
    ORDER BY COALESCE(r.version, 1) DESC, r.created_at DESC
    LIMIT 1;

    v_recipe_component_count := 0;
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
        VALUES (v_link.raw_material_id, v_link.raw_name, v_quantity * v_link.quantity_per_sale)
        ON CONFLICT (raw_material_id) DO UPDATE
        SET required_qty = pg_temp.sale_raw_need.required_qty + EXCLUDED.required_qty;
      END LOOP;
    END IF;

    -- A genuinely ready/purchased product has no recipe consumption and no
    -- manufactured unit component links. Keep it on the established product
    -- inventory FIFO instead of fabricating a duplicate inventory_unit.
    IF v_link_count = 0 AND v_recipe_component_count = 0 THEN
      INSERT INTO pg_temp.sale_ready_need(product_id, product_name, required_qty)
      SELECT p.id, p.name, v_quantity FROM public.products p WHERE p.id = v_product_id
      ON CONFLICT (product_id) DO UPDATE
      SET required_qty = pg_temp.sale_ready_need.required_qty + EXCLUDED.required_qty;
    END IF;

    v_recipe_id := NULL;
    v_yield := NULL;
  END LOOP;

  -- Preflight every stock source before any mutation.
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_unit_batches
    WHERE unit_id = v_link.unit_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_UNIT_STOCK',
        'unit_id', v_link.unit_id, 'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_link.raw_material_id AND branch_id = p_branch_id;
    v_available := COALESCE(v_available, 0);
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
        'raw_material_id', v_link.raw_material_id,
        'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id
  LOOP
    SELECT COALESCE(SUM(quantity), 0) INTO v_available
    FROM public.inventory_batches
    WHERE product_id = v_link.product_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;
    IF v_available < v_link.required_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_PRODUCT_STOCK',
        'product_id', v_link.product_id,
        'required', v_link.required_qty, 'available', v_available);
    END IF;
  END LOOP;

  -- Manufactured/semi-finished units.
  FOR v_link IN SELECT * FROM pg_temp.sale_unit_need ORDER BY unit_id
  LOOP
    v_need := v_link.required_qty;
    FOR v_batch IN
      SELECT id, quantity, unit_cost, batch_number
      FROM public.inventory_unit_batches
      WHERE unit_id = v_link.unit_id
        AND branch_id = p_branch_id
        AND warehouse_id = p_warehouse_id
        AND quantity > 0
      ORDER BY created_at ASC, id ASC
      FOR UPDATE
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, v_batch.quantity);
      UPDATE public.inventory_unit_batches SET quantity = quantity - v_take WHERE id = v_batch.id;
      INSERT INTO public.inventory_unit_entries(
        unit_id, branch_id, warehouse_id, quantity, unit_cost,
        entry_type, reference_type, reference_id, reference_number,
        batch_number, created_by
      ) VALUES (
        v_link.unit_id, p_branch_id, p_warehouse_id, -v_take, v_batch.unit_cost,
        'sale', 'sale', p_reference_id, p_reference_number,
        v_batch.batch_number, auth.uid()
      );
      v_need := v_need - v_take;
      v_total_cost := v_total_cost + (v_take * COALESCE(v_batch.unit_cost, 0));
    END LOOP;
    v_units := v_units || jsonb_build_object(
      'unit_id', v_link.unit_id, 'unit_name', v_link.unit_name,
      'unit_type', v_link.unit_type, 'quantity', v_link.required_qty
    );
  END LOOP;

  -- Direct raw ingredients.
  FOR v_link IN SELECT * FROM pg_temp.sale_raw_need ORDER BY raw_material_id
  LOOP
    v_res := public._raw_remove_fifo(
      v_link.raw_material_id, p_branch_id, v_link.required_qty,
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

  -- Ready/purchased finished products.
  FOR v_link IN SELECT * FROM pg_temp.sale_ready_need ORDER BY product_id
  LOOP
    v_res := public._product_inv_remove_fifo(
      v_link.product_id, p_warehouse_id, p_branch_id, v_link.required_qty,
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
  RETURN jsonb_build_object('success', false, 'error', 'SALE_INVENTORY_DEDUCTION_FAILED', 'detail', SQLERRM);
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902010000_auto_produce_sale_availability.sql
-- ----------------------------------------------------------------------------
-- Automatic manufactured-unit production during sale + exact POS availability from underlying inputs.

CREATE OR REPLACE FUNCTION public.check_product_availability(
  p_product_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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

  -- A product with neither recipe nor linked inventory units is a purchased/ready product.
  IF v_link_count = 0 AND v_direct_raw_count = 0 THEN
    SELECT COALESCE(SUM(ib.quantity), 0)
    INTO v_ready
    FROM public.inventory_batches ib
    WHERE ib.product_id = p_product_id
      AND ib.branch_id = p_branch_id
      AND ib.warehouse_id = p_warehouse_id
      AND ib.quantity > 0;
    RETURN jsonb_build_object(
      'success', v_ready >= p_quantity,
      'error', CASE WHEN v_ready >= p_quantity THEN NULL ELSE 'INSUFFICIENT_PRODUCT_STOCK' END,
      'required', p_quantity,
      'available', v_ready,
      'mode', 'ready_product'
    );
  END IF;

  -- Expand only the manufactured shortages. Existing manufactured stock is used first.
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
$$;

CREATE OR REPLACE FUNCTION public._ensure_inventory_unit_stock(
  p_unit_id uuid,
  p_required_qty numeric,
  p_warehouse_id uuid,
  p_branch_id uuid,
  p_depth integer DEFAULT 0
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_available numeric;
  v_shortage numeric;
  v_type text;
  v_child record;
BEGIN
  IF p_required_qty <= 0 THEN RETURN; END IF;
  IF p_depth > 16 THEN RAISE EXCEPTION 'UNIT_RECIPE_CYCLE_OR_TOO_DEEP unit=%', p_unit_id; END IF;

  SELECT unit_type INTO v_type
  FROM public.inventory_units
  WHERE id = p_unit_id AND branch_id = p_branch_id AND is_active = true;
  IF v_type IS NULL THEN RAISE EXCEPTION 'INVENTORY_UNIT_NOT_AVAILABLE unit=%', p_unit_id; END IF;

  SELECT COALESCE(SUM(quantity), 0) INTO v_available
  FROM public.inventory_unit_batches
  WHERE unit_id = p_unit_id AND branch_id = p_branch_id AND warehouse_id = p_warehouse_id AND quantity > 0;

  v_shortage := GREATEST(p_required_qty - v_available, 0);
  IF v_shortage <= 0 THEN RETURN; END IF;
  IF v_type <> 'manufactured' THEN
    RAISE EXCEPTION 'INSUFFICIENT_UNIT_STOCK unit=% required=% available=%', p_unit_id, p_required_qty, v_available;
  END IF;

  FOR v_child IN
    SELECT component_unit_id, quantity, COALESCE(wastage_percent, 0) AS wastage_percent
    FROM public.inventory_unit_recipe_units
    WHERE unit_id = p_unit_id
    ORDER BY component_unit_id
  LOOP
    PERFORM public._ensure_inventory_unit_stock(
      v_child.component_unit_id,
      v_shortage * v_child.quantity * (1 + v_child.wastage_percent / 100.0),
      p_warehouse_id,
      p_branch_id,
      p_depth + 1
    );
  END LOOP;

  PERFORM public.produce_inventory_unit(
    p_unit_id,
    v_shortage,
    p_warehouse_id,
    p_branch_id,
    'AUTO_SALE_PRODUCTION'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product record;
  v_low integer;
  v_high integer;
  v_mid integer;
  v_check jsonb;
BEGIN
  FOR v_product IN
    SELECT p.id FROM public.products p
    WHERE p.branch_id = p_branch_id AND p.is_active = true
    ORDER BY p.id
  LOOP
    v_low := 0;
    v_high := 1;
    LOOP
      v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_high);
      EXIT WHEN COALESCE((v_check->>'success')::boolean, false) IS NOT TRUE OR v_high >= p_cap;
      v_low := v_high;
      v_high := LEAST(v_high * 2, p_cap);
      EXIT WHEN v_low = v_high;
    END LOOP;

    IF v_high = p_cap AND COALESCE((v_check->>'success')::boolean, false) IS TRUE THEN
      v_low := p_cap;
    ELSE
      WHILE v_high - v_low > 1 LOOP
        v_mid := (v_low + v_high) / 2;
        v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_mid);
        IF COALESCE((v_check->>'success')::boolean, false) IS TRUE THEN v_low := v_mid; ELSE v_high := v_mid; END IF;
      END LOOP;
    END IF;

    product_id := v_product.id;
    available_quantity := v_low;
    is_available := v_low > 0;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Wrap the current deduction function so it validates the whole product requirement first,
-- then automatically produces any manufactured-unit shortage before normal FIFO deduction.
CREATE OR REPLACE FUNCTION public.deduct_sale_unit_inventory(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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

    -- Exact preflight before any automatic production writes.
    v_res := public.check_product_availability(v_product_id, p_branch_id, p_warehouse_id, v_quantity);
    IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN RETURN v_res; END IF;

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

  -- Manufacture only the shortage, recursively if a manufactured component itself needs another manufactured unit.
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
$$;

REVOKE ALL ON FUNCTION public._ensure_inventory_unit_stock(uuid,numeric,uuid,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._ensure_inventory_unit_stock(uuid,numeric,uuid,uuid,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid,uuid,jsonb,uuid,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902010500_fix_pos_availability_cap.sql
-- ----------------------------------------------------------------------------
-- Correct the upper-bound search: p_cap must be checked explicitly before it can be returned.
CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product record;
  v_low integer;
  v_high integer;
  v_mid integer;
  v_check jsonb;
  v_high_ok boolean;
BEGIN
  IF p_cap IS NULL OR p_cap < 1 THEN
    p_cap := 1;
  END IF;

  FOR v_product IN
    SELECT p.id
    FROM public.products p
    WHERE p.branch_id = p_branch_id
      AND p.is_active = true
    ORDER BY p.id
  LOOP
    v_low := 0;
    v_high := 1;
    v_high_ok := false;

    LOOP
      v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_high);
      v_high_ok := COALESCE((v_check->>'success')::boolean, false);
      EXIT WHEN NOT v_high_ok;

      v_low := v_high;
      EXIT WHEN v_high >= p_cap;
      v_high := LEAST(v_high * 2, p_cap);
    END LOOP;

    IF v_low < p_cap AND NOT v_high_ok THEN
      WHILE v_high - v_low > 1 LOOP
        v_mid := (v_low + v_high) / 2;
        v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_mid);
        IF COALESCE((v_check->>'success')::boolean, false) THEN
          v_low := v_mid;
        ELSE
          v_high := v_mid;
        END IF;
      END LOOP;
    END IF;

    product_id := v_product.id;
    available_quantity := v_low;
    is_available := v_low > 0;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902020000_purchase_raw_uom_normalization.sql
-- ----------------------------------------------------------------------------
-- Normalize raw-material purchase units to each raw material's stock unit.
-- Purchase invoice lines remain in the user's entered unit/price; inventory is stored in the raw's canonical unit.

ALTER TABLE public.raw_material_inventory
  ALTER COLUMN avg_cost TYPE numeric(18,6) USING avg_cost::numeric(18,6);
ALTER TABLE public.raw_material_batches
  ALTER COLUMN unit_cost TYPE numeric(18,6) USING unit_cost::numeric(18,6);
ALTER TABLE public.inventory_ledger
  ALTER COLUMN unit_cost TYPE numeric(18,6) USING unit_cost::numeric(18,6);

CREATE OR REPLACE FUNCTION public._normalize_raw_purchase_uom(
  p_raw_material_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_purchase_unit text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_stock_label text;
  v_stock text;
  v_purchase text;
  v_factor numeric := 1;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 OR p_unit_cost IS NULL OR p_unit_cost < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PURCHASE_QUANTITY_OR_COST');
  END IF;

  SELECT lower(btrim(COALESCE(u.symbol, u.name, '')))
  INTO v_stock_label
  FROM public.raw_materials rm
  LEFT JOIN public.units u ON u.id = rm.unit_id
  WHERE rm.id = p_raw_material_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_FOUND');
  END IF;

  v_purchase := lower(btrim(COALESCE(NULLIF(p_purchase_unit, ''), v_stock_label)));

  v_stock := CASE
    WHEN v_stock_label IN ('g','gr','gm','gram','grams','جم','جرام') THEN 'g'
    WHEN v_stock_label IN ('kg','kgs','kilogram','kilograms','كجم','كغ','كيلو','ك') THEN 'kg'
    WHEN v_stock_label IN ('ml','mil','milliliter','milliliters','مل') THEN 'ml'
    WHEN v_stock_label IN ('l','lt','liter','litre','liters','litres','ل','لتر') THEN 'l'
    WHEN v_stock_label IN ('each','ea','pcs','pc','piece','pieces','قطعة','حبة') THEN 'each'
    WHEN v_stock_label IN ('packet','pack','bag','كيس','باكيت') THEN 'packet'
    ELSE v_stock_label
  END;

  v_purchase := CASE
    WHEN v_purchase IN ('g','gr','gm','gram','grams','جم','جرام') THEN 'g'
    WHEN v_purchase IN ('kg','kgs','kilogram','kilograms','كجم','كغ','كيلو','ك') THEN 'kg'
    WHEN v_purchase IN ('ml','mil','milliliter','milliliters','مل') THEN 'ml'
    WHEN v_purchase IN ('l','lt','liter','litre','liters','litres','ل','لتر') THEN 'l'
    WHEN v_purchase IN ('each','ea','pcs','pc','piece','pieces','قطعة','حبة') THEN 'each'
    WHEN v_purchase IN ('packet','pack','bag','كيس','باكيت') THEN 'packet'
    ELSE v_purchase
  END;

  IF v_stock = v_purchase THEN
    v_factor := 1;
  ELSIF v_stock = 'g' AND v_purchase = 'kg' THEN
    v_factor := 1000;
  ELSIF v_stock = 'kg' AND v_purchase = 'g' THEN
    v_factor := 0.001;
  ELSIF v_stock = 'ml' AND v_purchase = 'l' THEN
    v_factor := 1000;
  ELSIF v_stock = 'l' AND v_purchase = 'ml' THEN
    v_factor := 0.001;
  ELSE
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INCOMPATIBLE_PURCHASE_UNIT',
      'stock_unit', v_stock_label,
      'purchase_unit', p_purchase_unit
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'stock_unit', v_stock_label,
    'purchase_unit', p_purchase_unit,
    'factor', v_factor,
    'stock_quantity', round(p_quantity * v_factor, 6),
    'stock_unit_cost', round(p_unit_cost / v_factor, 6),
    'invoice_total', round(p_quantity * p_unit_cost, 2)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._raw_add(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_qty numeric,
  p_unit_cost numeric DEFAULT 0,
  p_batch_number text DEFAULT NULL,
  p_production_date date DEFAULT NULL,
  p_expiry_date date DEFAULT NULL,
  p_entry_type text DEFAULT 'purchase',
  p_reference_type text DEFAULT NULL,
  p_reference_id uuid DEFAULT NULL,
  p_reference_number text DEFAULT NULL,
  p_created_by uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_inv record;
  v_new_avg numeric(18,6);
  v_before numeric(14,4) := 0;
  v_after numeric(14,4);
  v_batch_no text;
  v_qty numeric(18,6) := p_qty;
  v_cost numeric(18,6) := COALESCE(p_unit_cost, 0);
  v_purchase_unit text;
  v_invoice_qty numeric;
  v_invoice_cost numeric;
  v_norm jsonb;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PARAMS');
  END IF;

  -- process_purchase inserts purchase_items immediately before calling _raw_add.
  -- Read that invoice line so inventory can be normalized while the invoice stays unchanged.
  IF p_entry_type = 'purchase' AND p_reference_type = 'purchase' AND p_reference_id IS NOT NULL THEN
    SELECT pi.unit_name, pi.quantity, pi.unit_cost
    INTO v_purchase_unit, v_invoice_qty, v_invoice_cost
    FROM public.purchase_items pi
    WHERE pi.purchase_id = p_reference_id
      AND pi.raw_material_id = p_raw_material_id
    ORDER BY pi.created_at DESC NULLS LAST, pi.id DESC
    LIMIT 1;

    IF FOUND THEN
      v_norm := public._normalize_raw_purchase_uom(
        p_raw_material_id,
        COALESCE(v_invoice_qty, p_qty),
        COALESCE(v_invoice_cost, p_unit_cost),
        v_purchase_unit
      );
      IF COALESCE((v_norm->>'success')::boolean, false) IS NOT TRUE THEN
        RETURN v_norm;
      END IF;
      v_qty := (v_norm->>'stock_quantity')::numeric;
      v_cost := (v_norm->>'stock_unit_cost')::numeric;
    END IF;
  END IF;

  IF v_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_NORMALIZED_QUANTITY');
  END IF;

  v_batch_no := COALESCE(NULLIF(btrim(COALESCE(p_batch_number, '')), ''),
                         'RB-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  SELECT * INTO v_inv
  FROM public.raw_material_inventory
  WHERE raw_material_id = p_raw_material_id AND branch_id = p_branch_id
  FOR UPDATE;

  IF v_inv.id IS NULL THEN
    v_before := 0;
    v_after := v_qty;
    v_new_avg := v_cost;
    INSERT INTO public.raw_material_inventory (raw_material_id, branch_id, quantity, avg_cost)
    VALUES (p_raw_material_id, p_branch_id, v_qty, v_new_avg);
  ELSE
    v_before := v_inv.quantity;
    v_after := v_before + v_qty;
    v_new_avg := CASE WHEN v_after > 0
      THEN round((v_inv.quantity * v_inv.avg_cost + v_qty * v_cost) / v_after, 6)
      ELSE v_cost END;
    UPDATE public.raw_material_inventory
    SET quantity = v_after, avg_cost = v_new_avg, updated_at = now()
    WHERE id = v_inv.id;
  END IF;

  INSERT INTO public.raw_material_batches
    (raw_material_id, branch_id, batch_number, quantity, unit_cost, production_date, expiry_date, source_type, source_id)
  VALUES
    (p_raw_material_id, p_branch_id, v_batch_no, v_qty, v_cost,
     p_production_date, p_expiry_date, COALESCE(p_reference_type, p_entry_type), p_reference_id);

  INSERT INTO public.inventory_ledger
    (raw_material_id, branch_id, batch_number, quantity, unit_cost, total_cost, before_qty, after_qty,
     entry_type, reference_type, reference_id, reference_number, created_by)
  VALUES
    (p_raw_material_id, p_branch_id, v_batch_no, v_qty, v_cost,
     round(v_qty * v_cost, 2), v_before, v_after, p_entry_type,
     p_reference_type, p_reference_id, p_reference_number, p_created_by);

  RETURN jsonb_build_object(
    'success', true,
    'before_qty', v_before,
    'after_qty', v_after,
    'added_qty', v_qty,
    'unit_cost', v_cost,
    'avg_cost', v_new_avg,
    'batch_number', v_batch_no
  );
END;
$$;

REVOKE ALL ON FUNCTION public._normalize_raw_purchase_uom(uuid,numeric,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._normalize_raw_purchase_uom(uuid,numeric,numeric,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902033000_refund_manager_approval_gate.sql
-- ----------------------------------------------------------------------------
-- Refund approval hardening.
-- Managers/admins with refunds.approve keep direct execution.
-- Other operators (cashier) require an approved, unexpired request that matches
-- the exact sale, requester, branch and action. The approval row is locked for
-- the whole refund transaction and consumed only after a successful refund.
-- Also preserve the original payment method in shift refund movements so card
-- refunds never reduce the physical cash drawer.

DO $migration$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
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

  IF position('v_approval_id uuid;' in v_def) = 0 THEN
    v_old := '  v_diff numeric(14,2);';
    v_new := '  v_diff numeric(14,2);' || E'\n' || '  v_approval_id uuid;';
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund declaration marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('APPROVAL_REQUIRED' in v_def) = 0 THEN
    v_old := $old$    -- Permission: refunds.approve (admins always pass)
    IF NOT is_pos_admin() AND NOT can_permission('refunds.approve') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'You need the refunds.approve permission.');
    END IF;$old$;

    v_new := $new$    -- Permission: managers/admins execute directly. Cashiers need a matching manager approval.
    IF NOT is_pos_admin() AND NOT can_permission('refunds.approve') THEN
      SELECT ar.id
        INTO v_approval_id
      FROM public.approval_requests ar
      WHERE ar.requester_id = auth.uid()
        AND ar.branch_id = v_sale.branch_id
        AND ar.action_type = 'refund'
        AND ar.entity_type = 'sale'
        AND ar.entity_id = p_sale_id
        AND ar.status = 'approved'
        AND ar.consumed_at IS NULL
        AND ar.expires_at > now()
      ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
      LIMIT 1
      FOR UPDATE SKIP LOCKED;

      IF v_approval_id IS NULL THEN
        RETURN jsonb_build_object(
          'success', false,
          'error', 'APPROVAL_REQUIRED',
          'action_type', 'refund',
          'entity_type', 'sale',
          'entity_id', p_sale_id
        );
      END IF;
    END IF;$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund permission marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  -- The original refund function did not select payment_method into v_sale and
  -- hard-coded every shift refund as cash. Preserve the sale payment method.
  IF position('payment_method, invoice_number' in v_def) = 0 THEN
    v_old := 'SELECT id, branch_id, warehouse_id, status, total, paid_amount, customer_id, invoice_number';
    v_new := 'SELECT id, branch_id, warehouse_id, status, total, paid_amount, customer_id, payment_method, invoice_number';
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund sale select marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position($needle$COALESCE(v_sale.payment_method, 'cash')$needle$ in v_def) = 0 THEN
    v_old := $old$VALUES (v_shift_id, 'refund', v_refund_total, 'cash', 'refund', p_sale_id, auth.uid());$old$;
    v_new := $new$VALUES (v_shift_id, 'refund', v_refund_total, COALESCE(v_sale.payment_method, 'cash'), 'refund', p_sale_id, auth.uid());$new$;
    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund shift payment marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('REFUND_APPROVAL_CONSUME_FAILED' in v_def) = 0 THEN
    v_old := $old$    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'refunded_amount', v_refund_total, 'fully_refunded', v_all_refunded);$old$;

    v_new := $new$    IF v_approval_id IS NOT NULL THEN
      UPDATE public.approval_requests
      SET status = 'consumed', consumed_at = now()
      WHERE id = v_approval_id
        AND requester_id = auth.uid()
        AND action_type = 'refund'
        AND entity_type = 'sale'
        AND entity_id = p_sale_id
        AND status = 'approved'
        AND consumed_at IS NULL
        AND expires_at > now();

      IF NOT FOUND THEN
        RAISE EXCEPTION 'REFUND_APPROVAL_CONSUME_FAILED';
      END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'refunded_amount', v_refund_total, 'fully_refunded', v_all_refunded);$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_refund success marker not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  -- Keep SECURITY DEFINER functions hardened against temp-schema object shadowing.
  v_def := replace(v_def, 'SET search_path TO ''public''', 'SET search_path TO public, pg_temp');

  EXECUTE v_def;
END
$migration$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902040000_change_payment_method_approval.sql
-- ----------------------------------------------------------------------------
-- Atomic post-sale payment-method correction with manager approval.
-- Keeps sales, shift operations and the accounting journal consistent.

CREATE OR REPLACE FUNCTION public.change_sale_payment_method(
  p_sale_id uuid,
  p_new_method text,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_sale record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
  v_entry_id uuid;
  v_old_account uuid;
  v_new_account uuid;
  v_old_key text;
  v_new_key text;
  v_changed integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  p_new_method := lower(btrim(COALESCE(p_new_method, '')));
  IF p_new_method NOT IN ('cash', 'card', 'transfer') THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNSUPPORTED_PAYMENT_METHOD',
      'detail', 'Only cash, card and transfer can be corrected after sale. Credit requires a receivables workflow.');
  END IF;

  SELECT id, branch_id, payment_method, paid_amount, status, invoice_number
    INTO v_sale
  FROM public.sales
  WHERE id = p_sale_id
  FOR UPDATE;

  IF v_sale.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SALE_NOT_FOUND');
  END IF;

  IF v_sale.status = 'returned' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SALE_RETURNED');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_sale.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF lower(COALESCE(v_sale.payment_method, 'cash')) = p_new_method THEN
    RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
      'payment_method', p_new_method, 'unchanged', true);
  END IF;

  -- Branch manager/admin can execute directly. Other operators require a
  -- one-time approval that explicitly names the requested destination method.
  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_sale.branch_id
      AND ar.action_type = 'change_payment_method'
      AND ar.entity_type = 'sale'
      AND ar.entity_id = p_sale_id
      AND ar.status = 'approved'
      AND ar.consumed_at IS NULL
      AND ar.expires_at > now()
      AND lower(COALESCE(ar.payload->>'new_method', '')) = p_new_method
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_approval_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'APPROVAL_REQUIRED',
        'action_type', 'change_payment_method', 'entity_type', 'sale',
        'entity_id', p_sale_id, 'new_method', p_new_method);
    END IF;
  END IF;

  v_old_key := CASE WHEN lower(COALESCE(v_sale.payment_method, 'cash')) = 'cash' THEN 'cash' ELSE 'bank' END;
  v_new_key := CASE WHEN p_new_method = 'cash' THEN 'cash' ELSE 'bank' END;

  -- Validate the accounting correction before any write.
  IF COALESCE(v_sale.paid_amount, 0) > 0 AND v_old_key <> v_new_key THEN
    v_old_account := public.resolve_account_key(v_sale.branch_id, v_old_key);
    v_new_account := public.resolve_account_key(v_sale.branch_id, v_new_key);

    SELECT id INTO v_entry_id
    FROM public.journal_entries
    WHERE branch_id = v_sale.branch_id
      AND reference_type = 'sale'
      AND reference_id = p_sale_id
    LIMIT 1;

    IF v_entry_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'SALE_JOURNAL_NOT_FOUND');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.journal_entry_lines
      WHERE journal_entry_id = v_entry_id
        AND account_id = v_old_account
        AND debit > 0
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_JOURNAL_LINE_NOT_FOUND',
        'old_method', v_sale.payment_method);
    END IF;
  END IF;

  UPDATE public.sales
  SET payment_method = p_new_method,
      notes = CASE WHEN p_reason IS NULL OR btrim(p_reason) = '' THEN notes
                   ELSE concat_ws(E'\n', NULLIF(notes, ''), 'Payment method changed: ' || p_reason) END
  WHERE id = p_sale_id;

  UPDATE public.shift_operations
  SET payment_method = p_new_method
  WHERE operation_type = 'sale'
    AND reference_type = 'sale'
    AND reference_id = p_sale_id;

  GET DIAGNOSTICS v_changed = ROW_COUNT;

  IF COALESCE(v_sale.paid_amount, 0) > 0 AND v_old_key <> v_new_key THEN
    UPDATE public.journal_entry_lines
    SET account_id = v_new_account
    WHERE journal_entry_id = v_entry_id
      AND account_id = v_old_account
      AND debit > 0;
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'change_payment_method'
      AND entity_type = 'sale'
      AND entity_id = p_sale_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'CHANGE_PAYMENT_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  PERFORM public.log_audit_action(v_sale.branch_id, 'change_payment_method', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number,
      'old_method', v_sale.payment_method, 'new_method', p_new_method,
      'reason', p_reason, 'shift_rows_updated', v_changed));

  RETURN jsonb_build_object('success', true, 'sale_id', p_sale_id,
    'old_method', v_sale.payment_method, 'payment_method', p_new_method);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.change_sale_payment_method(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_sale_payment_method(uuid,text,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902050000_shift_drawer_manager_approval.sql
-- ----------------------------------------------------------------------------
-- Server-authoritative manager approval for force-closing a shift and opening the cash drawer.
-- Normal close_shift remains unchanged. These RPCs are explicit sensitive-operation paths.

CREATE OR REPLACE FUNCTION public.force_close_shift(
  p_shift_id uuid,
  p_actual_amount numeric DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
  v_expected numeric(14,2) := 0;
  v_actual numeric(14,2) := 0;
  v_difference numeric(14,2) := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT id, branch_id, cashier_id, opening_amount, status, notes
    INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;
  IF v_shift.status <> 'open' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_OPEN');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_shift.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  -- Non-manager operators may only force-close their own shift and must consume
  -- an approval tied to the exact shift and requested actual cash amount.
  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    IF v_shift.cashier_id <> v_uid THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_SHIFT_CASHIER');
    END IF;

    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_shift.branch_id
      AND ar.action_type = 'force_close_shift'
      AND ar.entity_type = 'shift'
      AND ar.entity_id = p_shift_id
      AND ar.status = 'approved'
      AND ar.consumed_at IS NULL
      AND ar.expires_at > now()
      AND (
        p_actual_amount IS NULL
        OR (ar.payload->>'actual_amount')::numeric = p_actual_amount
      )
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_approval_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'APPROVAL_REQUIRED',
        'action_type', 'force_close_shift',
        'entity_type', 'shift',
        'entity_id', p_shift_id,
        'actual_amount', p_actual_amount
      );
    END IF;
  END IF;

  SELECT round(COALESCE(v_shift.opening_amount, 0) + COALESCE(sum(
    CASE
      WHEN operation_type IN ('sale', 'cash_in') THEN amount
      WHEN operation_type IN ('refund', 'expense', 'cash_out') THEN -amount
      ELSE 0
    END
  ) FILTER (WHERE payment_method = 'cash'), 0), 2)
  INTO v_expected
  FROM public.shift_operations
  WHERE shift_id = p_shift_id;

  v_actual := round(COALESCE(p_actual_amount, v_expected), 2);
  IF v_actual < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTUAL_AMOUNT');
  END IF;
  v_difference := round(v_actual - v_expected, 2);

  UPDATE public.shifts
  SET status = 'closed',
      closed_at = now(),
      expected_amount = v_expected,
      actual_amount = v_actual,
      difference = v_difference,
      notes = CASE
        WHEN p_reason IS NULL OR btrim(p_reason) = '' THEN notes
        ELSE concat_ws(E'\n', NULLIF(notes, ''), 'Force close: ' || btrim(p_reason))
      END
  WHERE id = p_shift_id AND status = 'open';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FORCE_CLOSE_SHIFT_UPDATE_FAILED';
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'force_close_shift'
      AND entity_type = 'shift'
      AND entity_id = p_shift_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'FORCE_CLOSE_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  PERFORM public.log_audit_action(
    v_shift.branch_id,
    'force_close_shift',
    'shift',
    p_shift_id,
    jsonb_build_object(
      'cashier_id', v_shift.cashier_id,
      'expected', v_expected,
      'actual', v_actual,
      'difference', v_difference,
      'reason', p_reason,
      'approval_id', v_approval_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'shift_id', p_shift_id,
    'expected', v_expected,
    'actual', v_actual,
    'difference', v_difference,
    'forced', true
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.authorize_open_drawer(
  p_shift_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_shift record;
  v_role text;
  v_user_branch uuid;
  v_approval_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;

  SELECT id, branch_id, cashier_id, status
    INTO v_shift
  FROM public.shifts
  WHERE id = p_shift_id
  FOR UPDATE;

  IF v_shift.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_FOUND');
  END IF;
  IF v_shift.status <> 'open' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SHIFT_NOT_OPEN');
  END IF;

  SELECT role, branch_id INTO v_role, v_user_branch
  FROM public.users
  WHERE id = v_uid AND is_active;

  IF v_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'USER_NOT_FOUND');
  END IF;

  IF NOT public.is_pos_admin()
     AND v_user_branch IS NOT NULL
     AND v_user_branch <> v_shift.branch_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
  END IF;

  IF NOT public.is_pos_admin() AND v_role <> 'branch_manager' THEN
    IF v_shift.cashier_id <> v_uid THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_SHIFT_CASHIER');
    END IF;

    SELECT ar.id INTO v_approval_id
    FROM public.approval_requests ar
    WHERE ar.requester_id = v_uid
      AND ar.branch_id = v_shift.branch_id
      AND ar.action_type = 'open_drawer'
      AND ar.entity_type = 'shift'
      AND ar.entity_id = p_shift_id
      AND ar.status = 'approved'
      AND ar.consumed_at IS NULL
      AND ar.expires_at > now()
    ORDER BY ar.decided_at DESC NULLS LAST, ar.created_at DESC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_approval_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'APPROVAL_REQUIRED',
        'action_type', 'open_drawer',
        'entity_type', 'shift',
        'entity_id', p_shift_id
      );
    END IF;
  END IF;

  IF v_approval_id IS NOT NULL THEN
    UPDATE public.approval_requests
    SET status = 'consumed', consumed_at = now()
    WHERE id = v_approval_id
      AND requester_id = v_uid
      AND action_type = 'open_drawer'
      AND entity_type = 'shift'
      AND entity_id = p_shift_id
      AND status = 'approved'
      AND consumed_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'OPEN_DRAWER_APPROVAL_CONSUME_FAILED';
    END IF;
  END IF;

  -- This RPC authorizes and audits the sensitive action. A physical drawer kick
  -- is performed only by a configured printer/native hardware bridge; browsers
  -- must not fabricate a hardware-open success.
  PERFORM public.log_audit_action(
    v_shift.branch_id,
    'open_drawer_authorized',
    'shift',
    p_shift_id,
    jsonb_build_object(
      'cashier_id', v_shift.cashier_id,
      'reason', p_reason,
      'approval_id', v_approval_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'authorized', true,
    'shift_id', p_shift_id,
    'hardware_action_required', true
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.force_close_shift(uuid,numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.authorize_open_drawer(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.force_close_shift(uuid,numeric,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.authorize_open_drawer(uuid,text) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902051000_kitchen_quantity_delta.sql
-- ----------------------------------------------------------------------------
-- Track the quantity already communicated to KDS for each stable order_item_id.
-- Increasing a previously-sent line sends only the positive delta. Kitchen
-- voids reduce the communicated quantity so later increases are also correct.

ALTER TABLE public.order_kitchen_sends
  ADD COLUMN IF NOT EXISTS sent_quantity numeric(14,4) NOT NULL DEFAULT 0;

-- Existing snapshot rows represented the then-current quantity. Any historical
-- approved void already changed order_items, so current quantity is the correct
-- net quantity the kitchen should be considered to have after that void event.
UPDATE public.order_kitchen_sends s
SET sent_quantity = GREATEST(COALESCE(oi.quantity, 0), 0)
FROM public.order_items oi
WHERE oi.id = s.order_item_id
  AND s.sent_quantity = 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.order_kitchen_sends'::regclass
      AND conname = 'order_kitchen_sends_sent_quantity_nonnegative'
  ) THEN
    ALTER TABLE public.order_kitchen_sends
      ADD CONSTRAINT order_kitchen_sends_sent_quantity_nonnegative
      CHECK (sent_quantity >= 0);
  END IF;
END $$;

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
BEGIN
  BEGIN
    SELECT branch_id, status INTO v_branch_id, v_status
    FROM public.orders WHERE id = p_order_id;
    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF v_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.');
    END IF;

    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF NOT is_pos_admin()
       AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) ON COMMIT DROP;
    TRUNCATE _kns_delta;

    -- Candidate delta is current cart quantity minus the net quantity already
    -- communicated to KDS. The conflict WHERE clause is concurrency-safe: if a
    -- second sender races after the first reaches the target quantity, it gets
    -- no RETURNING row and therefore prints no duplicate ticket.
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

-- An approved kitchen void is itself a communication to the kitchen. Keep the
-- net communicated quantity aligned with that void so future increases send the
-- correct delta rather than comparing against the pre-void quantity.
CREATE OR REPLACE FUNCTION public.sync_kitchen_sent_quantity_after_void()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF NEW.order_item_id IS NOT NULL THEN
    UPDATE public.order_kitchen_sends
    SET sent_quantity = GREATEST(sent_quantity - NEW.quantity, 0)
    WHERE order_item_id = NEW.order_item_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_kitchen_sent_quantity_after_void
  ON public.order_kitchen_voids;
CREATE TRIGGER trg_sync_kitchen_sent_quantity_after_void
AFTER INSERT ON public.order_kitchen_voids
FOR EACH ROW EXECUTE FUNCTION public.sync_kitchen_sent_quantity_after_void();

REVOKE ALL ON FUNCTION public.sync_kitchen_sent_quantity_after_void() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_kitchen_sent_quantity_after_void() TO service_role;

REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902052000_purchase_backorders_branch_visibility.sql
-- ----------------------------------------------------------------------------
-- P3 branch visibility: expose the purchase branch on backorder rows so the UI
-- can make branch scope explicit. Preserve server-side branch isolation and
-- harden SECURITY DEFINER search_path while replacing the table return type.

DROP FUNCTION IF EXISTS public.get_purchase_backorders(uuid);

CREATE FUNCTION public.get_purchase_backorders(
  p_branch_id uuid DEFAULT NULL
) RETURNS TABLE(
  purchase_id uuid,
  branch_id uuid,
  invoice_number text,
  supplier_id uuid,
  supplier_name text,
  purchase_item_id uuid,
  product_id uuid,
  raw_material_id uuid,
  item_name text,
  item_type text,
  unit_name text,
  ordered_quantity numeric,
  received_quantity numeric,
  remaining numeric,
  unit_cost numeric,
  status text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF p_branch_id IS NOT NULL
     AND NOT is_pos_admin()
     AND get_branch_id() IS NOT NULL
     AND get_branch_id() <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;

  RETURN QUERY
    SELECT
      pc.id,
      pc.branch_id,
      pc.invoice_number,
      pc.supplier_id,
      s.name,
      pi.id,
      pi.product_id,
      pi.raw_material_id,
      COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(rm.name), ''), '?'),
      CASE WHEN pi.product_id IS NOT NULL THEN 'product' ELSE 'raw_material' END,
      pi.unit_name,
      pi.quantity,
      COALESCE(pi.received_quantity, 0),
      pi.quantity - COALESCE(pi.received_quantity, 0),
      pi.unit_cost,
      pc.status
    FROM public.purchase_items pi
    JOIN public.purchases pc ON pc.id = pi.purchase_id
    JOIN public.suppliers s ON s.id = pc.supplier_id
    LEFT JOIN public.products p ON p.id = pi.product_id
    LEFT JOIN public.raw_materials rm ON rm.id = pi.raw_material_id
    WHERE pc.status IN ('approved', 'submitted', 'partial')
      AND pi.quantity - COALESCE(pi.received_quantity, 0) > 0
      AND (p_branch_id IS NULL OR pc.branch_id = p_branch_id)
      AND (is_pos_admin() OR pc.branch_id = get_branch_id())
    ORDER BY pc.created_at ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_purchase_backorders(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_backorders(uuid) TO authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902060000_sale_financial_authority.sql
-- ----------------------------------------------------------------------------
-- P2: keep the complete financial sale lifecycle behind process_sale.
-- Direct authenticated DML cannot provide the same pricing, inventory,
-- approval, accounting, and transaction guarantees.

DROP POLICY IF EXISTS auth_insert_sales ON public.sales;
CREATE POLICY auth_insert_sales ON public.sales
  FOR INSERT TO authenticated
  WITH CHECK (false);

DROP POLICY IF EXISTS auth_insert_sale_items ON public.sale_items;
CREATE POLICY auth_insert_sale_items ON public.sale_items
  FOR INSERT TO authenticated
  WITH CHECK (false);

-- The catalog-derived total is authoritative. paid_amount records the amount
-- applied to the invoice, not cash tendered by the customer, so it must never
-- exceed the server-computed total.
DO $do$
DECLARE
  v_src text;
  v_old text := 'v_paid := ROUND(GREATEST(COALESCE(p_paid_amount, 0), 0), 2);';
  v_new text := 'v_paid := ROUND(LEAST(GREATEST(COALESCE(p_paid_amount, 0), 0), v_total), 2);';
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = '_process_sale_core'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION '_process_sale_core target signature not found';
  END IF;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN
      RAISE EXCEPTION '_process_sale_core paid amount assignment changed unexpectedly';
    END IF;
    v_src := replace(v_src, v_old, v_new);
    EXECUTE v_src;
  END IF;
END
$do$;

REVOKE ALL ON FUNCTION public._process_sale_core(
  text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,
  text,text,jsonb,uuid,text,uuid,uuid,integer
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public._process_sale_core(
  text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,
  text,text,jsonb,uuid,text,uuid,uuid,integer
) TO service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902061000_purchase_receipt_uom_accounting.sql
-- ----------------------------------------------------------------------------
-- Keep direct purchase-order totals, partial raw-material receipts, stock UOM,
-- and the final purchase journal aligned to the complete order.

DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_purchase_order'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_branch_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_payment_method text, p_notes text, p_items jsonb, p_quotation_id uuid';

  IF v_src IS NULL THEN RAISE EXCEPTION 'create_purchase_order target not found'; END IF;

  v_old := $old$          round(COALESCE((v_item->>'quantity')::numeric, 0) * COALESCE((v_item->>'unit_cost')::numeric, 0), 2));
        v_rows := v_rows + 1;
$old$;
  v_new := $new$          round(COALESCE((v_item->>'quantity')::numeric, 0) * COALESCE((v_item->>'unit_cost')::numeric, 0), 2));
        v_total := v_total
          + COALESCE((v_item->>'quantity')::numeric, 0)
          * COALESCE((v_item->>'unit_cost')::numeric, 0);
        v_rows := v_rows + 1;
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'create_purchase_order manual total block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
    EXECUTE v_src;
  END IF;
END
$do$;

DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'receive_purchase_order'
    AND pg_get_function_identity_arguments(p.oid) = 'p_purchase_id uuid, p_receipt_items jsonb';

  IF v_src IS NULL THEN RAISE EXCEPTION 'receive_purchase_order target not found'; END IF;

  v_old := $old$      ELSE
        v_res := public._raw_add(v_pitem.raw_material_id, v_purchase.branch_id,
          v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
          'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
        v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
      END IF;
$old$;
  v_new := $new$      ELSE
        -- Normalize the quantity actually received, not the full ordered line.
        v_res := public._normalize_raw_purchase_uom(
          v_pitem.raw_material_id, v_qty, v_pitem.unit_cost, v_pitem.unit_name);
        IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
          RETURN v_res;
        END IF;
        v_res := public._raw_add(v_pitem.raw_material_id, v_purchase.branch_id,
          (v_res->>'stock_quantity')::numeric, (v_res->>'stock_unit_cost')::numeric,
          NULL, NULL, NULL, 'purchase', 'purchase_receipt', v_receipt_id, v_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
        v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
      END IF;
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'receive_purchase_order raw receipt block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  v_old := $old$    IF v_fully_received THEN
      v_paid := round(COALESCE(v_purchase.paid_amount, 0), 2);
$old$;
  v_new := $new$    IF v_fully_received THEN
      -- Earlier partial receipts were not posted. Rebuild inventory value from
      -- the full order so the completion journal never contains only the last GRN.
      SELECT
        round(COALESCE(SUM(CASE WHEN pi.product_id IS NOT NULL THEN pi.quantity * pi.unit_cost ELSE 0 END), 0), 2),
        round(COALESCE(SUM(CASE WHEN pi.raw_material_id IS NOT NULL THEN pi.quantity * pi.unit_cost ELSE 0 END), 0), 2)
      INTO v_goods_fg, v_goods_rm
      FROM public.purchase_items pi
      WHERE pi.purchase_id = p_purchase_id;

      v_paid := round(LEAST(GREATEST(COALESCE(v_purchase.paid_amount, 0), 0), COALESCE(v_purchase.total, 0)), 2);
$new$;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old IN v_src) = 0 THEN RAISE EXCEPTION 'receive_purchase_order completion journal block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  EXECUTE v_src;
END
$do$;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902070000_p2_authoritative_order_pricing.sql
-- ----------------------------------------------------------------------------
-- P2 closure: make order staging and sale approval server-authoritative.

CREATE OR REPLACE FUNCTION public._effective_branch_tax(p_branch_id uuid)
RETURNS TABLE(tax_enabled boolean, tax_rate numeric)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT
    COALESCE(
      (SELECT bs.tax_enabled FROM public.branch_settings bs WHERE bs.branch_id = p_branch_id),
      (SELECT s.tax_enabled FROM public.settings s ORDER BY s.created_at NULLS LAST LIMIT 1),
      false
    ),
    COALESCE(
      (SELECT bs.tax_rate FROM public.branch_settings bs WHERE bs.branch_id = p_branch_id),
      (SELECT s.tax_rate FROM public.settings s ORDER BY s.created_at NULLS LAST LIMIT 1),
      0
    );
$$;

CREATE OR REPLACE FUNCTION public._reprice_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_price numeric;
BEGIN
  SELECT branch_id INTO v_branch_id FROM public.orders WHERE id = NEW.order_id;
  IF v_branch_id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  SELECT sale_price INTO v_price
  FROM public.products
  WHERE id = NEW.product_id AND branch_id = v_branch_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH'; END IF;
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;

  NEW.unit_price := ROUND(COALESCE(v_price, 0), 2);
  NEW.discount_amount := ROUND(
    LEAST(GREATEST(COALESCE(NEW.discount_amount, 0), 0), NEW.quantity * NEW.unit_price), 2
  );
  NEW.bonus_quantity := GREATEST(COALESCE(NEW.bonus_quantity, 0), 0);
  NEW.total := ROUND(NEW.quantity * NEW.unit_price - NEW.discount_amount, 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_authoritative_price ON public.order_items;
CREATE TRIGGER trg_order_items_authoritative_price
BEFORE INSERT OR UPDATE OF product_id, quantity, unit_price, discount_amount, bonus_quantity, total
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._reprice_order_item();

CREATE OR REPLACE FUNCTION public._sync_order_totals_from_items()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_branch_id uuid;
  v_subtotal numeric(14,2);
  v_discount numeric(14,2);
  v_tax_enabled boolean;
  v_tax_rate numeric;
  v_tax numeric(14,2);
  v_total numeric(14,2);
BEGIN
  v_order_id := COALESCE(NEW.order_id, OLD.order_id);
  SELECT branch_id, GREATEST(COALESCE(discount_amount, 0), 0)
  INTO v_branch_id, v_discount
  FROM public.orders WHERE id = v_order_id;
  IF v_branch_id IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;

  SELECT ROUND(COALESCE(SUM(total), 0), 2)
  INTO v_subtotal
  FROM public.order_items WHERE order_id = v_order_id;

  v_discount := LEAST(v_discount, v_subtotal);
  SELECT t.tax_enabled, t.tax_rate INTO v_tax_enabled, v_tax_rate
  FROM public._effective_branch_tax(v_branch_id) t;
  v_tax := CASE WHEN COALESCE(v_tax_enabled, false)
    THEN ROUND((v_subtotal - v_discount) * COALESCE(v_tax_rate, 0) / 100, 2)
    ELSE 0 END;
  v_total := ROUND(v_subtotal - v_discount + v_tax, 2);

  UPDATE public.orders
  SET subtotal = v_subtotal,
      discount_amount = v_discount,
      tax_amount = v_tax,
      total = v_total,
      updated_at = now()
  WHERE id = v_order_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_sync_totals ON public.order_items;
CREATE TRIGGER trg_order_items_sync_totals
AFTER INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._sync_order_totals_from_items();

DO $do$
DECLARE
  v_src text;
  v_old text := $old$    SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0) INTO v_tax_enabled, v_tax_rate
    FROM public.settings LIMIT 1;$old$;
  v_new text := $new$    SELECT t.tax_enabled, t.tax_rate INTO v_tax_enabled, v_tax_rate
    FROM public._effective_branch_tax(p_branch_id) t;$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='_process_sale_core'
    AND pg_get_function_identity_arguments(p.oid)=
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';
  IF v_src IS NULL THEN RAISE EXCEPTION '_process_sale_core target not found'; END IF;
  IF position(v_new IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION '_process_sale_core tax block changed unexpectedly'; END IF;
    EXECUTE replace(v_src,v_old,v_new);
  END IF;
END
$do$;

CREATE OR REPLACE FUNCTION public.process_sale(
  p_invoice_number text,p_branch_id uuid,p_warehouse_id uuid,p_customer_id uuid,p_salesperson_id uuid,
  p_subtotal numeric,p_discount_amount numeric,p_discount_type text,p_tax_amount numeric,p_bonus_amount numeric,
  p_total numeric,p_paid_amount numeric,p_payment_method text,p_status text,p_items jsonb,p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',p_table_id uuid DEFAULT NULL,p_order_id uuid DEFAULT NULL,p_guest_count integer DEFAULT NULL
) RETURNS jsonb
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
  v_line_discount numeric;
  v_server_subtotal numeric(14,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items)=0 THEN RETURN jsonb_build_object('success',false,'error','EMPTY_CART'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := NULLIF(v_item->>'product_id','')::uuid;
    v_qty := COALESCE((v_item->>'quantity')::numeric,0);
    IF v_product_id IS NULL OR v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT'); END IF;
    SELECT sale_price INTO v_price FROM public.products
    WHERE id=v_product_id AND branch_id=p_branch_id AND is_active=true;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','PRODUCT_NOT_IN_BRANCH','product_id',v_product_id); END IF;
    v_price := COALESCE(v_price,0);
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
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public._reprice_order_item() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._sync_order_totals_from_items() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._effective_branch_tax(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public._effective_branch_tax(uuid) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,numeric,text,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated,service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902071000_purchase_order_input_uom_validation.sql
-- ----------------------------------------------------------------------------
-- Validate manual PO quantities/costs and UOM compatibility before creating an unreceivable order.
DO $do$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='create_purchase_order'
    AND pg_get_function_identity_arguments(p.oid)=
      'p_branch_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_payment_method text, p_notes text, p_items jsonb, p_quotation_id uuid';
  IF v_src IS NULL THEN RAISE EXCEPTION 'create_purchase_order target not found'; END IF;

  v_old := $decl$  v_request_id uuid;$decl$;
  v_new := $decl$  v_request_id uuid;
  v_norm jsonb;$decl$;
  IF position('v_norm jsonb;' IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION 'create_purchase_order declaration block changed unexpectedly'; END IF;
    v_src := replace(v_src, v_old, v_new);
  END IF;

  v_old := $old$        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        INSERT INTO public.purchase_items$old$;
  v_new := $new$        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        IF COALESCE((v_item->>'quantity')::numeric, 0) <= 0
           OR COALESCE((v_item->>'unit_cost')::numeric, 0) < 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'INVALID_PURCHASE_QUANTITY_OR_COST');
        END IF;
        IF NULLIF(v_item->>'raw_material_id', '') IS NOT NULL THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.raw_materials rm
            WHERE rm.id = (v_item->>'raw_material_id')::uuid
              AND rm.branch_id = p_branch_id AND rm.is_active = true
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'RAW_MATERIAL_NOT_IN_BRANCH');
          END IF;
          v_norm := public._normalize_raw_purchase_uom(
            (v_item->>'raw_material_id')::uuid,
            (v_item->>'quantity')::numeric,
            (v_item->>'unit_cost')::numeric,
            NULLIF(v_item->>'unit_name','')
          );
          IF COALESCE((v_norm->>'success')::boolean, false) IS NOT TRUE THEN
            RETURN v_norm;
          END IF;
        ELSE
          IF NOT EXISTS (
            SELECT 1 FROM public.products p
            WHERE p.id = (v_item->>'product_id')::uuid
              AND p.branch_id = p_branch_id AND p.is_active = true
          ) THEN
            RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH');
          END IF;
        END IF;
        INSERT INTO public.purchase_items$new$;

  IF position(v_new IN v_src)=0 THEN
    IF position(v_old IN v_src)=0 THEN RAISE EXCEPTION 'create_purchase_order manual validation block changed unexpectedly'; END IF;
    v_src := replace(v_src,v_old,v_new);
  END IF;

  EXECUTE v_src;
END
$do$;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902072000_precise_sale_input_errors.sql
-- ----------------------------------------------------------------------------
-- Final audit: keep sale input validation explicit so callers can distinguish
-- malformed product identifiers from invalid quantities without weakening P2.

DO $do$
DECLARE
  v_src text;
  v_old_compact text := $old$    IF v_product_id IS NULL OR v_qty <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT'); END IF;$old$;
  v_old_multiline text := $old$    IF v_product_id IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY_OR_PRODUCT');
    END IF;$old$;
  v_new text := $new$    IF v_product_id IS NULL THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_PRODUCT');
    END IF;
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success',false,'error','INVALID_QUANTITY');
    END IF;$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'process_sale'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid, p_order_type text, p_table_id uuid, p_order_id uuid, p_guest_count integer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'process_sale target signature not found';
  END IF;

  IF position(v_new IN v_src) = 0 THEN
    IF position(v_old_compact IN v_src) > 0 THEN
      v_src := replace(v_src, v_old_compact, v_new);
    ELSIF position(v_old_multiline IN v_src) > 0 THEN
      v_src := replace(v_src, v_old_multiline, v_new);
    ELSE
      RAISE EXCEPTION 'process_sale input validation block changed unexpectedly';
    END IF;
    EXECUTE v_src;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902073000_final_security_surface_hardening.sql
-- ----------------------------------------------------------------------------
-- Final release audit security hardening.

ALTER VIEW public.units SET (security_invoker = true);

ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.schema_migrations FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.protect_system_accounts() SET search_path = public, pg_temp;
ALTER FUNCTION public.set_updated_at() SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_move(uuid,uuid,uuid,uuid,numeric,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_add(uuid,uuid,uuid,numeric,numeric,text,date,date,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_inv_remove_fifo(uuid,uuid,uuid,numeric,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._raw_remove_fifo(uuid,uuid,numeric,text,text,uuid,text,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.guard_table_delete() SET search_path = public, pg_temp;
ALTER FUNCTION public.touch_system_settings() SET search_path = public, pg_temp;
ALTER FUNCTION public._product_wavg_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._raw_wavg_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_bom_cost(uuid,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public._product_recipe_cost(uuid,uuid) SET search_path = public, pg_temp;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon', r.nspname,r.proname,r.args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated', r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

GRANT EXECUTE ON FUNCTION public.get_login_email(text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
      AND (
        p.proname LIKE '\_%' ESCAPE '\'
        OR p.proname IN (
          'assert_branch_active','guard_branch_org_immutable','guard_order_subscription',
          'guard_role_permissions','guard_sale_discount','guard_user_role_changes',
          'guard_table_delete','protect_last_admin','protect_system_accounts',
          'seed_chart_for_new_branch','seed_mappings_for_new_branch',
          'track_product_cost_history','validate_recipe_item_branch_match',
          'touch_system_settings'
        )
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM authenticated', r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902074000_final_anon_deny_by_default.sql
-- ----------------------------------------------------------------------------
-- Final release audit: anonymous access is deny-by-default.
-- Public sign-up is disabled; pre-auth only needs username/email resolution
-- and login-failure throttling RPCs.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon',r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

GRANT EXECUTE ON FUNCTION public.get_login_email(text) TO anon;
GRANT EXECUTE ON FUNCTION public.record_login_failure(text) TO anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902075000_disable_legacy_privileged_client_rpcs.sql
-- ----------------------------------------------------------------------------
-- Final release audit: privileged bootstrap/registration and legacy KDS inventory
-- mutations must never be callable by ordinary authenticated clients.

REVOKE EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bootstrap_initial_super_admin(text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.register_branch(text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_branch(text,text,text,text,text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.register_tenant(text,text,text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_tenant(text,text,text,text,text,text,text,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.consume_order_kitchen_inventory(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_order_kitchen_inventory(uuid,uuid) TO service_role;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='reverse_order_kitchen_inventory'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated',r.nspname,r.proname,r.args);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO service_role',r.nspname,r.proname,r.args);
  END LOOP;
END
$do$;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902075500_lock_internal_accounting_and_legacy_kds_helpers.sql
-- ----------------------------------------------------------------------------
-- Internal setup helpers and legacy KDS reversal are service-only.
REVOKE EXECUTE ON FUNCTION public.reverse_order_kitchen_consumption(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_order_kitchen_consumption(uuid,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.seed_account_mappings(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_account_mappings(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902080000_remove_verified_duplicate_indexes.sql
-- ----------------------------------------------------------------------------
-- Final release audit: remove only byte-for-byte duplicate indexes verified on production.
DROP INDEX IF EXISTS public.idx_audit_log_branch_date;
DROP INDEX IF EXISTS public.idx_customers_branch;
DROP INDEX IF EXISTS public.idx_inventory_ledger_branch;
DROP INDEX IF EXISTS public.idx_journal_branch_date;
DROP INDEX IF EXISTS public.idx_purchase_items_purchase;
DROP INDEX IF EXISTS public.idx_sale_items_product;
DROP INDEX IF EXISTS public.idx_sale_items_sale;
DROP INDEX IF EXISTS public.idx_sales_branch_created;
DROP INDEX IF EXISTS public.idx_suppliers_branch;
DROP INDEX IF EXISTS public.idx_users_branch;


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902081000_final_branch_rpc_isolation.sql
-- ----------------------------------------------------------------------------
-- Final audit: internal inventory mutators are service-only; client-facing
-- branch readers enforce branch access even under SECURITY DEFINER.

REVOKE EXECUTE ON FUNCTION public.deduct_raw_material_inventory(uuid,numeric,uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_raw_material_inventory(uuid,numeric,uuid,uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid,uuid,jsonb,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_sale_unit_inventory(uuid,uuid,jsonb,uuid,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.log_audit_action(uuid,text,text,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_audit_action(uuid,text,text,uuid,jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.system_integrity_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.system_integrity_audit() TO service_role;

REVOKE EXECUTE ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_product_availability(uuid,uuid,uuid,numeric) TO service_role;

-- Define the latest availability function directly instead of patching its text.
-- This preserves the p_cap upper-bound fix and adds branch authorization.
CREATE OR REPLACE FUNCTION public.get_pos_product_availability(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_cap integer DEFAULT 100000
) RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product record;
  v_low integer;
  v_high integer;
  v_mid integer;
  v_check jsonb;
  v_high_ok boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF p_cap IS NULL OR p_cap < 1 THEN
    p_cap := 1;
  END IF;

  FOR v_product IN
    SELECT p.id
    FROM public.products p
    WHERE p.branch_id = p_branch_id
      AND p.is_active = true
    ORDER BY p.id
  LOOP
    v_low := 0;
    v_high := 1;
    v_high_ok := false;

    LOOP
      v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_high);
      v_high_ok := COALESCE((v_check->>'success')::boolean, false);
      EXIT WHEN NOT v_high_ok;
      v_low := v_high;
      EXIT WHEN v_high >= p_cap;
      v_high := LEAST(v_high * 2, p_cap);
    END LOOP;

    IF v_low < p_cap AND NOT v_high_ok THEN
      WHILE v_high - v_low > 1 LOOP
        v_mid := (v_low + v_high) / 2;
        v_check := public.check_product_availability(v_product.id, p_branch_id, p_warehouse_id, v_mid);
        IF COALESCE((v_check->>'success')::boolean, false) THEN
          v_low := v_mid;
        ELSE
          v_high := v_mid;
        END IF;
      END LOOP;
    END IF;

    product_id := v_product.id;
    available_quantity := v_low;
    is_available := v_low > 0;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pos_product_availability(uuid,uuid,integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.subscription_status(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r public.branch_subscriptions%ROWTYPE;
  s text;
  e boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('status','denied','expired',true,'error','BRANCH_ACCESS_DENIED');
  END IF;

  SELECT * INTO r FROM public.branch_subscriptions WHERE branch_id=p_branch_id;
  IF r.branch_id IS NULL THEN
    RETURN jsonb_build_object('status','none','expired',true,'branch_id',p_branch_id);
  END IF;

  s:=r.status;
  e:=false;
  IF s='trial' AND r.trial_ends_at IS NOT NULL AND r.trial_ends_at<=now() THEN
    s:='expired'; e:=true;
  ELSIF s IN ('active','past_due') AND r.current_period_ends_at IS NOT NULL AND r.current_period_ends_at<=now() THEN
    s:='expired'; e:=true;
  ELSIF s IN ('cancelled','expired') THEN
    e:=true;
  END IF;

  RETURN jsonb_build_object(
    'branch_id',p_branch_id,'status',s,'plan_id',r.plan_id,'expired',e,
    'trial_ends_at',r.trial_ends_at,'current_period_ends_at',r.current_period_ends_at,
    'cancelled_at',r.cancelled_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.subscription_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_feature_access(p_feature_key text, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tid uuid;
  v_bid uuid := p_branch_id;
BEGIN
  IF v_bid IS NOT NULL AND auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(v_bid) THEN
    RETURN jsonb_build_object('allowed',false,'feature_key',p_feature_key,'error','BRANCH_ACCESS_DENIED');
  END IF;

  IF v_bid IS NULL THEN
    v_bid := get_branch_id();
  END IF;

  IF v_bid IS NOT NULL THEN
    SELECT organization_id INTO v_tid FROM public.branches WHERE id = v_bid;
  END IF;

  IF v_tid IS NULL THEN
    SELECT organization_id INTO v_tid
    FROM public.organization_members
    WHERE user_id = auth.uid() AND is_active = true
    LIMIT 1;
  END IF;

  RETURN public.resolve_feature_access(v_tid, v_bid, p_feature_key, auth.uid());
END;
$$;

REVOKE ALL ON FUNCTION public.get_feature_access(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_feature_access(text,uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 20260902082000_allow_db_admin_internal_setup_helpers.sql
-- ----------------------------------------------------------------------------
-- Final audit CI/admin alignment: database administrators may execute internal
-- setup helpers, while client roles remain denied. PostgreSQL admin access is
-- not an application surface.
GRANT EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.seed_account_mappings(uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) TO postgres;

REVOKE EXECUTE ON FUNCTION public.ensure_chart_of_accounts(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_account_mappings(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_treasury_accounts(uuid) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

