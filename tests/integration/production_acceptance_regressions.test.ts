import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { getDbUrl, openDb } from './db';
import type pg from 'pg';

const dbUrl = getDbUrl();

async function asUser(client: pg.Client, userId: string, sql: string, params: unknown[] = []) {
  const sp = `sp_${randomUUID().split('-').join('')}`;
  await client.query(`SAVEPOINT ${sp}`);
  try {
    await client.query('SET LOCAL ROLE authenticated');
    await client.query(`SELECT set_config('app.user_id', $1, true)`, [userId]);
    return await client.query(sql, params);
  } finally {
    await client.query(`ROLLBACK TO SAVEPOINT ${sp}`);
    await client.query(`RELEASE SAVEPOINT ${sp}`);
  }
}

describe.skipIf(!dbUrl)('Production acceptance regressions', () => {
  let client: pg.Client;
  const orgId = randomUUID();
  const branchId = randomUUID();
  const warehouseId = randomUUID();
  const managerId = randomUUID();
  const cashierId = randomUUID();
  const lowId = randomUUID();
  const lowRole = `qa_low_${randomUUID().slice(0, 8)}`;

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');

    await client.query(`INSERT INTO public.organizations(id,name,slug) VALUES ($1,'Acceptance Org',$2)`, [orgId, `accept-${randomUUID()}`]);
    await client.query(`INSERT INTO public.branches(id,organization_id,name) VALUES ($1,$2,'Acceptance Branch')`, [branchId, orgId]);
    await client.query(`INSERT INTO public.warehouses(id,branch_id,name,is_active) VALUES ($1,$2,'Acceptance WH',true)`, [warehouseId, branchId]);
    await client.query(
      `INSERT INTO public.roles(role,name_ar,name_en,permissions)
       VALUES ($1,'اختبار محدود','Low QA','["dashboard.view"]'::jsonb)`,
      [lowRole],
    );

    await client.query('ALTER TABLE public.users DISABLE TRIGGER trg_users_role_guard');
    try {
      await client.query(
        `INSERT INTO public.users(id,email,username,full_name,role,branch_id,is_active) VALUES
         ($1,$2,$3,'Acceptance Manager','branch_manager',$7,true),
         ($4,$5,$6,'Acceptance Cashier','cashier',$7,true),
         ($8,$9,$10,'Acceptance Low',$11,$7,true)`,
        [
          managerId, `mgr-${randomUUID()}@test.local`, `mgr_${randomUUID().slice(0, 8)}`,
          cashierId, `cash-${randomUUID()}@test.local`, `cash_${randomUUID().slice(0, 8)}`,
          branchId,
          lowId, `low-${randomUUID()}@test.local`, `low_${randomUUID().slice(0, 8)}`, lowRole,
        ],
      );
    } finally {
      await client.query('ALTER TABLE public.users ENABLE TRIGGER trg_users_role_guard');
    }

    await client.query(
      `INSERT INTO public.organization_members(organization_id,user_id,membership_role,is_active)
       VALUES ($1,$2,'member',true),($1,$3,'member',true),($1,$4,'member',true)`,
      [orgId, managerId, cashierId, lowId],
    );

    const supplier = (await client.query<{ id: string }>(
      `INSERT INTO public.suppliers(name,branch_id) VALUES ('Acceptance Supplier',$1) RETURNING id`, [branchId],
    )).rows[0].id;
    const product = (await client.query<{ id: string }>(
      `INSERT INTO public.products(name,branch_id,cost_price,sale_price,is_active) VALUES ('Acceptance Product',$1,10,20,true) RETURNING id`, [branchId],
    )).rows[0].id;
    await client.query(
      `INSERT INTO public.purchases(invoice_number,supplier_id,branch_id,warehouse_id,subtotal,discount_amount,tax_amount,total,paid_amount,payment_method,status)
       VALUES ($1,$2,$3,$4,20,0,0,20,20,'cash','completed')`,
      [`P-${randomUUID()}`, supplier, branchId, warehouseId],
    );
    await client.query(
      `INSERT INTO public.sales(invoice_number,branch_id,warehouse_id,subtotal,discount_amount,tax_amount,total,paid_amount,payment_method,status)
       VALUES ($1,$2,$3,20,0,0,20,20,'cash','completed')`,
      [`S-${randomUUID()}`, branchId, warehouseId],
    );
    await client.query(
      `INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
       VALUES ($1,$2,'QA_READ','products',$3,'{}'::jsonb,$4)`,
      [managerId, 'mgr@test.local', product, branchId],
    );
  });

  afterAll(async () => {
    await client.query('ROLLBACK').catch(() => {});
    await client.end().catch(() => {});
  });

  it('branch manager can create a dining area with floor_plan.manage', async () => {
    const res = await asUser(
      client,
      managerId,
      `INSERT INTO public.dining_areas(branch_id,name,sort_order) VALUES ($1,'Manager Area',1) RETURNING id`,
      [branchId],
    );
    expect(res.rows).toHaveLength(1);
  });

  it('cashier keeps established financial visibility while unrelated sensitive reads remain permission-gated', async () => {
    const products = await asUser(client, cashierId, `SELECT count(*)::int c FROM public.products WHERE branch_id=$1`, [branchId]);
    const sales = await asUser(client, cashierId, `SELECT count(*)::int c FROM public.sales WHERE branch_id=$1`, [branchId]);
    const purchases = await asUser(client, cashierId, `SELECT count(*)::int c FROM public.purchases WHERE branch_id=$1`, [branchId]);
    const users = await asUser(client, cashierId, `SELECT count(*)::int c FROM public.users WHERE branch_id=$1 AND id<>auth.uid()`, [branchId]);
    const audit = await asUser(client, cashierId, `SELECT count(*)::int c FROM public.audit_log WHERE branch_id=$1`, [branchId]);

    expect(products.rows[0].c).toBeGreaterThan(0);
    expect(sales.rows[0].c).toBeGreaterThan(0);
    expect(purchases.rows[0].c).toBeGreaterThan(0);
    expect(users.rows[0].c).toBe(0);
    expect(audit.rows[0].c).toBeGreaterThan(0);
  });

  it('a dashboard-only role cannot read products, sales, or other users directly', async () => {
    for (const table of ['products', 'sales'] as const) {
      const res = await asUser(client, lowId, `SELECT count(*)::int c FROM public.${table} WHERE branch_id=$1`, [branchId]);
      expect(res.rows[0].c, table).toBe(0);
    }
    const users = await asUser(client, lowId, `SELECT count(*)::int c FROM public.users WHERE branch_id=$1 AND id<>auth.uid()`, [branchId]);
    expect(users.rows[0].c).toBe(0);

    // Purchases and direct audit rows intentionally retain their established
    // branch/financial-visibility contracts; those are covered by dedicated
    // regression suites and must not be silently overridden here.
    const purchases = await asUser(client, lowId, `SELECT count(*)::int c FROM public.purchases WHERE branch_id=$1`, [branchId]);
    const audit = await asUser(client, lowId, `SELECT count(*)::int c FROM public.audit_log WHERE branch_id=$1`, [branchId]);
    expect(purchases.rows[0].c).toBeGreaterThan(0);
    expect(audit.rows[0].c).toBeGreaterThan(0);
  });
});
