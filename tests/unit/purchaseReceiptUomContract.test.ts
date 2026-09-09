import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const source = readFileSync(
  resolve(process.cwd(), 'supabase/migrations/20260902061000_purchase_receipt_uom_accounting.sql'),
  'utf8',
);

describe('purchase receipt UOM accounting contract', () => {
  it('totals manual purchase-order items', () => {
    expect(source).toContain("v_total := v_total");
    expect(source).toContain("(v_item->>'quantity')::numeric");
    expect(source).toContain("(v_item->>'unit_cost')::numeric");
  });

  it('normalizes the quantity received and links stock movements to the GRN', () => {
    expect(source).toContain('v_pitem.raw_material_id, v_qty, v_pitem.unit_cost, v_pitem.unit_name');
    expect(source).toContain("'purchase', 'purchase_receipt', v_receipt_id, v_number");
    expect(source).toContain("(v_res->>'stock_quantity')::numeric");
    expect(source).toContain("(v_res->>'stock_unit_cost')::numeric");
  });

  it('rebuilds the completion journal from the full purchase order', () => {
    expect(source).toContain('SUM(CASE WHEN pi.product_id IS NOT NULL');
    expect(source).toContain('SUM(CASE WHEN pi.raw_material_id IS NOT NULL');
    expect(source).toContain('WHERE pi.purchase_id = p_purchase_id');
  });
});
