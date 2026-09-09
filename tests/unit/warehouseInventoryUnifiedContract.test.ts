import { describe, expect, it } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const read = (path: string) => readFileSync(resolve(process.cwd(), path), 'utf8');

describe('Warehouse-scoped Unified Inventory & POS Availability Contract', () => {
  it('migration 20260908150000_unify_warehouse_inventory_and_pos_availability.sql exists and enforces warehouse scoping', () => {
    const migrationPath = 'supabase/migrations/20260908150000_unify_warehouse_inventory_and_pos_availability.sql';
    expect(existsSync(resolve(process.cwd(), migrationPath))).toBe(true);

    const sql = read(migrationPath);

    // Schema alterations
    expect(sql).toContain('ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES public.warehouses(id)');

    // Strict same-branch backfill with zero cross-branch leakage
    expect(sql).not.toContain('WHERE w.is_active = true\n  ORDER BY w.is_default DESC, w.created_at ASC\n  LIMIT 1\n)\nWHERE rmi.warehouse_id IS NULL');
    expect(sql).toContain('STRICT INTEGRITY CHECK:');
    expect(sql).toContain('Assigning a warehouse from another branch is strictly prohibited.');
    expect(sql).toContain('trg_validate_warehouse_branch_integrity');
    expect(sql).toContain('WAREHOUSE_BRANCH_MISMATCH');

    // Warehouse resolution in _raw_add and _raw_remove_fifo
    expect(sql).toContain('FUNCTION public._raw_add');
    expect(sql).toContain('p_warehouse_id uuid DEFAULT NULL');
    expect(sql).toContain('FUNCTION public._raw_remove_fifo');

    // POS availability scoped by warehouse
    expect(sql).toContain('FUNCTION public.check_product_availability');
    expect(sql).toContain('FUNCTION public.get_pos_product_availability');

    // Unified inventory view
    expect(sql).toContain('CREATE OR REPLACE VIEW public.unified_inventory_view AS');
    expect(sql).toContain("'product_ready'");
    expect(sql).toContain("'raw_material' AS item_type");

    // Purchase receiving into warehouse
    expect(sql).toContain('FUNCTION public.process_purchase');
    expect(sql).toContain('FUNCTION public.receive_purchase_order');
  });

  it('PurchasesPage enforces warehouse selection for all purchases', () => {
    const purchasesPage = read('src/features/trade/pages/PurchasesPage.tsx');

    // Warehouse is strictly required for purchases
    expect(purchasesPage).toContain('!form.warehouse_id');
    expect(purchasesPage).toContain("show(isAr ? 'يرجى تحديد المستودع المستلم للمشتريات' : t('required') + ': ' + t('warehouse'), 'error')");
    expect(purchasesPage).toContain('p_warehouse_id: form.warehouse_id || null');
  });

  it('InventoryPage supports unified view of all inventory types with branch and warehouse scoping', () => {
    const inventoryPage = read('src/features/inventory/pages/InventoryPage.tsx');

    // Queries unified view with fallback
    expect(inventoryPage).toContain("from('unified_inventory_view')");
    expect(inventoryPage).toContain('raw_material_inventory');

    // Displays types
    expect(inventoryPage).toContain('product_ready');
    expect(inventoryPage).toContain('product_component');
    expect(inventoryPage).toContain('raw_material');

    // Supports filters
    expect(inventoryPage).toContain('filterBranch');
    expect(inventoryPage).toContain('filterWarehouse');
    expect(inventoryPage).toContain('filterType');
    expect(inventoryPage).toContain('filterStatus');

    // Summary KPIs
    expect(inventoryPage).toContain('totalValue');
    expect(inventoryPage).toContain('lowStockCount');
    expect(inventoryPage).toContain('outOfStockCount');
  });
});
