import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { randomUUID } from 'node:crypto';
import { getDbUrl, openDb } from './db';
import type pg from 'pg';

const dbUrl = getDbUrl();
const skip = !dbUrl;

describe.skipIf(skip)('Kitchen M091/M092 RBAC + branch isolation', () => {
  let client: pg.Client;
  const branchA = randomUUID();
  const branchB = randomUUID();
  const productionUser = randomUUID();
  const cashierUser = randomUUID();
  const orderA = randomUUID();
  const orderB = randomUUID();

  async function asUser<T>(userId: string, fn: () => Promise<T>): Promise<T> {
    await client.query(`SELECT set_config('app.user_id', $1, true)`, [userId]);
    await client.query(`SET LOCAL ROLE authenticated`);
    try { return await fn(); }
    finally {
      await client.query('RESET ROLE').catch(() => {});
      await client.query('RESET app.user_id').catch(() => {});
    }
  }

  async function expectDbError(fn: () => Promise<unknown>): Promise<void> {
    const sp = `sp_${randomUUID().replace(/-/g, '')}`;
    await client.query(`SAVEPOINT ${sp}`);
    let threw = false;
    try {
      await fn();
    } catch {
      threw = true;
    }
    await client.query(`ROLLBACK TO SAVEPOINT ${sp}`);
    await client.query(`RELEASE SAVEPOINT ${sp}`);
    expect(threw).toBe(true);
  }

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');
    await client.query(`ALTER TABLE public.users DISABLE TRIGGER trg_users_role_guard`);
    await client.query(`INSERT INTO public.branches (id, name) VALUES ($1, 'Kitchen RBAC A'), ($2, 'Kitchen RBAC B')`, [branchA, branchB]);
    await client.query(
      `INSERT INTO public.users (id, email, full_name, role, branch_id, is_active)
       VALUES ($1, $2, 'Production User', 'production_manager', $3, true),
              ($4, $5, 'Cashier User', 'cashier', $3, true)`,
      [productionUser, `${randomUUID()}@test.local`, branchA, cashierUser, `${randomUUID()}@test.local`],
    );
    await client.query(
      `INSERT INTO public.orders (id, order_number, branch_id, status, kitchen_status, station)
       VALUES ($1, 'M091-A', $2, 'open', 'sent', 'main'),
              ($3, 'M091-B', $4, 'open', 'sent', 'main')`,
      [orderA, branchA, orderB, branchB],
    );
  });

  afterAll(async () => {
    await client.query('ROLLBACK').catch(() => {});
    await client.end().catch(() => {});
  });

  it('production_manager can query own-branch KDS and cannot read another branch', async () => {
    await asUser(productionUser, async () => {
      const own = await client.query<{ order_id: string }>(
        `SELECT order_id FROM public.get_kitchen_queue(NULL, $1)`, [branchA],
      );
      expect(own.rows.some(r => r.order_id === orderA)).toBe(true);

      const other = await client.query<{ order_id: string }>(
        `SELECT order_id FROM public.get_kitchen_queue(NULL, $1)`, [branchB],
      );
      expect(other.rowCount).toBe(0);
    });
  });

  it('production_manager can route own-branch orders but not cross-branch orders', async () => {
    await asUser(productionUser, async () => {
      await client.query(`SELECT public.route_to_station($1, 'grill')`, [orderA]);
      const own = await client.query<{ station: string }>(`SELECT station FROM public.orders WHERE id = $1`, [orderA]);
      expect(own.rows[0].station).toBe('grill');

      await expectDbError(() => client.query(`SELECT public.route_to_station($1, 'grill')`, [orderB]));
    });
  });

  it('cashier cannot query KDS without pos.kds_view', async () => {
    await asUser(cashierUser, async () => {
      const r = await client.query(`SELECT * FROM public.get_kitchen_queue(NULL, $1)`, [branchA]);
      expect(r.rowCount).toBe(0);
    });
  });

  it('cashier cannot route kitchen stations without pos.kds_view', async () => {
    await asUser(cashierUser, async () => {
      await expectDbError(() => client.query(`SELECT public.route_to_station($1, 'grill')`, [orderA]));
    });
  });
});
