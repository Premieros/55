import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const boundary = readFileSync(
  resolve(process.cwd(), 'supabase/migrations/20260904050000_kitchen_send_inventory_boundary.sql'),
  'utf8',
);
const reconcile = readFileSync(
  resolve(process.cwd(), 'supabase/migrations/20260905001500_kitchen_inventory_kds_permission_reconcile.sql'),
  'utf8',
);

describe('kitchen inventory boundary contract', () => {
  it('stores the warehouse and records kitchen inventory effects', () => {
    expect(boundary).toContain('inventory_warehouse_id');
    expect(boundary).toContain('order_kitchen_inventory_events');
    expect(boundary).toContain('order_kitchen_inventory_effects');
    expect(reconcile).toContain('public._deduct_sale_inventory_with_modifiers_core');
    expect(reconcile).toContain("entry_type = 'kitchen_send'");
  });

  it('keeps the latest KDS lifecycle while using granular permission checks', () => {
    expect(reconcile).toContain("public.can_permission('pos.send_kitchen')");
    expect(reconcile).toContain('public.is_platform_admin()');
    expect(reconcile).not.toContain('public.is_pos_admin()');
    expect(reconcile).toContain("kitchen_status = CASE");
    expect(reconcile).toContain('kitchen_sent_at = COALESCE');
  });

  it('does not let the legacy one-argument RPC bypass inventory deduction', () => {
    expect(reconcile).toContain('CREATE OR REPLACE FUNCTION public.send_to_kitchen(p_order_id uuid)');
    expect(reconcile).toContain('RETURN public.send_to_kitchen(p_order_id, auth.uid());');
  });

  it('deducts inventory before advancing the kitchen send ledger', () => {
    const deductAt = reconcile.indexOf('v_inventory := public._deduct_sale_inventory_with_modifiers_core');
    const sendAt = reconcile.indexOf('INSERT INTO public.order_kitchen_sends');
    expect(deductAt).toBeGreaterThan(-1);
    expect(sendAt).toBeGreaterThan(deductAt);
  });
});
