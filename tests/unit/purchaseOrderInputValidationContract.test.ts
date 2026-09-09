import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const source = readFileSync(
  resolve(process.cwd(), 'supabase/migrations/20260902071000_purchase_order_input_uom_validation.sql'),
  'utf8',
);

describe('purchase order input validation contract', () => {
  it('rejects invalid manual quantities and costs', () => {
    expect(source).toContain('INVALID_PURCHASE_QUANTITY_OR_COST');
    expect(source).toContain("(v_item->>'quantity')::numeric, 0) <= 0");
    expect(source).toContain("(v_item->>'unit_cost')::numeric, 0) < 0");
  });

  it('validates raw-material UOM before creating the PO', () => {
    expect(source).toContain('_normalize_raw_purchase_uom');
    expect(source).toContain('RAW_MATERIAL_NOT_IN_BRANCH');
    expect(source).toContain('RETURN v_norm');
  });

  it('prevents cross-branch product purchase lines', () => {
    expect(source).toContain('PRODUCT_NOT_IN_BRANCH');
    expect(source).toContain('p.branch_id = p_branch_id');
  });
});
