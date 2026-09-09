import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const source = readFileSync(
  resolve(process.cwd(), 'supabase/migrations/20260902070000_p2_authoritative_order_pricing.sql'),
  'utf8',
);

describe('P2 authoritative pricing contract', () => {
  it('reprices staged order lines from the product catalog', () => {
    expect(source).toContain('NEW.unit_price := ROUND(COALESCE(v_price, 0), 2)');
    expect(source).toContain('NEW.total := ROUND(NEW.quantity * NEW.unit_price - NEW.discount_amount, 2)');
    expect(source).toContain('trg_order_items_authoritative_price');
  });

  it('recomputes staged order totals and branch tax server-side', () => {
    expect(source).toContain('_effective_branch_tax');
    expect(source).toContain('trg_order_items_sync_totals');
    expect(source).toContain('SET subtotal = v_subtotal');
    expect(source).toContain('tax_amount = v_tax');
    expect(source).toContain('total = v_total');
  });

  it('binds discount approval to server-computed catalog subtotal', () => {
    expect(source).toContain('v_server_subtotal');
    expect(source).toContain("payload->>'subtotal'");
    expect(source).toContain("'scope','line'");
    expect(source).not.toContain("- p_subtotal) < 0.0001");
  });

  it('does not trust client header tax or total at the sale boundary', () => {
    expect(source).toContain('v_server_subtotal,p_discount_amount,p_discount_type,0,p_bonus_amount,0,p_paid_amount');
  });
});
