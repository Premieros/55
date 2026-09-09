-- ============================================================================
-- PREMIER / JOHN-S POS & ERP - COMPLETE DATABASE SCHEMA & RPCS
-- Consolidated Build Script generated on 2026-09-06T13:52:49.808Z
-- Contains all 237 migrations in canonical order
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- MIGRATION: 049_demo_data_management.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 049. Demo data management (seed + delete, per branch)
-- ----------------------------------------------------------------------------
-- Branch admins / super admins need a safe, reversible way to populate a branch
-- with throwaway test data for trying the POS. Every demo row carries the
-- is_demo flag (default false, so nothing real is ever flagged) and:
--
--   * seed_demo_data(p_branch_id)   - idempotent: seeds once per branch
--   * delete_demo_data(p_branch_id) - removes demo business data + any
--                                     orders/sales that reference it
--
-- Deletion order matters for FKs:
--   production_orders reference products with NO ACTION  -> delete first
--   sales / orders reference customers, tables, products -> delete next
--   demo customers / products / categories / tables / areas -> last
--
-- Users/auth are intentionally out of scope: a demo cashier account is created
-- by an administrator directly and is not removed by this function.
-- ============================================================================

ALTER TABLE public.dining_areas   ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.dining_tables  ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.customers      ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.categories     ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;
ALTER TABLE public.products       ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_demo_products_branch
  ON public.products (branch_id) WHERE is_demo;
CREATE INDEX IF NOT EXISTS idx_demo_tables_branch
  ON public.dining_tables (branch_id) WHERE is_demo;

-- ============================================================================
-- seed_demo_data: one call seeds an area, tables, a category, products and
-- customers for the branch. Safe to call repeatedly (no-op if already seeded).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.seed_demo_data(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_area_id uuid;
  v_cat_id  uuid;
  v_areas   integer := 0;
  v_tables  integer := 0;
  v_cats    integer := 0;
  v_prods   integer := 0;
  v_custs   integer := 0;
BEGIN
  IF NOT is_pos_admin() AND NOT (is_branch_manager() AND get_branch_id() = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  -- Idempotent: a branch with demo rows already present is left untouched.
  IF EXISTS (SELECT 1 FROM public.dining_areas WHERE branch_id = p_branch_id AND is_demo)
     OR EXISTS (SELECT 1 FROM public.products WHERE branch_id = p_branch_id AND is_demo) THEN
    RETURN jsonb_build_object('success', true, 'seeded', 0, 'existing', true);
  END IF;

  INSERT INTO public.dining_areas (branch_id, name, is_demo)
  VALUES (p_branch_id, 'منطقة تجريبية', true)
  RETURNING id INTO v_area_id;
  v_areas := v_areas + 1;

  INSERT INTO public.dining_tables (branch_id, area_id, name, capacity, is_demo) VALUES
    (p_branch_id, v_area_id, 'طاولة تجريبية 1', 4, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 2', 4, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 3', 2, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 4', 8, true);
  v_tables := 4;

  INSERT INTO public.categories (branch_id, name, name_en, is_demo)
  VALUES (p_branch_id, 'أصناف تجريبية', 'Demo items', true)
  RETURNING id INTO v_cat_id;
  v_cats := 1;

  INSERT INTO public.products (
    branch_id, category_id, name, name_en, sku, barcode,
    cost_price, sale_price, wholesale_price, product_type, is_demo, low_stock_threshold, is_active
  ) VALUES
    (p_branch_id, v_cat_id, 'قهوة تركية',     'Turkish coffee',   'DEMO-001', 'DEMO00000001', 8,  25, 20, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'قهوة فرنسية',    'French coffee',    'DEMO-002', 'DEMO00000002', 7,  20, 16, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'شاي',            'Tea',              'DEMO-003', 'DEMO00000003', 4,  15, 12, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'عصير برتقال',    'Orange juice',     'DEMO-004', 'DEMO00000004', 10, 30, 24, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'بيبسي',          'Pepsi',            'DEMO-005', 'DEMO00000005', 5,  15, 12, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'بيتزا صغيرة',    'Small pizza',      'DEMO-006', 'DEMO00000006', 20, 45, 36, 'ready', true, 10, true),
    (p_branch_id, v_cat_id, 'برجر',           'Burger',           'DEMO-007', 'DEMO00000007', 28, 60, 48, 'ready', true, 10, true),
    (p_branch_id, v_cat_id, 'سلطة سيزر',      'Caesar salad',     'DEMO-008', 'DEMO00000008', 15, 35, 28, 'ready', true, 10, true);
  v_prods := 8;

  INSERT INTO public.customers (branch_id, name, phone, is_demo) VALUES
    (p_branch_id, 'عميل تجريبي 1', '01111111111', true),
    (p_branch_id, 'عميل تجريبي 2', '01122222222', true);
  v_custs := 2;

  RETURN jsonb_build_object('success', true, 'seeded', 1, 'existing', false,
    'areas', v_areas, 'tables', v_tables, 'categories', v_cats,
    'products', v_prods, 'customers', v_custs);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'SEED_FAILED', 'detail', SQLERRM);
END;
$fn$;

-- ============================================================================
-- delete_demo_data: removes demo business rows and every order/sale that
-- references them (referencing rows are demo artifacts only, but the branch
-- scope keeps the operation safe).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_demo_data(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  n_prod_orders integer := 0;
  n_shift_ops   integer := 0;
  n_sales       integer := 0;
  n_orders      integer := 0;
  n_custs       integer := 0;
  n_prods       integer := 0;
  n_cats        integer := 0;
  n_tables      integer := 0;
  n_areas       integer := 0;
BEGIN
  IF NOT is_pos_admin() AND NOT (is_branch_manager() AND get_branch_id() = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- production_orders has a NO ACTION FK on product_id -> delete them first.
  DELETE FROM public.production_orders
  WHERE product_id IN (
    SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo
  );
  GET DIAGNOSTICS n_prod_orders = ROW_COUNT;

  -- shift_operations are not FK'd to sales: clear the sale entries that point
  -- at sales we are about to delete so the drawer stays consistent.
  DELETE FROM public.shift_operations
  WHERE operation_type = 'sale'
    AND reference_id IN (
      SELECT s.id FROM public.sales s
      WHERE s.branch_id = p_branch_id
        AND (s.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
             OR s.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
             OR EXISTS (SELECT 1 FROM public.sale_items si
                        WHERE si.sale_id = s.id
                          AND si.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
    );
  GET DIAGNOSTICS n_shift_ops = ROW_COUNT;

  DELETE FROM public.sales WHERE id IN (
    SELECT s.id FROM public.sales s
    WHERE s.branch_id = p_branch_id
      AND (s.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
           OR s.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
           OR EXISTS (SELECT 1 FROM public.sale_items si
                      WHERE si.sale_id = s.id
                        AND si.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
  );
  GET DIAGNOSTICS n_sales = ROW_COUNT;

  DELETE FROM public.orders WHERE id IN (
    SELECT o.id FROM public.orders o
    WHERE o.branch_id = p_branch_id
      AND (o.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
           OR o.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
           OR EXISTS (SELECT 1 FROM public.order_items oi
                      WHERE oi.order_id = o.id
                        AND oi.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
  );
  GET DIAGNOSTICS n_orders = ROW_COUNT;

  DELETE FROM public.customers     WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_custs = ROW_COUNT;

  DELETE FROM public.products      WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_prods = ROW_COUNT;

  DELETE FROM public.categories    WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_cats = ROW_COUNT;

  DELETE FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_tables = ROW_COUNT;

  DELETE FROM public.dining_areas  WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_areas = ROW_COUNT;

  RETURN jsonb_build_object('success', true,
    'production_orders', n_prod_orders, 'shift_operations', n_shift_ops,
    'sales', n_sales, 'orders', n_orders, 'customers', n_custs,
    'products', n_prods, 'categories', n_cats, 'tables', n_tables, 'areas', n_areas);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'DELETE_FAILED', 'detail', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.seed_demo_data(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_demo_data(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 049_remove_duplicate_users_branch_fk.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 049. Remove duplicate users.branch_id foreign key
-- ----------------------------------------------------------------------------
-- The production schema previously contained two foreign keys for the same
-- relationship: users.branch_id -> branches.id. Keep the strict RBAC FK and
-- remove the legacy duplicate so PostgREST cannot expose an ambiguous
-- relationship for this column.
--
-- Idempotent: safe to apply to databases where the legacy constraint is
-- already absent (including the current production database).
-- ============================================================================

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_branch_id_fkey;


-- ----------------------------------------------------------------------------
-- MIGRATION: 050_demo_data_inventory.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 050. Demo data: sellable inventory + full cascade cleanup
-- ----------------------------------------------------------------------------
-- The initial demo seeder (049) created products/tables/customers but the POS
-- product grid disables products with zero stock, so demo rows were not
-- sellable. This migration upgrades the two functions:
--
--   * seed_demo_data   - ensures a branch warehouse and inserts inventory rows
--                        for every demo product (so they are clickable/sellable)
--   * delete_demo_data - also clears the NO ACTION FKs (production_waste,
--                        warehouse_transfer_items) and any warehouse the seeder
--                        created (is_demo), plus inventory that points at it
-- ============================================================================

ALTER TABLE public.warehouses ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

-- ============================================================================
-- seed_demo_data (upgrade)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.seed_demo_data(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_area_id    uuid;
  v_cat_id     uuid;
  v_warehouse  uuid;
  v_prod       record;
  v_areas      integer := 0;
  v_tables     integer := 0;
  v_cats       integer := 0;
  v_prods      integer := 0;
  v_custs      integer := 0;
  v_inv        integer := 0;
  v_wh         integer := 0;
BEGIN
  IF NOT is_pos_admin() AND NOT (is_branch_manager() AND get_branch_id() = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  -- Idempotent: a branch with demo rows already present is left untouched.
  IF EXISTS (SELECT 1 FROM public.dining_areas WHERE branch_id = p_branch_id AND is_demo)
     OR EXISTS (SELECT 1 FROM public.products WHERE branch_id = p_branch_id AND is_demo) THEN
    RETURN jsonb_build_object('success', true, 'seeded', 0, 'existing', true);
  END IF;

  -- Warehouse: reuse the first active one, otherwise create a demo one.
  SELECT id INTO v_warehouse
  FROM public.warehouses
  WHERE branch_id = p_branch_id AND is_active
  ORDER BY created_at
  LIMIT 1;
  IF v_warehouse IS NULL THEN
    INSERT INTO public.warehouses (branch_id, name, is_active, is_demo)
    VALUES (p_branch_id, 'مستودع تجريبي', true, true)
    RETURNING id INTO v_warehouse;
    v_wh := 1;
  END IF;

  INSERT INTO public.dining_areas (branch_id, name, is_demo)
  VALUES (p_branch_id, 'منطقة تجريبية', true)
  RETURNING id INTO v_area_id;
  v_areas := v_areas + 1;

  INSERT INTO public.dining_tables (branch_id, area_id, name, capacity, is_demo) VALUES
    (p_branch_id, v_area_id, 'طاولة تجريبية 1', 4, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 2', 4, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 3', 2, true),
    (p_branch_id, v_area_id, 'طاولة تجريبية 4', 8, true);
  v_tables := 4;

  INSERT INTO public.categories (branch_id, name, name_en, is_demo)
  VALUES (p_branch_id, 'أصناف تجريبية', 'Demo items', true)
  RETURNING id INTO v_cat_id;
  v_cats := 1;

  INSERT INTO public.products (
    branch_id, category_id, name, name_en, sku, barcode,
    cost_price, sale_price, wholesale_price, product_type, is_demo, low_stock_threshold, is_active
  ) VALUES
    (p_branch_id, v_cat_id, 'قهوة تركية',     'Turkish coffee',   'DEMO-001', 'DEMO00000001', 8,  25, 20, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'قهوة فرنسية',    'French coffee',    'DEMO-002', 'DEMO00000002', 7,  20, 16, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'شاي',            'Tea',              'DEMO-003', 'DEMO00000003', 4,  15, 12, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'عصير برتقال',    'Orange juice',     'DEMO-004', 'DEMO00000004', 10, 30, 24, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'بيبسي',          'Pepsi',            'DEMO-005', 'DEMO00000005', 5,  15, 12, 'ready', true, 20, true),
    (p_branch_id, v_cat_id, 'بيتزا صغيرة',    'Small pizza',      'DEMO-006', 'DEMO00000006', 20, 45, 36, 'ready', true, 10, true),
    (p_branch_id, v_cat_id, 'برجر',           'Burger',           'DEMO-007', 'DEMO00000007', 28, 60, 48, 'ready', true, 10, true),
    (p_branch_id, v_cat_id, 'سلطة سيزر',      'Caesar salad',     'DEMO-008', 'DEMO00000008', 15, 35, 28, 'ready', true, 10, true);
  v_prods := 8;

  INSERT INTO public.customers (branch_id, name, phone, is_demo) VALUES
    (p_branch_id, 'عميل تجريبي 1', '01111111111', true),
    (p_branch_id, 'عميل تجريبي 2', '01122222222', true);
  v_custs := 2;

  -- Stock every demo product so the POS grid shows them as sellable.
  INSERT INTO public.inventory (id, product_id, warehouse_id, quantity, branch_id)
  SELECT gen_random_uuid(), p.id, v_warehouse, 100, p.branch_id
  FROM public.products p
  WHERE p.branch_id = p_branch_id AND p.is_demo;
  GET DIAGNOSTICS v_inv = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'seeded', 1, 'existing', false,
    'areas', v_areas, 'tables', v_tables, 'categories', v_cats,
    'products', v_prods, 'customers', v_custs, 'inventory', v_inv,
    'warehouses', v_wh);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'SEED_FAILED', 'detail', SQLERRM);
END;
$fn$;

-- ============================================================================
-- delete_demo_data (upgrade)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_demo_data(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  n_prod_orders integer := 0;
  n_prod_waste  integer := 0;
  n_tr_items    integer := 0;
  n_shift_ops   integer := 0;
  n_sales       integer := 0;
  n_orders      integer := 0;
  n_custs       integer := 0;
  n_prods       integer := 0;
  n_cats        integer := 0;
  n_tables      integer := 0;
  n_areas       integer := 0;
  n_inv         integer := 0;
  n_wh          integer := 0;
BEGIN
  IF NOT is_pos_admin() AND NOT (is_branch_manager() AND get_branch_id() = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  -- production_orders has a NO ACTION FK on product_id -> delete them first.
  DELETE FROM public.production_orders
  WHERE product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo);
  GET DIAGNOSTICS n_prod_orders = ROW_COUNT;

  DELETE FROM public.production_waste
  WHERE product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo);
  GET DIAGNOSTICS n_prod_waste = ROW_COUNT;

  DELETE FROM public.warehouse_transfer_items
  WHERE product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo);
  GET DIAGNOSTICS n_tr_items = ROW_COUNT;

  -- shift_operations are not FK'd to sales: clear the sale entries that point
  -- at sales we are about to delete so the drawer stays consistent.
  DELETE FROM public.shift_operations
  WHERE operation_type = 'sale'
    AND reference_id IN (
      SELECT s.id FROM public.sales s
      WHERE s.branch_id = p_branch_id
        AND (s.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
             OR s.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
             OR EXISTS (SELECT 1 FROM public.sale_items si
                        WHERE si.sale_id = s.id
                          AND si.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
    );
  GET DIAGNOSTICS n_shift_ops = ROW_COUNT;

  DELETE FROM public.sales WHERE id IN (
    SELECT s.id FROM public.sales s
    WHERE s.branch_id = p_branch_id
      AND (s.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
           OR s.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
           OR EXISTS (SELECT 1 FROM public.sale_items si
                      WHERE si.sale_id = s.id
                        AND si.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
  );
  GET DIAGNOSTICS n_sales = ROW_COUNT;

  DELETE FROM public.orders WHERE id IN (
    SELECT o.id FROM public.orders o
    WHERE o.branch_id = p_branch_id
      AND (o.table_id IN (SELECT id FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo)
           OR o.customer_id IN (SELECT id FROM public.customers WHERE branch_id = p_branch_id AND is_demo)
           OR EXISTS (SELECT 1 FROM public.order_items oi
                      WHERE oi.order_id = o.id
                        AND oi.product_id IN (SELECT id FROM public.products WHERE branch_id = p_branch_id AND is_demo)))
  );
  GET DIAGNOSTICS n_orders = ROW_COUNT;

  DELETE FROM public.customers     WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_custs = ROW_COUNT;

  -- Products cascade into inventory/inventory_ledger/stock_transactions/etc.
  DELETE FROM public.products      WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_prods = ROW_COUNT;

  DELETE FROM public.categories    WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_cats = ROW_COUNT;

  DELETE FROM public.dining_tables WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_tables = ROW_COUNT;

  DELETE FROM public.dining_areas  WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_areas = ROW_COUNT;

  -- Any inventory pointing at a demo warehouse, then the warehouse itself.
  DELETE FROM public.inventory WHERE warehouse_id IN (
    SELECT id FROM public.warehouses WHERE branch_id = p_branch_id AND is_demo
  );
  GET DIAGNOSTICS n_inv = ROW_COUNT;

  DELETE FROM public.warehouses    WHERE branch_id = p_branch_id AND is_demo;
  GET DIAGNOSTICS n_wh = ROW_COUNT;

  RETURN jsonb_build_object('success', true,
    'production_orders', n_prod_orders, 'production_waste', n_prod_waste,
    'transfer_items', n_tr_items, 'shift_operations', n_shift_ops,
    'sales', n_sales, 'orders', n_orders, 'customers', n_custs,
    'products', n_prods, 'categories', n_cats, 'tables', n_tables, 'areas', n_areas,
    'inventory', n_inv, 'warehouses', n_wh);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'DELETE_FAILED', 'detail', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.seed_demo_data(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_demo_data(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 050_system_control_center.sql
-- ----------------------------------------------------------------------------
-- 050. Centralized System Control Center
-- Stores configurable business/UI behavior without changing application code.
CREATE TABLE IF NOT EXISTS public.system_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "system_settings_select_admin" ON public.system_settings;
CREATE POLICY "system_settings_select_admin" ON public.system_settings
  FOR SELECT TO authenticated
  USING (is_pos_admin());

DROP POLICY IF EXISTS "system_settings_insert_admin" ON public.system_settings;
CREATE POLICY "system_settings_insert_admin" ON public.system_settings
  FOR INSERT TO authenticated
  WITH CHECK (is_pos_admin());

DROP POLICY IF EXISTS "system_settings_update_admin" ON public.system_settings;
CREATE POLICY "system_settings_update_admin" ON public.system_settings
  FOR UPDATE TO authenticated
  USING (is_pos_admin())
  WITH CHECK (is_pos_admin());

INSERT INTO public.system_settings (id, config)
VALUES (1, '{
  "general": {"default_language":"ar","default_currency":"EGP","date_format":"DD/MM/YYYY","time_format":"24h","week_starts":"saturday"},
  "pos": {"default_order_type":"quick","ask_table_people":true,"allow_hold":true,"allow_split":true,"allow_discount":true,"allow_price_override":false,"require_customer":false,"auto_print":false,"auto_close_order":false,"show_product_images":true},
  "order_types": {"dine_in":true,"delivery":true,"takeaway":true,"quick":true,"car":true},
  "payments": {"cash":true,"card":true,"wallet":true,"credit":false,"other":false,"default_method":"cash"},
  "sales": {"tax_enabled":false,"tax_rate":0,"discount_max_percent":100,"allow_returns":true,"return_requires_approval":false,"negative_stock":false,"invoice_prefix":"INV-"},
  "inventory": {"low_stock_threshold":5,"allow_negative":false,"auto_deduct_on_sale":true,"auto_deduct_components":true,"allow_zero_cost":false,"enable_expiry":false},
  "purchases": {"auto_post_inventory":true,"require_receiving":false,"allow_edit_posted":false,"default_payment_status":"unpaid"},
  "manufacturing": {"auto_consume_components":true,"allow_overproduction":false,"require_approval":false,"rounding_decimals":3},
  "accounting": {"auto_journal":true,"fiscal_year_start":"01-01","decimal_places":2,"cost_method":"weighted_average"},
  "customers_suppliers": {"allow_customer_credit":false,"allow_supplier_credit":true,"credit_limit_default":0,"require_phone":false},
  "printing": {"paper":"80mm","copies":1,"show_logo":true,"show_tax":true,"show_cashier":true,"show_customer":true,"show_barcode":true,"footer":"شكراً لزيارتكم"},
  "dashboard": {"default_range":"today","show_sales":true,"show_expenses":true,"show_profit":true,"show_inventory":true,"show_top_products":true,"show_recent_sales":true,"show_payment_chart":true,"show_employee_chart":true},
  "reports": {"default_range":"today","default_rows":25,"show_zero_rows":false,"allow_export_excel":true,"allow_export_pdf":true,"allow_print":true},
  "notifications": {"low_stock":true,"shift_open":true,"shift_close":true,"purchase_due":true,"customer_due":false},
  "security": {"session_timeout_minutes":480,"max_login_attempts":5,"lockout_minutes":15,"require_password_change":false,"audit_all_changes":true},
  "ui": {"compact_tables":false,"animations":true,"confirm_delete":true,"confirm_post":true,"rtl":true,"show_help":true}
}'::jsonb)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.touch_system_settings()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  NEW.updated_by = auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_system_settings ON public.system_settings;
CREATE TRIGGER trg_touch_system_settings
BEFORE UPDATE ON public.system_settings
FOR EACH ROW EXECUTE FUNCTION public.touch_system_settings();


-- ----------------------------------------------------------------------------
-- MIGRATION: 051_system_settings_compatibility.sql
-- ----------------------------------------------------------------------------
-- 051. Keep the existing centralized JSONB settings schema compatible with the System Control Center.
-- This migration is intentionally non-destructive: it preserves the existing config row.

CREATE TABLE IF NOT EXISTS public.system_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.system_settings
  ADD COLUMN IF NOT EXISTS config jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.system_settings
  ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.system_settings
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "system_settings_select_admin" ON public.system_settings;
CREATE POLICY "system_settings_select_admin" ON public.system_settings
  FOR SELECT TO authenticated
  USING (is_pos_admin());

DROP POLICY IF EXISTS "system_settings_insert_admin" ON public.system_settings;
CREATE POLICY "system_settings_insert_admin" ON public.system_settings
  FOR INSERT TO authenticated
  WITH CHECK (is_pos_admin());

DROP POLICY IF EXISTS "system_settings_update_admin" ON public.system_settings;
CREATE POLICY "system_settings_update_admin" ON public.system_settings
  FOR UPDATE TO authenticated
  USING (is_pos_admin())
  WITH CHECK (is_pos_admin());

INSERT INTO public.system_settings (id, config)
VALUES (1, '{}'::jsonb)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.touch_system_settings()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  NEW.updated_by = auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_system_settings ON public.system_settings;
CREATE TRIGGER trg_touch_system_settings
BEFORE UPDATE ON public.system_settings
FOR EACH ROW EXECUTE FUNCTION public.touch_system_settings();

-- Refresh PostgREST's schema cache after the compatibility migration.
NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 052_system_integrity_checks.sql
-- ----------------------------------------------------------------------------
-- PHASE 0.2: read-only integrity audit helpers
-- These functions NEVER modify business data. They return counts only.

create or replace function public.system_integrity_audit()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb := '{}'::jsonb;
  n bigint;
begin
  -- Orphan / consistency checks. Missing tables are reported as null rather than
  -- making the whole audit fail on installations with optional modules.
  if to_regclass('public.orders') is not null and to_regclass('public.order_items') is not null then
    select count(*) into n from public.orders o
    where not exists (select 1 from public.order_items i where i.order_id = o.id)
      and coalesce(o.status, '') not in ('cancelled','void','deleted');
    result := result || jsonb_build_object('orders_without_items', n);
  end if;

  if to_regclass('public.order_items') is not null and to_regclass('public.products') is not null then
    select count(*) into n from public.order_items i
    where i.product_id is not null
      and not exists (select 1 from public.products p where p.id = i.product_id);
    result := result || jsonb_build_object('order_items_missing_product', n);
  end if;

  if to_regclass('public.products') is not null and to_regclass('public.branches') is not null then
    select count(*) into n from public.products p
    where p.branch_id is not null
      and not exists (select 1 from public.branches b where b.id = p.branch_id);
    result := result || jsonb_build_object('products_missing_branch', n);
  end if;

  if to_regclass('public.inventory') is not null and to_regclass('public.products') is not null then
    select count(*) into n from public.inventory s
    where s.product_id is not null
      and not exists (select 1 from public.products p where p.id = s.product_id);
    result := result || jsonb_build_object('inventory_missing_product', n);
  elsif to_regclass('public.warehouse_stock') is not null and to_regclass('public.products') is not null then
    select count(*) into n from public.warehouse_stock s
    where s.product_id is not null
      and not exists (select 1 from public.products p where p.id = s.product_id);
    result := result || jsonb_build_object('warehouse_stock_missing_product', n);
  end if;

  if to_regclass('public.purchase_items') is not null and to_regclass('public.purchases') is not null then
    select count(*) into n from public.purchase_items pi
    where pi.purchase_id is not null
      and not exists (select 1 from public.purchases p where p.id = pi.purchase_id);
    result := result || jsonb_build_object('purchase_items_missing_purchase', n);
  end if;

  if to_regclass('public.users') is not null and to_regclass('public.branches') is not null then
    select count(*) into n from public.users u
    where u.branch_id is not null
      and not exists (select 1 from public.branches b where b.id = u.branch_id);
    result := result || jsonb_build_object('users_missing_branch', n);
  end if;

  return result;
end;
$$;

revoke all on function public.system_integrity_audit() from public;
grant execute on function public.system_integrity_audit() to authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 053_phase8_12_hardening.sql
-- ----------------------------------------------------------------------------
-- PHASE 8-12: production hardening
-- Branch ownership is mandatory for every user.
ALTER TABLE public.users ALTER COLUMN branch_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_branch_id ON public.users(branch_id);
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_branch_fk_strict;
ALTER TABLE public.users ADD CONSTRAINT users_branch_fk_strict
  FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE RESTRICT;

-- Prevent invalid financial/inventory values.
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_positive_prices;
ALTER TABLE public.products ADD CONSTRAINT products_positive_prices
  CHECK (COALESCE(cost_price,0) >= 0 AND COALESCE(sale_price,0) >= 0 AND COALESCE(wholesale_price,0) >= 0);
ALTER TABLE public.sale_items DROP CONSTRAINT IF EXISTS sale_items_positive_values;
ALTER TABLE public.sale_items ADD CONSTRAINT sale_items_positive_values
  CHECK (quantity > 0 AND unit_price >= 0 AND COALESCE(discount_amount,0) >= 0
         AND COALESCE(refunded_quantity,0) >= 0 AND COALESCE(refunded_amount,0) >= 0);
ALTER TABLE public.purchase_items DROP CONSTRAINT IF EXISTS purchase_items_positive_values;
ALTER TABLE public.purchase_items ADD CONSTRAINT purchase_items_positive_values
  CHECK (quantity > 0 AND unit_cost >= 0 AND COALESCE(total,0) >= 0
         AND COALESCE(returned_quantity,0) >= 0 AND COALESCE(returned_amount,0) >= 0);
ALTER TABLE public.inventory DROP CONSTRAINT IF EXISTS inventory_nonnegative_quantity;
ALTER TABLE public.inventory ADD CONSTRAINT inventory_nonnegative_quantity CHECK (quantity >= 0);
ALTER TABLE public.shifts DROP CONSTRAINT IF EXISTS shifts_nonnegative_amounts;
ALTER TABLE public.shifts ADD CONSTRAINT shifts_nonnegative_amounts
  CHECK (opening_amount >= 0 AND expected_amount >= 0 AND actual_amount >= 0);

-- Performance indexes for branch-scoped reporting and operations.
CREATE INDEX IF NOT EXISTS idx_sales_branch_created_at ON public.sales(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id ON public.sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_product_id ON public.sale_items(product_id);
CREATE INDEX IF NOT EXISTS idx_purchases_branch_created_at ON public.purchases(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase_id ON public.purchase_items(purchase_id);
CREATE INDEX IF NOT EXISTS idx_inventory_branch_product ON public.inventory(branch_id,product_id);
CREATE INDEX IF NOT EXISTS idx_expenses_branch_date ON public.expenses(branch_id,expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_journal_entries_branch_date ON public.journal_entries(branch_id,entry_date DESC);
CREATE INDEX IF NOT EXISTS idx_orders_branch_created_at ON public.orders(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_branch_created_at ON public.inventory_ledger(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_branch_created_at ON public.audit_log(branch_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_customers_branch_id ON public.customers(branch_id);
CREATE INDEX IF NOT EXISTS idx_suppliers_branch_id ON public.suppliers(branch_id);
CREATE INDEX IF NOT EXISTS idx_products_branch_category ON public.products(branch_id,category_id);
CREATE INDEX IF NOT EXISTS idx_shifts_branch_status ON public.shifts(branch_id,status);


-- ----------------------------------------------------------------------------
-- MIGRATION: 054_ci_rls_admin_branch_fixture.sql
-- ----------------------------------------------------------------------------
-- CI-only compatibility for the strict branch ownership rule.
--
-- Production rule: public.users.branch_id is NOT NULL (053) and every real
-- user must belong to a branch. The RLS integration fixture historically
-- created super_admin/owner rows with NULL branch_id because those roles can
-- see all branches. That fixture is now incompatible with the production
-- invariant.
--
-- The CI database is identified by auth.is_ci_stub(), which exists only in
-- supabase/ci/stub_auth.sql and is never installed on a real Supabase project.
-- In CI only, assign a missing admin fixture branch to the first branch created
-- by the fixture. This keeps branch_id mandatory while preserving admin-wide
-- visibility semantics. No production database behavior is changed.

DO $$
BEGIN
  IF to_regprocedure('auth.is_ci_stub()') IS NOT NULL THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION public.ci_assign_admin_fixture_branch()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $body$
      BEGIN
        IF NEW.branch_id IS NULL AND NEW.role IN ('super_admin', 'owner') THEN
          SELECT b.id
            INTO NEW.branch_id
            FROM public.branches b
            ORDER BY b.created_at ASC, b.id ASC
            LIMIT 1;

          IF NEW.branch_id IS NULL THEN
            RAISE EXCEPTION 'CI RLS fixture requires at least one branch before creating an admin user';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $body$;
    $fn$;

    EXECUTE 'DROP TRIGGER IF EXISTS trg_ci_assign_admin_fixture_branch ON public.users';
    EXECUTE $sql$
      CREATE TRIGGER trg_ci_assign_admin_fixture_branch
      BEFORE INSERT ON public.users
      FOR EACH ROW
      EXECUTE FUNCTION public.ci_assign_admin_fixture_branch()
    $sql$;
  END IF;
END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 055_subscriptions.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 055. Subscriptions: 14-day trial + paid plans (Basic / Standard / Enterprise)
-- ----------------------------------------------------------------------------
-- Adds the subscription layer that gates selling per branch:
--
--   1. subscription_plans        – the three paid tiers (EGP, monthly & yearly).
--   2. branch_subscriptions      – one subscription row per branch (PK=branch_id);
--      status: trial → active / past_due / cancelled / expired.
--   3. subscription_status()     – effective status of a branch (trial window /
--      billing period aware). SECURITY DEFINER so anon/authenticated can query.
--   4. subscription_expired()    – boolean helper used by the sale guard.
--   5. register_branch(...)      – anon self-service signup: creates branch +
--      main warehouse + branch_settings + owner auth account (email confirmed)
--      + a 14-day trial subscription, atomically. Reuses create_user(), which
--      gains an app.register_branch GUC bypass mirroring app.login_guard_bypass.
--   6. activate_subscription()   – admin-only: start/cancel a plan.
--   7. process_sale()            – returns SUBSCRIPTION_EXPIRED before any write
--      when the branch subscription is not active/live-trial. super_admin only
--      is exempt (owners manage plans, they do not bypass the gate).
--
-- Backfill: every existing branch gets an active trial starting now, so nothing
-- already deployed is locked out.
--
-- Additive + idempotent (safe to re-run; the migration runner also gates it by
-- checksum). create_user() and guard_user_role_changes() are re-created with the
-- register_branch bypass; process_sale() is re-created with the gate on top of
-- the exact 047 body.
-- ============================================================================

-- ============ 1. SUBSCRIPTION PLANS ============
CREATE TABLE IF NOT EXISTS public.subscription_plans (
  id text PRIMARY KEY,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  monthly_price_egp numeric(10,2) NOT NULL,
  yearly_price_egp numeric(10,2) NOT NULL,
  features jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.subscription_plans (id, name_ar, name_en, monthly_price_egp, yearly_price_egp, features)
VALUES
  ('basic',      'الأساسية', 'Basic',      299, 2990,
    '["Users: 2","Warehouses: 1","Inventory & sales"]'::jsonb),
  ('standard',   'القياسية', 'Standard',   599, 5990,
    '["Users: 5","Warehouses: 3","Accounting & reports"]'::jsonb),
  ('enterprise', 'المتقدمة', 'Enterprise', 999, 9990,
    '["Users: unlimited","Multi-branch","Full suite + priority support"]'::jsonb)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "plans_read_all" ON public.subscription_plans;
CREATE POLICY "plans_read_all" ON public.subscription_plans FOR SELECT TO anon, authenticated
  USING (true);

GRANT SELECT ON public.subscription_plans TO anon, authenticated, service_role;

-- ============ 2. BRANCH SUBSCRIPTIONS ============
CREATE TABLE IF NOT EXISTS public.branch_subscriptions (
  branch_id uuid PRIMARY KEY REFERENCES public.branches(id) ON DELETE CASCADE,
  plan_id text REFERENCES public.subscription_plans(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'trial',
  trial_starts_at timestamptz NOT NULL DEFAULT now(),
  trial_ends_at timestamptz,
  current_period_starts_at timestamptz,
  current_period_ends_at timestamptz,
  cancel_at timestamptz,
  cancelled_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT branch_subscriptions_status_check
    CHECK (status IN ('trial', 'active', 'past_due', 'cancelled', 'expired'))
);

CREATE INDEX IF NOT EXISTS idx_branch_subscriptions_status ON public.branch_subscriptions (status);

ALTER TABLE public.branch_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subs_select_own" ON public.branch_subscriptions;
CREATE POLICY "subs_select_own" ON public.branch_subscriptions FOR SELECT TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id());

DROP POLICY IF EXISTS "subs_admin_insert" ON public.branch_subscriptions;
CREATE POLICY "subs_admin_insert" ON public.branch_subscriptions FOR INSERT TO authenticated
  WITH CHECK (is_pos_admin());

DROP POLICY IF EXISTS "subs_admin_update" ON public.branch_subscriptions;
CREATE POLICY "subs_admin_update" ON public.branch_subscriptions FOR UPDATE TO authenticated
  USING (is_pos_admin()) WITH CHECK (is_pos_admin());

DROP POLICY IF EXISTS "subs_admin_delete" ON public.branch_subscriptions;
CREATE POLICY "subs_admin_delete" ON public.branch_subscriptions FOR DELETE TO authenticated
  USING (is_pos_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.branch_subscriptions TO authenticated, service_role;

-- ============ 3. BACKFILL: existing branches start an active trial ============
INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
SELECT b.id, 'trial', now(), now() + interval '14 days'
FROM public.branches b
WHERE NOT EXISTS (SELECT 1 FROM public.branch_subscriptions s WHERE s.branch_id = b.id);

-- ============ 4. STATUS HELPERS ============
CREATE OR REPLACE FUNCTION public.subscription_status(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.branch_subscriptions%ROWTYPE;
  v_status text;
  v_expired boolean;
BEGIN
  SELECT * INTO v_row FROM public.branch_subscriptions WHERE branch_id = p_branch_id;

  IF v_row.branch_id IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'none', 'plan_id', NULL,
      'expired', true, 'trial_ends_at', NULL, 'current_period_ends_at', NULL
    );
  END IF;

  v_status := v_row.status;
  v_expired := false;

  IF v_status IN ('trial', 'active', 'past_due') THEN
    IF v_status = 'trial' THEN
      IF v_row.trial_ends_at IS NOT NULL AND v_row.trial_ends_at <= now() THEN
        v_status := 'expired';
        v_expired := true;
      END IF;
    ELSE
      IF v_row.current_period_ends_at IS NOT NULL AND v_row.current_period_ends_at <= now() THEN
        v_status := 'expired';
        v_expired := true;
      END IF;
    END IF;
  ELSE
    v_expired := true;
  END IF;

  RETURN jsonb_build_object(
    'branch_id', p_branch_id,
    'status', v_status,
    'plan_id', v_row.plan_id,
    'expired', v_expired,
    'trial_ends_at', v_row.trial_ends_at,
    'current_period_ends_at', v_row.current_period_ends_at,
    'cancelled_at', v_row.cancelled_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.subscription_expired(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (public.subscription_status(p_branch_id)->>'expired')::boolean;
$$;

GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.subscription_expired(uuid) TO anon, authenticated, service_role;

-- ============ 5. ACTIVATE / CANCEL PLAN (admin only) ============
CREATE OR REPLACE FUNCTION public.activate_subscription(
  p_branch_id uuid,
  p_plan_id text,
  p_billing_period text DEFAULT 'monthly',
  p_activate boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan public.subscription_plans%ROWTYPE;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_price numeric(10,2);
BEGIN
  IF NOT is_pos_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF p_branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT p_activate THEN
    UPDATE public.branch_subscriptions
    SET status = 'cancelled',
        cancel_at = now(),
        cancelled_at = now(),
        updated_at = now()
    WHERE branch_id = p_branch_id;
    RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'status', 'cancelled');
  END IF;

  SELECT * INTO v_plan FROM public.subscription_plans WHERE id = p_plan_id AND is_active;
  IF v_plan.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PLAN_NOT_FOUND');
  END IF;

  v_period_start := now();
  IF p_billing_period = 'yearly' THEN
    v_period_end := v_period_start + interval '1 year';
    v_price := v_plan.yearly_price_egp;
  ELSE
    v_period_end := v_period_start + interval '1 month';
    v_price := v_plan.monthly_price_egp;
  END IF;

  INSERT INTO public.branch_subscriptions (
    branch_id, plan_id, status,
    trial_starts_at, trial_ends_at,
    current_period_starts_at, current_period_ends_at,
    cancel_at, cancelled_at, updated_at
  ) VALUES (
    p_branch_id, v_plan.id, 'active',
    NULL, NULL,
    v_period_start, v_period_end,
    NULL, NULL, now()
  )
  ON CONFLICT (branch_id) DO UPDATE SET
    plan_id = EXCLUDED.plan_id,
    status = 'active',
    trial_starts_at = NULL,
    trial_ends_at = NULL,
    current_period_starts_at = EXCLUDED.current_period_starts_at,
    current_period_ends_at = EXCLUDED.current_period_ends_at,
    cancel_at = NULL,
    cancelled_at = NULL,
    updated_at = now();

  RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'status', 'active',
    'plan_id', v_plan.id, 'price_egp', v_price);
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_subscription(uuid, text, text, boolean) TO authenticated, service_role;

-- ============ 6. create_user: register_branch GUC bypass ============
-- Mirrors the app.login_guard_bypass pattern so the anon self-service RPC can
-- provision the owner account while everything else stays admin/branch-manager.
CREATE OR REPLACE FUNCTION public.create_user(
  p_email text,
  p_password text,
  p_full_name text DEFAULT NULL,
  p_role text DEFAULT 'cashier',
  p_branch_id uuid DEFAULT NULL,
  p_is_active boolean DEFAULT true,
  p_username text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_role text;
  v_hash text;
  v_email text;
  v_username text;
  v_pgc_schema text;
  v_caller_role text;
  v_caller_branch uuid;
  v_u_cols text;
  v_u_vals text;
  v_i_cols text;
  v_i_vals text;
BEGIN
  SELECT role, branch_id INTO v_caller_role, v_caller_branch FROM public.users WHERE id = auth.uid();

  IF current_setting('app.register_branch', true) = 'on' THEN
    NULL; -- trusted caller: register_branch (SECURITY DEFINER) pre-validates
  ELSIF is_pos_admin() THEN
    NULL;
  ELSIF v_caller_role = 'branch_manager' AND v_caller_branch IS NOT NULL THEN
    -- branch manager: force their own branch and forbid admin roles
    IF p_branch_id IS NOT NULL AND p_branch_id <> v_caller_branch THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Branch managers can only create users in their own branch');
    END IF;
    IF p_role IN ('super_admin', 'owner') THEN
      RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
        'detail', 'Only a super admin can create super_admin/owner accounts');
    END IF;
    p_branch_id := v_caller_branch;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  v_email := lower(btrim(p_email));

  -- Email uniqueness (both auth accounts and app profiles)
  IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMAIL_TAKEN');
  END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE email = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMAIL_TAKEN');
  END IF;

  -- Username: default to email prefix, sanitized, must be unique
  v_username := regexp_replace(
    regexp_replace(lower(btrim(coalesce(NULLIF(p_username, ''), split_part(v_email, '@', 1)))), '[^a-z0-9._-]', '_', 'g'),
    '^[._-]+', '', 'g'
  );
  IF v_username = '' THEN
    v_username := 'user' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE username = v_username) THEN
    RETURN jsonb_build_object('success', false, 'error', 'USERNAME_TAKEN');
  END IF;

  SELECT extnamespace::regnamespace::text INTO v_pgc_schema
  FROM pg_extension WHERE extname = 'pgcrypto';

  IF v_pgc_schema IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', 'pgcrypto extension is not enabled');
  END IF;

  EXECUTE format('SELECT %I.crypt($1, %I.gen_salt($2, $3))', v_pgc_schema, v_pgc_schema)
    INTO v_hash USING p_password, 'bf', 10;

  -- Custom-role aware: the assigned role must exist in the matrix and be
  -- assignable by the caller (BM: global or own-branch roles only).
  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE role = p_role) THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ROLE');
  END IF;
  IF v_caller_role = 'branch_manager' AND NOT EXISTS (
    SELECT 1 FROM public.roles
    WHERE role = p_role AND (scope = 'global' OR branch_id = v_caller_branch)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED',
      'detail', 'Role not assignable in this branch');
  END IF;
  v_role := p_role;

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

  INSERT INTO public.users (id, email, username, full_name, role, branch_id, is_active)
  VALUES (v_user_id, v_email, v_username, p_full_name, v_role, p_branch_id, p_is_active);

  RETURN jsonb_build_object('success', true, 'user_id', v_user_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_ERROR', 'detail', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_user(text, text, text, text, uuid, boolean, text) TO authenticated;

-- ============ 7. guard_user_role_changes: register_branch bypass ============
CREATE OR REPLACE FUNCTION public.guard_user_role_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_caller_role text;
  v_caller_branch uuid;
  v_bypass boolean;
  v_register boolean;
BEGIN
  SELECT role, branch_id INTO v_caller_role, v_caller_branch
  FROM public.users WHERE id = auth.uid();

  v_bypass := COALESCE(current_setting('app.login_guard_bypass', true), '') = 'on';
  v_register := COALESCE(current_setting('app.register_branch', true), '') = 'on';

  -- Self-service registration: register_branch (SECURITY DEFINER) owns the whole
  -- user row (owner account for the freshly created branch).
  IF v_register THEN
    RETURN NEW;
  END IF;

  -- Assigned role must exist in the matrix.
  IF NOT EXISTS (SELECT 1 FROM public.roles WHERE role = NEW.role) THEN
    RAISE EXCEPTION 'UNKNOWN_ROLE';
  END IF;

  -- Unknown / anonymous caller (e.g. anon lockout RPC, or self-registration).
  IF v_caller_role IS NULL THEN
    IF TG_OP = 'INSERT' THEN
      -- Self-registration: fresh basic cashier profile owned by the caller
      -- (RLS already enforces this exact shape).
      IF NEW.id = auth.uid() AND NEW.role = 'cashier' AND NEW.branch_id IS NULL THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;
    -- UPDATE: only lockout counters may change (record_login_failure as anon).
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

  -- Only admins may create or modify admin accounts.
  IF NEW.role IN ('super_admin', 'owner') AND v_caller_role NOT IN ('super_admin', 'owner') THEN
    RAISE EXCEPTION 'PERMISSION_DENIED: only an admin can assign admin roles';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Only admins may modify existing admin accounts.
    IF OLD.role IN ('super_admin', 'owner') AND v_caller_role NOT IN ('super_admin', 'owner') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: only an admin can modify admin accounts';
    END IF;

    -- No self-demotion / self-deactivation / self-branch-change for non-admins.
    IF NEW.id = auth.uid() AND v_caller_role NOT IN ('super_admin', 'owner') THEN
      IF NEW.role IS DISTINCT FROM OLD.role
         OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
         OR NEW.is_active IS DISTINCT FROM OLD.is_active THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: users cannot change their own role/branch/status';
      END IF;

      -- Lockout fields are system-managed (only the lockout RPC may touch them).
      IF NOT v_bypass THEN
        IF NEW.is_locked IS DISTINCT FROM OLD.is_locked
           OR NEW.failed_attempts IS DISTINCT FROM OLD.failed_attempts
           OR NEW.lock_until IS DISTINCT FROM OLD.lock_until THEN
          RAISE EXCEPTION 'PERMISSION_DENIED: users cannot modify their own lock state';
        END IF;
      END IF;
    END IF;
  END IF;

  -- Branch managers may only manage staff of their own branch.
  IF v_caller_role = 'branch_manager' THEN
    IF NEW.branch_id IS DISTINCT FROM v_caller_branch THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: branch managers can only manage their own branch';
    END IF;
    -- Assigned role must be a global role or a role of this branch.
    IF NOT EXISTS (
      SELECT 1 FROM public.roles
      WHERE role = NEW.role AND is_active AND (scope = 'global' OR branch_id = v_caller_branch)
    ) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: role is not assignable in this branch';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- ============ 8. register_branch: anon self-service signup ============
CREATE OR REPLACE FUNCTION public.register_branch(
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
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_user_id uuid;
  v_email text;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
  v_res jsonb;
BEGIN
  BEGIN
    v_email := lower(btrim(p_email));
    IF v_email = '' OR v_email !~ '@' OR v_email !~ '.' THEN
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

    INSERT INTO public.branches (name, name_en, address, phone, is_active)
    VALUES (p_store_name, p_store_name_en, p_address, p_phone, true)
    RETURNING id INTO v_branch_id;

    INSERT INTO public.warehouses (name, branch_id, is_active)
    VALUES (p_store_name || ' - Main', v_branch_id, true)
    RETURNING id INTO v_warehouse_id;

    SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
    INTO v_global_tax, v_global_tax_enabled, v_global_currency
    FROM public.settings ORDER BY id LIMIT 1;

    INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
    VALUES (v_branch_id, v_global_tax, v_global_tax_enabled,
      COALESCE(NULLIF(btrim(p_currency), ''), v_global_currency), 10);

    INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
    VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

    -- Provision the owner auth account (email confirmed) inside the same
    -- transaction. register_branch owns the whole row, so the guard bypasses.
    PERFORM set_config('app.register_branch', 'on', true);
    v_res := public.create_user(v_email, p_password, p_owner_name, 'owner', v_branch_id, true, NULL);
    PERFORM set_config('app.register_branch', 'off', true);

    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'USER_CREATE_FAILED: %', coalesce(v_res->>'error', 'UNKNOWN');
    END IF;
    v_user_id := (v_res->>'user_id')::uuid;

    RETURN jsonb_build_object('success', true,
      'branch_id', v_branch_id, 'warehouse_id', v_warehouse_id,
      'user_id', v_user_id, 'trial_days', 14);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'REGISTRATION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_branch(text, text, text, text, text, text, text, text)
  TO anon, authenticated, service_role;

-- ============ 9. process_sale: subscription gate on the exact 047 body ============
-- The 19-arg overload from 038/045 is dropped first (matching 047); the single
-- 20-arg implementation below keeps the same call shape plus p_guest_count.
DROP FUNCTION IF EXISTS public.process_sale(
  text, uuid, uuid, uuid, uuid, numeric, numeric, text, numeric, numeric,
  numeric, numeric, text, text, jsonb, uuid, text, uuid, uuid);

CREATE OR REPLACE FUNCTION public.process_sale(p_invoice_number text, p_branch_id uuid, p_warehouse_id uuid, p_customer_id uuid, p_salesperson_id uuid, p_subtotal numeric, p_discount_amount numeric, p_discount_type text, p_tax_amount numeric, p_bonus_amount numeric, p_total numeric, p_paid_amount numeric, p_payment_method text, p_status text, p_items jsonb, p_shift_id uuid DEFAULT NULL::uuid, p_order_type text DEFAULT 'takeaway', p_table_id uuid DEFAULT NULL::uuid, p_order_id uuid DEFAULT NULL::uuid, p_guest_count integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sale_id uuid;
  v_user_branch uuid;
  v_role text;
  v_shift_id uuid;
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_unit_price numeric(12,2);
  v_discount_amount numeric(14,2);
  v_bonus_quantity numeric(14,4);
  v_item_total numeric(14,2);
  v_warehouse_ids uuid[];
  v_available numeric(14,4);
  v_res jsonb;
  v_short numeric(14,4);
  v_cogs_total numeric(14,2) := 0;
  v_subtotal numeric(14,2) := 0;
  v_discount numeric(14,2);
  v_tax numeric(14,2) := 0;
  v_tax_enabled boolean;
  v_tax_rate numeric(14,2);
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_ar numeric(14,2);
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_balance_account text;
  v_order_table uuid;
BEGIN
  BEGIN
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_CART');
    END IF;

    -- Subscription gate: only super_admin may sell on an expired / non-active
    -- subscription. Owners manage plans from the console but do not bypass.
    IF NOT EXISTS (
      SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'super_admin'
    ) AND public.subscription_expired(p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SUBSCRIPTION_EXPIRED',
        'subscription', public.subscription_status(p_branch_id));
    END IF;

    SELECT role, branch_id INTO v_role, v_user_branch FROM public.users WHERE id = auth.uid();

    -- Branch isolation (mirror of RLS on sales)
    IF NOT is_pos_admin() THEN
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    -- Origin table must belong to the sale branch
    IF p_table_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.dining_tables WHERE id = p_table_id AND branch_id = p_branch_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_IN_BRANCH', 'table_id', p_table_id);
    END IF;

    -- Shift enforcement for register operators
    IF v_role = 'cashier' AND NOT is_pos_admin() THEN
      IF p_shift_id IS NULL THEN
        SELECT id INTO v_shift_id
        FROM shifts
        WHERE cashier_id = auth.uid() AND branch_id = p_branch_id AND status = 'open'
        ORDER BY opened_at DESC LIMIT 1;
      ELSE
        IF NOT EXISTS (
          SELECT 1 FROM shifts
          WHERE id = p_shift_id AND cashier_id = auth.uid() AND branch_id = p_branch_id AND status = 'open'
        ) THEN
          RETURN jsonb_build_object('success', false, 'error', 'NO_OPEN_SHIFT',
            'detail', 'Open a shift before selling. The sale was not created.');
        END IF;
        v_shift_id := p_shift_id;
      END IF;

      IF v_shift_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'NO_OPEN_SHIFT',
          'detail', 'Open a shift before selling. The sale was not created.');
      END IF;
    END IF;

    -- ===== VALIDATE the linked order BEFORE any writes =====
    -- FOUND (not the table value) is what matters: a held takeaway/delivery
    -- order legitimately has table_id = NULL and must still be payable. Any
    -- RETURN here is safe because nothing has been written yet.
    IF p_order_id IS NOT NULL THEN
      SELECT table_id INTO v_order_table
      FROM public.orders
      WHERE id = p_order_id AND branch_id = p_branch_id AND status IN ('open', 'held');

      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND',
          'detail', 'The order must exist, belong to this branch, and be open or held. No sale was created.');
      END IF;
    END IF;

    -- Stock deduction scope: all active warehouses of the branch
    SELECT array_agg(id) INTO v_warehouse_ids
    FROM warehouses WHERE branch_id = p_branch_id AND is_active = true;

    -- ===== VALIDATION PHASE: check every item BEFORE writing anything =====
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
      IF v_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
      END IF;

      IF NOT EXISTS (SELECT 1 FROM products WHERE id = v_product_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND', 'product_id', v_product_id);
      END IF;

      -- Branch ownership: the product must belong to the sale branch
      IF NOT EXISTS (
        SELECT 1 FROM products WHERE id = v_product_id AND branch_id = p_branch_id
      ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH',
          'product_id', v_product_id, 'branch_id', p_branch_id);
      END IF;

      SELECT COALESCE(SUM(quantity), 0) INTO v_available
      FROM inventory_batches
      WHERE product_id = v_product_id AND warehouse_id = ANY(v_warehouse_ids);
      IF v_available < v_quantity THEN
        RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK',
          'product_id', v_product_id, 'required', v_quantity, 'available', v_available);
      END IF;

      -- Accumulate the authoritative subtotal (catalog price, clamped discount)
      SELECT COALESCE(sale_price, 0) INTO v_unit_price FROM products WHERE id = v_product_id;
      v_discount_amount := GREATEST(COALESCE((v_item->>'discount_amount')::numeric, 0), 0);
      IF v_discount_amount > v_quantity * v_unit_price THEN
        v_discount_amount := v_quantity * v_unit_price;
      END IF;
      v_subtotal := v_subtotal + ROUND(v_quantity * v_unit_price - v_discount_amount, 2);
    END LOOP;

    -- ===== SERVER-SIDE HEADER TOTALS (computed from authoritative prices) =====
    v_discount := GREATEST(COALESCE(p_discount_amount, 0), 0);
    IF v_discount > v_subtotal THEN v_discount := v_subtotal; END IF;
    SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0) INTO v_tax_enabled, v_tax_rate
    FROM public.settings LIMIT 1;
    IF v_tax_enabled THEN
      v_tax := ROUND((v_subtotal - v_discount) * v_tax_rate / 100, 2);
    END IF;
    v_total := ROUND(v_subtotal - v_discount + v_tax, 2);
    v_paid := ROUND(GREATEST(COALESCE(p_paid_amount, 0), 0), 2);
    v_ar := ROUND(GREATEST(v_total - v_paid, 0), 2);

    -- ===== WRITE PHASE 1: sale header (authoritative totals) =====
    INSERT INTO sales (invoice_number, branch_id, warehouse_id, customer_id, cashier_id, salesperson_id,
      subtotal, discount_amount, discount_type, tax_amount, bonus_amount, total, paid_amount, payment_method, status, order_type, table_id, guest_count)
    VALUES (p_invoice_number, p_branch_id, p_warehouse_id, p_customer_id, auth.uid(), p_salesperson_id,
      v_subtotal, v_discount, p_discount_type, v_tax, COALESCE(p_bonus_amount, 0),
      v_total, v_paid, p_payment_method, p_status, COALESCE(p_order_type, 'takeaway'), p_table_id, p_guest_count)
    RETURNING id INTO v_sale_id;

    -- ===== WRITE PHASE 2: items + FIFO stock deduction + ledger =====
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
      v_discount_amount := GREATEST(COALESCE((v_item->>'discount_amount')::numeric, 0), 0);

      SELECT sale_price INTO v_unit_price FROM products WHERE id = v_product_id;
      v_unit_price := COALESCE(v_unit_price, 0);
      IF v_discount_amount > v_quantity * v_unit_price THEN
        v_discount_amount := v_quantity * v_unit_price;
      END IF;
      v_bonus_quantity := COALESCE((v_item->>'bonus_quantity')::numeric, 0);
      v_item_total := ROUND(v_quantity * v_unit_price - v_discount_amount, 2);

      INSERT INTO sale_items (sale_id, product_id, unit_name, quantity, unit_price, discount_amount, bonus_quantity, total)
      VALUES (v_sale_id, v_product_id, COALESCE(v_item->>'unit_name', 'piece'),
        v_quantity, v_unit_price, v_discount_amount, v_bonus_quantity, v_item_total);

      v_res := public._product_inv_remove_fifo(v_product_id, NULL, p_branch_id, v_quantity,
        'sale', 'sale', v_sale_id, p_invoice_number, auth.uid());
      v_short := (v_res->>'shortage')::numeric;
      IF v_short > 0 THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK: product % needs % but only % available',
          v_product_id, v_quantity, (v_quantity - v_short);
      END IF;
      v_cogs_total := v_cogs_total + COALESCE((v_res->>'total_cost')::numeric, 0);
    END LOOP;

    -- ===== WRITE PHASE 2b: settle the linked order + free tables atomically =====
    -- H4: only free a table when NO other open/held order still references it.
    -- H3: a direct dine-in sale (no linked order) frees its origin table here,
    --     inside the sale transaction, instead of client-side afterwards.
    IF p_order_id IS NOT NULL THEN
      UPDATE public.orders SET status = 'completed', completed_at = now(), updated_at = now()
      WHERE id = p_order_id;
      -- NULL table (held takeaway/delivery) has no table to free.
      IF v_order_table IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.orders
        WHERE table_id = v_order_table AND status IN ('open', 'held') AND id <> p_order_id
      ) THEN
        UPDATE public.dining_tables SET status = 'vacant', updated_at = now()
        WHERE id = v_order_table;
      END IF;
    ELSIF p_table_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = p_table_id AND status IN ('open', 'held')
    ) THEN
      UPDATE public.dining_tables SET status = 'vacant', updated_at = now()
      WHERE id = p_table_id;
    END IF;

    -- ===== WRITE PHASE 3: log the sale into the active shift =====
    IF v_shift_id IS NOT NULL THEN
      INSERT INTO shift_operations (shift_id, operation_type, amount, payment_method, reference_type, reference_id, created_by)
      VALUES (v_shift_id, 'sale', v_paid, p_payment_method, 'sale', v_sale_id, auth.uid());
    END IF;

    -- ===== WRITE PHASE 4: post the sales + COGS journal entry =====
    IF v_paid > 0 THEN
      v_balance_account := CASE WHEN COALESCE(p_payment_method, 'cash') = 'cash' THEN 'cash' ELSE 'bank' END;
      v_lines := v_lines || jsonb_build_object('account_key', v_balance_account,
        'debit', v_paid, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + v_paid;
    END IF;
    IF v_ar > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'ar',
        'debit', v_ar, 'credit', 0, 'customer_id', p_customer_id, 'note', p_invoice_number);
      v_dr := v_dr + v_ar;
    END IF;
    IF v_discount > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'discount_given', 'debit', v_discount, 'credit', 0);
      v_dr := v_dr + v_discount;
    END IF;
    IF v_subtotal > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'revenue', 'debit', 0, 'credit', v_subtotal);
      v_cr := v_cr + v_subtotal;
    END IF;
    IF v_tax > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'vat_payable', 'debit', 0, 'credit', v_tax);
      v_cr := v_cr + v_tax;
    END IF;
    IF v_cogs_total > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'cogs', 'debit', v_cogs_total, 'credit', 0);
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', 0, 'credit', v_cogs_total);
      v_dr := v_dr + v_cogs_total;
      v_cr := v_cr + v_cogs_total;
    END IF;

    -- Balance any rounding/frontend discrepancy on the discount account so a
    -- posted entry is always balanced (normally the difference is zero).
    v_diff := round(v_dr - v_cr, 2);
    IF v_diff <> 0 THEN
      IF v_diff > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'discount_given', 'debit', 0, 'credit', v_diff);
      ELSE
        v_lines := v_lines || jsonb_build_object('account_key', 'discount_given', 'debit', -v_diff, 'credit', 0);
      END IF;
    END IF;

    PERFORM public._post_journal_entry(p_branch_id, 'sale', v_sale_id, p_invoice_number,
      'فاتورة مبيعات ' || p_invoice_number, v_lines);

    RETURN jsonb_build_object('success', true, 'sale_id', v_sale_id, 'invoice_number', p_invoice_number,
      'cogs', v_cogs_total);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'INSUFFICIENT_STOCK%' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_STOCK', 'detail', SQLERRM);
    END IF;
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_sale(text, uuid, uuid, uuid, uuid, numeric, numeric, text, numeric, numeric, numeric, numeric, text, text, jsonb, uuid, text, uuid, uuid, integer) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 056_fix_activate_subscription.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 056. Fix activate_subscription: never touch NOT NULL trial columns
-- ----------------------------------------------------------------------------
-- 055 activated a plan by writing trial_starts_at/trial_ends_at = NULL, but
-- both columns are NOT NULL, so every activate_subscription call raised
-- "null value in column trial_starts_at". The trial fields are historical once
-- the row becomes 'active' (subscription_status reads current_period_ends_at),
-- so activation now leaves them untouched. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.activate_subscription(
  p_branch_id uuid,
  p_plan_id text,
  p_billing_period text DEFAULT 'monthly',
  p_activate boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan public.subscription_plans%ROWTYPE;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_price numeric(10,2);
BEGIN
  IF NOT is_pos_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF p_branch_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  IF NOT p_activate THEN
    UPDATE public.branch_subscriptions
    SET status = 'cancelled',
        cancel_at = now(),
        cancelled_at = now(),
        updated_at = now()
    WHERE branch_id = p_branch_id;
    RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'status', 'cancelled');
  END IF;

  SELECT * INTO v_plan FROM public.subscription_plans WHERE id = p_plan_id AND is_active;
  IF v_plan.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PLAN_NOT_FOUND');
  END IF;

  v_period_start := now();
  IF p_billing_period = 'yearly' THEN
    v_period_end := v_period_start + interval '1 year';
    v_price := v_plan.yearly_price_egp;
  ELSE
    v_period_end := v_period_start + interval '1 month';
    v_price := v_plan.monthly_price_egp;
  END IF;

  INSERT INTO public.branch_subscriptions (
    branch_id, plan_id, status,
    current_period_starts_at, current_period_ends_at,
    cancel_at, cancelled_at, updated_at
  ) VALUES (
    p_branch_id, v_plan.id, 'active',
    v_period_start, v_period_end,
    NULL, NULL, now()
  )
  ON CONFLICT (branch_id) DO UPDATE SET
    plan_id = EXCLUDED.plan_id,
    status = 'active',
    current_period_starts_at = EXCLUDED.current_period_starts_at,
    current_period_ends_at = EXCLUDED.current_period_ends_at,
    cancel_at = NULL,
    cancelled_at = NULL,
    updated_at = now();

  RETURN jsonb_build_object('success', true, 'branch_id', p_branch_id, 'status', 'active',
    'plan_id', v_plan.id, 'price_egp', v_price);
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_subscription(uuid, text, text, boolean) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 057_subscriptions_implicit_trial.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 057. Implicit 14-day trial for branches without a subscription row
-- ----------------------------------------------------------------------------
-- The 055 sale guard blocks any branch whose subscription is not active / on a
-- live trial. subscription_status() treated a branch with NO row in
-- branch_subscriptions as 'none' + expired, which locked out two legitimate
-- cases:
--
--   1. Branches created directly by an admin from the branches panel (a plain
--      INSERT into public.branches, not register_branch): they never received a
--      subscription row, so every non-super_admin sale returned SUBSCRIPTION_EXPIRED.
--   2. Integration tests that insert fixture branches directly: the guard now
--      short-circuits them with SUBSCRIPTION_EXPIRED before any sale logic runs.
--
-- Fix: when a branch exists but has no subscription row, subscription_status()
-- now reports the same trial register_branch()/the 055 backfill grant, anchored
-- to branches.created_at so it is a real, non-renewable 14-day window. Unknown
-- branch ids (no row AND no branch) still report 'none'/expired. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.subscription_status(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.branch_subscriptions%ROWTYPE;
  v_created timestamptz;
  v_implicit_end timestamptz;
  v_status text;
  v_expired boolean;
BEGIN
  SELECT * INTO v_row FROM public.branch_subscriptions WHERE branch_id = p_branch_id;

  IF v_row.branch_id IS NULL THEN
    SELECT created_at INTO v_created FROM public.branches WHERE id = p_branch_id;
    IF v_created IS NULL THEN
      RETURN jsonb_build_object(
        'branch_id', p_branch_id,
        'status', 'none', 'plan_id', NULL,
        'expired', true, 'trial_ends_at', NULL,
        'current_period_ends_at', NULL, 'cancelled_at', NULL
      );
    END IF;
    v_implicit_end := v_created + interval '14 days';
    RETURN jsonb_build_object(
      'branch_id', p_branch_id,
      'status', 'trial', 'plan_id', NULL,
      'expired', v_implicit_end <= now(),
      'trial_ends_at', v_implicit_end,
      'current_period_ends_at', NULL, 'cancelled_at', NULL
    );
  END IF;

  v_status := v_row.status;
  v_expired := false;

  IF v_status IN ('trial', 'active', 'past_due') THEN
    IF v_status = 'trial' THEN
      IF v_row.trial_ends_at IS NOT NULL AND v_row.trial_ends_at <= now() THEN
        v_status := 'expired';
        v_expired := true;
      END IF;
    ELSE
      IF v_row.current_period_ends_at IS NOT NULL AND v_row.current_period_ends_at <= now() THEN
        v_status := 'expired';
        v_expired := true;
      END IF;
    END IF;
  ELSE
    v_expired := true;
  END IF;

  RETURN jsonb_build_object(
    'branch_id', p_branch_id,
    'status', v_status,
    'plan_id', v_row.plan_id,
    'expired', v_expired,
    'trial_ends_at', v_row.trial_ends_at,
    'current_period_ends_at', v_row.current_period_ends_at,
    'cancelled_at', v_row.cancelled_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 058_super_admin_subscription_control.sql
-- ----------------------------------------------------------------------------
-- 058. Super Admin-only subscription control and DB sale guard
-- Keeps subscription management exclusive to the super_admin role.

CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid() AND u.is_active AND u.role = 'super_admin'
  );
$$;
REVOKE ALL ON FUNCTION public.is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO authenticated;

CREATE TABLE IF NOT EXISTS public.subscription_plans (
  id text PRIMARY KEY,
  name_ar text NOT NULL,
  name_en text NOT NULL,
  monthly_price_egp numeric(10,2) NOT NULL DEFAULT 0,
  yearly_price_egp numeric(10,2) NOT NULL DEFAULT 0,
  features jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.branch_subscriptions (
  branch_id uuid PRIMARY KEY REFERENCES public.branches(id) ON DELETE CASCADE,
  plan_id text REFERENCES public.subscription_plans(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'trial',
  trial_starts_at timestamptz NOT NULL DEFAULT now(),
  trial_ends_at timestamptz,
  current_period_starts_at timestamptz,
  current_period_ends_at timestamptz,
  cancel_at timestamptz,
  cancelled_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT branch_subscriptions_status_check CHECK (status IN ('trial','active','past_due','cancelled','expired'))
);

INSERT INTO public.subscription_plans (id,name_ar,name_en,monthly_price_egp,yearly_price_egp,features)
VALUES
('basic','الأساسية','Basic',299,2990,'["Users: 2","Warehouses: 1","Inventory & sales"]'),
('standard','القياسية','Standard',599,5990,'["Users: 5","Warehouses: 3","Accounting & reports"]'),
('enterprise','المتقدمة','Enterprise',999,9990,'["Users: unlimited","Multi-branch","Full suite + priority support"]')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.branch_subscriptions(branch_id,status,trial_starts_at,trial_ends_at)
SELECT b.id,'trial',now(),now()+interval '14 days'
FROM public.branches b
WHERE NOT EXISTS (SELECT 1 FROM public.branch_subscriptions s WHERE s.branch_id=b.id);

ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_public_read ON public.subscription_plans;
CREATE POLICY subscription_plans_public_read ON public.subscription_plans FOR SELECT TO anon,authenticated USING (is_active=true);
DROP POLICY IF EXISTS subscription_plans_super_admin_write ON public.subscription_plans;
CREATE POLICY subscription_plans_super_admin_write ON public.subscription_plans FOR ALL TO authenticated USING (is_super_admin()) WITH CHECK (is_super_admin());
DROP POLICY IF EXISTS branch_subscriptions_super_admin_only ON public.branch_subscriptions;
CREATE POLICY branch_subscriptions_super_admin_only ON public.branch_subscriptions FOR ALL TO authenticated USING (is_super_admin()) WITH CHECK (is_super_admin());
GRANT SELECT ON public.subscription_plans TO anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.subscription_plans, public.branch_subscriptions TO authenticated;

CREATE OR REPLACE FUNCTION public.subscription_status(p_branch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.branch_subscriptions%ROWTYPE; s text; e boolean;
BEGIN
 SELECT * INTO r FROM public.branch_subscriptions WHERE branch_id=p_branch_id;
 IF r.branch_id IS NULL THEN RETURN jsonb_build_object('status','none','expired',true,'branch_id',p_branch_id); END IF;
 s:=r.status; e:=false;
 IF s='trial' AND r.trial_ends_at IS NOT NULL AND r.trial_ends_at<=now() THEN s:='expired'; e:=true;
 ELSIF s IN ('active','past_due') AND r.current_period_ends_at IS NOT NULL AND r.current_period_ends_at<=now() THEN s:='expired'; e:=true;
 ELSIF s IN ('cancelled','expired') THEN e:=true; END IF;
 RETURN jsonb_build_object('branch_id',p_branch_id,'status',s,'plan_id',r.plan_id,'expired',e,'trial_ends_at',r.trial_ends_at,'current_period_ends_at',r.current_period_ends_at,'cancelled_at',r.cancelled_at);
END; $$;
REVOKE ALL ON FUNCTION public.subscription_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.subscription_expired(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT COALESCE((public.subscription_status(p_branch_id)->>'expired')::boolean, true);
$$;
REVOKE ALL ON FUNCTION public.subscription_expired(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_expired(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.activate_subscription(p_branch_id uuid,p_plan_id text,p_billing_period text DEFAULT 'monthly',p_activate boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.subscription_plans%ROWTYPE; st timestamptz:=now(); en timestamptz; price numeric(10,2);
BEGIN
 IF NOT is_super_admin() THEN RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED'); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.branches WHERE id=p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND'); END IF;
 IF NOT p_activate THEN
   UPDATE public.branch_subscriptions SET status='cancelled',cancel_at=now(),cancelled_at=now(),updated_at=now() WHERE branch_id=p_branch_id;
   RETURN jsonb_build_object('success',true,'status','cancelled','branch_id',p_branch_id);
 END IF;
 SELECT * INTO p FROM public.subscription_plans WHERE id=p_plan_id AND is_active;
 IF p.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','PLAN_NOT_FOUND'); END IF;
 IF p_billing_period='yearly' THEN en:=st+interval '1 year'; price:=p.yearly_price_egp; ELSE en:=st+interval '1 month'; price:=p.monthly_price_egp; END IF;
 INSERT INTO public.branch_subscriptions(branch_id,plan_id,status,trial_starts_at,trial_ends_at,current_period_starts_at,current_period_ends_at,cancel_at,cancelled_at,updated_at)
 VALUES(p_branch_id,p.id,'active',NULL,NULL,st,en,NULL,NULL,now())
 ON CONFLICT(branch_id) DO UPDATE SET plan_id=excluded.plan_id,status='active',trial_starts_at=NULL,trial_ends_at=NULL,current_period_starts_at=excluded.current_period_starts_at,current_period_ends_at=excluded.current_period_ends_at,cancel_at=NULL,cancelled_at=NULL,updated_at=now();
 RETURN jsonb_build_object('success',true,'status','active','branch_id',p_branch_id,'plan_id',p.id,'price_egp',price,'current_period_ends_at',en);
END; $$;
REVOKE ALL ON FUNCTION public.activate_subscription(uuid,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_subscription(uuid,text,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_order_subscription()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN RETURN NEW; END IF;
  IF public.is_super_admin() THEN RETURN NEW; END IF;
  IF NEW.branch_id IS NULL OR public.subscription_expired(NEW.branch_id) THEN
    RAISE EXCEPTION 'SUBSCRIPTION_EXPIRED' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_order_subscription() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guard_order_subscription() TO authenticated,service_role;
DROP TRIGGER IF EXISTS trg_guard_order_subscription ON public.orders;
CREATE TRIGGER trg_guard_order_subscription BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.guard_order_subscription();


-- ----------------------------------------------------------------------------
-- MIGRATION: 059_instapay_subscription_payments.sql
-- ----------------------------------------------------------------------------
-- 059. InstaPay subscription transfer workflow
-- Super Admin is global and is never restricted to a branch.

CREATE TABLE IF NOT EXISTS public.subscription_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  plan_id text REFERENCES public.subscription_plans(id) ON DELETE SET NULL,
  amount numeric(10,2) NOT NULL CHECK (amount >= 0),
  billing_period text NOT NULL DEFAULT 'monthly' CHECK (billing_period IN ('monthly','yearly')),
  payment_method text NOT NULL DEFAULT 'instapay' CHECK (payment_method = 'instapay'),
  reference text,
  receipt_url text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  submitted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  approved_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  rejected_at timestamptz,
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscription_payments_branch ON public.subscription_payments(branch_id);
CREATE INDEX IF NOT EXISTS idx_subscription_payments_status ON public.subscription_payments(status);

ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subscription_payments_super_admin_all ON public.subscription_payments;
CREATE POLICY subscription_payments_super_admin_all ON public.subscription_payments FOR ALL TO authenticated USING (public.is_super_admin()) WITH CHECK (public.is_super_admin());

CREATE OR REPLACE FUNCTION public.submit_instapay_payment(p_branch_id uuid,p_plan_id text,p_amount numeric,p_billing_period text DEFAULT 'monthly',p_reference text DEFAULT NULL,p_receipt_url text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RETURN jsonb_build_object('success',false,'error','UNAUTHENTICATED'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id=uid AND u.is_active) THEN RETURN jsonb_build_object('success',false,'error','USER_INACTIVE'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id=p_branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscription_plans WHERE id=p_plan_id AND is_active) THEN RETURN jsonb_build_object('success',false,'error','PLAN_NOT_FOUND'); END IF;
  IF p_amount <= 0 THEN RETURN jsonb_build_object('success',false,'error','INVALID_AMOUNT'); END IF;
  INSERT INTO public.subscription_payments(branch_id,plan_id,amount,billing_period,reference,receipt_url,submitted_by)
  VALUES(p_branch_id,p_plan_id,p_amount,p_billing_period,p_reference,p_receipt_url,uid);
  RETURN jsonb_build_object('success',true,'status','pending');
END; $$;
REVOKE ALL ON FUNCTION public.submit_instapay_payment(uuid,text,numeric,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_instapay_payment(uuid,text,numeric,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.review_instapay_payment(p_payment_id uuid,p_approve boolean,p_rejection_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE pay public.subscription_payments%ROWTYPE; uid uuid := auth.uid();
BEGIN
  IF NOT public.is_super_admin() THEN RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED'); END IF;
  SELECT * INTO pay FROM public.subscription_payments WHERE id=p_payment_id FOR UPDATE;
  IF pay.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','PAYMENT_NOT_FOUND'); END IF;
  IF pay.status <> 'pending' THEN RETURN jsonb_build_object('success',false,'error','PAYMENT_ALREADY_REVIEWED'); END IF;
  IF NOT p_approve THEN
    UPDATE public.subscription_payments SET status='rejected',rejected_at=now(),rejection_reason=p_rejection_reason,approved_by=uid,updated_at=now() WHERE id=p_payment_id;
    RETURN jsonb_build_object('success',true,'status','rejected');
  END IF;
  UPDATE public.subscription_payments SET status='approved',approved_by=uid,approved_at=now(),updated_at=now() WHERE id=p_payment_id;
  PERFORM public.activate_subscription(pay.branch_id,pay.plan_id,pay.billing_period,true);
  RETURN jsonb_build_object('success',true,'status','approved','branch_id',pay.branch_id);
END; $$;
REVOKE ALL ON FUNCTION public.review_instapay_payment(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_instapay_payment(uuid,boolean,text) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 059_subscription_ci_bypass.sql
-- ----------------------------------------------------------------------------
-- 059. CI-only subscription bypass hook
-- The flag is OFF by default and is never set on a real Supabase project.
-- It exists so disposable Postgres integration fixtures can test POS/RLS
-- behavior without a subscription fixture masking the behavior under test.

CREATE OR REPLACE FUNCTION public.subscription_expired(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN current_setting('app.ci_subscription_bypass', true) = 'on' THEN false
    ELSE COALESCE((public.subscription_status(p_branch_id)->>'expired')::boolean, true)
  END;
$$;

REVOKE ALL ON FUNCTION public.subscription_expired(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_expired(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- MIGRATION: 060_branch_isolate_raw_materials.sql
-- ----------------------------------------------------------------------------
-- Branch isolation for raw materials and recipe items.
-- Super Admin/Owner remain global through the canonical is_pos_admin() helper;
-- branch users are restricted through get_branch_id().

ALTER TABLE public.raw_materials ADD COLUMN IF NOT EXISTS branch_id uuid;

-- Backfill materials that are used by exactly one branch from their recipe.
UPDATE public.raw_materials rm
SET branch_id = x.branch_id
FROM (
  SELECT ri.raw_material_id,
         (array_agg(r.branch_id ORDER BY r.branch_id))[1] AS branch_id
  FROM public.recipe_items ri
  JOIN public.recipes r ON r.id = ri.recipe_id
  WHERE r.branch_id IS NOT NULL
  GROUP BY ri.raw_material_id
  HAVING count(DISTINCT r.branch_id) = 1
) x
WHERE rm.id = x.raw_material_id AND rm.branch_id IS NULL;

-- Legacy materials with no unambiguous recipe ownership are assigned to the
-- oldest branch, matching the project's existing catalog backfill convention.
DO $$
DECLARE
  v_default_branch uuid;
BEGIN
  SELECT id INTO v_default_branch
  FROM public.branches
  ORDER BY created_at, id
  LIMIT 1;

  IF v_default_branch IS NULL THEN
    INSERT INTO public.branches (name) VALUES ('الفرع الرئيسي')
    RETURNING id INTO v_default_branch;
  END IF;

  UPDATE public.raw_materials
  SET branch_id = v_default_branch
  WHERE branch_id IS NULL;
END $$;

ALTER TABLE public.raw_materials ALTER COLUMN branch_id SET NOT NULL;
ALTER TABLE public.raw_materials DROP CONSTRAINT IF EXISTS raw_materials_branch_id_fkey;
ALTER TABLE public.raw_materials
  ADD CONSTRAINT raw_materials_branch_id_fkey
  FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS idx_raw_materials_branch_id ON public.raw_materials(branch_id);

ALTER TABLE public.raw_materials ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS raw_materials_write ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_select_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_insert_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_update_branch_isolated ON public.raw_materials;
DROP POLICY IF EXISTS raw_materials_delete_branch_isolated ON public.raw_materials;

CREATE POLICY raw_materials_select_branch_isolated
ON public.raw_materials FOR SELECT
USING (public.is_pos_admin() OR branch_id = public.get_branch_id());

CREATE POLICY raw_materials_insert_branch_isolated
ON public.raw_materials FOR INSERT
WITH CHECK (public.is_pos_admin() OR branch_id = public.get_branch_id());

CREATE POLICY raw_materials_update_branch_isolated
ON public.raw_materials FOR UPDATE
USING (public.is_pos_admin() OR branch_id = public.get_branch_id())
WITH CHECK (public.is_pos_admin() OR branch_id = public.get_branch_id());

CREATE POLICY raw_materials_delete_branch_isolated
ON public.raw_materials FOR DELETE
USING (public.is_pos_admin() OR branch_id = public.get_branch_id());

-- Prevent recipe items from connecting a recipe to a raw material owned by
-- another branch. SECURITY DEFINER is intentional so validation is not
-- bypassed by RLS visibility.
CREATE OR REPLACE FUNCTION public.validate_recipe_item_branch_match()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  recipe_branch uuid;
  material_branch uuid;
BEGIN
  SELECT branch_id INTO recipe_branch
  FROM public.recipes
  WHERE id = NEW.recipe_id;

  SELECT branch_id INTO material_branch
  FROM public.raw_materials
  WHERE id = NEW.raw_material_id;

  IF recipe_branch IS NULL OR material_branch IS NULL OR recipe_branch <> material_branch THEN
    RAISE EXCEPTION 'RAW_MATERIAL_BRANCH_MISMATCH';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_recipe_item_branch ON public.recipe_items;
CREATE TRIGGER trg_validate_recipe_item_branch
BEFORE INSERT OR UPDATE ON public.recipe_items
FOR EACH ROW EXECUTE FUNCTION public.validate_recipe_item_branch_match();


-- ----------------------------------------------------------------------------
-- MIGRATION: 060_harden_instapay_submission.sql
-- ----------------------------------------------------------------------------
-- 060. Harden InstaPay submission and enforce branch ownership.
-- Super Admin is global; ordinary users can submit only for their own branch.

CREATE OR REPLACE FUNCTION public.submit_instapay_payment(
  p_branch_id uuid,
  p_plan_id text,
  p_amount numeric,
  p_billing_period text DEFAULT 'monthly',
  p_reference text DEFAULT NULL,
  p_receipt_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  expected_amount numeric;
  own_branch uuid;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','UNAUTHENTICATED');
  END IF;

  SELECT u.branch_id INTO own_branch
  FROM public.users u
  WHERE u.id = uid AND u.is_active;

  IF own_branch IS NULL AND NOT public.is_super_admin() THEN
    RETURN jsonb_build_object('success',false,'error','NO_BRANCH');
  END IF;

  IF NOT public.is_super_admin() AND own_branch <> p_branch_id THEN
    RETURN jsonb_build_object('success',false,'error','BRANCH_ACCESS_DENIED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.is_active) THEN
    RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND');
  END IF;

  IF p_billing_period NOT IN ('monthly','yearly') THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_BILLING_PERIOD');
  END IF;

  SELECT CASE WHEN p_billing_period = 'yearly' THEN yearly_price_egp ELSE monthly_price_egp END
  INTO expected_amount
  FROM public.subscription_plans
  WHERE id = p_plan_id AND is_active;

  IF expected_amount IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','PLAN_NOT_FOUND');
  END IF;

  IF p_amount <> expected_amount THEN
    RETURN jsonb_build_object('success',false,'error','AMOUNT_MISMATCH','expected_amount',expected_amount);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.subscription_payments sp
    WHERE sp.branch_id = p_branch_id
      AND sp.status = 'pending'
  ) THEN
    RETURN jsonb_build_object('success',false,'error','PENDING_PAYMENT_EXISTS');
  END IF;

  INSERT INTO public.subscription_payments(
    branch_id, plan_id, amount, billing_period, reference, receipt_url, submitted_by
  )
  VALUES(
    p_branch_id, p_plan_id, p_amount, p_billing_period, NULLIF(trim(p_reference), ''), NULLIF(trim(p_receipt_url), ''), uid
  );

  RETURN jsonb_build_object('success',true,'status','pending');
END;
$$;

REVOKE ALL ON FUNCTION public.submit_instapay_payment(uuid,text,numeric,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_instapay_payment(uuid,text,numeric,text,text,text) TO authenticated;

CREATE INDEX IF NOT EXISTS idx_subscription_payments_pending_branch
  ON public.subscription_payments(branch_id)
  WHERE status = 'pending';


-- ----------------------------------------------------------------------------
-- MIGRATION: 061_instapay_payment_read_policy.sql
-- ----------------------------------------------------------------------------
-- 061. Allow users to view only their own branch's InstaPay payment history.
DROP POLICY IF EXISTS subscription_payments_branch_read ON public.subscription_payments;
CREATE POLICY subscription_payments_branch_read
ON public.subscription_payments
FOR SELECT TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active
      AND u.branch_id = subscription_payments.branch_id
  )
);


-- ----------------------------------------------------------------------------
-- MIGRATION: 061_inventory_stock_counts.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: stock counts, approval, variance and audited adjustments.
CREATE TABLE IF NOT EXISTS stock_counts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  warehouse_id uuid NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','approved','applied','rejected')),
  count_type text NOT NULL DEFAULT 'cycle' CHECK (count_type IN ('full','partial','cycle')),
  notes text,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  submitted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  applied_at timestamptz
);
ALTER TABLE stock_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_stock_counts_select" ON stock_counts FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_stock_counts_insert" ON stock_counts FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "auth_stock_counts_update" ON stock_counts FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE TABLE IF NOT EXISTS stock_count_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stock_count_id uuid NOT NULL REFERENCES stock_counts(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  system_quantity numeric(14,4) NOT NULL DEFAULT 0,
  counted_quantity numeric(14,4) NOT NULL DEFAULT 0,
  variance_quantity numeric(14,4) GENERATED ALWAYS AS (counted_quantity - system_quantity) STORED,
  unit_cost numeric(12,2) NOT NULL DEFAULT 0,
  variance_value numeric(16,2) GENERATED ALWAYS AS ((counted_quantity - system_quantity) * unit_cost) STORED,
  reason text,
  UNIQUE (stock_count_id, product_id)
);
ALTER TABLE stock_count_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_stock_count_items_select" ON stock_count_items FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_stock_count_items_insert" ON stock_count_items FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "auth_stock_count_items_update" ON stock_count_items FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_stock_counts_branch_warehouse ON stock_counts(branch_id, warehouse_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_count_items_count ON stock_count_items(stock_count_id);

CREATE OR REPLACE FUNCTION apply_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count stock_counts%ROWTYPE;
  v_item stock_count_items%ROWTYPE;
  v_inv inventory%ROWTYPE;
  v_user_branch uuid;
  v_applied integer := 0;
BEGIN
  SELECT * INTO v_count FROM stock_counts WHERE id = p_stock_count_id FOR UPDATE;
  IF v_count.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','COUNT_NOT_FOUND'); END IF;
  IF v_count.status <> 'approved' THEN RETURN jsonb_build_object('success',false,'error','COUNT_NOT_APPROVED'); END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
      RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH');
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM stock_count_items WHERE stock_count_id = p_stock_count_id ORDER BY id FOR UPDATE
  LOOP
    SELECT * INTO v_inv FROM inventory WHERE product_id = v_item.product_id AND warehouse_id = v_count.warehouse_id FOR UPDATE;
    IF v_inv.id IS NULL THEN
      INSERT INTO inventory(product_id, warehouse_id, quantity)
      VALUES(v_item.product_id, v_count.warehouse_id, v_item.counted_quantity)
      RETURNING * INTO v_inv;
      INSERT INTO stock_transactions(product_id, warehouse_id, branch_id, transaction_type, component_flow, reference_type, reference_id, quantity, before_quantity, after_quantity, unit_cost, reason, created_by)
      VALUES(v_item.product_id, v_count.warehouse_id, v_count.branch_id, 'adjustment', false, 'stock_count', v_count.id, v_item.counted_quantity, 0, v_item.counted_quantity, v_item.unit_cost, COALESCE(v_item.reason,'stock_count'), auth.uid());
    ELSIF v_item.variance_quantity <> 0 THEN
      UPDATE inventory SET quantity = v_item.counted_quantity, updated_at = now() WHERE id = v_inv.id;
      INSERT INTO stock_transactions(product_id, warehouse_id, branch_id, transaction_type, component_flow, reference_type, reference_id, quantity, before_quantity, after_quantity, unit_cost, reason, created_by)
      VALUES(v_item.product_id, v_count.warehouse_id, v_count.branch_id, 'adjustment', false, 'stock_count', v_count.id, v_item.variance_quantity, v_inv.quantity, v_item.counted_quantity, v_item.unit_cost, COALESCE(v_item.reason,'stock_count'), auth.uid());
    END IF;
    v_applied := v_applied + 1;
  END LOOP;

  UPDATE stock_counts SET status='applied', applied_at=now() WHERE id=p_stock_count_id;
  RETURN jsonb_build_object('success',true,'items_applied',v_applied);
END;
$$;

REVOKE ALL ON FUNCTION apply_stock_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_stock_count(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 063_subscription_settings.sql
-- ----------------------------------------------------------------------------
-- 063. Global subscription settings, Super Admin only.
-- Super Admin is global and is never restricted to a branch.

CREATE TABLE IF NOT EXISTS public.subscription_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id = true),
  instapay_id text,
  beneficiary_name text,
  qr_code_url text,
  instructions_ar text,
  instructions_en text,
  trial_days integer NOT NULL DEFAULT 14 CHECK (trial_days >= 0 AND trial_days <= 365),
  warning_days integer NOT NULL DEFAULT 7 CHECK (warning_days >= 0 AND warning_days <= 90),
  grace_days integer NOT NULL DEFAULT 0 CHECK (grace_days >= 0 AND grace_days <= 90),
  require_receipt boolean NOT NULL DEFAULT true,
  allow_monthly boolean NOT NULL DEFAULT true,
  allow_yearly boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL
);

INSERT INTO public.subscription_settings (id) VALUES (true)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.subscription_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS subscription_settings_super_admin_select ON public.subscription_settings;
DROP POLICY IF EXISTS subscription_settings_super_admin_write ON public.subscription_settings;

CREATE POLICY subscription_settings_super_admin_select
ON public.subscription_settings FOR SELECT TO authenticated
USING (public.is_super_admin());

CREATE POLICY subscription_settings_super_admin_write
ON public.subscription_settings FOR ALL TO authenticated
USING (public.is_super_admin())
WITH CHECK (public.is_super_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.subscription_settings TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.subscription_settings_get()
RETURNS public.subscription_settings
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v public.subscription_settings%ROWTYPE;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'PERMISSION_DENIED';
  END IF;
  SELECT * INTO v FROM public.subscription_settings WHERE id=true;
  RETURN v;
END; $$;

CREATE OR REPLACE FUNCTION public.subscription_settings_update(
  p_instapay_id text,
  p_beneficiary_name text,
  p_qr_code_url text,
  p_instructions_ar text,
  p_instructions_en text,
  p_trial_days integer,
  p_warning_days integer,
  p_grace_days integer,
  p_require_receipt boolean,
  p_allow_monthly boolean,
  p_allow_yearly boolean
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED');
  END IF;
  IF p_trial_days < 0 OR p_trial_days > 365 OR p_warning_days < 0 OR p_warning_days > 90 OR p_grace_days < 0 OR p_grace_days > 90 THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_SETTINGS');
  END IF;
  IF NOT p_allow_monthly AND NOT p_allow_yearly THEN
    RETURN jsonb_build_object('success',false,'error','ONE_BILLING_PERIOD_REQUIRED');
  END IF;
  UPDATE public.subscription_settings SET
    instapay_id = NULLIF(btrim(p_instapay_id),''),
    beneficiary_name = NULLIF(btrim(p_beneficiary_name),''),
    qr_code_url = NULLIF(btrim(p_qr_code_url),''),
    instructions_ar = NULLIF(btrim(p_instructions_ar),''),
    instructions_en = NULLIF(btrim(p_instructions_en),''),
    trial_days = p_trial_days,
    warning_days = p_warning_days,
    grace_days = p_grace_days,
    require_receipt = p_require_receipt,
    allow_monthly = p_allow_monthly,
    allow_yearly = p_allow_yearly,
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id=true;
  RETURN jsonb_build_object('success',true);
END; $$;

REVOKE ALL ON FUNCTION public.subscription_settings_get() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.subscription_settings_update(text,text,text,text,text,integer,integer,integer,boolean,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscription_settings_update(text,text,text,text,text,integer,integer,integer,boolean,boolean,boolean) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 064_subscription_settings_rpc.sql
-- ----------------------------------------------------------------------------
-- Compatibility migration.
-- Subscription settings schema and RPCs are defined canonically by 063_subscription_settings.sql.
-- This migration intentionally performs no schema mutation so fresh CI databases do not redefine
-- the singleton id column with a conflicting type.
DO $$ BEGIN NULL; END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 065_fix_paid_subscription_activation_trial_dates.sql
-- ----------------------------------------------------------------------------
-- Fix paid subscription activation against canonical branch_subscriptions schema.
-- trial_starts_at is NOT NULL; paid activation is represented by a zero-length trial marker.
CREATE OR REPLACE FUNCTION public.activate_subscription(
  p_branch_id uuid,
  p_plan_id text,
  p_billing_period text DEFAULT 'monthly',
  p_activate boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p public.subscription_plans%ROWTYPE;
  st timestamptz := now();
  en timestamptz;
  price numeric(10,2);
BEGIN
  IF NOT public.is_super_admin() THEN
    RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id=p_branch_id) THEN
    RETURN jsonb_build_object('success',false,'error','BRANCH_NOT_FOUND');
  END IF;
  IF NOT p_activate THEN
    UPDATE public.branch_subscriptions
      SET status='cancelled', cancel_at=now(), cancelled_at=now(), updated_at=now()
      WHERE branch_id=p_branch_id;
    RETURN jsonb_build_object('success',true,'status','cancelled','branch_id',p_branch_id);
  END IF;

  SELECT * INTO p
  FROM public.subscription_plans
  WHERE id=p_plan_id AND is_active;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','PLAN_NOT_FOUND');
  END IF;

  IF p_billing_period='yearly' THEN
    en := st + interval '1 year';
    price := p.yearly_price_egp;
  ELSE
    en := st + interval '1 month';
    price := p.monthly_price_egp;
  END IF;

  INSERT INTO public.branch_subscriptions(
    branch_id, plan_id, status,
    trial_starts_at, trial_ends_at,
    current_period_starts_at, current_period_ends_at,
    cancel_at, cancelled_at, updated_at
  ) VALUES (
    p_branch_id, p.id, 'active',
    st, st,
    st, en,
    NULL, NULL, now()
  )
  ON CONFLICT(branch_id) DO UPDATE SET
    plan_id=excluded.plan_id,
    status='active',
    trial_starts_at=excluded.trial_starts_at,
    trial_ends_at=excluded.trial_ends_at,
    current_period_starts_at=excluded.current_period_starts_at,
    current_period_ends_at=excluded.current_period_ends_at,
    cancel_at=NULL,
    cancelled_at=NULL,
    updated_at=now();

  RETURN jsonb_build_object(
    'success',true,
    'status','active',
    'branch_id',p_branch_id,
    'plan_id',p.id,
    'price_egp',price,
    'current_period_ends_at',en
  );
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 065_subscription_settings_rpc_compat.sql
-- ----------------------------------------------------------------------------
-- Compatibility migration.
-- 063_subscription_settings.sql already defines the canonical Super Admin-only
-- subscription_settings_get() and subscription_settings_update(...) RPCs.
-- Keep this migration idempotent without introducing a second incompatible signature.
DO $$ BEGIN NULL; END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 066_fix_subscription_settings_nulls.sql
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.subscription_settings_update(
  p_instapay_id text,
  p_beneficiary_name text,
  p_qr_code_url text,
  p_instructions_ar text,
  p_instructions_en text,
  p_trial_days integer,
  p_warning_days integer,
  p_grace_days integer,
  p_require_receipt boolean,
  p_allow_monthly boolean,
  p_allow_yearly boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  IF coalesce(p_trial_days, 0) < 0 OR coalesce(p_trial_days, 0) > 365
     OR coalesce(p_warning_days, 7) < 0 OR coalesce(p_warning_days, 7) > 90
     OR coalesce(p_grace_days, 0) < 0 OR coalesce(p_grace_days, 0) > 90 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_SETTINGS');
  END IF;

  IF coalesce(p_allow_monthly, true) = false AND coalesce(p_allow_yearly, true) = false THEN
    RETURN jsonb_build_object('success', false, 'error', 'ONE_BILLING_PERIOD_REQUIRED');
  END IF;

  UPDATE public.subscription_settings
  SET instapay_id = coalesce(nullif(btrim(p_instapay_id), ''), ''),
      beneficiary_name = coalesce(nullif(btrim(p_beneficiary_name), ''), ''),
      qr_code_url = coalesce(nullif(btrim(p_qr_code_url), ''), ''),
      instructions_ar = coalesce(nullif(btrim(p_instructions_ar), ''), ''),
      instructions_en = coalesce(nullif(btrim(p_instructions_en), ''), ''),
      trial_days = coalesce(p_trial_days, 0),
      warning_days = coalesce(p_warning_days, 7),
      grace_days = coalesce(p_grace_days, 0),
      require_receipt = coalesce(p_require_receipt, true),
      allow_monthly = coalesce(p_allow_monthly, true),
      allow_yearly = coalesce(p_allow_yearly, true),
      updated_at = now(),
      updated_by = auth.uid()
  WHERE id = true;

  RETURN jsonb_build_object('success', true);
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 066_normalize_subscription_settings_schema.sql
-- ----------------------------------------------------------------------------
-- Compatibility migration. The canonical subscription_settings schema is defined in 063.
-- The production repair is implemented idempotently in 067.
DO $$ BEGIN NULL; END $$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 067_fix_subscription_settings_return_type.sql
-- ----------------------------------------------------------------------------
BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='id' AND data_type='integer') THEN
    ALTER TABLE public.subscription_settings DROP CONSTRAINT IF EXISTS subscription_settings_id_check;
    ALTER TABLE public.subscription_settings ALTER COLUMN id DROP DEFAULT;
    ALTER TABLE public.subscription_settings ALTER COLUMN id TYPE boolean USING (id <> 0);
    ALTER TABLE public.subscription_settings ALTER COLUMN id SET DEFAULT true;
    ALTER TABLE public.subscription_settings ADD CONSTRAINT subscription_settings_id_check CHECK (id = true);
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='grace_period_days') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='grace_days') THEN ALTER TABLE public.subscription_settings RENAME COLUMN grace_period_days TO grace_days; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='monthly_enabled') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='allow_monthly') THEN ALTER TABLE public.subscription_settings RENAME COLUMN monthly_enabled TO allow_monthly; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='annual_enabled') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='allow_yearly') THEN ALTER TABLE public.subscription_settings RENAME COLUMN annual_enabled TO allow_yearly; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='subscription_settings' AND column_name='updated_by') THEN ALTER TABLE public.subscription_settings ADD COLUMN updated_by uuid REFERENCES public.users(id) ON DELETE SET NULL; END IF;
END $$;

DROP FUNCTION IF EXISTS public.subscription_settings_get();
DROP FUNCTION IF EXISTS public.subscription_settings_update(jsonb);

CREATE OR REPLACE FUNCTION public.subscription_settings_get()
RETURNS public.subscription_settings LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v public.subscription_settings%ROWTYPE;
BEGIN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'PERMISSION_DENIED'; END IF;
  SELECT * INTO v FROM public.subscription_settings WHERE id=true;
  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.subscription_settings_update(p_instapay_id text,p_beneficiary_name text,p_qr_code_url text,p_instructions_ar text,p_instructions_en text,p_trial_days integer,p_warning_days integer,p_grace_days integer,p_require_receipt boolean,p_allow_monthly boolean,p_allow_yearly boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT public.is_super_admin() THEN RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED'); END IF;
  IF p_trial_days < 0 OR p_trial_days > 365 OR p_warning_days < 0 OR p_warning_days > 90 OR p_grace_days < 0 OR p_grace_days > 90 THEN RETURN jsonb_build_object('success',false,'error','INVALID_SETTINGS'); END IF;
  IF NOT p_allow_monthly AND NOT p_allow_yearly THEN RETURN jsonb_build_object('success',false,'error','ONE_BILLING_PERIOD_REQUIRED'); END IF;
  UPDATE public.subscription_settings SET instapay_id=NULLIF(btrim(p_instapay_id),''),beneficiary_name=NULLIF(btrim(p_beneficiary_name),''),qr_code_url=NULLIF(btrim(p_qr_code_url),''),instructions_ar=NULLIF(btrim(p_instructions_ar),''),instructions_en=NULLIF(btrim(p_instructions_en),''),trial_days=p_trial_days,warning_days=p_warning_days,grace_days=p_grace_days,require_receipt=p_require_receipt,allow_monthly=p_allow_monthly,allow_yearly=p_allow_yearly,updated_at=now(),updated_by=auth.uid() WHERE id=true;
  RETURN jsonb_build_object('success',true);
END;
$$;

REVOKE ALL ON FUNCTION public.subscription_settings_get() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.subscription_settings_update(text,text,text,text,text,integer,integer,integer,boolean,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscription_settings_update(text,text,text,text,text,integer,integer,integer,boolean,boolean,boolean) TO authenticated;

COMMIT;


-- ----------------------------------------------------------------------------
-- MIGRATION: 068_security_harden_audit_gaps.sql
-- ----------------------------------------------------------------------------
-- 068. P0 security hardening — closes the audited branch-isolation gaps.
--
--   * process_sale:       was granted to `anon` (047/055). An anonymous caller
--                         has auth.uid() = NULL, so the branch guard
--                         (047/055) passed and a cross-branch write was
--                         possible. Restricted to authenticated + service_role.
--   * subscription_status: was granted to `anon` (058). It reads any branch's
--                         subscription state for a given branch_id. Restricted
--                         to authenticated + service_role.
--   * product_components:  SELECT policy was `USING (true)` (002), exposing the
--                         full recipe graph across branches. INSERT/UPDATE/
--                         DELETE were already gated (044); the SELECT policy is
--                         now scoped through the parent product's branch,
--                         mirroring the 044 pattern.
--
-- Behavior-preserving for legitimate users: the application only calls
-- process_sale and subscription_status from authenticated sessions
-- (src/api/modules.ts, src/context/AuthContext.tsx,
-- src/features/admin/pages/SubscriptionsAdminPage.tsx).

-- 1. process_sale: authenticated + service_role only -------------------------
REVOKE ALL ON FUNCTION public.process_sale(
  text, uuid, uuid, uuid, uuid, numeric, numeric, text, numeric, numeric,
  numeric, numeric, text, text, jsonb, uuid, text, uuid, uuid, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_sale(
  text, uuid, uuid, uuid, uuid, numeric, numeric, text, numeric, numeric,
  numeric, numeric, text, text, jsonb, uuid, text, uuid, uuid, integer
) FROM anon;
GRANT EXECUTE ON FUNCTION public.process_sale(
  text, uuid, uuid, uuid, uuid, numeric, numeric, text, numeric, numeric,
  numeric, numeric, text, text, jsonb, uuid, text, uuid, uuid, integer
) TO authenticated, service_role;

-- 2. subscription_status: authenticated + service_role only ------------------
REVOKE ALL ON FUNCTION public.subscription_status(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.subscription_status(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.subscription_status(uuid) TO authenticated, service_role;

-- 3. product_components SELECT: branch-scoped through the parent product ------
DROP POLICY IF EXISTS "auth_select_product_components" ON public.product_components;
CREATE POLICY "auth_select_product_components" ON public.product_components FOR SELECT TO authenticated
USING (
  is_pos_admin() OR EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = product_components.product_id
      AND p.branch_id = get_branch_id()
  )
);


-- ----------------------------------------------------------------------------
-- MIGRATION: 069_resume_order_kitchen_incremental.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 069. Resume-order kitchen sending stays incremental across update_order
-- ----------------------------------------------------------------------------
-- ERP-01 item 4: "previously sent items must not be duplicated to KDS, newly
-- added items must be sent." The authoritative send boundary is 048's
-- order_kitchen_sends (order_item_id UNIQUE) + send_to_kitchen, both correct.
--
-- The bug lived in update_order (046): it rewrote the item lines with
--
--     DELETE FROM public.order_items WHERE order_id = p_order_id;
--
-- then re-inserted every line with a brand-new id. Because order_kitchen_sends
-- references order_item_id ON DELETE CASCADE, any re-persist of an order that
-- had already been sent to the kitchen (e.g. Hold after Send Kitchen, then
-- resume + Send again) silently deleted the send rows and re-sent everything,
-- duplicating kitchen tickets for already-sent items.
--
-- Fix (additive, same signature): update_order now preserves the identity of
-- an existing line when product_id / unit_name / unit_price / discount_amount
-- / bonus_quantity match. Matched lines keep their order_item_id (only
-- quantity/total/notes refresh in place), so their kitchen-send rows survive.
-- Genuinely new lines are inserted (unsent) and vanished lines are deleted
-- (their send rows cascade away). Result:
--
--   * previously sent items are never re-sent on resume/hold/retry;
--   * newly added items send exactly once;
--   * a same-cart re-persist is a no-op for the kitchen (items_sent_count 0).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_order(
  p_order_id uuid,
  p_order_type text DEFAULT 'dine_in',
  p_table_id uuid DEFAULT NULL,
  p_customer_id uuid DEFAULT NULL,
  p_guest_count integer DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb,
  p_subtotal numeric DEFAULT 0,
  p_discount_amount numeric DEFAULT 0,
  p_discount_type text DEFAULT 'amount',
  p_tax_amount numeric DEFAULT 0,
  p_total numeric DEFAULT 0,
  p_status text DEFAULT 'held'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_branch_id uuid;
  v_old_table uuid;
  v_old_status text;
  v_user_branch uuid;
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,4);
  v_matched_id uuid;
BEGIN
  BEGIN
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_CART');
    END IF;

    IF p_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
    END IF;

    SELECT branch_id, table_id, status INTO v_branch_id, v_old_table, v_old_status
    FROM public.orders WHERE id = p_order_id;
    IF v_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;
    IF v_old_status NOT IN ('open', 'held') THEN
      RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be edited.');
    END IF;

    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF NOT is_pos_admin() AND COALESCE(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    -- New table must belong to the order branch and be active.
    IF p_table_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.dining_tables WHERE id = p_table_id AND branch_id = v_branch_id AND is_active
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'TABLE_NOT_IN_BRANCH', 'table_id', p_table_id);
    END IF;

    -- Validate every line before writing anything.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
      IF v_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY', 'product_id', v_product_id);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = v_product_id AND branch_id = v_branch_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_IN_BRANCH', 'product_id', v_product_id);
      END IF;
    END LOOP;

    UPDATE public.orders SET
      order_type = COALESCE(p_order_type, order_type),
      table_id = p_table_id,
      customer_id = p_customer_id,
      guest_count = p_guest_count,
      notes = p_notes,
      subtotal = COALESCE(p_subtotal, 0),
      discount_amount = COALESCE(p_discount_amount, 0),
      discount_type = COALESCE(p_discount_type, 'amount'),
      tax_amount = COALESCE(p_tax_amount, 0),
      total = COALESCE(p_total, 0),
      status = p_status,
      updated_at = now()
    WHERE id = p_order_id;

    -- Replace the item lines while PRESERVING the identity of existing lines.
    -- A line keeps its order_item_id when product/unit/price/discount/bonus
    -- match (quantity/total/notes refresh in place), so per-item kitchen-send
    -- state keyed on order_item_id survives re-persists of a sent order.
    CREATE TEMP TABLE IF NOT EXISTS _upd_matched (order_item_id uuid) ON COMMIT DROP;
    TRUNCATE _upd_matched;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := COALESCE((v_item->>'quantity')::numeric, 1);

      v_matched_id := NULL;
      SELECT oi.id INTO v_matched_id
      FROM public.order_items oi
      WHERE oi.order_id = p_order_id
        AND oi.product_id = v_product_id
        AND oi.unit_name = COALESCE(v_item->>'unit_name', 'piece')
        AND oi.unit_price = COALESCE((v_item->>'unit_price')::numeric, oi.unit_price)
        AND oi.discount_amount = COALESCE((v_item->>'discount_amount')::numeric, oi.discount_amount)
        AND oi.bonus_quantity = COALESCE((v_item->>'bonus_quantity')::numeric, oi.bonus_quantity)
        AND NOT EXISTS (
          SELECT 1 FROM _upd_matched m WHERE m.order_item_id = oi.id
        )
      LIMIT 1;

      IF v_matched_id IS NOT NULL THEN
        UPDATE public.order_items SET
          quantity = v_quantity,
          total = COALESCE((v_item->>'total')::numeric, 0),
          notes = NULLIF(v_item->>'notes', '')
        WHERE id = v_matched_id;
        INSERT INTO _upd_matched (order_item_id) VALUES (v_matched_id);
      ELSE
        INSERT INTO public.order_items (order_id, product_id, unit_name, quantity, unit_price,
          discount_amount, bonus_quantity, total, notes)
        VALUES (p_order_id, v_product_id,
          COALESCE(v_item->>'unit_name', 'piece'),
          v_quantity,
          COALESCE((v_item->>'unit_price')::numeric, 0),
          COALESCE((v_item->>'discount_amount')::numeric, 0),
          COALESCE((v_item->>'bonus_quantity')::numeric, 0),
          COALESCE((v_item->>'total')::numeric, 0),
          NULLIF(v_item->>'notes', ''))
        RETURNING id INTO v_matched_id;
        -- Protect the brand-new line from the deletion sweep below.
        INSERT INTO _upd_matched (order_item_id) VALUES (v_matched_id);
      END IF;
    END LOOP;

    -- Remove lines that vanished from the cart (their send rows cascade away).
    DELETE FROM public.order_items oi
    WHERE oi.order_id = p_order_id
      AND NOT EXISTS (
        SELECT 1 FROM _upd_matched m WHERE m.order_item_id = oi.id
      );

    -- Occupancy reconciliation: free the OLD table only when the order moved
    -- away/detached AND no other open/held order still references it.
    IF v_old_table IS NOT NULL AND v_old_table IS DISTINCT FROM p_table_id AND NOT EXISTS (
      SELECT 1 FROM public.orders
      WHERE table_id = v_old_table AND status IN ('open', 'held') AND id <> p_order_id
    ) THEN
      UPDATE public.dining_tables SET status = 'vacant', updated_at = now() WHERE id = v_old_table;
    END IF;

    -- Occupy the (new) table for dine-in orders.
    IF p_table_id IS NOT NULL THEN
      UPDATE public.dining_tables SET status = 'occupied', updated_at = now() WHERE id = p_table_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'order_id', p_order_id, 'status', p_status);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 070_stock_count_workflow.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: Stock Count workflow.
-- Additive-only. Completes the slice from 061_inventory_stock_counts.sql by
-- adding the lifecycle RPCs (create/submit/approve/reject/add-item/update/remove)
-- and making apply_stock_count batch-aware (inventory_batches + inventory_ledger
-- + stock_transactions stay consistent with the legacy `inventory` quantity).
--
-- All state transitions go through SECURITY DEFINER RPCs that enforce the
-- permission and branch-isolation rules; direct table writes remain governed by
-- the RLS policies already created in 061.

ALTER TABLE public.stock_counts ADD COLUMN IF NOT EXISTS count_number text;
ALTER TABLE public.stock_counts ADD COLUMN IF NOT EXISTS rejection_reason text;
CREATE INDEX IF NOT EXISTS idx_stock_counts_number ON public.stock_counts(count_number);

INSERT INTO public.document_sequences (seq_type, next_value) VALUES ('stock_count', 1)
ON CONFLICT (seq_type) DO NOTHING;

-- ---------------------------------------------------------------------------
-- create_stock_count: create a draft count with optional pre-seeded items.
-- system_quantity and unit_cost are computed server-side so clients never
-- supply their own stock truth.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_stock_count(
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_count_type text,
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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

        -- Prefer the weighted-average batch cost when batches exist.
        SELECT COALESCE(round(SUM(quantity * unit_cost) / NULLIF(SUM(quantity), 0), 2), 0)
        INTO v_unit_cost
        FROM public.inventory_batches b
        WHERE b.product_id = v_product_id AND b.warehouse_id = p_warehouse_id AND b.quantity > 0;
        IF v_unit_cost IS NULL THEN v_unit_cost := 0; END IF;

        INSERT INTO public.stock_count_items (stock_count_id, product_id, system_quantity, counted_quantity, unit_cost, reason)
        VALUES (v_count_id, v_product_id, COALESCE(v_system_qty, 0),
          COALESCE(NULLIF((v_item->>'counted_quantity')::text, ''), v_system_qty)::numeric,
          v_unit_cost, NULLIF((v_item->>'reason')::text, ''));
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

GRANT EXECUTE ON FUNCTION public.create_stock_count(uuid, uuid, text, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- add_stock_count_item: add/edit an item on a draft count (upsert by product).
-- The client may only supply counted_quantity and reason; system_quantity and
-- unit_cost are computed here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_stock_count_item(
  p_stock_count_id uuid,
  p_product_id uuid,
  p_counted_quantity numeric DEFAULT NULL,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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

GRANT EXECUTE ON FUNCTION public.add_stock_count_item(uuid, uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- update_stock_count_item: edit counted_quantity / reason of a draft item.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_stock_count_item(
  p_stock_count_id uuid,
  p_product_id uuid,
  p_counted_quantity numeric,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
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

    UPDATE public.stock_count_items
    SET counted_quantity = p_counted_quantity, reason = p_reason
    WHERE stock_count_id = p_stock_count_id AND product_id = p_product_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND');
    END IF;
    RETURN jsonb_build_object('success', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.update_stock_count_item(uuid, uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- remove_stock_count_item: remove an item from a draft count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_stock_count_item(
  p_stock_count_id uuid,
  p_product_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
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

    DELETE FROM public.stock_count_items
    WHERE stock_count_id = p_stock_count_id AND product_id = p_product_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'ITEM_NOT_FOUND');
    END IF;
    RETURN jsonb_build_object('success', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.remove_stock_count_item(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- submit_stock_count: draft -> submitted. A count needs at least one item.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
  v_items integer;
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
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    SELECT COUNT(*) INTO v_items FROM public.stock_count_items WHERE stock_count_id = p_stock_count_id;
    IF v_items = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_COUNT');
    END IF;

    UPDATE public.stock_counts
    SET status = 'submitted', submitted_by = auth.uid(), submitted_at = now()
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.submit_stock_count(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- approve_stock_count: submitted -> approved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
  v_user_branch uuid;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Approving stock counts requires the inventory.manage permission.');
    END IF;
    SELECT * INTO v_count FROM public.stock_counts WHERE id = p_stock_count_id FOR UPDATE;
    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;
    IF v_count.status <> 'submitted' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    UPDATE public.stock_counts
    SET status = 'approved', approved_by = auth.uid(), approved_at = now(), rejection_reason = NULL
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.approve_stock_count(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- reject_stock_count: submitted -> rejected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_stock_count(
  p_stock_count_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count record;
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
    IF v_count.status <> 'submitted' THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_count.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    UPDATE public.stock_counts
    SET status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_reason
    WHERE id = p_stock_count_id;

    RETURN jsonb_build_object('success', true, 'stock_count_id', p_stock_count_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reject_stock_count(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- apply_stock_count (replaced): approved -> applied.
-- Batch-aware: applies each variance against the CURRENT inventory quantity via
-- the canonical _product_inv_add / _product_inv_remove_fifo helpers so
-- inventory, inventory_batches, inventory_ledger and stock_transactions stay in
-- sync. Returns an error instead of silently breaking the batch invariant.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_stock_count(p_stock_count_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_count stock_counts%ROWTYPE;
  v_item stock_count_items%ROWTYPE;
  v_current numeric(14,4);
  v_variance numeric(14,4);
  v_user_branch uuid;
  v_applied integer := 0;
  v_res jsonb;
  v_shortage numeric(14,4);
BEGIN
  BEGIN
    SELECT * INTO v_count FROM public.stock_counts WHERE id = p_stock_count_id FOR UPDATE;
    IF v_count.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_FOUND');
    END IF;
    IF v_count.status <> 'approved' THEN
      RETURN jsonb_build_object('success', false, 'error', 'COUNT_NOT_APPROVED', 'status', v_count.status);
    END IF;

    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Applying stock counts requires the inventory.manage permission.');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_count.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    FOR v_item IN
      SELECT * FROM public.stock_count_items
      WHERE stock_count_id = p_stock_count_id
      ORDER BY id
      FOR UPDATE
    LOOP
      SELECT COALESCE(quantity, 0) INTO v_current
      FROM public.inventory
      WHERE product_id = v_item.product_id AND warehouse_id = v_count.warehouse_id;
      IF v_current IS NULL THEN v_current := 0; END IF;

      v_variance := v_item.counted_quantity - v_current;

      IF v_variance > 0 THEN
        v_res := public._product_inv_add(
          v_item.product_id, v_count.warehouse_id, v_count.branch_id, v_variance,
          v_item.unit_cost, NULL, NULL, NULL, 'adjustment', 'stock_count',
          v_count.id, v_count.count_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN jsonb_build_object('success', false, 'error', 'ADJUST_FAILED',
            'product_id', v_item.product_id, 'detail', v_res->>'error');
        END IF;
      ELSIF v_variance < 0 THEN
        v_res := public._product_inv_remove_fifo(
          v_item.product_id, v_count.warehouse_id, v_count.branch_id, -v_variance,
          'adjustment', 'stock_count', v_count.id, v_count.count_number, auth.uid());
        v_shortage := COALESCE((v_res->>'shortage')::numeric, 0);
        IF v_shortage > 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'STOCK_COUNT_SHORTAGE',
            'product_id', v_item.product_id, 'shortage', v_shortage);
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
$function$;

GRANT EXECUTE ON FUNCTION public.apply_stock_count(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 071_inventory_policy_reorder.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: Min/Max + Reorder Point + Low Stock Alerts.
-- Additive-only. Adds the ordering policy columns to products and exposes a
-- branch-scoped low-stock alert query used by the Inventory and Reports UI.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS min_stock numeric(14,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS max_stock numeric(14,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reorder_point numeric(14,4) NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------------------
-- get_low_stock_alerts(p_branch_id, p_warehouse_id)
-- Returns every product whose on-hand quantity is below its reorder point (or
-- low_stock_threshold when reorder_point is 0). Admins may omit p_branch_id to
-- scan all branches; non-admin users are always forced to their own branch.
-- Rows: product_id, product_name, barcode, sku, warehouse_id, warehouse_name,
--       quantity, min_stock, max_stock, reorder_point, low_stock_threshold,
--       shortage_qty, status ('out' | 'low' | 'ok')
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_low_stock_alerts(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id uuid,
  product_name text,
  barcode text,
  sku text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  min_stock numeric(14,4),
  max_stock numeric(14,4),
  reorder_point numeric(14,4),
  low_stock_threshold numeric(14,4),
  shortage_qty numeric(14,4),
  status text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  -- Admins can scope freely; branch staff are locked to their own branch.
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    p.id AS product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    p.sku,
    s.warehouse_id,
    w.name AS warehouse_name,
    COALESCE(s.branch_id, v_scope) AS branch_id,
    COALESCE(s.quantity, 0) AS quantity,
    COALESCE(p.min_stock, 0) AS min_stock,
    COALESCE(p.max_stock, 0) AS max_stock,
    COALESCE(p.reorder_point, 0) AS reorder_point,
    COALESCE(p.low_stock_threshold, 0) AS low_stock_threshold,
    GREATEST(0, COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold, 0) - COALESCE(s.quantity, 0)) AS shortage_qty,
    CASE
      WHEN COALESCE(s.quantity, 0) <= 0 THEN 'out'
      WHEN COALESCE(s.quantity, 0) < COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold, 0) THEN 'low'
      ELSE 'ok'
    END AS status
  FROM public.products p
  LEFT JOIN LATERAL (
    SELECT
      i.warehouse_id,
      i.branch_id,
      COALESCE(SUM(i.quantity), 0)::numeric(14,4) AS quantity
    FROM public.inventory i
    WHERE i.product_id = p.id
      AND (v_scope IS NULL OR i.branch_id = v_scope)
      AND (p_warehouse_id IS NULL OR i.warehouse_id = p_warehouse_id)
    GROUP BY i.warehouse_id, i.branch_id
  ) s ON true
  LEFT JOIN public.warehouses w ON w.id = s.warehouse_id
  WHERE p.is_active = true
    AND (s.warehouse_id IS NOT NULL OR (p_warehouse_id IS NULL AND v_scope IS NOT NULL)
         OR (p_warehouse_id IS NULL AND v_scope IS NULL AND p.branch_id IS NULL))
  ORDER BY status ASC, branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_low_stock_alerts(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_low_stock_summary(p_branch_id, p_warehouse_id): counts for dashboards.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_low_stock_summary(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (out_count bigint, low_count bigint, ok_count bigint)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
  SELECT
    COUNT(*) FILTER (WHERE status = 'out')::bigint,
    COUNT(*) FILTER (WHERE status = 'low')::bigint,
    COUNT(*) FILTER (WHERE status = 'ok')::bigint
  FROM public.get_low_stock_alerts(p_branch_id, p_warehouse_id);
$function$;

GRANT EXECUTE ON FUNCTION public.get_low_stock_summary(uuid, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 072_stock_valuation.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: Stock Valuation.
-- Additive-only. Reports the on-hand quantity and cost value of finished-goods
-- inventory per product/warehouse using the weighted-average batch unit cost,
-- plus a grand total. Branch-scoped like the other reporting functions: admins
-- may pass NULL p_branch_id to scan all branches; branch staff are locked to
-- their own branch.

CREATE OR REPLACE FUNCTION public.get_stock_valuation(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id uuid,
  product_name text,
  barcode text,
  sku text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  unit_cost numeric(12,2),
  total_value numeric(16,2)
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  WITH val AS (
    SELECT
      b.product_id,
      b.warehouse_id,
      b.branch_id,
      COALESCE(SUM(b.quantity), 0)::numeric(14,4) AS quantity,
      COALESCE(round(SUM(b.quantity * b.unit_cost) / NULLIF(SUM(b.quantity), 0), 2), 0)::numeric(12,2) AS unit_cost
    FROM public.inventory_batches b
    WHERE (v_scope IS NULL OR b.branch_id = v_scope)
      AND (p_warehouse_id IS NULL OR b.warehouse_id = p_warehouse_id)
    GROUP BY b.product_id, b.warehouse_id, b.branch_id
  )
  SELECT
    v.product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    p.sku,
    v.warehouse_id,
    w.name AS warehouse_name,
    v.branch_id,
    v.quantity,
    v.unit_cost,
    round(v.quantity * v.unit_cost, 2)::numeric(16,2) AS total_value
  FROM val v
  JOIN public.products p ON p.id = v.product_id
  LEFT JOIN public.warehouses w ON w.id = v.warehouse_id
  WHERE v.quantity > 0
  ORDER BY v.branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_valuation(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_stock_valuation_summary: per-branch and grand totals.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_stock_valuation_summary(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  branch_id uuid,
  branch_name text,
  total_quantity numeric(14,4),
  total_value numeric(16,2),
  item_count bigint
) LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
  SELECT
    v.branch_id,
    br.name AS branch_name,
    COALESCE(SUM(v.quantity), 0)::numeric(14,4),
    COALESCE(SUM(v.total_value), 0)::numeric(16,2),
    COUNT(*)::bigint
  FROM public.get_stock_valuation(p_branch_id, p_warehouse_id) v
  LEFT JOIN public.branches br ON br.id = v.branch_id
  GROUP BY v.branch_id, br.name
  ORDER BY br.name ASC;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_valuation_summary(uuid, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 073_batch_expiry.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: Lot/Batch + Expiry.
-- Additive-only. Adds an RPC to open a batch manually (e.g. opening stock or a
-- supplier batch not tied to a purchase) and an expiry-alert query that lists
-- batches expiring within a horizon (including already-expired ones).

-- ---------------------------------------------------------------------------
-- add_inventory_batch: open a finished-goods batch with production/expiry dates.
-- Delegates to the canonical _product_inv_add so inventory + batches + ledger +
-- stock_transactions stay consistent. Branch-scoped.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_inventory_batch(
  p_product_id uuid,
  p_warehouse_id uuid,
  p_branch_id uuid,
  p_quantity numeric,
  p_unit_cost numeric DEFAULT 0,
  p_batch_number text DEFAULT NULL,
  p_production_date date DEFAULT NULL,
  p_expiry_date date DEFAULT NULL,
  p_source_type text DEFAULT 'opening',
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_res jsonb;
  v_user_branch uuid;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('inventory.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Opening a batch requires the inventory.manage permission.');
    END IF;
    IF p_product_id IS NULL OR p_warehouse_id IS NULL OR p_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_PARAMS');
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
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

    v_res := public._product_inv_add(
      p_product_id, p_warehouse_id, p_branch_id, p_quantity, p_unit_cost,
      p_batch_number, p_production_date, p_expiry_date,
      'opening', 'batch', NULL, NULL, auth.uid());

    IF NOT (v_res->>'success')::boolean THEN
      RETURN jsonb_build_object('success', false, 'error', v_res->>'error');
    END IF;

    RETURN jsonb_build_object('success', true, 'batch_number', v_res->>'batch_number');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.add_inventory_batch(uuid, uuid, uuid, numeric, numeric, text, date, date, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_expiring_batches(p_branch_id, p_warehouse_id, p_horizon_days)
-- Lists batches expiring within the horizon (or already expired). Branch-scoped.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_expiring_batches(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL,
  p_horizon_days integer DEFAULT 90
) RETURNS TABLE (
  batch_id uuid,
  batch_number text,
  product_id uuid,
  product_name text,
  barcode text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  unit_cost numeric(12,2),
  production_date date,
  expiry_date date,
  days_to_expiry bigint,
  status text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
  v_horizon integer;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;
  v_horizon := COALESCE(p_horizon_days, 90);
  IF v_horizon < 0 THEN v_horizon := 0; END IF;

  RETURN QUERY
  SELECT
    b.id AS batch_id,
    COALESCE(NULLIF(btrim(b.batch_number), ''), '-') AS batch_number,
    b.product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    b.warehouse_id,
    w.name AS warehouse_name,
    b.branch_id,
    b.quantity,
    b.unit_cost,
    b.production_date,
    b.expiry_date,
    CASE WHEN b.expiry_date IS NULL THEN NULL
         ELSE (b.expiry_date - CURRENT_DATE)::bigint END AS days_to_expiry,
    CASE
      WHEN b.expiry_date IS NULL THEN 'none'
      WHEN b.expiry_date < CURRENT_DATE THEN 'expired'
      WHEN b.expiry_date <= CURRENT_DATE + (v_horizon || ' days')::interval THEN 'expiring'
      ELSE 'ok'
    END AS status
  FROM public.inventory_batches b
  JOIN public.products p ON p.id = b.product_id
  LEFT JOIN public.warehouses w ON w.id = b.warehouse_id
  WHERE b.quantity > 0
    AND (v_scope IS NULL OR b.branch_id = v_scope)
    AND (p_warehouse_id IS NULL OR b.warehouse_id = p_warehouse_id)
    AND (b.expiry_date IS NULL
         OR b.expiry_date <= CURRENT_DATE + (v_horizon || ' days')::interval)
  ORDER BY b.expiry_date ASC NULLS LAST, b.branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_expiring_batches(uuid, uuid, integer) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 074_product_costing.sql
-- ----------------------------------------------------------------------------
-- =====================================================================
-- P0 Item 2: Product / Recipe Costing.
-- Additive-only. Adds:
--   1. product_cost_history table + trigger tracking products.cost_price
--      changes (any source: manual edit, purchase recomputation, ...).
--   2. Costing analysis RPCs:
--      - get_costing_overview             per-product cost figures
--      - get_product_costing_detail       deep detail + component/recipe/history
--      - get_cost_history                 cost changes for one product
--      - get_supplier_price_impact        purchase-price trend per supplier item
--      - get_order_margin                 gross margin per sale order
-- All RPCs are SECURITY DEFINER and branch-scoped like the other reporting
-- functions: admins may pass NULL p_branch_id to scan all branches; branch
-- staff are locked to their own branch.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Cost history
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_cost_history (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  old_cost   numeric(12,2) NOT NULL DEFAULT 0,
  new_cost   numeric(12,2) NOT NULL DEFAULT 0,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid,
  source     text NOT NULL DEFAULT 'change'
);
COMMENT ON TABLE public.product_cost_history IS 'سجل تغيّر تكلفة المنتج (أي مصدر: تعديل يدوي، مشتريات، ...)';

CREATE INDEX IF NOT EXISTS idx_product_cost_history_product
  ON public.product_cost_history (product_id, changed_at DESC);

ALTER TABLE public.product_cost_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "product_cost_history_select" ON public.product_cost_history;
CREATE POLICY "product_cost_history_select" ON public.product_cost_history
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "product_cost_history_insert" ON public.product_cost_history;
CREATE POLICY "product_cost_history_insert" ON public.product_cost_history
  FOR INSERT TO authenticated WITH CHECK (true);

-- Trigger function runs as SECURITY DEFINER so the history insert succeeds
-- regardless of the caller's path (direct table update or RPC).
CREATE OR REPLACE FUNCTION public.track_product_cost_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.cost_price IS DISTINCT FROM OLD.cost_price THEN
    INSERT INTO public.product_cost_history (product_id, old_cost, new_cost, changed_by, source)
    VALUES (NEW.id, COALESCE(OLD.cost_price, 0), COALESCE(NEW.cost_price, 0), auth.uid(), 'auto');
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_product_cost_history ON public.products;
CREATE TRIGGER trg_product_cost_history
  AFTER UPDATE OF cost_price ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.track_product_cost_history();

-- ---------------------------------------------------------------------
-- 2. Internal cost helpers (reused by overview + detail)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._product_wavg_cost(p_product_id uuid, p_branch_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $function$
  SELECT CASE WHEN SUM(b.quantity) > 0
    THEN round(SUM(b.quantity * b.unit_cost) / SUM(b.quantity), 2)
    ELSE 0 END
  FROM public.inventory_batches b
  WHERE b.product_id = p_product_id AND b.quantity > 0
    AND (p_branch_id IS NULL OR b.branch_id = p_branch_id)
$function$;

CREATE OR REPLACE FUNCTION public._raw_wavg_cost(p_raw_material_id uuid, p_branch_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $function$
  SELECT CASE WHEN SUM(b.quantity) > 0
    THEN round(SUM(b.quantity * b.unit_cost) / SUM(b.quantity), 2)
    ELSE COALESCE(
      (SELECT rm.default_cost FROM public.raw_materials rm WHERE rm.id = p_raw_material_id),
      0) END
  FROM public.raw_material_batches b
  WHERE b.raw_material_id = p_raw_material_id AND b.quantity > 0
    AND (p_branch_id IS NULL OR b.branch_id = p_branch_id)
$function$;

CREATE OR REPLACE FUNCTION public._product_bom_cost(p_product_id uuid, p_branch_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $function$
  SELECT COALESCE(round(SUM(
    pc.quantity * COALESCE(public._product_wavg_cost(pc.component_product_id, p_branch_id), 0)
  ), 2), 0)
  FROM public.product_components pc
  WHERE pc.product_id = p_product_id
$function$;

CREATE OR REPLACE FUNCTION public._product_recipe_cost(p_product_id uuid, p_branch_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $function$
  SELECT COALESCE(round(SUM(
    ri.quantity * (1 + COALESCE(ri.wastage_percent, 0) / 100.0) *
    COALESCE(public._raw_wavg_cost(ri.raw_material_id, p_branch_id), 0)
  ), 2), 0)
  FROM public.recipe_items ri
  JOIN public.recipes r ON r.id = ri.recipe_id
  WHERE r.product_id = p_product_id
    AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
$function$;

-- ---------------------------------------------------------------------
-- 3. get_costing_overview: per-product cost figures for the costing screen
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_costing_overview(
  p_branch_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id        uuid,
  product_name      text,
  barcode           text,
  sku               text,
  category_name     text,
  product_type      text,
  sale_price        numeric(12,2),
  unit_cost         numeric(12,2),
  theoretical_cost  numeric(12,2),
  actual_cost       numeric(12,2),
  component_count   bigint,
  recipe_item_count bigint
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product'),
    p.barcode,
    p.sku,
    c.name,
    COALESCE(p.product_type, 'ready'),
    COALESCE(p.sale_price, 0)::numeric(12,2),
    COALESCE(public._product_wavg_cost(p.id, v_scope), 0)::numeric(12,2),
    COALESCE(public._product_bom_cost(p.id, v_scope), 0)::numeric(12,2),
    COALESCE(public._product_recipe_cost(p.id, v_scope), 0)::numeric(12,2),
    (SELECT COUNT(*) FROM public.product_components pc WHERE pc.product_id = p.id)::bigint,
    (SELECT COUNT(*) FROM public.recipe_items ri JOIN public.recipes r ON r.id = ri.recipe_id
      WHERE r.product_id = p.id)::bigint
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
  WHERE p.is_active = true
    AND (v_scope IS NULL OR p.branch_id = v_scope)
  ORDER BY p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_costing_overview(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. get_product_costing_detail: deep detail for one product
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_product_costing_detail(
  p_product_id uuid,
  p_branch_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
  v_row record;
  v_components jsonb;
  v_recipe jsonb;
  v_history jsonb;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  SELECT
    p.id, p.name, p.barcode, p.sku,
    COALESCE(p.sale_price, 0) AS sale_price,
    COALESCE(public._product_wavg_cost(p.id, v_scope), 0) AS unit_cost,
    COALESCE(public._product_bom_cost(p.id, v_scope), 0) AS theoretical_cost,
    COALESCE(public._product_recipe_cost(p.id, v_scope), 0) AS actual_cost,
    (SELECT COUNT(*) FROM public.product_components pc WHERE pc.product_id = p.id) AS component_count,
    (SELECT COUNT(*) FROM public.recipe_items ri JOIN public.recipes r ON r.id = ri.recipe_id
      WHERE r.product_id = p.id) AS recipe_item_count
  INTO v_row
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'component_product_id', cp.id,
    'component_name', COALESCE(NULLIF(btrim(cp.name), ''), 'Component'),
    'quantity', pc.quantity,
    'unit_cost', COALESCE(public._product_wavg_cost(pc.component_product_id, v_scope), 0),
    'line_cost', round(pc.quantity * COALESCE(public._product_wavg_cost(pc.component_product_id, v_scope), 0), 2)
  ) ORDER BY cp.name), '[]'::jsonb)
  INTO v_components
  FROM public.product_components pc
  JOIN public.products cp ON cp.id = pc.component_product_id
  WHERE pc.product_id = p_product_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'raw_material_id', rm.id,
    'raw_material_name', COALESCE(NULLIF(btrim(rm.name), ''), 'Raw Material'),
    'quantity', ri.quantity,
    'wastage_percent', ri.wastage_percent,
    'unit_cost', COALESCE(public._raw_wavg_cost(ri.raw_material_id, v_scope), 0),
    'line_cost', round(ri.quantity * (1 + COALESCE(ri.wastage_percent, 0) / 100.0) *
      COALESCE(public._raw_wavg_cost(ri.raw_material_id, v_scope), 0), 2)
  ) ORDER BY rm.name), '[]'::jsonb)
  INTO v_recipe
  FROM public.recipe_items ri
  JOIN public.recipes r ON r.id = ri.recipe_id
  JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
  WHERE r.product_id = p_product_id
    AND (v_scope IS NULL OR r.branch_id = v_scope);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ch.id,
    'old_cost', ch.old_cost,
    'new_cost', ch.new_cost,
    'changed_at', ch.changed_at,
    'changed_by', COALESCE(NULLIF(btrim(u.username), ''), u.full_name, u.email, ''),
    'source', ch.source
  ) ORDER BY ch.changed_at DESC), '[]'::jsonb)
  INTO v_history
  FROM public.product_cost_history ch
  LEFT JOIN public.users u ON u.id = ch.changed_by
  WHERE ch.product_id = p_product_id;

  RETURN jsonb_build_object(
    'success', true,
    'product_id', v_row.id,
    'product_name', v_row.name,
    'barcode', v_row.barcode,
    'sku', v_row.sku,
    'sale_price', v_row.sale_price,
    'unit_cost', v_row.unit_cost,
    'theoretical_cost', v_row.theoretical_cost,
    'actual_cost', v_row.actual_cost,
    'component_count', v_row.component_count,
    'recipe_item_count', v_row.recipe_item_count,
    'components', v_components,
    'recipe_items', v_recipe,
    'history', v_history
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_product_costing_detail(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. get_cost_history: cost changes for one product
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_cost_history(
  p_product_id uuid,
  p_limit integer DEFAULT 50
) RETURNS TABLE (
  id         uuid,
  product_id uuid,
  old_cost   numeric(12,2),
  new_cost   numeric(12,2),
  changed_at timestamptz,
  changed_by text,
  source     text
) LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' STABLE
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
  LEFT JOIN public.users u ON u.id = ch.changed_by
  WHERE ch.product_id = p_product_id
  ORDER BY ch.changed_at DESC
  LIMIT GREATEST(LEAST(p_limit, 500), 1)
$function$;

GRANT EXECUTE ON FUNCTION public.get_cost_history(uuid, integer) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. get_supplier_price_impact: purchase-price trend per supplier item
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_supplier_price_impact(
  p_supplier_id uuid
) RETURNS TABLE (
  item_id          uuid,
  item_type        text,
  item_name        text,
  first_cost       numeric(12,2),
  last_cost        numeric(12,2),
  avg_cost         numeric(12,2),
  change_pct       numeric(10,2),
  purchase_count   bigint,
  last_purchased_at timestamptz
) LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
  SELECT
    p.id,
    'product'::text AS item_type,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product'),
    (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]::numeric(12,2),
    (array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1]::numeric(12,2),
    round(AVG(pi.unit_cost), 2)::numeric(12,2),
    round(CASE
      WHEN (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1] > 0
      THEN ((array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1] - (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]) * 100.0
        / (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]
      ELSE 0 END, 2)::numeric(10,2),
    COUNT(*)::bigint,
    MAX(pc.created_at)::timestamptz
  FROM public.purchase_items pi
  JOIN public.purchases pc ON pc.id = pi.purchase_id
  JOIN public.products p ON p.id = pi.product_id
  WHERE pc.supplier_id = p_supplier_id
    AND pc.status = 'completed'
    AND pi.product_id IS NOT NULL
  GROUP BY p.id
UNION ALL
  SELECT
    rm.id,
    'raw_material'::text,
    COALESCE(NULLIF(btrim(rm.name), ''), 'Raw Material'),
    (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]::numeric(12,2),
    (array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1]::numeric(12,2),
    round(AVG(pi.unit_cost), 2)::numeric(12,2),
    round(CASE
      WHEN (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1] > 0
      THEN ((array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1] - (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]) * 100.0
        / (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]
      ELSE 0 END, 2)::numeric(10,2),
    COUNT(*)::bigint,
    MAX(pc.created_at)::timestamptz
  FROM public.purchase_items pi
  JOIN public.purchases pc ON pc.id = pi.purchase_id
  JOIN public.raw_materials rm ON rm.id = pi.raw_material_id
  WHERE pc.supplier_id = p_supplier_id
    AND pc.status = 'completed'
    AND pi.raw_material_id IS NOT NULL
  GROUP BY rm.id
  ORDER BY 2 ASC, 3 ASC
$function$;

GRANT EXECUTE ON FUNCTION public.get_supplier_price_impact(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. get_order_margin: gross margin per sale order (COGS from the ledger)
--    inventory_ledger records sale deductions with entry_type='sale' and
--    reference_id = sale.id; total_cost is negative on deductions.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_order_margin(
  p_branch_id uuid DEFAULT NULL,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
) RETURNS TABLE (
  sale_id        uuid,
  invoice_number text,
  branch_id      uuid,
  sale_date      date,
  total          numeric(14,2),
  discount_amount numeric(14,2),
  cogs           numeric(16,2),
  gross_margin   numeric(16,2)
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    s.id,
    s.invoice_number,
    s.branch_id,
    s.created_at::date,
    COALESCE(s.total, 0),
    COALESCE(s.discount_amount, 0),
    COALESCE(-SUM(il.total_cost), 0)::numeric(16,2) AS cogs,
    round(COALESCE(s.total, 0) - COALESCE(-SUM(il.total_cost), 0), 2)::numeric(16,2) AS gross_margin
  FROM public.sales s
  LEFT JOIN public.inventory_ledger il
    ON il.reference_id = s.id AND il.entry_type = 'sale' AND il.reference_type = 'sale'
  WHERE (v_scope IS NULL OR s.branch_id = v_scope)
    AND (p_from IS NULL OR s.created_at::date >= p_from)
    AND (p_to IS NULL OR s.created_at::date <= p_to)
  GROUP BY s.id
  ORDER BY s.created_at DESC
  LIMIT 500;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_order_margin(uuid, date, date) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 075_procurement_workflow.sql
-- ----------------------------------------------------------------------------
-- =====================================================================
-- P0 Procurement Workflow: Purchase Request -> RFQ -> Supplier Quotation
-- -> Purchase Order (approval lifecycle) -> Receiving (GRN) -> Backorders
-- -> Payment (existing pay_supplier) + Supplier evaluation/history.
--
-- Additive-only. New tables and RPCs sit alongside the legacy
-- process_purchase quick path (unchanged). The PO reuses `purchases` so the
-- existing inventory/ledger/reporting chain stays intact:
--   * create_purchase_order  -> purchases with status 'draft' (no posting)
--   * update_purchase_order_status -> draft -> submitted -> approved
--   * receive_purchase_order -> GRN; inventory is added per receipt line;
--     when fully received the PO is posted to the ledger exactly like
--     process_purchase (inventory_fg/rm + vat_receivable + discount_received
--     + cash/bank + AP) via the idempotent _post_journal_entry.
--   * backorders = purchase_items.quantity - received_quantity.
--
-- All state transitions go through SECURITY DEFINER RPCs enforcing
-- is_pos_admin()/can_permission('purchases.manage') and branch isolation;
-- RLS policies below are a backstop and never weaken existing RLS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Workflow columns on existing documents
-- ---------------------------------------------------------------------
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS approved_by uuid REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS request_id uuid;

ALTER TABLE public.purchase_items
  ADD COLUMN IF NOT EXISTS received_quantity numeric(14,4) NOT NULL DEFAULT 0;

-- Status CHECK on purchases (additive, only when existing rows comply).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'purchases_status_check'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.purchases
    WHERE status IS NULL OR status NOT IN (
      'draft', 'submitted', 'approved', 'completed', 'partial', 'returned', 'cancelled'
    )
  ) THEN
    ALTER TABLE public.purchases ADD CONSTRAINT purchases_status_check
      CHECK (status IN ('draft', 'submitted', 'approved', 'completed', 'partial', 'returned', 'cancelled'));
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. Purchase Requests
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.purchase_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_number    text NOT NULL UNIQUE,
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  supplier_id       uuid REFERENCES public.suppliers(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'ordered', 'cancelled')),
  priority          text NOT NULL DEFAULT 'normal'
                    CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  expected_date     date,
  notes             text,
  requested_by      uuid REFERENCES public.users(id),
  approved_by       uuid REFERENCES public.users(id),
  approved_at       timestamptz,
  created_by        uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.purchase_requests IS 'طلبات الشراء (بداية سلسلة المشتريات)';
CREATE INDEX IF NOT EXISTS idx_purchase_requests_branch ON public.purchase_requests(branch_id, created_at);

-- FK from purchases.request_id (deferred until the table above exists).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchases_request_id_fk') THEN
    ALTER TABLE public.purchases ADD CONSTRAINT purchases_request_id_fk
      FOREIGN KEY (request_id) REFERENCES public.purchase_requests(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.purchase_request_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id        uuid NOT NULL REFERENCES public.purchase_requests(id) ON DELETE CASCADE,
  product_id        uuid REFERENCES public.products(id) ON DELETE SET NULL,
  raw_material_id   uuid REFERENCES public.raw_materials(id) ON DELETE SET NULL,
  quantity          numeric(14,4) NOT NULL CHECK (quantity > 0),
  unit_name         text NOT NULL DEFAULT 'piece',
  estimated_cost    numeric(12,2),
  notes             text,
  CONSTRAINT purchase_request_items_one_target CHECK (
    (product_id IS NOT NULL) <> (raw_material_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_purchase_request_items_request ON public.purchase_request_items(request_id);

INSERT INTO public.document_sequences (seq_type, next_value) VALUES ('purchase_request', 1)
ON CONFLICT (seq_type) DO NOTHING;

ALTER TABLE public.purchase_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_requests_select ON public.purchase_requests;
CREATE POLICY purchase_requests_select ON public.purchase_requests
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id());
DROP POLICY IF EXISTS purchase_requests_insert ON public.purchase_requests;
CREATE POLICY purchase_requests_insert ON public.purchase_requests
  FOR INSERT TO authenticated
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));
DROP POLICY IF EXISTS purchase_requests_update ON public.purchase_requests;
CREATE POLICY purchase_requests_update ON public.purchase_requests
  FOR UPDATE TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));
DROP POLICY IF EXISTS purchase_requests_delete ON public.purchase_requests;
CREATE POLICY purchase_requests_delete ON public.purchase_requests
  FOR DELETE TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));

ALTER TABLE public.purchase_request_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_request_items_select ON public.purchase_request_items;
CREATE POLICY purchase_request_items_select ON public.purchase_request_items
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR EXISTS (
    SELECT 1 FROM public.purchase_requests r
    WHERE r.id = request_id AND r.branch_id = get_branch_id()));
DROP POLICY IF EXISTS purchase_request_items_write ON public.purchase_request_items;
CREATE POLICY purchase_request_items_write ON public.purchase_request_items
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.purchase_requests r
    WHERE r.id = request_id AND r.branch_id = get_branch_id())))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.purchase_requests r
    WHERE r.id = request_id AND r.branch_id = get_branch_id())));

-- ---------------------------------------------------------------------
-- 2. RFQs
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rfqs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_number        text NOT NULL UNIQUE,
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  request_id        uuid REFERENCES public.purchase_requests(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'sent', 'received', 'awarded', 'cancelled')),
  due_date          date,
  notes             text,
  created_by        uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.rfqs IS 'طلبات عروض الأسعار (وسط سلسلة المشتريات)';
CREATE INDEX IF NOT EXISTS idx_rfqs_branch ON public.rfqs(branch_id, created_at);

CREATE TABLE IF NOT EXISTS public.rfq_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_id            uuid NOT NULL REFERENCES public.rfqs(id) ON DELETE CASCADE,
  product_id        uuid REFERENCES public.products(id) ON DELETE SET NULL,
  raw_material_id   uuid REFERENCES public.raw_materials(id) ON DELETE SET NULL,
  quantity          numeric(14,4) NOT NULL CHECK (quantity > 0),
  unit_name         text NOT NULL DEFAULT 'piece',
  notes             text,
  CONSTRAINT rfq_items_one_target CHECK (
    (product_id IS NOT NULL) <> (raw_material_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_rfq_items_rfq ON public.rfq_items(rfq_id);

INSERT INTO public.document_sequences (seq_type, next_value) VALUES ('rfq', 1)
ON CONFLICT (seq_type) DO NOTHING;

ALTER TABLE public.rfqs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rfqs_select ON public.rfqs;
CREATE POLICY rfqs_select ON public.rfqs
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id());
DROP POLICY IF EXISTS rfqs_write ON public.rfqs;
CREATE POLICY rfqs_write ON public.rfqs
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));

ALTER TABLE public.rfq_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rfq_items_select ON public.rfq_items;
CREATE POLICY rfq_items_select ON public.rfq_items
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR EXISTS (
    SELECT 1 FROM public.rfqs r
    WHERE r.id = rfq_id AND r.branch_id = get_branch_id()));
DROP POLICY IF EXISTS rfq_items_write ON public.rfq_items;
CREATE POLICY rfq_items_write ON public.rfq_items
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.rfqs r
    WHERE r.id = rfq_id AND r.branch_id = get_branch_id())))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.rfqs r
    WHERE r.id = rfq_id AND r.branch_id = get_branch_id())));

-- ---------------------------------------------------------------------
-- 3. Supplier Quotations
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supplier_quotations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_number  text NOT NULL UNIQUE,
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  rfq_id            uuid REFERENCES public.rfqs(id) ON DELETE SET NULL,
  supplier_id       uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  status            text NOT NULL DEFAULT 'received'
                    CHECK (status IN ('draft', 'received', 'selected', 'rejected', 'expired')),
  valid_until       date,
  delivery_days     integer,
  total             numeric(14,2) NOT NULL DEFAULT 0,
  notes             text,
  created_by        uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.supplier_quotations IS 'عروض أسعار الموردين';
CREATE INDEX IF NOT EXISTS idx_supplier_quotations_rfq ON public.supplier_quotations(rfq_id, supplier_id);

CREATE TABLE IF NOT EXISTS public.supplier_quotation_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id      uuid NOT NULL REFERENCES public.supplier_quotations(id) ON DELETE CASCADE,
  product_id        uuid REFERENCES public.products(id) ON DELETE SET NULL,
  raw_material_id   uuid REFERENCES public.raw_materials(id) ON DELETE SET NULL,
  quantity          numeric(14,4) NOT NULL CHECK (quantity > 0),
  unit_cost         numeric(12,2) NOT NULL DEFAULT 0,
  total             numeric(14,2) NOT NULL DEFAULT 0,
  CONSTRAINT supplier_quotation_items_one_target CHECK (
    (product_id IS NOT NULL) <> (raw_material_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_supplier_quotation_items_quote ON public.supplier_quotation_items(quotation_id);

INSERT INTO public.document_sequences (seq_type, next_value) VALUES ('supplier_quotation', 1)
ON CONFLICT (seq_type) DO NOTHING;

ALTER TABLE public.supplier_quotations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS supplier_quotations_select ON public.supplier_quotations;
CREATE POLICY supplier_quotations_select ON public.supplier_quotations
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id());
DROP POLICY IF EXISTS supplier_quotations_write ON public.supplier_quotations;
CREATE POLICY supplier_quotations_write ON public.supplier_quotations
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));

ALTER TABLE public.supplier_quotation_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS supplier_quotation_items_select ON public.supplier_quotation_items;
CREATE POLICY supplier_quotation_items_select ON public.supplier_quotation_items
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR EXISTS (
    SELECT 1 FROM public.supplier_quotations q
    WHERE q.id = quotation_id AND q.branch_id = get_branch_id()));
DROP POLICY IF EXISTS supplier_quotation_items_write ON public.supplier_quotation_items;
CREATE POLICY supplier_quotation_items_write ON public.supplier_quotation_items
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.supplier_quotations q
    WHERE q.id = quotation_id AND q.branch_id = get_branch_id())))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.supplier_quotations q
    WHERE q.id = quotation_id AND q.branch_id = get_branch_id())));

-- ---------------------------------------------------------------------
-- 4. Receiving (GRN) + backorder tracking
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.purchase_receipts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_number    text NOT NULL UNIQUE,
  purchase_id       uuid NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id      uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  received_by       uuid REFERENCES public.users(id),
  notes             text,
  received_at       timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.purchase_receipts IS 'إيصالات استلام المشتريات (GRN)';
CREATE INDEX IF NOT EXISTS idx_purchase_receipts_purchase ON public.purchase_receipts(purchase_id);
CREATE INDEX IF NOT EXISTS idx_purchase_receipts_branch ON public.purchase_receipts(branch_id, received_at);

CREATE TABLE IF NOT EXISTS public.purchase_receipt_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id         uuid NOT NULL REFERENCES public.purchase_receipts(id) ON DELETE CASCADE,
  purchase_item_id   uuid NOT NULL REFERENCES public.purchase_items(id) ON DELETE CASCADE,
  quantity_received  numeric(14,4) NOT NULL CHECK (quantity_received > 0),
  unit_cost          numeric(12,2) NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_purchase_receipt_items_receipt ON public.purchase_receipt_items(receipt_id);
CREATE INDEX IF NOT EXISTS idx_purchase_receipt_items_pitem ON public.purchase_receipt_items(purchase_item_id);

INSERT INTO public.document_sequences (seq_type, next_value) VALUES ('purchase_receipt', 1)
ON CONFLICT (seq_type) DO NOTHING;

ALTER TABLE public.purchase_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_receipts_select ON public.purchase_receipts;
CREATE POLICY purchase_receipts_select ON public.purchase_receipts
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR branch_id = get_branch_id());
DROP POLICY IF EXISTS purchase_receipts_write ON public.purchase_receipts;
CREATE POLICY purchase_receipts_write ON public.purchase_receipts
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND branch_id = get_branch_id()));

ALTER TABLE public.purchase_receipt_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_receipt_items_select ON public.purchase_receipt_items;
CREATE POLICY purchase_receipt_items_select ON public.purchase_receipt_items
  FOR SELECT TO authenticated
  USING (is_pos_admin() OR EXISTS (
    SELECT 1 FROM public.purchase_receipts r
    WHERE r.id = receipt_id AND r.branch_id = get_branch_id()));
DROP POLICY IF EXISTS purchase_receipt_items_write ON public.purchase_receipt_items;
CREATE POLICY purchase_receipt_items_write ON public.purchase_receipt_items
  FOR ALL TO authenticated
  USING (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.purchase_receipts r
    WHERE r.id = receipt_id AND r.branch_id = get_branch_id())))
  WITH CHECK (is_pos_admin() OR (can_permission('purchases.manage') AND EXISTS (
    SELECT 1 FROM public.purchase_receipts r
    WHERE r.id = receipt_id AND r.branch_id = get_branch_id())));

-- ---------------------------------------------------------------------
-- 5. create_purchase_request: draft request with optional line items
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_request(
  p_branch_id uuid,
  p_supplier_id uuid DEFAULT NULL,
  p_priority text DEFAULT 'normal',
  p_expected_date date DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_request_id uuid;
  v_number text;
  v_user_branch uuid;
  v_item jsonb;
  v_rows integer := 0;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Purchase requests require the purchases.manage permission.');
    END IF;
    IF p_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    v_number := (public.next_document_number('purchase_request')->>'number')::text;

    INSERT INTO public.purchase_requests
      (request_number, branch_id, supplier_id, status, priority, expected_date, notes, requested_by, created_by)
    VALUES (v_number, p_branch_id, p_supplier_id, 'draft', COALESCE(p_priority, 'normal'),
            p_expected_date, p_notes, auth.uid(), auth.uid())
    RETURNING id INTO v_request_id;

    IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        INSERT INTO public.purchase_request_items
          (request_id, product_id, raw_material_id, quantity, unit_name, estimated_cost, notes)
        VALUES (v_request_id,
          NULLIF(v_item->>'product_id', '')::uuid,
          NULLIF(v_item->>'raw_material_id', '')::uuid,
          COALESCE((v_item->>'quantity')::numeric, 0),
          COALESCE(NULLIF(v_item->>'unit_name', ''), 'piece'),
          NULLIF(v_item->>'estimated_cost', '')::numeric,
          NULLIF(v_item->>'notes', ''));
        v_rows := v_rows + 1;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true, 'request_id', v_request_id,
      'request_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_purchase_request(uuid, uuid, text, date, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. update_purchase_request_status: draft->submitted->approved/rejected/...
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_purchase_request_status(
  p_request_id uuid,
  p_status text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_request record;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_request FROM public.purchase_requests WHERE id = p_request_id FOR UPDATE;
    IF v_request.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'REQUEST_NOT_FOUND');
    END IF;
    IF NOT is_pos_admin() AND get_branch_id() IS NOT NULL AND get_branch_id() <> v_request.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    IF p_status = 'submitted' THEN
      IF v_request.status <> 'draft' THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_request.status, 'to', p_status);
      END IF;
    ELSIF p_status IN ('approved', 'rejected') THEN
      IF v_request.status <> 'submitted' THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_request.status, 'to', p_status);
      END IF;
    ELSIF p_status = 'cancelled' THEN
      IF v_request.status NOT IN ('draft', 'submitted') THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_request.status, 'to', p_status);
      END IF;
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
    END IF;

    UPDATE public.purchase_requests
    SET status = p_status,
        approved_by = CASE WHEN p_status = 'approved' THEN auth.uid() ELSE approved_by END,
        approved_at = CASE WHEN p_status = 'approved' THEN now() ELSE approved_at END
    WHERE id = p_request_id;

    RETURN jsonb_build_object('success', true, 'request_id', p_request_id, 'status', p_status);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.update_purchase_request_status(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. create_rfq: standalone or copied from an approved purchase request
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_rfq(
  p_branch_id uuid,
  p_request_id uuid DEFAULT NULL,
  p_due_date date DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_rfq_id uuid;
  v_number text;
  v_user_branch uuid;
  v_item record;
  v_rows integer := 0;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    IF p_branch_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    v_number := (public.next_document_number('rfq')->>'number')::text;

    INSERT INTO public.rfqs (rfq_number, branch_id, request_id, status, due_date, notes, created_by)
    VALUES (v_number, p_branch_id, p_request_id, 'draft', p_due_date, p_notes, auth.uid())
    RETURNING id INTO v_rfq_id;

    IF p_request_id IS NOT NULL THEN
      -- Copy items from the (approved) purchase request.
      FOR v_item IN
        SELECT product_id, raw_material_id, quantity, unit_name, notes
        FROM public.purchase_request_items WHERE request_id = p_request_id
      LOOP
        INSERT INTO public.rfq_items (rfq_id, product_id, raw_material_id, quantity, unit_name, notes)
        VALUES (v_rfq_id, v_item.product_id, v_item.raw_material_id, v_item.quantity,
                COALESCE(v_item.unit_name, 'piece'), v_item.notes);
        v_rows := v_rows + 1;
      END LOOP;
    ELSIF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        INSERT INTO public.rfq_items (rfq_id, product_id, raw_material_id, quantity, unit_name, notes)
        VALUES (v_rfq_id,
          NULLIF(v_item->>'product_id', '')::uuid,
          NULLIF(v_item->>'raw_material_id', '')::uuid,
          COALESCE((v_item->>'quantity')::numeric, 0),
          COALESCE(NULLIF(v_item->>'unit_name', ''), 'piece'),
          NULLIF(v_item->>'notes', ''));
        v_rows := v_rows + 1;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('success', true, 'rfq_id', v_rfq_id,
      'rfq_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_rfq(uuid, uuid, date, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. update_rfq_status: draft->sent->received; award/cancel handling
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_rfq_status(
  p_rfq_id uuid,
  p_status text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_rfq record;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_rfq FROM public.rfqs WHERE id = p_rfq_id FOR UPDATE;
    IF v_rfq.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'RFQ_NOT_FOUND');
    END IF;
    IF NOT is_pos_admin() AND get_branch_id() IS NOT NULL AND get_branch_id() <> v_rfq.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    IF p_status IN ('sent', 'received') THEN
      IF v_rfq.status NOT IN ('draft', 'sent', 'received') THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_rfq.status, 'to', p_status);
      END IF;
    ELSIF p_status = 'cancelled' THEN
      IF v_rfq.status IN ('awarded', 'cancelled') THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_rfq.status, 'to', p_status);
      END IF;
    ELSIF p_status = 'awarded' THEN
      IF NOT EXISTS (SELECT 1 FROM public.supplier_quotations q
                     WHERE q.rfq_id = p_rfq_id AND q.status = 'selected') THEN
        RETURN jsonb_build_object('success', false, 'error', 'NO_SELECTED_QUOTATION');
      END IF;
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
    END IF;

    UPDATE public.rfqs SET status = p_status WHERE id = p_rfq_id;
    RETURN jsonb_build_object('success', true, 'rfq_id', p_rfq_id, 'status', p_status);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.update_rfq_status(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 9. record_supplier_quotation: one supplier's reply to an RFQ
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_supplier_quotation(
  p_rfq_id uuid,
  p_supplier_id uuid,
  p_valid_until date DEFAULT NULL,
  p_delivery_days integer DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_rfq record;
  v_quotation_id uuid;
  v_number text;
  v_item jsonb;
  v_total numeric(14,2) := 0;
  v_rows integer := 0;
  v_unit_cost numeric(12,2);
  v_qty numeric(14,4);
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_rfq FROM public.rfqs WHERE id = p_rfq_id;
    IF v_rfq.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'RFQ_NOT_FOUND');
    END IF;
    IF NOT is_pos_admin() AND get_branch_id() IS NOT NULL AND get_branch_id() <> v_rfq.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
    IF v_rfq.status IN ('awarded', 'cancelled') THEN
      RETURN jsonb_build_object('success', false, 'error', 'RFQ_CLOSED', 'status', v_rfq.status);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = p_supplier_id AND branch_id = v_rfq.branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_IN_BRANCH');
    END IF;
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_ITEMS');
    END IF;

    v_number := (public.next_document_number('supplier_quotation')->>'number')::text;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
      END IF;
      v_unit_cost := COALESCE((v_item->>'unit_cost')::numeric, 0);
      v_qty := COALESCE((v_item->>'quantity')::numeric, 0);
      v_total := v_total + v_unit_cost * v_qty;
    END LOOP;

    INSERT INTO public.supplier_quotations
      (quotation_number, branch_id, rfq_id, supplier_id, status, valid_until, delivery_days, total, notes, created_by)
    VALUES (v_number, v_rfq.branch_id, p_rfq_id, p_supplier_id, 'received',
            p_valid_until, p_delivery_days, round(v_total, 2), p_notes, auth.uid())
    RETURNING id INTO v_quotation_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_unit_cost := COALESCE((v_item->>'unit_cost')::numeric, 0);
      v_qty := COALESCE((v_item->>'quantity')::numeric, 0);
      INSERT INTO public.supplier_quotation_items
        (quotation_id, product_id, raw_material_id, quantity, unit_cost, total)
      VALUES (v_quotation_id,
        NULLIF(v_item->>'product_id', '')::uuid,
        NULLIF(v_item->>'raw_material_id', '')::uuid,
        v_qty, v_unit_cost, round(v_unit_cost * v_qty, 2));
      v_rows := v_rows + 1;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'quotation_id', v_quotation_id,
      'quotation_number', v_number, 'items_added', v_rows, 'total', round(v_total, 2));
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.record_supplier_quotation(uuid, uuid, date, integer, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 10. select_supplier_quotation: pick a winner, reject the rest, award the RFQ
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.select_supplier_quotation(
  p_quotation_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_quote record;
  v_rfq record;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_quote FROM public.supplier_quotations WHERE id = p_quotation_id FOR UPDATE;
    IF v_quote.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'QUOTATION_NOT_FOUND');
    END IF;
    IF NOT is_pos_admin() AND get_branch_id() IS NOT NULL AND get_branch_id() <> v_quote.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
    IF v_quote.status <> 'received' THEN
      RETURN jsonb_build_object('success', false, 'error', 'QUOTATION_NOT_RECEIVED', 'status', v_quote.status);
    END IF;

    IF v_quote.rfq_id IS NOT NULL THEN
      UPDATE public.supplier_quotations SET status = 'rejected'
      WHERE rfq_id = v_quote.rfq_id AND id <> v_quote.id AND status = 'received';
      SELECT * INTO v_rfq FROM public.rfqs WHERE id = v_quote.rfq_id;
      IF v_rfq.id IS NOT NULL AND v_rfq.status <> 'awarded' THEN
        UPDATE public.rfqs SET status = 'awarded' WHERE id = v_quote.rfq_id;
      END IF;
    END IF;

    UPDATE public.supplier_quotations SET status = 'selected' WHERE id = v_quote.id;

    RETURN jsonb_build_object('success', true, 'quotation_id', v_quote.id,
      'rfq_id', v_quote.rfq_id, 'status', 'selected');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.select_supplier_quotation(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 11. get_rfq_comparison: per line item, quote from every supplier
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_rfq_comparison(p_rfq_id uuid)
RETURNS TABLE (
  item_id            uuid,
  item_type          text,
  item_name          text,
  requested_quantity numeric,
  best_supplier_id   uuid,
  best_supplier_name text,
  best_unit_cost     numeric(12,2),
  avg_unit_cost      numeric(12,2),
  quotation_count    bigint,
  quotations         jsonb
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_branch uuid;
BEGIN
  SELECT r.branch_id INTO v_branch FROM public.rfqs r WHERE r.id = p_rfq_id;
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'RFQ_NOT_FOUND';
  END IF;
  IF NOT is_pos_admin() AND get_branch_id() <> v_branch THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;

  RETURN QUERY
    SELECT
      COALESCE(ri.product_id, ri.raw_material_id) AS item_id,
      CASE WHEN ri.product_id IS NOT NULL THEN 'product' ELSE 'raw_material' END AS item_type,
      COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(rm.name), ''), '?') AS item_name,
      ri.quantity AS requested_quantity,
      (array_agg(q.supplier_id ORDER BY ql.unit_cost ASC))[1] AS best_supplier_id,
      (array_agg(s.name ORDER BY ql.unit_cost ASC))[1] AS best_supplier_name,
      (array_agg(ql.unit_cost ORDER BY ql.unit_cost ASC))[1] AS best_unit_cost,
      round(AVG(ql.unit_cost), 2) AS avg_unit_cost,
      COUNT(ql.id) AS quotation_count,
      COALESCE(jsonb_agg(jsonb_build_object(
        'quotation_id', q.id,
        'supplier_id', q.supplier_id,
        'supplier_name', s.name,
        'unit_cost', ql.unit_cost,
        'quotation_number', q.quotation_number,
        'status', q.status
      )), '[]'::jsonb) AS quotations
    FROM public.rfq_items ri
    LEFT JOIN public.products p ON p.id = ri.product_id
    LEFT JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
    LEFT JOIN public.supplier_quotation_items ql
      ON ql.product_id IS NOT DISTINCT FROM ri.product_id
     AND ql.raw_material_id IS NOT DISTINCT FROM ri.raw_material_id
    LEFT JOIN public.supplier_quotations q ON q.id = ql.quotation_id
    LEFT JOIN public.suppliers s ON s.id = q.supplier_id
    WHERE ri.rfq_id = p_rfq_id
      AND (q.id IS NULL OR q.status IN ('received', 'selected'))
    GROUP BY ri.id, ri.product_id, ri.raw_material_id, ri.quantity, p.name, rm.name
    ORDER BY 3 ASC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_rfq_comparison(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 12. create_purchase_order: draft PO (direct or from a selected quotation)
--     No inventory/ledger posting happens at this stage.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_order(
  p_branch_id uuid,
  p_supplier_id uuid,
  p_warehouse_id uuid DEFAULT NULL,
  p_payment_method text DEFAULT 'cash',
  p_notes text DEFAULT NULL,
  p_items jsonb DEFAULT NULL,
  p_quotation_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase_id uuid;
  v_number text;
  v_user_branch uuid;
  v_quote record;
  v_qitem record;
  v_item jsonb;
  v_unit_name text;
  v_total numeric(14,2) := 0;
  v_rows integer := 0;
  v_request_id uuid;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED',
        'detail', 'Creating purchase orders requires the purchases.manage permission.');
    END IF;
    IF p_branch_id IS NULL OR p_supplier_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'MISSING_SUPPLIER_BRANCH');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = p_supplier_id AND branch_id = p_branch_id) THEN
      RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_IN_BRANCH');
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> p_branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    IF p_quotation_id IS NOT NULL THEN
      SELECT * INTO v_quote FROM public.supplier_quotations WHERE id = p_quotation_id;
      IF v_quote.id IS NULL OR v_quote.status <> 'selected' THEN
        RETURN jsonb_build_object('success', false, 'error', 'QUOTATION_NOT_SELECTED');
      END IF;
      IF v_quote.branch_id <> p_branch_id OR v_quote.supplier_id <> p_supplier_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'QUOTATION_MISMATCH');
      END IF;
      SELECT r.request_id INTO v_request_id FROM public.rfqs r WHERE r.id = v_quote.rfq_id;
    END IF;

    v_number := (public.next_document_number('purchase')->>'number')::text;

    INSERT INTO public.purchases
      (invoice_number, supplier_id, branch_id, warehouse_id, buyer_id,
       subtotal, discount_amount, tax_amount, total, paid_amount, payment_method, status, notes, request_id)
    VALUES (v_number, p_supplier_id, p_branch_id, p_warehouse_id, auth.uid(),
      0, 0, 0, 0, 0, COALESCE(p_payment_method, 'cash'), 'draft', p_notes, v_request_id)
    RETURNING id INTO v_purchase_id;

    IF p_quotation_id IS NOT NULL THEN
      FOR v_qitem IN
        SELECT product_id, raw_material_id, quantity, unit_cost
        FROM public.supplier_quotation_items WHERE quotation_id = p_quotation_id
      LOOP
        IF v_qitem.product_id IS NOT NULL THEN
          v_unit_name := 'piece';
        ELSE
          SELECT COALESCE(u.symbol, u.name, 'وحدة') INTO v_unit_name
          FROM public.raw_materials rm LEFT JOIN public.units u ON u.id = rm.unit_id
          WHERE rm.id = v_qitem.raw_material_id;
        END IF;
        INSERT INTO public.purchase_items (purchase_id, product_id, raw_material_id, unit_name, quantity, unit_cost, total)
        VALUES (v_purchase_id, v_qitem.product_id, v_qitem.raw_material_id,
                COALESCE(v_unit_name, 'piece'), v_qitem.quantity, v_qitem.unit_cost,
                round(v_qitem.quantity * v_qitem.unit_cost, 2));
        v_total := v_total + v_qitem.quantity * v_qitem.unit_cost;
        v_rows := v_rows + 1;
      END LOOP;
    ELSIF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
      LOOP
        IF (v_item->>'product_id') IS NULL AND (v_item->>'raw_material_id') IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
        END IF;
        INSERT INTO public.purchase_items
          (purchase_id, product_id, raw_material_id, unit_name, quantity, unit_cost, total)
        VALUES (v_purchase_id,
          NULLIF(v_item->>'product_id', '')::uuid,
          NULLIF(v_item->>'raw_material_id', '')::uuid,
          COALESCE(NULLIF(v_item->>'unit_name', ''), 'piece'),
          COALESCE((v_item->>'quantity')::numeric, 0),
          COALESCE((v_item->>'unit_cost')::numeric, 0),
          round(COALESCE((v_item->>'quantity')::numeric, 0) * COALESCE((v_item->>'unit_cost')::numeric, 0), 2));
        v_rows := v_rows + 1;
      END LOOP;
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_ITEMS');
    END IF;

    UPDATE public.purchases SET total = round(v_total, 2), subtotal = round(v_total, 2)
    WHERE id = v_purchase_id;

    IF v_request_id IS NOT NULL THEN
      UPDATE public.purchase_requests SET status = 'ordered'
      WHERE id = v_request_id AND status = 'approved';
    END IF;

    RETURN jsonb_build_object('success', true, 'purchase_id', v_purchase_id,
      'invoice_number', v_number, 'items_added', v_rows);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_purchase_order(uuid, uuid, uuid, text, text, jsonb, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 13. update_purchase_order_status: draft->submitted->approved/cancelled
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_purchase_order_status(
  p_purchase_id uuid,
  p_status text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase record;
BEGIN
  BEGIN
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_purchase FROM public.purchases WHERE id = p_purchase_id FOR UPDATE;
    IF v_purchase.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
    END IF;
    IF NOT is_pos_admin() AND get_branch_id() IS NOT NULL AND get_branch_id() <> v_purchase.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;

    IF p_status = 'submitted' THEN
      IF v_purchase.status <> 'draft' THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_purchase.status, 'to', p_status);
      END IF;
    ELSIF p_status = 'approved' THEN
      IF v_purchase.status <> 'submitted' THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_purchase.status, 'to', p_status);
      END IF;
    ELSIF p_status = 'cancelled' THEN
      IF v_purchase.status NOT IN ('draft', 'submitted') THEN
        RETURN jsonb_build_object('success', false, 'error', 'BAD_TRANSITION', 'from', v_purchase.status, 'to', p_status);
      END IF;
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS');
    END IF;

    UPDATE public.purchases
    SET status = p_status,
        approved_by = CASE WHEN p_status = 'approved' THEN auth.uid() ELSE approved_by END,
        approved_at = CASE WHEN p_status = 'approved' THEN now() ELSE approved_at END
    WHERE id = p_purchase_id;

    RETURN jsonb_build_object('success', true, 'purchase_id', p_purchase_id, 'status', p_status);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.update_purchase_order_status(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 14. receive_purchase_order: GRN; adds inventory per received line and,
--     when the PO is fully received, posts the purchase journal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_purchase_order(
  p_purchase_id uuid,
  p_receipt_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase record;
  v_user_branch uuid;
  v_receipt_id uuid;
  v_number text;
  v_item jsonb;
  v_pitem record;
  v_qty numeric(14,4);
  v_res jsonb;
  v_stock numeric(14,4);
  v_stock_val numeric(14,2);
  v_new_cost numeric(12,2);
  v_fully_received boolean := true;
  v_rows integer := 0;
  v_goods_fg numeric(14,2) := 0;
  v_goods_rm numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_paid numeric(14,2);
  v_ap numeric(14,2);
BEGIN
  BEGIN
    IF p_receipt_items IS NULL OR jsonb_array_length(p_receipt_items) = 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'EMPTY_RECEIPT');
    END IF;
    IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
    SELECT * INTO v_purchase FROM public.purchases WHERE id = p_purchase_id FOR UPDATE;
    IF v_purchase.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
    END IF;
    IF v_purchase.status NOT IN ('approved', 'submitted', 'partial') THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_RECEIVABLE', 'status', v_purchase.status);
    END IF;
    IF NOT is_pos_admin() THEN
      SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
      IF v_user_branch IS NOT NULL AND v_user_branch <> v_purchase.branch_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      END IF;
    END IF;

    -- Validate every line against the ordered items before writing anything.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
    LOOP
      v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);
      IF v_qty <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
      END IF;
      SELECT * INTO v_pitem FROM public.purchase_items
      WHERE id = (v_item->>'purchase_item_id')::uuid;
      IF v_pitem.id IS NULL OR v_purchase.id <> (
        SELECT purchase_id FROM public.purchase_items WHERE id = (v_item->>'purchase_item_id')::uuid
      ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_ITEM_NOT_FOUND');
      END IF;
      IF v_qty > v_pitem.quantity - COALESCE(v_pitem.received_quantity, 0) THEN
        RETURN jsonb_build_object('success', false, 'error', 'OVER_RECEIPT',
          'purchase_item_id', v_item->>'purchase_item_id',
          'ordered', v_pitem.quantity, 'already_received', v_pitem.received_quantity, 'receiving', v_qty);
      END IF;
    END LOOP;

    v_number := (public.next_document_number('purchase_receipt')->>'number')::text;

    INSERT INTO public.purchase_receipts
      (receipt_number, purchase_id, branch_id, warehouse_id, received_by, notes)
    VALUES (v_number, p_purchase_id, v_purchase.branch_id, v_purchase.warehouse_id, auth.uid(),
            NULL)
    RETURNING id INTO v_receipt_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
    LOOP
      v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);

      SELECT * INTO v_pitem FROM public.purchase_items WHERE id = (v_item->>'purchase_item_id')::uuid;

      INSERT INTO public.purchase_receipt_items (receipt_id, purchase_item_id, quantity_received, unit_cost)
      VALUES (v_receipt_id, v_pitem.id, v_qty, v_pitem.unit_cost);

      IF v_pitem.product_id IS NOT NULL THEN
        IF v_purchase.warehouse_id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED',
            'detail', 'Select a warehouse to receive product items.');
        END IF;
        v_res := public._product_inv_add(v_pitem.product_id, v_purchase.warehouse_id, v_purchase.branch_id,
          v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
          'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;

        SELECT COALESCE(SUM(b.quantity), 0), COALESCE(SUM(b.quantity * b.unit_cost), 0)
        INTO v_stock, v_stock_val
        FROM public.inventory_batches b WHERE b.product_id = v_pitem.product_id;
        v_new_cost := CASE WHEN v_stock > 0 THEN round(v_stock_val / v_stock, 2) ELSE v_pitem.unit_cost END;
        UPDATE public.products SET cost_price = v_new_cost, updated_at = now() WHERE id = v_pitem.product_id;

        v_goods_fg := round(v_goods_fg + v_qty * v_pitem.unit_cost, 2);
      ELSE
        v_res := public._raw_add(v_pitem.raw_material_id, v_purchase.branch_id,
          v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
          'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid());
        IF NOT (v_res->>'success')::boolean THEN
          RETURN v_res;
        END IF;
        v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
      END IF;

      UPDATE public.purchase_items
      SET received_quantity = COALESCE(received_quantity, 0) + v_qty
      WHERE id = v_pitem.id;

      v_rows := v_rows + 1;
    END LOOP;

    -- Any remaining ordered quantity means the PO is still on backorder.
    SELECT EXISTS (
      SELECT 1 FROM public.purchase_items
      WHERE purchase_id = p_purchase_id
        AND quantity - COALESCE(received_quantity, 0) > 0
    ) INTO v_fully_received;
    v_fully_received := NOT v_fully_received;

    -- ===== LEDGER POSTING (only when the PO is fully received) =====
    IF v_fully_received THEN
      v_paid := round(COALESCE(v_purchase.paid_amount, 0), 2);
      v_ap := round(COALESCE(v_purchase.total, 0) - v_paid, 2);

      IF v_goods_fg > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_goods_fg, 'credit', 0, 'note', v_purchase.invoice_number);
        v_dr := v_dr + v_goods_fg;
      END IF;
      IF v_goods_rm > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_goods_rm, 'credit', 0, 'note', v_purchase.invoice_number);
        v_dr := v_dr + v_goods_rm;
      END IF;
      IF COALESCE(v_purchase.tax_amount, 0) > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'vat_receivable', 'debit', v_purchase.tax_amount, 'credit', 0);
        v_dr := v_dr + v_purchase.tax_amount;
      END IF;
      IF COALESCE(v_purchase.discount_amount, 0) > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', 0, 'credit', v_purchase.discount_amount);
        v_cr := v_cr + v_purchase.discount_amount;
      END IF;
      IF v_paid > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', CASE WHEN COALESCE(v_purchase.payment_method, 'cash') = 'cash' THEN 'cash' ELSE 'bank' END,
          'debit', 0, 'credit', v_paid, 'note', v_purchase.invoice_number);
        v_cr := v_cr + v_paid;
      END IF;
      IF v_ap > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_key', 'ap', 'debit', 0, 'credit', v_ap,
          'supplier_id', v_purchase.supplier_id, 'note', v_purchase.invoice_number);
        v_cr := v_cr + v_ap;
      END IF;

      v_diff := round(v_dr - v_cr, 2);
      IF v_diff <> 0 THEN
        IF v_diff > 0 THEN
          v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', 0, 'credit', v_diff);
        ELSE
          v_lines := v_lines || jsonb_build_object('account_key', 'discount_received', 'debit', -v_diff, 'credit', 0);
        END IF;
      END IF;

      PERFORM public._post_journal_entry(v_purchase.branch_id, 'purchase', p_purchase_id,
        v_purchase.invoice_number, 'فاتورة شراء ' || v_purchase.invoice_number, v_lines);
    END IF;

    UPDATE public.purchases SET status = CASE WHEN v_fully_received THEN 'completed' ELSE 'partial' END
    WHERE id = p_purchase_id;

    RETURN jsonb_build_object('success', true, 'receipt_id', v_receipt_id,
      'receipt_number', v_number, 'items_received', v_rows,
      'fully_received', v_fully_received, 'status', CASE WHEN v_fully_received THEN 'completed' ELSE 'partial' END);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.receive_purchase_order(uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 15. get_purchase_backorders: open lines awaiting receipt
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_purchase_backorders(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  purchase_id      uuid,
  invoice_number   text,
  supplier_id      uuid,
  supplier_name    text,
  purchase_item_id uuid,
  product_id       uuid,
  raw_material_id  uuid,
  item_name        text,
  item_type        text,
  unit_name        text,
  ordered_quantity numeric,
  received_quantity numeric,
  remaining        numeric,
  unit_cost        numeric(12,2),
  status           text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
BEGIN
  IF p_branch_id IS NOT NULL AND NOT is_pos_admin()
     AND get_branch_id() IS NOT NULL AND get_branch_id() <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;
  RETURN QUERY
    SELECT
      pc.id, pc.invoice_number, pc.supplier_id, s.name,
      pi.id, pi.product_id, pi.raw_material_id,
      COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(rm.name), ''), '?'),
      CASE WHEN pi.product_id IS NOT NULL THEN 'product' ELSE 'raw_material' END,
      pi.unit_name, pi.quantity, COALESCE(pi.received_quantity, 0),
      pi.quantity - COALESCE(pi.received_quantity, 0),
      pi.unit_cost, pc.status
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
GRANT EXECUTE ON FUNCTION public.get_purchase_backorders(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 16. get_purchase_receipts: GRN list with PO + supplier context
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_purchase_receipts(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  receipt_id     uuid,
  receipt_number text,
  purchase_id    uuid,
  invoice_number text,
  supplier_id    uuid,
  supplier_name  text,
  branch_id      uuid,
  warehouse_id   uuid,
  received_by    uuid,
  received_at    timestamptz,
  notes          text,
  item_count     bigint,
  total_quantity numeric
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
BEGIN
  IF p_branch_id IS NOT NULL AND NOT is_pos_admin()
     AND get_branch_id() IS NOT NULL AND get_branch_id() <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;
  RETURN QUERY
    SELECT
      r.id, r.receipt_number, r.purchase_id, pc.invoice_number,
      pc.supplier_id, s.name, r.branch_id, r.warehouse_id, r.received_by, r.received_at, r.notes,
      COUNT(ri.id), COALESCE(SUM(ri.quantity_received), 0)
    FROM public.purchase_receipts r
    JOIN public.purchases pc ON pc.id = r.purchase_id
    JOIN public.suppliers s ON s.id = pc.supplier_id
    LEFT JOIN public.purchase_receipt_items ri ON ri.receipt_id = r.id
    WHERE (p_branch_id IS NULL OR r.branch_id = p_branch_id)
      AND (is_pos_admin() OR r.branch_id = get_branch_id())
    GROUP BY r.id, pc.invoice_number, pc.supplier_id, s.name
    ORDER BY r.received_at DESC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_purchase_receipts(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 17. get_supplier_evaluation: supplier performance from real documents
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_supplier_evaluation(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  supplier_id      uuid,
  supplier_name    text,
  orders_count     bigint,
  total_purchased  numeric(14,2),
  total_returned   numeric(14,2),
  return_rate      numeric(10,2),
  avg_order_value  numeric(14,2),
  quotations_count bigint,
  last_purchase_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
BEGIN
  IF p_branch_id IS NOT NULL AND NOT is_pos_admin()
     AND get_branch_id() IS NOT NULL AND get_branch_id() <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;
  RETURN QUERY
    SELECT
      s.id, s.name,
      COALESCE(pc.orders_count, 0),
      COALESCE(pc.total_purchased, 0),
      COALESCE(pc.total_returned, 0),
      COALESCE(pc.return_rate, 0),
      COALESCE(pc.avg_order_value, 0),
      COALESCE(q.quotations_count, 0),
      pc.last_purchase_at
    FROM public.suppliers s
    LEFT JOIN (
      SELECT p.supplier_id,
        COUNT(*) AS orders_count,
        SUM(p.total) AS total_purchased,
        SUM(p.returned_amount) AS total_returned,
        round(CASE WHEN COALESCE(SUM(p.total), 0) > 0
          THEN COALESCE(SUM(p.returned_amount), 0) * 100.0 / SUM(p.total)
          ELSE 0 END, 2) AS return_rate,
        AVG(p.total) AS avg_order_value,
        MAX(p.created_at) AS last_purchase_at
      FROM public.purchases p
      WHERE (p_branch_id IS NULL OR p.branch_id = p_branch_id)
      GROUP BY p.supplier_id
    ) pc ON pc.supplier_id = s.id
    LEFT JOIN (
      SELECT q.supplier_id, COUNT(*) AS quotations_count
      FROM public.supplier_quotations q
      WHERE (p_branch_id IS NULL OR q.branch_id = p_branch_id)
      GROUP BY q.supplier_id
    ) q ON q.supplier_id = s.id
    WHERE (p_branch_id IS NULL OR s.branch_id = p_branch_id)
      AND (is_pos_admin() OR s.branch_id = get_branch_id())
    ORDER BY COALESCE(pc.total_purchased, 0) DESC, s.name ASC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_supplier_evaluation(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 18. Hardening: get_supplier_price_impact must respect branch isolation.
--     Signature is unchanged so existing callers keep working; the returned
--     rows are now restricted to the caller's branch (admins see all).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_supplier_price_impact(p_supplier_id uuid)
RETURNS TABLE (
  item_id          uuid,
  item_type        text,
  item_name        text,
  first_cost       numeric(12,2),
  last_cost        numeric(12,2),
  avg_cost         numeric(12,2),
  change_pct       numeric(10,2),
  purchase_count   bigint,
  last_purchased_at timestamptz
) LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
  SELECT
    p.id,
    'product'::text AS item_type,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product'),
    (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]::numeric(12,2),
    (array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1]::numeric(12,2),
    round(AVG(pi.unit_cost), 2)::numeric(12,2),
    round(CASE
      WHEN (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1] > 0
      THEN ((array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1] - (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]) * 100.0
        / (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]
      ELSE 0 END, 2)::numeric(10,2),
    COUNT(*)::bigint,
    MAX(pc.created_at)::timestamptz
  FROM public.purchase_items pi
  JOIN public.purchases pc ON pc.id = pi.purchase_id
  JOIN public.products p ON p.id = pi.product_id
  WHERE pc.supplier_id = p_supplier_id
    AND pc.status = 'completed'
    AND pi.product_id IS NOT NULL
    AND (public.is_pos_admin() OR pc.branch_id = public.get_branch_id())
  GROUP BY p.id
  UNION ALL
  SELECT
    rm.id,
    'raw_material'::text AS item_type,
    COALESCE(NULLIF(btrim(rm.name), ''), 'Raw Material'),
    (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]::numeric(12,2),
    (array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1]::numeric(12,2),
    round(AVG(pi.unit_cost), 2)::numeric(12,2),
    round(CASE
      WHEN (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1] > 0
      THEN ((array_agg(pi.unit_cost ORDER BY pc.created_at DESC))[1] - (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]) * 100.0
        / (array_agg(pi.unit_cost ORDER BY pc.created_at ASC))[1]
      ELSE 0 END, 2)::numeric(10,2),
    COUNT(*)::bigint,
    MAX(pc.created_at)::timestamptz
  FROM public.purchase_items pi
  JOIN public.purchases pc ON pc.id = pi.purchase_id
  JOIN public.raw_materials rm ON rm.id = pi.raw_material_id
  WHERE pc.supplier_id = p_supplier_id
    AND pc.status = 'completed'
    AND pi.raw_material_id IS NOT NULL
    AND (public.is_pos_admin() OR pc.branch_id = public.get_branch_id())
  GROUP BY rm.id
  ORDER BY 2 ASC, 3 ASC
$function$;
GRANT EXECUTE ON FUNCTION public.get_supplier_price_impact(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 076_fix_stock_valuation_ambiguity.sql
-- ----------------------------------------------------------------------------
-- P0 Inventory Lifecycle: fix ambiguous column reference in get_stock_valuation.
--
-- ROOT CAUSE (found by executing the RPC on the local test database, which no
-- integration test had exercised before):
--   The function declares `RETURNS TABLE (... branch_id uuid, ...)`, so
--   `branch_id` exists as a PL/pgSQL output variable in scope. The statement
--     SELECT branch_id INTO v_user_branch FROM public.users ...
--   then fails with:
--     column reference "branch_id" is ambiguous
--     It could refer to either a PL/pgSQL variable or a table column.
--   This path runs for every non-admin (branch-staff) caller, so the valuation
--   page would break for staff even on a DB that has migration 072 applied.
--
-- FIX: qualify the users column (`u.branch_id`). Signature is unchanged
-- (uuid, uuid), so this is fully backward compatible with the published
-- frontend and with any existing grants. No overload was removed or added.

CREATE OR REPLACE FUNCTION public.get_stock_valuation(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id uuid,
  product_name text,
  barcode text,
  sku text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  unit_cost numeric(12,2),
  total_value numeric(16,2)
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT u.branch_id INTO v_user_branch FROM public.users u WHERE u.id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  WITH val AS (
    SELECT
      b.product_id,
      b.warehouse_id,
      b.branch_id,
      COALESCE(SUM(b.quantity), 0)::numeric(14,4) AS quantity,
      COALESCE(round(SUM(b.quantity * b.unit_cost) / NULLIF(SUM(b.quantity), 0), 2), 0)::numeric(12,2) AS unit_cost
    FROM public.inventory_batches b
    WHERE (v_scope IS NULL OR b.branch_id = v_scope)
      AND (p_warehouse_id IS NULL OR b.warehouse_id = p_warehouse_id)
    GROUP BY b.product_id, b.warehouse_id, b.branch_id
  )
  SELECT
    v.product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    p.sku,
    v.warehouse_id,
    w.name AS warehouse_name,
    v.branch_id,
    v.quantity,
    v.unit_cost,
    round(v.quantity * v.unit_cost, 2)::numeric(16,2) AS total_value
  FROM val v
  JOIN public.products p ON p.id = v.product_id
  LEFT JOIN public.warehouses w ON w.id = v.warehouse_id
  WHERE v.quantity > 0
  ORDER BY v.branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_valuation(uuid, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 077_replace_product_units.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 077_replace_product_units.sql
--
-- The frontend calls `replace_product_units(p_product_id, p_units)` on every
-- product save (ProductsPage.save -> api.catalog.replaceProductUnits), but the
-- function was NEVER defined in any migration. On the live site and any fully
-- migrated database, every product create/edit silently failed at this RPC
-- with PGRST202 ("Could not find the function ... in the schema cache") --
-- exactly the class of bug the schema contract (supabase/api-contract.json +
-- verify-schema.js) exists to catch.
--
-- Additive-only: creates a single new function, touches nothing else.
-- Same conventions as sibling RPCs: SECURITY DEFINER, SET search_path=public,
-- branch isolation via is_pos_admin(), audit logging, atomic replace
-- (delete existing units, insert the new set).
-- ============================================================================

CREATE OR REPLACE FUNCTION replace_product_units(
  p_product_id uuid,
  p_units jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_branch_id uuid;
  v_user_branch uuid;
  v_item jsonb;
  v_units_count integer;
  v_base_count integer;
  v_unit_name text;
  v_row record;
BEGIN
  -- Branch isolation: admin may manage any product; others only their branch.
  SELECT branch_id INTO v_branch_id FROM products WHERE id = p_product_id;
  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM users WHERE id = auth.uid();
    IF v_user_branch IS NULL OR v_user_branch IS DISTINCT FROM v_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
    END IF;
  END IF;

  IF p_units IS NULL THEN
    RETURN jsonb_build_object('success', true, 'deleted', 0);
  END IF;

  SELECT count(*) INTO v_units_count FROM jsonb_array_elements(p_units);
  SELECT count(*) INTO v_base_count
  FROM jsonb_array_elements(p_units) AS t(u)
  WHERE COALESCE((t.u->>'is_base')::boolean, false);

  IF v_units_count = 0 OR v_base_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_BASE_UNIT');
  END IF;

  -- Atomic replace inside a single transaction (the RPC is a single statement
  -- with an implicit transaction, so partial states are impossible).
  DELETE FROM product_units WHERE product_id = p_product_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_units) LOOP
    v_unit_name := v_item->>'unit_name';
    IF v_unit_name IS NULL OR v_unit_name = '' THEN
      CONTINUE;
    END IF;
    INSERT INTO product_units (
      product_id, unit_name, unit_name_en, conversion_factor,
      sale_price, cost_price, barcode, is_base
    ) VALUES (
      p_product_id,
      v_unit_name,
      COALESCE(v_item->>'unit_name_en', v_unit_name),
      COALESCE((v_item->>'conversion_factor')::numeric, 1),
      COALESCE((v_item->>'sale_price')::numeric, 0),
      COALESCE((v_item->>'cost_price')::numeric, 0),
      NULLIF(v_item->>'barcode', ''),
      COALESCE((v_item->>'is_base')::boolean, false)
    );
  END LOOP;

  INSERT INTO audit_log (user_id, user_email, action, entity, entity_id, details, branch_id)
  VALUES (auth.uid(), NULL, 'replace_product_units', 'products', p_product_id,
          jsonb_build_object('units_count', v_units_count), v_branch_id);

  RETURN jsonb_build_object('success', true, 'units', v_units_count);
END;
$$;

GRANT EXECUTE ON FUNCTION replace_product_units(uuid, jsonb) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 078_register_branch.sql
-- ----------------------------------------------------------------------------
-- ============================================================================
-- 078_register_branch.sql
--
-- Production gap-fill (2026-08-16): the production database was migrated to
-- ~077 objects via a mechanism that did NOT record entries past 048 in
-- public.schema_migrations, and `register_branch` (from 055_subscriptions.sql)
-- was never present. This file adds ONLY that one function, verbatim from 055,
-- without re-running the rest of 055 (which would re-INSERT subscription plan
-- rows, UPDATE branch_subscriptions, and DROP/re-create process_sale).
--
-- Additive-only: creates a single function, touches nothing else.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.register_branch(
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
  v_branch_id uuid;
  v_warehouse_id uuid;
  v_user_id uuid;
  v_email text;
  v_global_tax numeric(5,2);
  v_global_tax_enabled boolean;
  v_global_currency text;
  v_res jsonb;
BEGIN
  BEGIN
    v_email := lower(btrim(p_email));
    IF v_email = '' OR v_email !~ '@' OR v_email !~ '.' THEN
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

    INSERT INTO public.branches (name, name_en, address, phone, is_active)
    VALUES (p_store_name, p_store_name_en, p_address, p_phone, true)
    RETURNING id INTO v_branch_id;

    INSERT INTO public.warehouses (name, branch_id, is_active)
    VALUES (p_store_name || ' - Main', v_branch_id, true)
    RETURNING id INTO v_warehouse_id;

    SELECT COALESCE(tax_rate, 15), COALESCE(tax_enabled, true), COALESCE(currency, 'EGP')
    INTO v_global_tax, v_global_tax_enabled, v_global_currency
    FROM public.settings ORDER BY id LIMIT 1;

    INSERT INTO public.branch_settings (branch_id, tax_rate, tax_enabled, currency, low_stock_threshold)
    VALUES (v_branch_id, v_global_tax, v_global_tax_enabled,
      COALESCE(NULLIF(btrim(p_currency), ''), v_global_currency), 10);

    INSERT INTO public.branch_subscriptions (branch_id, status, trial_starts_at, trial_ends_at)
    VALUES (v_branch_id, 'trial', now(), now() + interval '14 days');

    -- Provision the owner auth account (email confirmed) inside the same
    -- transaction. register_branch owns the whole row, so the guard bypasses.
    PERFORM set_config('app.register_branch', 'on', true);
    v_res := public.create_user(v_email, p_password, p_owner_name, 'owner', v_branch_id, true, NULL);
    PERFORM set_config('app.register_branch', 'off', true);

    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'USER_CREATE_FAILED: %', coalesce(v_res->>'error', 'UNKNOWN');
    END IF;
    v_user_id := (v_res->>'user_id')::uuid;

    RETURN jsonb_build_object('success', true,
      'branch_id', v_branch_id, 'warehouse_id', v_warehouse_id,
      'user_id', v_user_id, 'trial_days', 14);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'REGISTRATION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_branch(text, text, text, text, text, text, text, text)
  TO anon, authenticated, service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 079_fix_cost_order_margin_branch.sql
-- ----------------------------------------------------------------------------
-- P0 Item 2 (Costing): fix ambiguous branch_id in get_order_margin.
--
-- ROOT CAUSE (found by the new product_costing integration test executing
-- get_order_margin(p_branch_id, ...) against a live Postgres):
--   The query joins public.sales s LEFT JOIN public.inventory_ledger il and
--   filters with `(v_scope IS NULL OR s.branch_id = v_scope)`. Both `sales`
--   and `inventory_ledger` have a `branch_id` column, so PostgreSQL raises:
--     column reference "branch_id" is ambiguous
--   whenever the branch predicate is actually evaluated (v_scope NOT NULL,
--   which is the case for every non-admin caller and for admins scoping to a
--   branch). With v_scope NULL the constant-folder drops the predicate and the
--   call appears to work, which is why unit/mocked coverage never caught it.
--
-- FIX: qualify the predicate column as s.branch_id. Signature is unchanged
-- (uuid, date, date), so this is fully backward compatible with the published
-- frontend (api.costing.getOrderMargin) and existing grants. No overload was
-- removed or added.

CREATE OR REPLACE FUNCTION public.get_order_margin(
  p_branch_id uuid DEFAULT NULL,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
) RETURNS TABLE (
  sale_id        uuid,
  invoice_number text,
  branch_id      uuid,
  sale_date      date,
  total          numeric(14,2),
  discount_amount numeric(14,2),
  cogs           numeric(16,2),
  gross_margin   numeric(16,2)
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT u.branch_id INTO v_user_branch FROM public.users u WHERE u.id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    s.id,
    s.invoice_number,
    s.branch_id,
    s.created_at::date,
    COALESCE(s.total, 0),
    COALESCE(s.discount_amount, 0),
    COALESCE(-SUM(il.total_cost), 0)::numeric(16,2) AS cogs,
    round(COALESCE(s.total, 0) - COALESCE(-SUM(il.total_cost), 0), 2)::numeric(16,2) AS gross_margin
  FROM public.sales s
  LEFT JOIN public.inventory_ledger il
    ON il.reference_id = s.id AND il.entry_type = 'sale' AND il.reference_type = 'sale'
  WHERE (v_scope IS NULL OR s.branch_id = v_scope)
    AND (p_from IS NULL OR s.created_at::date >= p_from)
    AND (p_to IS NULL OR s.created_at::date <= p_to)
  GROUP BY s.id
  ORDER BY s.created_at DESC
  LIMIT 500;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_order_margin(uuid, date, date) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 080_fix_ambiguous_branch_and_grants.sql
-- ----------------------------------------------------------------------------
-- Consolidated bug-fix migration (080). Fixes four issues discovered by
-- integration testing and codebase audit:
--
-- 1. get_low_stock_alerts (071): ambiguous branch_id (P0, same as 076/079)
--    RETURNS TABLE includes branch_id, making the
--    `SELECT branch_id INTO v_user_branch FROM public.users` ambiguous for
--    every non-admin caller.
-- 2. get_expiring_batches (073): identical ambiguous branch_id (P0).
-- 3. get_audit_trail (044): no GRANT EXECUTE TO authenticated — the audit
--    trail page is broken for every non-superuser (P1).
-- 4. send_to_kitchen / set_order_status (048): granted to anon, allowing
--    anonymous callers to bypass branch isolation (P2 security hardening).

-- -------------------------------------------------------------------
-- 1. Fix get_low_stock_alerts — qualify u.branch_id
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_low_stock_alerts(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id uuid,
  product_name text,
  barcode text,
  sku text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  min_stock numeric(14,4),
  max_stock numeric(14,4),
  reorder_point numeric(14,4),
  low_stock_threshold numeric(14,4),
  shortage_qty numeric(14,4),
  status text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT u.branch_id INTO v_user_branch FROM public.users u WHERE u.id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    p.id AS product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    p.sku,
    s.warehouse_id,
    w.name AS warehouse_name,
    COALESCE(s.branch_id, v_scope) AS branch_id,
    COALESCE(s.quantity, 0) AS quantity,
    COALESCE(p.min_stock, 0) AS min_stock,
    COALESCE(p.max_stock, 0) AS max_stock,
    COALESCE(p.reorder_point, 0)::numeric(14,4) AS reorder_point,
    COALESCE(p.low_stock_threshold, 0)::numeric(14,4) AS low_stock_threshold,
    GREATEST(0, COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold::numeric(14,4), 0) - COALESCE(s.quantity, 0)) AS shortage_qty,
    CASE
      WHEN COALESCE(s.quantity, 0) <= 0 THEN 'out'
      WHEN COALESCE(s.quantity, 0) < COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold::numeric(14,4), 0) THEN 'low'
      ELSE 'ok'
    END AS status
  FROM public.products p
  LEFT JOIN LATERAL (
    SELECT
      i.warehouse_id,
      i.branch_id,
      COALESCE(SUM(i.quantity), 0)::numeric(14,4) AS quantity
    FROM public.inventory i
    WHERE i.product_id = p.id
      AND (v_scope IS NULL OR i.branch_id = v_scope)
      AND (p_warehouse_id IS NULL OR i.warehouse_id = p_warehouse_id)
    GROUP BY i.warehouse_id, i.branch_id
  ) s ON true
  LEFT JOIN public.warehouses w ON w.id = s.warehouse_id
  WHERE p.is_active = true
    AND (s.warehouse_id IS NOT NULL OR (p_warehouse_id IS NULL AND v_scope IS NOT NULL)
         OR (p_warehouse_id IS NULL AND v_scope IS NULL AND p.branch_id IS NULL))
  ORDER BY status ASC, branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_low_stock_alerts(uuid, uuid) TO authenticated;

-- -------------------------------------------------------------------
-- 2. Fix get_expiring_batches — qualify u.branch_id
-- -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_expiring_batches(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL,
  p_horizon_days integer DEFAULT 90
) RETURNS TABLE (
  batch_id uuid,
  batch_number text,
  product_id uuid,
  product_name text,
  barcode text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  unit_cost numeric(12,2),
  production_date date,
  expiry_date date,
  days_to_expiry bigint,
  status text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
  v_horizon integer;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT u.branch_id INTO v_user_branch FROM public.users u WHERE u.id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;
  v_horizon := COALESCE(p_horizon_days, 90);
  IF v_horizon < 0 THEN v_horizon := 0; END IF;

  RETURN QUERY
  SELECT
    b.id AS batch_id,
    COALESCE(NULLIF(btrim(b.batch_number), ''), '-') AS batch_number,
    b.product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    b.warehouse_id,
    w.name AS warehouse_name,
    b.branch_id,
    b.quantity,
    b.unit_cost,
    b.production_date,
    b.expiry_date,
    CASE WHEN b.expiry_date IS NULL THEN NULL
         ELSE (b.expiry_date - CURRENT_DATE)::bigint END AS days_to_expiry,
    CASE
      WHEN b.expiry_date IS NULL THEN 'none'
      WHEN b.expiry_date < CURRENT_DATE THEN 'expired'
      WHEN b.expiry_date <= CURRENT_DATE + (v_horizon || ' days')::interval THEN 'expiring'
      ELSE 'ok'
    END AS status
  FROM public.inventory_batches b
  JOIN public.products p ON p.id = b.product_id
  LEFT JOIN public.warehouses w ON w.id = b.warehouse_id
  WHERE b.quantity > 0
    AND (v_scope IS NULL OR b.branch_id = v_scope)
    AND (p_warehouse_id IS NULL OR b.warehouse_id = p_warehouse_id)
    AND (b.expiry_date IS NULL
         OR b.expiry_date <= CURRENT_DATE + (v_horizon || ' days')::interval)
  ORDER BY b.expiry_date ASC NULLS LAST, b.branch_id ASC, p.name ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_expiring_batches(uuid, uuid, integer) TO authenticated;

-- -------------------------------------------------------------------
-- 3. Grant get_audit_trail to authenticated (missing since 044)
-- -------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.get_audit_trail(uuid, text, text, date, date, integer) TO authenticated;

-- -------------------------------------------------------------------
-- 4. Revoke anon from kitchen/order-status RPCs (security hardening)
-- -------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_order_status(uuid, text, text) FROM anon;


-- ----------------------------------------------------------------------------
-- MIGRATION: 081_fix_low_stock_numeric_cast.sql
-- ----------------------------------------------------------------------------
-- Fix type mismatch in get_low_stock_alerts introduced by 080:
-- `low_stock_threshold` is integer in the table, but RETURNS TABLE expects
-- numeric(14,4). The GREATEST/CASE expressions also mix integer
-- low_stock_threshold with numeric s.quantity.
CREATE OR REPLACE FUNCTION public.get_low_stock_alerts(
  p_branch_id uuid DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
) RETURNS TABLE (
  product_id uuid,
  product_name text,
  barcode text,
  sku text,
  warehouse_id uuid,
  warehouse_name text,
  branch_id uuid,
  quantity numeric(14,4),
  min_stock numeric(14,4),
  max_stock numeric(14,4),
  reorder_point numeric(14,4),
  low_stock_threshold numeric(14,4),
  shortage_qty numeric(14,4),
  status text
) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' STABLE
AS $function$
DECLARE
  v_user_branch uuid;
  v_scope uuid;
BEGIN
  IF NOT is_pos_admin() THEN
    SELECT u.branch_id INTO v_user_branch FROM public.users u WHERE u.id = auth.uid();
    v_scope := v_user_branch;
  ELSE
    v_scope := p_branch_id;
  END IF;

  RETURN QUERY
  SELECT
    p.id AS product_id,
    COALESCE(NULLIF(btrim(p.name), ''), 'Product') AS product_name,
    p.barcode,
    p.sku,
    s.warehouse_id,
    w.name AS warehouse_name,
    COALESCE(s.branch_id, v_scope) AS branch_id,
    COALESCE(s.quantity, 0)::numeric(14,4) AS quantity,
    COALESCE(p.min_stock, 0)::numeric(14,4) AS min_stock,
    COALESCE(p.max_stock, 0)::numeric(14,4) AS max_stock,
    COALESCE(p.reorder_point, 0)::numeric(14,4) AS reorder_point,
    COALESCE(p.low_stock_threshold, 0)::numeric(14,4) AS low_stock_threshold,
    GREATEST(0::numeric(14,4), COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold::numeric(14,4), 0) - COALESCE(s.quantity, 0)) AS shortage_qty,
    CASE
      WHEN COALESCE(s.quantity, 0) <= 0 THEN 'out'
      WHEN COALESCE(s.quantity, 0) < COALESCE(NULLIF(p.reorder_point, 0), p.low_stock_threshold::numeric(14,4), 0) THEN 'low'
      ELSE 'ok'
    END AS status
  FROM public.products p
  LEFT JOIN LATERAL (
    SELECT
      i.warehouse_id,
      i.branch_id,
      COALESCE(SUM(i.quantity), 0)::numeric(14,4) AS quantity
    FROM public.inventory i
    WHERE i.product_id = p.id
      AND (v_scope IS NULL OR i.branch_id = v_scope)
      AND (p_warehouse_id IS NULL OR i.warehouse_id = p_warehouse_id)
    GROUP BY i.warehouse_id, i.branch_id
  ) s ON true
  LEFT JOIN public.warehouses w ON w.id = s.warehouse_id
  WHERE p.is_active = true
    AND (s.warehouse_id IS NOT NULL OR (p_warehouse_id IS NULL AND v_scope IS NOT NULL)
         OR (p_warehouse_id IS NULL AND v_scope IS NULL AND p.branch_id IS NULL))
  ORDER BY status ASC, branch_id ASC, p.name ASC;
END;
$function$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 082_revoke_public_kitchen_security.sql
-- ----------------------------------------------------------------------------
-- Security hardening: REVOKE EXECUTE FROM PUBLIC for kitchen/order-status RPCs.
-- The REVOKE FROM anon in 080 was ineffective because PostgreSQL grants EXECUTE
-- to PUBLIC by default, and anon inherits from PUBLIC.
-- Fix: REVOKE from PUBLIC, then RE-GRANT to authenticated + service_role only.
REVOKE EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_order_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.set_order_status(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_order_status(uuid, text, text) TO service_role;


-- ----------------------------------------------------------------------------
-- MIGRATION: 083_rename_units_to_measurement_units.sql
-- ----------------------------------------------------------------------------
-- Migration 083: Rename 'units' (measurement units: KG, PCS, etc.) to
-- 'measurement_units', create a backward-compatible view, and prepare
-- for the new 'units' concept (intermediate sub-products) in 084.
--
-- This migration is safe because:
-- - The renamed table retains all data, indexes, and constraints.
-- - The compatibility view lets old RPCs (013, 020, 075) keep working.
-- - RLS policies are re-created with updated names.

-- 1. Rename the table
ALTER TABLE IF EXISTS public.units RENAME TO measurement_units;

-- 2. PK already exists from 011; no action needed.

-- 3. Drop old RLS policies that referenced the old table name
DROP POLICY IF EXISTS "units_select" ON public.measurement_units;
DROP POLICY IF EXISTS "units_write" ON public.measurement_units;

-- 4. Re-create RLS on measurement_units
CREATE POLICY measurement_units_select ON public.measurement_units
  FOR SELECT USING (true);
CREATE POLICY measurement_units_admin_write ON public.measurement_units
  FOR ALL USING (is_pos_admin());

-- 5. Backward-compatible view: old RPCs reference 'public.units'
CREATE OR REPLACE VIEW public.units AS
  SELECT id, code, name, symbol, is_active, created_at
  FROM public.measurement_units;

-- 6. Grants
GRANT SELECT ON public.units TO authenticated;
GRANT SELECT ON public.measurement_units TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 084_inventory_units_system.sql
-- ----------------------------------------------------------------------------
-- Migration 084: Create the NEW 'product_units' concept (intermediate
-- sub-products with their own stock, recipes, and production).
-- NOT to be confused with:
--   - measurement_units (old 'units' table, renamed in 083) — measurement UOMs
--   - product_units (existing table, UOM conversions per-product — bottle/carton)
--
-- New tables:
--   - inventory_units: intermediate products (Burger Patty, Bun, Sauce)
--   - product_unit_links: junction — which units a sellable product uses

-- ======================================================================
-- 1. inventory_units — intermediate sub-products
-- ======================================================================
CREATE TABLE public.inventory_units (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  name_en     text,
  unit_type   text NOT NULL DEFAULT 'ready'
                CHECK (unit_type IN ('ready','manufactured')),
  category_id uuid REFERENCES public.categories(id) ON DELETE SET NULL,
  branch_id   uuid REFERENCES public.branches(id) ON DELETE SET NULL,
  cost_price      numeric(12,2) NOT NULL DEFAULT 0,
  sale_price      numeric(12,2) NOT NULL DEFAULT 0,
  min_stock       numeric(14,4) NOT NULL DEFAULT 0,
  max_stock       numeric(14,4) NOT NULL DEFAULT 0,
  reorder_point   numeric(14,4) NOT NULL DEFAULT 0,
  low_stock_threshold integer NOT NULL DEFAULT 5,
  barcode     text,
  sku         text,
  description text,
  image_url   text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_units
  IS 'Intermediate sub-products (e.g. Burger Patty, Bun). Tracked in inventory independently from raw materials.';

CREATE TRIGGER inventory_units_updated_at
  BEFORE UPDATE ON public.inventory_units
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ======================================================================
-- 2. product_unit_links — which units a sellable product uses
-- ======================================================================
CREATE TABLE public.product_unit_links (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id  uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  unit_id     uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  quantity    numeric(14,4) NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE(product_id, unit_id)
);

COMMENT ON TABLE public.product_unit_links
  IS 'Junction: a sellable product consumes these inventory_units at sale time.';

-- ======================================================================
-- 3. inventory_unit_recipes — recipe for manufactured units
-- ======================================================================
CREATE TABLE public.inventory_unit_recipes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id     uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  raw_material_id uuid NOT NULL REFERENCES public.raw_materials(id) ON DELETE CASCADE,
  quantity    numeric(14,4) NOT NULL DEFAULT 1,
  wastage_percent numeric(5,2) NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE(unit_id, raw_material_id)
);

COMMENT ON TABLE public.inventory_unit_recipes
  IS 'Recipe ingredients for manufactured inventory_units.';

-- ======================================================================
-- 4. inventory_unit_batches — stock batches for units
-- ======================================================================
CREATE TABLE public.inventory_unit_batches (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id         uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id    uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  batch_number    text,
  quantity        numeric(14,4) NOT NULL DEFAULT 0,
  unit_cost       numeric(12,2) NOT NULL DEFAULT 0,
  production_date date,
  expiry_date     date,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_unit_batches
  IS 'Stock batches for inventory_units — mirrors inventory_batches pattern.';

-- ======================================================================
-- 5. inventory_unit_entries — movement ledger for units
-- ======================================================================
CREATE TABLE public.inventory_unit_entries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id         uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id    uuid REFERENCES public.warehouses(id),
  quantity        numeric(14,4) NOT NULL,
  unit_cost       numeric(12,2) NOT NULL DEFAULT 0,
  entry_type      text NOT NULL,
  reference_type  text,
  reference_id    uuid,
  reference_number text,
  batch_number    text,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_unit_entries
  IS 'Inventory movement ledger for inventory_units.';

-- ======================================================================
-- 6. RLS
-- ======================================================================
ALTER TABLE public.inventory_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_unit_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_unit_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_unit_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_unit_entries ENABLE ROW LEVEL SECURITY;

-- inventory_units
CREATE POLICY inventory_units_admin_all ON public.inventory_units
  FOR ALL USING (is_pos_admin());
CREATE POLICY inventory_units_branch_read ON public.inventory_units
  FOR SELECT USING (branch_id IS NULL OR branch_id = public.get_branch_id());

-- product_unit_links
CREATE POLICY pul_admin_all ON public.product_unit_links
  FOR ALL USING (is_pos_admin());
CREATE POLICY pul_branch_read ON public.product_unit_links
  FOR SELECT USING (
    product_id IN (SELECT id FROM public.products
                   WHERE branch_id = public.get_branch_id() OR branch_id IS NULL)
  );

-- inventory_unit_recipes
CREATE POLICY iur_admin_all ON public.inventory_unit_recipes
  FOR ALL USING (is_pos_admin());
CREATE POLICY iur_branch_read ON public.inventory_unit_recipes
  FOR SELECT USING (
    unit_id IN (SELECT id FROM public.inventory_units
                WHERE branch_id = public.get_branch_id() OR branch_id IS NULL)
  );

-- inventory_unit_batches
CREATE POLICY iub_admin_all ON public.inventory_unit_batches
  FOR ALL USING (is_pos_admin());
CREATE POLICY iub_branch_read ON public.inventory_unit_batches
  FOR SELECT USING (branch_id = public.get_branch_id());

-- inventory_unit_entries
CREATE POLICY iue_admin_all ON public.inventory_unit_entries
  FOR ALL USING (is_pos_admin());
CREATE POLICY iue_branch_read ON public.inventory_unit_entries
  FOR SELECT USING (branch_id = public.get_branch_id());

-- ======================================================================
-- 7. Indexes
-- ======================================================================
CREATE INDEX idx_inventory_units_branch ON public.inventory_units(branch_id);
CREATE INDEX idx_inventory_units_active ON public.inventory_units(is_active);
CREATE INDEX idx_product_unit_links_product ON public.product_unit_links(product_id);
CREATE INDEX idx_product_unit_links_unit ON public.product_unit_links(unit_id);
CREATE INDEX idx_inventory_unit_recipes_unit ON public.inventory_unit_recipes(unit_id);
CREATE INDEX idx_inventory_unit_batches_unit ON public.inventory_unit_batches(unit_id);
CREATE INDEX idx_inventory_unit_batches_branch ON public.inventory_unit_batches(branch_id);
CREATE INDEX idx_inventory_unit_entries_unit ON public.inventory_unit_entries(unit_id);
CREATE INDEX idx_inventory_unit_entries_branch ON public.inventory_unit_entries(branch_id);
CREATE INDEX idx_inventory_unit_entries_ref ON public.inventory_unit_entries(reference_type, reference_id);

-- ======================================================================
-- 8. Grants
-- ======================================================================
GRANT SELECT ON public.inventory_units TO authenticated;
GRANT SELECT ON public.product_unit_links TO authenticated;
GRANT SELECT ON public.inventory_unit_recipes TO authenticated;
GRANT SELECT ON public.inventory_unit_batches TO authenticated;
GRANT SELECT ON public.inventory_unit_entries TO authenticated;

GRANT INSERT, UPDATE ON public.inventory_units TO authenticated;
GRANT INSERT, UPDATE ON public.product_unit_links TO authenticated;
GRANT INSERT, UPDATE ON public.inventory_unit_recipes TO authenticated;
GRANT INSERT, UPDATE ON public.inventory_unit_batches TO authenticated;
GRANT INSERT ON public.inventory_unit_entries TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 086_order_status_split.sql
-- ----------------------------------------------------------------------------
-- Migration 086: Split order status into kitchen/payment/print status columns
-- This enables independent kitchen display, payment processing, and print workflow.

-- ======================================================================
-- 1. Add new columns to orders
-- ======================================================================
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS kitchen_status text DEFAULT 'pending'
    CHECK (kitchen_status IN ('pending','sent','cooking','ready','served','cancelled')),
  ADD COLUMN IF NOT EXISTS payment_status text DEFAULT 'unpaid'
    CHECK (payment_status IN ('unpaid','partial','paid','refunded')),
  ADD COLUMN IF NOT EXISTS print_status text DEFAULT 'pending'
    CHECK (print_status IN ('pending','printed','cancelled')),
  ADD COLUMN IF NOT EXISTS kitchen_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS kitchen_ready_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_at timestamptz,
  ADD COLUMN IF NOT EXISTS printed_at timestamptz;

COMMENT ON COLUMN public.orders.kitchen_status IS 'Kitchen workflow: pending → sent → cooking → ready → served';
COMMENT ON COLUMN public.orders.payment_status IS 'Payment workflow: unpaid → partial → paid → refunded';
COMMENT ON COLUMN public.orders.print_status IS 'Print workflow: pending → printed → cancelled';

-- ======================================================================
-- 2. Backfill from existing status column
-- ======================================================================
UPDATE public.orders SET
  kitchen_status = CASE
    WHEN status IN ('open','confirmed') THEN 'pending'
    WHEN status = 'kitchen' THEN 'cooking'
    WHEN status = 'served' THEN 'served'
    WHEN status = 'completed' THEN 'served'
    WHEN status = 'cancelled' THEN 'cancelled'
    ELSE 'pending'
  END,
  payment_status = CASE
    WHEN status IN ('open','confirmed','kitchen','served') THEN 'unpaid'
    WHEN status = 'completed' THEN 'paid'
    WHEN status = 'refunded' THEN 'refunded'
    ELSE 'unpaid'
  END,
  print_status = CASE
    WHEN status = 'completed' THEN 'printed'
    ELSE 'pending'
  END
WHERE kitchen_status = 'pending' AND payment_status = 'unpaid';

-- ======================================================================
-- 3. RPC: set_kitchen_status
-- ======================================================================
CREATE OR REPLACE FUNCTION public.set_kitchen_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('pending','sent','cooking','ready','served','cancelled') THEN
    RAISE EXCEPTION 'Invalid kitchen_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET kitchen_status = p_status,
      kitchen_sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE kitchen_sent_at END,
      kitchen_ready_at = CASE WHEN p_status = 'ready' THEN now() ELSE kitchen_ready_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'kitchen_status', 'order', p_order_id,
    jsonb_build_object('kitchen_status', p_status));
END;
$$;

-- ======================================================================
-- 4. RPC: set_payment_status
-- ======================================================================
CREATE OR REPLACE FUNCTION public.set_payment_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('unpaid','partial','paid','refunded') THEN
    RAISE EXCEPTION 'Invalid payment_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET payment_status = p_status,
      payment_at = CASE WHEN p_status IN ('paid','refunded') THEN now() ELSE payment_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'payment_status', 'order', p_order_id,
    jsonb_build_object('payment_status', p_status));
END;
$$;

-- ======================================================================
-- 5. RPC: set_print_status
-- ======================================================================
CREATE OR REPLACE FUNCTION public.set_print_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('pending','printed','cancelled') THEN
    RAISE EXCEPTION 'Invalid print_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET print_status = p_status,
      printed_at = CASE WHEN p_status = 'printed' THEN now() ELSE printed_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'print_status', 'order', p_order_id,
    jsonb_build_object('print_status', p_status));
END;
$$;

-- ======================================================================
-- 6. Grants
-- ======================================================================
GRANT EXECUTE ON FUNCTION public.set_kitchen_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_payment_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_print_status(uuid, text) TO authenticated;

-- ======================================================================
-- 7. Indexes for filtering by sub-status
-- ======================================================================
CREATE INDEX IF NOT EXISTS idx_orders_kitchen_status ON public.orders(kitchen_status);
CREATE INDEX IF NOT EXISTS idx_orders_payment_status ON public.orders(payment_status);
CREATE INDEX IF NOT EXISTS idx_orders_print_status ON public.orders(print_status);


-- ----------------------------------------------------------------------------
-- MIGRATION: 087_fix_audit_log_columns_in_status_rpcs.sql
-- ----------------------------------------------------------------------------
-- Migration 087: Fix audit_log column names in order status RPCs from migration 086.
-- audit_log uses: user_id (not actor_id), entity (not entity_type), details (not new_data)

CREATE OR REPLACE FUNCTION public.set_kitchen_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('pending','sent','cooking','ready','served','cancelled') THEN
    RAISE EXCEPTION 'Invalid kitchen_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET kitchen_status = p_status,
      kitchen_sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE kitchen_sent_at END,
      kitchen_ready_at = CASE WHEN p_status = 'ready' THEN now() ELSE kitchen_ready_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'kitchen_status', 'order', p_order_id,
    jsonb_build_object('kitchen_status', p_status));
END;
$$;

CREATE OR REPLACE FUNCTION public.set_payment_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('unpaid','partial','paid','refunded') THEN
    RAISE EXCEPTION 'Invalid payment_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET payment_status = p_status,
      payment_at = CASE WHEN p_status IN ('paid','refunded') THEN now() ELSE payment_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'payment_status', 'order', p_order_id,
    jsonb_build_object('payment_status', p_status));
END;
$$;

CREATE OR REPLACE FUNCTION public.set_print_status(
  p_order_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status NOT IN ('pending','printed','cancelled') THEN
    RAISE EXCEPTION 'Invalid print_status: %', p_status;
  END IF;

  UPDATE public.orders
  SET print_status = p_status,
      printed_at = CASE WHEN p_status = 'printed' THEN now() ELSE printed_at END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'print_status', 'order', p_order_id,
    jsonb_build_object('print_status', p_status));
END;
$$;


-- ----------------------------------------------------------------------------
-- MIGRATION: 088_production_enhancements.sql
-- ----------------------------------------------------------------------------
-- Migration 088: Production enhancements — recipe versioning + inventory unit production
-- Adds: recipe versioning, production RPCs for inventory_units, yield tracking

-- ======================================================================
-- 1. Recipe versioning
-- ======================================================================
ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.recipes.version IS 'Recipe version number. Increment when formula changes.';
COMMENT ON COLUMN public.recipes.is_active IS 'Only one active version per product at a time.';

-- ======================================================================
-- 2. Production orders for inventory_units
-- ======================================================================
CREATE TABLE IF NOT EXISTS public.inventory_unit_productions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id         uuid NOT NULL REFERENCES public.inventory_units(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  warehouse_id    uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  quantity        numeric(14,4) NOT NULL DEFAULT 1,
  status          text NOT NULL DEFAULT 'planned'
                    CHECK (status IN ('planned','in_progress','completed','cancelled')),
  total_cost      numeric(12,2) NOT NULL DEFAULT 0,
  planned_at      date,
  started_at      timestamptz,
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  cancel_reason   text,
  notes           text,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_unit_productions
  IS 'Production runs for inventory_units — manufacture from raw materials via recipes.';

CREATE TRIGGER inventory_unit_productions_updated_at
  BEFORE UPDATE ON public.inventory_unit_productions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ======================================================================
-- 3. RLS
-- ======================================================================
ALTER TABLE public.inventory_unit_productions ENABLE ROW LEVEL SECURITY;

CREATE POLICY iup_admin_all ON public.inventory_unit_productions
  FOR ALL USING (is_pos_admin());
CREATE POLICY iup_branch_read ON public.inventory_unit_productions
  FOR SELECT USING (branch_id = public.get_branch_id());

-- ======================================================================
-- 4. Indexes
-- ======================================================================
CREATE INDEX idx_iup_unit ON public.inventory_unit_productions(unit_id);
CREATE INDEX idx_iup_branch ON public.inventory_unit_productions(branch_id);
CREATE INDEX idx_iup_status ON public.inventory_unit_productions(status);
CREATE INDEX idx_recipes_version ON public.recipes(product_id, version);

-- ======================================================================
-- 5. RPC: produce_inventory_unit
--   Deducts raw materials from inventory, creates batch, records entries
-- ======================================================================
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
  -- Validate unit exists and is manufactured
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

  -- Process each recipe ingredient
  FOR v_recipe IN
    SELECT iur.raw_material_id, iur.quantity, iur.wastage_percent, rm.name as rm_name
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    WHERE iur.unit_id = p_unit_id
  LOOP
    -- Calculate required quantity with wastage
    v_rm_qty := p_quantity * v_recipe.quantity * (1 + v_recipe.wastage_percent / 100);

    -- Get cost from raw_materials.default_cost
    SELECT default_cost INTO v_rm_cost
    FROM public.raw_materials WHERE id = v_recipe.raw_material_id;

    v_total_cost := v_total_cost + (v_rm_qty * COALESCE(v_rm_cost, 0));

    -- Deduct from raw_material_inventory (FIFO)
    PERFORM public.deduct_raw_material_inventory(
      v_recipe.raw_material_id, v_rm_qty, p_branch_id, p_warehouse_id
    );

    -- Record in raw_material_inventory movement
    INSERT INTO public.raw_material_batches (
      raw_material_id, branch_id, warehouse_id, batch_number,
      quantity, unit_cost, expiry_date
    ) VALUES (
      v_recipe.raw_material_id, p_branch_id, p_warehouse_id, v_batch_number,
      -v_rm_qty, COALESCE(v_rm_cost, 0), NULL
    );
  END LOOP;

  -- Create inventory_unit batch (output)
  INSERT INTO public.inventory_unit_batches (
    unit_id, branch_id, warehouse_id, batch_number,
    quantity, unit_cost, production_date
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, v_batch_number,
    p_quantity, CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    CURRENT_DATE
  );

  -- Record entry in ledger
  INSERT INTO public.inventory_unit_entries (
    unit_id, branch_id, warehouse_id, quantity,
    unit_cost, entry_type, reference_type, reference_id, batch_number
  ) VALUES (
    p_unit_id, p_branch_id, p_warehouse_id, p_quantity,
    CASE WHEN p_quantity > 0 THEN v_total_cost / p_quantity ELSE 0 END,
    'production', 'production', v_production_id, v_batch_number
  );

  -- Create production order record
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

-- ======================================================================
-- 6. RPC: get_production_variance
--   Compare theoretical vs actual consumption
-- ======================================================================
CREATE OR REPLACE FUNCTION public.get_production_variance(
  p_unit_id uuid,
  p_branch_id uuid DEFAULT public.get_branch_id()
)
RETURNS TABLE (
  raw_material_id uuid,
  raw_material_name text,
  theoretical_qty numeric,
  actual_qty numeric,
  variance numeric,
  variance_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH totals AS (
    SELECT
      iur.raw_material_id,
      rm.name as rm_name,
      iur.quantity AS theoretical_per_unit,
      COALESCE(SUM(iue.quantity) FILTER (WHERE iue.entry_type = 'production'), 0) AS produced_units
    FROM public.inventory_unit_recipes iur
    JOIN public.raw_materials rm ON rm.id = iur.raw_material_id
    LEFT JOIN public.inventory_unit_entries iue
      ON iue.unit_id = iur.unit_id AND iue.entry_type = 'production'
    WHERE iur.unit_id = p_unit_id
    GROUP BY iur.raw_material_id, rm.name, iur.quantity
  )
  SELECT
    t.raw_material_id,
    t.rm_name::text,
    (t.theoretical_per_unit * ABS(t.produced_units))::numeric AS theoretical_qty,
    COALESCE(
      (SELECT ABS(SUM(rm_inv.quantity))
       FROM public.raw_material_batches rm_inv
       WHERE rm_inv.raw_material_id = t.raw_material_id
         AND rm_inv.branch_id = p_branch_id
         AND rm_inv.batch_number LIKE 'PRD-%'),
      0
    )::numeric AS actual_qty,
    (COALESCE(
      (SELECT ABS(SUM(rm_inv.quantity))
       FROM public.raw_material_batches rm_inv
       WHERE rm_inv.raw_material_id = t.raw_material_id
         AND rm_inv.branch_id = p_branch_id
         AND rm_inv.batch_number LIKE 'PRD-%'),
      0
    ) - (t.theoretical_per_unit * ABS(t.produced_units)))::numeric AS variance,
    CASE
      WHEN (t.theoretical_per_unit * ABS(t.produced_units)) > 0
      THEN ROUND(
        ((COALESCE(
          (SELECT ABS(SUM(rm_inv.quantity))
           FROM public.raw_material_batches rm_inv
           WHERE rm_inv.raw_material_id = t.raw_material_id
             AND rm_inv.branch_id = p_branch_id
             AND rm_inv.batch_number LIKE 'PRD-%'),
          0
        ) - (t.theoretical_per_unit * ABS(t.produced_units)))
        / (t.theoretical_per_unit * ABS(t.produced_units)) * 100), 2)
      ELSE 0
    END::numeric AS variance_pct
  FROM totals t;
END;
$$;

-- ======================================================================
-- 7. Grants
-- ======================================================================
GRANT SELECT ON public.inventory_unit_productions TO authenticated;
GRANT INSERT, UPDATE ON public.inventory_unit_productions TO authenticated;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_production_variance(uuid, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 089_waste_center.sql
-- ----------------------------------------------------------------------------
-- Migration 089: Waste Center — independent waste tracking
-- Tables: waste_entries, waste_categories
-- RPCs: create_waste_entry, approve_waste, get_waste_report

-- ======================================================================
-- 1. Waste categories (lookup)
-- ======================================================================
CREATE TABLE IF NOT EXISTS public.waste_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,
  name_en     text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.waste_categories (name, name_en) VALUES
  ('هالك مraw', 'Raw Material Waste'),
  ('هالك منتج', 'Finished Goods Waste'),
  ('هالك إنتاج', 'Production Waste'),
  ('منتهي الصلاحية', 'Expired'),
  ('تالف', 'Damaged')
ON CONFLICT (name) DO NOTHING;

-- ======================================================================
-- 2. Waste entries
-- ======================================================================
CREATE TABLE IF NOT EXISTS public.waste_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id         uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  waste_category_id uuid NOT NULL REFERENCES public.waste_categories(id),
  waste_type        text NOT NULL
                      CHECK (waste_type IN ('raw_material','finished_good','production','expired','damaged')),
  raw_material_id   uuid REFERENCES public.raw_materials(id) ON DELETE SET NULL,
  inventory_unit_id uuid REFERENCES public.inventory_units(id) ON DELETE SET NULL,
  product_id        uuid REFERENCES public.products(id) ON DELETE SET NULL,
  quantity          numeric(14,4) NOT NULL DEFAULT 1,
  unit_cost         numeric(12,2) NOT NULL DEFAULT 0,
  total_cost        numeric(14,2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,
  reason            text,
  warehouse_id      uuid REFERENCES public.warehouses(id) ON DELETE SET NULL,
  employee_id       uuid,
  approved_by       uuid,
  status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected')),
  approved_at       timestamptz,
  rejection_reason  text,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.waste_entries IS 'Independent waste tracking for raw materials, finished goods, and production waste.';

CREATE TRIGGER waste_entries_updated_at
  BEFORE UPDATE ON public.waste_entries
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ======================================================================
-- 3. RLS
-- ======================================================================
ALTER TABLE public.waste_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waste_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY wc_admin_all ON public.waste_categories
  FOR ALL USING (is_pos_admin());
CREATE POLICY wc_select ON public.waste_categories
  FOR SELECT USING (true);

CREATE POLICY we_admin_all ON public.waste_entries
  FOR ALL USING (is_pos_admin());
CREATE POLICY we_branch_read ON public.waste_entries
  FOR SELECT USING (branch_id = public.get_branch_id());

-- ======================================================================
-- 4. Indexes
-- ======================================================================
CREATE INDEX idx_waste_entries_branch ON public.waste_entries(branch_id);
CREATE INDEX idx_waste_entries_type ON public.waste_entries(waste_type);
CREATE INDEX idx_waste_entries_status ON public.waste_entries(status);
CREATE INDEX idx_waste_entries_date ON public.waste_entries(created_at);
CREATE INDEX idx_waste_entries_category ON public.waste_entries(waste_category_id);

-- ======================================================================
-- 5. RPC: create_waste_entry
-- ======================================================================
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
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_waste_type NOT IN ('raw_material','finished_good','production','expired','damaged') THEN
    RAISE EXCEPTION 'Invalid waste_type: %', p_waste_type;
  END IF;

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Waste quantity must be positive';
  END IF;

  v_id := gen_random_uuid();

  INSERT INTO public.waste_entries (
    id, branch_id, waste_category_id, waste_type,
    raw_material_id, inventory_unit_id, product_id,
    quantity, unit_cost, reason, warehouse_id,
    employee_id, created_by, status
  ) VALUES (
    v_id, p_branch_id, p_waste_category_id, p_waste_type,
    p_raw_material_id, p_inventory_unit_id, p_product_id,
    p_quantity, p_unit_cost, p_reason, p_warehouse_id,
    p_employee_id, auth.uid(), 'pending'
  );

  -- Audit log
  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'create', 'waste_entry', v_id,
    jsonb_build_object('waste_type', p_waste_type, 'quantity', p_quantity, 'total_cost', p_quantity * p_unit_cost));

  RETURN v_id;
END;
$$;

-- ======================================================================
-- 6. RPC: approve_waste
-- ======================================================================
CREATE OR REPLACE FUNCTION public.approve_waste(
  p_waste_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry record;
BEGIN
  SELECT * INTO v_entry FROM public.waste_entries WHERE id = p_waste_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Waste entry % not found', p_waste_id;
  END IF;

  IF v_entry.status != 'pending' THEN
    RAISE EXCEPTION 'Waste entry % is not pending (current status: %)', p_waste_id, v_entry.status;
  END IF;

  IF p_approve THEN
    UPDATE public.waste_entries
    SET status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
    VALUES (auth.uid(), 'approve', 'waste_entry', p_waste_id, jsonb_build_object('status', 'approved'));
  ELSE
    UPDATE public.waste_entries
    SET status = 'rejected', rejection_reason = p_rejection_reason, approved_by = auth.uid(),
        approved_at = now(), updated_at = now()
    WHERE id = p_waste_id;

    INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
    VALUES (auth.uid(), 'reject', 'waste_entry', p_waste_id,
      jsonb_build_object('status', 'rejected', 'reason', p_rejection_reason));
  END IF;
END;
$$;

-- ======================================================================
-- 7. RPC: get_waste_report
-- ======================================================================
CREATE OR REPLACE FUNCTION public.get_waste_report(
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_from_date date DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_to_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  waste_category text,
  waste_type text,
  total_quantity numeric,
  total_cost numeric,
  entry_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    wc.name AS waste_category,
    we.waste_type,
    SUM(we.quantity) AS total_quantity,
    SUM(we.total_cost) AS total_cost,
    COUNT(*)::bigint AS entry_count
  FROM public.waste_entries we
  JOIN public.waste_categories wc ON wc.id = we.waste_category_id
  WHERE we.branch_id = p_branch_id
    AND we.status = 'approved'
    AND we.created_at >= p_from_date
    AND we.created_at < (p_to_date + INTERVAL '1 day')
  GROUP BY wc.name, we.waste_type
  ORDER BY SUM(we.total_cost) DESC;
END;
$$;

-- ======================================================================
-- 8. Grants
-- ======================================================================
GRANT SELECT ON public.waste_categories TO authenticated;
GRANT SELECT ON public.waste_entries TO authenticated;
GRANT INSERT, UPDATE ON public.waste_entries TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_waste_entry(uuid, uuid, text, numeric, numeric, text, uuid, uuid, uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_waste(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_waste_report(uuid, date, date) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 090_kitchen_station_routing.sql
-- ----------------------------------------------------------------------------
-- Migration 090: Kitchen station routing
-- Adds station column to orders + get_kitchen_queue RPC

-- ======================================================================
-- 1. Station column on orders
-- ======================================================================
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS station text DEFAULT 'main'
    CHECK (station IN ('main','grill','salad','drinks','dessert','fryer'));

COMMENT ON COLUMN public.orders.station IS 'Kitchen station assigned to this order (grill/salad/drinks/etc).';

CREATE INDEX IF NOT EXISTS idx_orders_station ON public.orders(station);

-- ======================================================================
-- 2. RPC: route_to_station
-- ======================================================================
CREATE OR REPLACE FUNCTION public.route_to_station(
  p_order_id uuid,
  p_station text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_station NOT IN ('main','grill','salad','drinks','dessert','fryer') THEN
    RAISE EXCEPTION 'Invalid station: %', p_station;
  END IF;

  UPDATE public.orders
  SET station = p_station, updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'route_station', 'order', p_order_id,
    jsonb_build_object('station', p_station));
END;
$$;

-- ======================================================================
-- 3. RPC: get_kitchen_queue
-- ======================================================================
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
    o.table_number,
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

-- ======================================================================
-- 4. Grants
-- ======================================================================
GRANT EXECUTE ON FUNCTION public.route_to_station(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kitchen_queue(text, uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- MIGRATION: 091_kitchen_stations_and_waste_fix.sql
-- ----------------------------------------------------------------------------
-- Migration 091: Kitchen stations table + fix waste report for admin users

-- ======================================================================
-- 1. Kitchen stations table (replaces hardcoded CHECK constraint)
-- ======================================================================
CREATE TABLE IF NOT EXISTS public.kitchen_stations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL UNIQUE,
  name_ar    text NOT NULL,
  name_en    text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.kitchen_stations IS 'Configurable kitchen stations for KDS routing.';

INSERT INTO public.kitchen_stations (code, name_ar, name_en, sort_order) VALUES
  ('main',    'الرئيسي',   'Main',    0),
  ('grill',   'المشويات',  'Grill',   1),
  ('salad',   'السلط',     'Salad',   2),
  ('drinks',  'المشروبات', 'Drinks',  3),
  ('dessert', 'الحلويات',  'Dessert', 4),
  ('fryer',   'المقالي',   'Fryer',   5)
ON CONFLICT (code) DO NOTHING;

-- ======================================================================
-- 2. RLS — admins manage, everyone reads
-- ======================================================================
ALTER TABLE public.kitchen_stations ENABLE ROW LEVEL SECURITY;

CREATE POLICY ks_admin_all ON public.kitchen_stations
  FOR ALL USING (is_pos_admin());
CREATE POLICY ks_select ON public.kitchen_stations
  FOR SELECT USING (true);

GRANT SELECT ON public.kitchen_stations TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.kitchen_stations TO authenticated;

-- ======================================================================
-- 3. Fix get_waste_report: handle NULL branch_id for admin users
-- ======================================================================
CREATE OR REPLACE FUNCTION public.get_waste_report(
  p_branch_id uuid DEFAULT public.get_branch_id(),
  p_from_date date DEFAULT (CURRENT_DATE - INTERVAL '30 days'),
  p_to_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  waste_category text,
  waste_type text,
  total_quantity numeric,
  total_cost numeric,
  entry_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    wc.name AS waste_category,
    we.waste_type,
    SUM(we.quantity) AS total_quantity,
    SUM(we.total_cost) AS total_cost,
    COUNT(*)::bigint AS entry_count
  FROM public.waste_entries we
  JOIN public.waste_categories wc ON wc.id = we.waste_category_id
  WHERE (p_branch_id IS NULL OR we.branch_id = p_branch_id)
    AND we.status = 'approved'
    AND we.created_at >= p_from_date
    AND we.created_at < (p_to_date + INTERVAL '1 day')
  GROUP BY wc.name, we.waste_type
  ORDER BY SUM(we.total_cost) DESC;
END;
$$;

-- ======================================================================
-- 4. Fix route_to_station: validate against kitchen_stations table
-- ======================================================================
CREATE OR REPLACE FUNCTION public.route_to_station(
  p_order_id uuid,
  p_station text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exists boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.kitchen_stations WHERE code = p_station AND is_active = true) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION 'Invalid or inactive station: %', p_station;
  END IF;

  UPDATE public.orders
  SET station = p_station, updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.audit_log(user_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'route_station', 'order', p_order_id,
    jsonb_build_object('station', p_station));
END;
$$;

