import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const read = (path: string) => readFileSync(resolve(process.cwd(), path), 'utf8');

describe('sale financial authority contract', () => {
  it('uses process_sale as the only online sale write path', () => {
    const posApi = read('src/api/domains/pos.ts');
    expect(posApi).toContain("return rpc<RpcResult>('process_sale', p)");
    expect(posApi).not.toContain("from('sales').insert");
    expect(posApi).not.toContain("from('sale_items').insert");
    expect(posApi).not.toContain('Direct Sale Processing Fallback');
  });

  it('does not convert authoritative server rejection or ambiguous online failure into offline success', () => {
    const payment = read('src/features/pos/services/payment.ts');
    const onlinePath = payment.slice(payment.indexOf('try {'));
    expect(onlinePath).not.toContain('offlinePosManager.enqueueSale(p)');
    expect(payment).toContain('A server rejection');
    expect(payment).toContain('the server may have');
  });

  it('blocks raw authenticated inserts and clamps applied payment server-side', () => {
    const migration = read('supabase/migrations/20260902060000_sale_financial_authority.sql');
    expect(migration).toContain('CREATE POLICY auth_insert_sales');
    expect(migration).toContain('CREATE POLICY auth_insert_sale_items');
    expect(migration.match(/WITH CHECK \(false\)/g)).toHaveLength(2);
    expect(migration).toContain('LEAST(GREATEST(COALESCE(p_paid_amount, 0), 0), v_total)');
  });
});
