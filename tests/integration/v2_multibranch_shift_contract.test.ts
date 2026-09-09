import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';

const dbUrl = getDbUrl();
const skip = !dbUrl;

type RpcResult = {
  success?: boolean;
  error?: string;
  open?: boolean;
  shift_id?: string;
  branch_id?: string;
  shift?: { id: string; branch_id: string; cashier_id: string };
};

describe.skipIf(skip)('V2 multi-branch shift contract', () => {
  let client: pg.Client;
  const branchA = randomUUID();
  const branchB = randomUUID();
  const branchC = randomUUID();
  const userId = randomUUID();
  const role = `v2_shift_${randomUUID().slice(0, 8)}`;
  let shiftId = '';

  async function asUser<T>(fn: () => Promise<T>): Promise<T> {
    await client.query(`SELECT set_config('app.user_id', $1, true)`, [userId]);
    await client.query(`SET LOCAL ROLE authenticated`);
    try {
      return await fn();
    } finally {
      await client.query('RESET ROLE').catch(() => {});
      await client.query('RESET app.user_id').catch(() => {});
    }
  }

  const rpc = async (sql: string, params: unknown[] = []): Promise<RpcResult> => {
    const result = await client.query<{ r: RpcResult }>(sql, params);
    return result.rows[0].r;
  };

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');

    await client.query(
      `INSERT INTO public.branches (id, name)
       VALUES ($1, 'V2 Shift A'), ($2, 'V2 Shift B'), ($3, 'V2 Shift C')`,
      [branchA, branchB, branchC],
    );
    await client.query(
      `INSERT INTO public.roles (role, name_ar, name_en, permissions, scope, is_active)
       VALUES ($1, 'V2 shift user', 'V2 shift user', '["pos.view","shifts.view","shifts.open"]'::jsonb, 'global', true)`,
      [role],
    );
    await client.query(`ALTER TABLE public.users DISABLE TRIGGER trg_users_role_guard`);
    await client.query(
      `INSERT INTO public.users (id, email, full_name, role, branch_id, is_active)
       VALUES ($1, $2, 'V2 Multi Branch User', $3, $4, true)`,
      [userId, `${randomUUID()}@test.local`, role, branchA],
    );
    await client.query(
      `INSERT INTO public.user_branch_access (user_id, branch_id) VALUES ($1, $2)`,
      [userId, branchB],
    );
  });

  afterAll(async () => {
    if (!client) return;
    await client.query('ROLLBACK').catch(() => {});
    await client.end().catch(() => {});
  });

  it('opens the user shift in an explicitly authorized secondary branch', async () => {
    const opened = await asUser(() => rpc(
      `SELECT public.open_shift($1, $2, $3) AS r`,
      [branchB, 100, 'secondary branch shift'],
    ));
    expect(opened).toMatchObject({ success: true, branch_id: branchB });
    expect(opened.shift_id).toBeTruthy();
    shiftId = opened.shift_id || '';
  });

  it('returns the same open shift regardless of the selected UI branch', async () => {
    const active = await asUser(() => rpc(`SELECT public.get_active_shift(NULL) AS r`));
    expect(active).toMatchObject({ success: true, open: true });
    expect(active.shift).toMatchObject({ branch_id: branchB, cashier_id: userId });
  });

  it('prevents a second simultaneous shift for the same user', async () => {
    const second = await asUser(() => rpc(
      `SELECT public.open_shift($1, $2, NULL) AS r`,
      [branchA, 0],
    ));
    expect(second).toMatchObject({ success: false, error: 'SHIFT_ALREADY_OPEN' });
  });

  it('rejects a branch the user has not been granted', async () => {
    const denied = await asUser(() => rpc(
      `SELECT public.open_shift($1, $2, NULL) AS r`,
      [branchC, 0],
    ));
    expect(denied).toMatchObject({ success: false, error: 'BRANCH_MISMATCH' });
  });

  it('does not let the shift owner close without shifts.close', async () => {
    const denied = await asUser(() => rpc(
      `SELECT public.close_shift($1, $2, $3) AS r`,
      [shiftId, 100, 'no close permission'],
    ));
    expect(denied).toMatchObject({ success: false, error: 'SHIFT_CLOSE_DENIED' });
  });

  it('closes the own shift after shifts.close is explicitly granted', async () => {
    await client.query(
      `UPDATE public.roles
       SET permissions = permissions || '["shifts.close"]'::jsonb
       WHERE role = $1`,
      [role],
    );

    const closed = await asUser(() => rpc(
      `SELECT public.close_shift($1, $2, $3) AS r`,
      [shiftId, 100, 'authorized close'],
    ));
    expect(closed.success).toBe(true);
    expect(closed.shift_id).toBe(shiftId);
  });
});
