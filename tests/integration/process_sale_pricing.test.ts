import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { getDbUrl, openDb } from './db';
import type pg from 'pg';

const dbUrl = getDbUrl();
const skip = !dbUrl;

describe.skipIf(skip)('process_sale authoritative pricing (D13)', () => {
  let client: pg.Client;
  const branchId = randomUUID();
  const warehouseId = randomUUID();
  const productId = randomUUID();
  const unitId = randomUUID();
  const actorId = randomUUID();
  const invoiceNumber = `D13-TEST-${Date.now()}`;

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');
    await client.query(`INSERT INTO public.branches (id, name) VALUES ($1, $2)`, [branchId, 'D13 Test Branch']);
    await client.query(`INSERT INTO public.warehouses (id, name, branch_id, is_active) VALUES ($1, $2, $3, true)`, [warehouseId, 'D13 Test Warehouse', branchId]);
    await client.query(`INSERT INTO public.products (id, name, branch_id, sale_price, cost_price, is_active) VALUES ($1, $2, $3, 100, 50, true)`, [productId, 'D13 Test Product', branchId]);
    await client.query(
      `INSERT INTO public.inventory_units (id, code, name, unit_type, branch_id, cost_price, sale_price, is_active)
       VALUES ($1, $2, $3, 'ready', $4, 50, 100, true)`,
      [unitId, `D13-${randomUUID()}`, 'D13 Test Unit', branchId],
    );
    await client.query(`INSERT INTO public.product_unit_links (product_id, unit_id, quantity) VALUES ($1, $2, 1)`, [productId, unitId]);
    await client.query(`INSERT INTO public.inventory_unit_batches (unit_id, branch_id, warehouse_id, quantity, unit_cost) VALUES ($1, $2, $3, 10, 50)`, [unitId, branchId, warehouseId]);

    // Keep the production AUTH_REQUIRED guard intact. CI authenticates through
    // the auth stub's app.user_id GUC, so this test exercises the public RPC.
    await client.query('ALTER TABLE public.users DISABLE TRIGGER trg_users_role_guard');
    try {
      await client.query(
        `INSERT INTO public.users (id, email, username, full_name, role, branch_id, is_active)
         VALUES ($1, $2, $3, 'D13 Pricing CI Admin', 'super_admin', NULL, true)`,
        [actorId, `pricing-${actorId}@test.local`, `pricing-${actorId.slice(0, 8)}`],
      );
    } finally {
      await client.query('ALTER TABLE public.users ENABLE TRIGGER trg_users_role_guard');
    }
    await client.query(`SELECT set_config('app.user_id', $1, true)`, [actorId]);

    await client.query(`SELECT public.ensure_chart_of_accounts($1)`, [branchId]);
    await client.query(`SELECT public.seed_account_mappings($1)`, [branchId]);
    await client.query(`UPDATE public.settings SET tax_enabled = false`);
  });

  afterAll(async () => {
    if (client) {
      await client.query('ROLLBACK').catch(() => {});
      await client.end();
    }
  });

  it('books catalog price, not the client-supplied price', async () => {
    const res = await client.query(
      `SELECT public.process_sale($1, $2, $3, NULL, NULL, 2, 0, 'amount', 0, 0, 2, 200, 'cash', 'completed',
         $4::jsonb) AS r`,
      [invoiceNumber, branchId, warehouseId, JSON.stringify([{ product_id: productId, unit_name: 'piece', quantity: 2, unit_price: 1, discount_amount: 0, bonus_quantity: 0, total: 2 }])],
    );
    const r = res.rows[0].r;
    expect(r.success).toBe(true);
    if (!r.success) throw new Error(JSON.stringify(r));
    const items = await client.query(`SELECT unit_price, quantity, discount_amount, total FROM public.sale_items WHERE sale_id = $1`, [r.sale_id]);
    expect(items.rows).toHaveLength(1);
    expect(Number(items.rows[0].unit_price)).toBe(100);
    expect(Number(items.rows[0].total)).toBe(200);
    const sale = await client.query(`SELECT subtotal, discount_amount, tax_amount, total, paid_amount FROM public.sales WHERE id = $1`, [r.sale_id]);
    expect(Number(sale.rows[0].subtotal)).toBe(200);
    expect(Number(sale.rows[0].total)).toBe(200);
    expect(Number(sale.rows[0].paid_amount)).toBe(200);
    expect(Number(sale.rows[0].tax_amount)).toBe(0);
    const batch = await client.query(`SELECT quantity FROM public.inventory_unit_batches WHERE unit_id = $1 AND warehouse_id = $2`, [unitId, warehouseId]);
    expect(Number(batch.rows[0].quantity)).toBe(8);
    const ledger = await client.query(`SELECT entry_type, quantity FROM public.inventory_unit_entries WHERE reference_id = $1`, [r.sale_id]);
    expect(ledger.rows.length).toBeGreaterThan(0);
    expect(ledger.rows[0].entry_type).toBe('sale');
    expect(Number(ledger.rows[0].quantity)).toBe(-2);
    const journal = await client.query(`SELECT COALESCE(SUM(l.debit), 0)::numeric(14,2) AS dr, COALESCE(SUM(l.credit), 0)::numeric(14,2) AS cr FROM public.journal_entries j JOIN public.journal_entry_lines l ON l.journal_entry_id = j.id WHERE j.reference_id = $1`, [r.sale_id]);
    expect(Number(journal.rows[0].dr)).toBe(Number(journal.rows[0].cr));
    expect(Number(journal.rows[0].dr)).toBeGreaterThan(0);
  });

  it('rejects a discount that exceeds the line total (clamped server-side)', async () => {
    const inv2 = `${invoiceNumber}-B`;
    const res = await client.query(
      `SELECT public.process_sale($1, $2, $3, NULL, NULL, 0, 0, 'amount', 0, 0, 0, 0, 'cash', 'completed', $4::jsonb) AS r`,
      [inv2, branchId, warehouseId, JSON.stringify([{ product_id: productId, unit_name: 'piece', quantity: 1, unit_price: 100, discount_amount: 500, bonus_quantity: 0, total: -400 }])],
    );
    const r = res.rows[0].r;
    expect(r.success).toBe(true);
    if (!r.success) throw new Error(JSON.stringify(r));
    const items = await client.query(`SELECT unit_price, discount_amount, total FROM public.sale_items WHERE sale_id = $1`, [r.sale_id]);
    expect(Number(items.rows[0].unit_price)).toBe(100);
    expect(Number(items.rows[0].discount_amount)).toBe(100);
    expect(Number(items.rows[0].total)).toBe(0);
  });

  it('ignores tampered header totals and applies configured tax to the authoritative base', async () => {
    await client.query(`UPDATE public.settings SET tax_enabled = true, tax_rate = 15`);
    const inv3 = `${invoiceNumber}-C`;
    const res = await client.query(
      `SELECT public.process_sale($1, $2, $3, NULL, NULL, 1, 10, 'percent', 999, 0, 9999, 9999, 'cash', 'completed', $4::jsonb) AS r`,
      [inv3, branchId, warehouseId, JSON.stringify([{ product_id: productId, unit_name: 'tampered-unit', quantity: 1, unit_price: 0.01, discount_amount: 0, bonus_quantity: 0, total: 0.01 }])],
    );
    const r = res.rows[0].r;
    expect(r.success).toBe(true);
    if (!r.success) throw new Error(JSON.stringify(r));

    const sale = await client.query(
      `SELECT subtotal, discount_amount, discount_type, tax_amount, total, paid_amount FROM public.sales WHERE id = $1`,
      [r.sale_id],
    );
    expect(Number(sale.rows[0].subtotal)).toBe(100);
    expect(Number(sale.rows[0].discount_amount)).toBe(10);
    expect(sale.rows[0].discount_type).toBe('percent');
    expect(Number(sale.rows[0].tax_amount)).toBe(13.5);
    expect(Number(sale.rows[0].total)).toBe(103.5);
    expect(Number(sale.rows[0].paid_amount)).toBe(103.5);

    const line = await client.query(`SELECT unit_price, quantity, total FROM public.sale_items WHERE sale_id = $1`, [r.sale_id]);
    expect(Number(line.rows[0].unit_price)).toBe(100);
    expect(Number(line.rows[0].quantity)).toBe(1);
    expect(Number(line.rows[0].total)).toBe(100);

    const journal = await client.query(
      `SELECT COALESCE(SUM(l.debit), 0)::numeric(14,2) AS dr, COALESCE(SUM(l.credit), 0)::numeric(14,2) AS cr
       FROM public.journal_entries j
       JOIN public.journal_entry_lines l ON l.journal_entry_id = j.id
       WHERE j.reference_id = $1`,
      [r.sale_id],
    );
    expect(Number(journal.rows[0].dr)).toBe(Number(journal.rows[0].cr));
    await client.query(`UPDATE public.settings SET tax_enabled = false`);
  });

  it.each([0, -1])('rejects non-positive quantity %s before any sale write', async (quantity) => {
    const invoice = `${invoiceNumber}-Q-${quantity}`;
    const res = await client.query(
      `SELECT public.process_sale($1, $2, $3, NULL, NULL, 100, 0, 'amount', 0, 0, 100, 100, 'cash', 'completed', $4::jsonb) AS r`,
      [invoice, branchId, warehouseId, JSON.stringify([{ product_id: productId, unit_name: 'piece', quantity, unit_price: 100, discount_amount: 0, bonus_quantity: 0, total: 100 }])],
    );
    expect(res.rows[0].r.success).toBe(false);
    expect(res.rows[0].r.error).toBe('INVALID_QUANTITY');
    const written = await client.query(`SELECT count(*)::int AS count FROM public.sales WHERE invoice_number = $1`, [invoice]);
    expect(written.rows[0].count).toBe(0);
  });
});
