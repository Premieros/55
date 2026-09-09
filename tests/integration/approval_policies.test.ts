import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';

const dbUrl = getDbUrl();

describe.skipIf(!dbUrl)('approval policy contract', () => {
  let client: pg.Client;
  const branchId = randomUUID();
  const selectedApprover = randomUUID();
  const otherApprover = randomUUID();
  const selectedRole = `policy_selected_${randomUUID().slice(0, 8)}`;
  const otherRole = `policy_other_${randomUUID().slice(0, 8)}`;

  async function canApprove(userId: string, amount: number): Promise<boolean> {
    await client.query(`SELECT set_config('app.user_id',$1,true)`, [userId]);
    await client.query(`SET LOCAL ROLE authenticated`);
    try {
      const result = await client.query<{ allowed: boolean }>(
        `SELECT public.can_approve_by_policy('waste',$1,$2,'waste.approve') AS allowed`,
        [branchId, amount],
      );
      return result.rows[0].allowed;
    } finally {
      await client.query('RESET ROLE').catch(() => {});
      await client.query('RESET app.user_id').catch(() => {});
    }
  }

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');
    await client.query(`INSERT INTO public.branches(id,name) VALUES($1,'Approval Policy Branch')`, [branchId]);
    await client.query(
      `INSERT INTO public.roles(role,name_ar,name_en,permissions,scope,is_active) VALUES
       ($1,'Selected','Selected','["waste.approve"]'::jsonb,'global',true),
       ($2,'Other','Other','["waste.approve"]'::jsonb,'global',true)`,
      [selectedRole, otherRole],
    );
    await client.query(`ALTER TABLE public.users DISABLE TRIGGER trg_users_role_guard`);
    await client.query(
      `INSERT INTO public.users(id,email,full_name,role,branch_id,is_active) VALUES
       ($1,$2,'Selected Approver',$3,$4,true),($5,$6,'Other Approver',$7,$4,true)`,
      [selectedApprover, `${randomUUID()}@test.local`, selectedRole, branchId, otherApprover, `${randomUUID()}@test.local`, otherRole],
    );
  });

  afterAll(async () => {
    if (!client) return;
    await client.query('ROLLBACK').catch(() => {});
    await client.end().catch(() => {});
  });

  it('uses the existing permission when no policy is configured', async () => {
    expect(await canApprove(otherApprover, 25)).toBe(true);
  });

  it('restricts the configured amount band to the selected approver', async () => {
    await client.query(
      `INSERT INTO public.approval_policies(scope,branch_id,min_amount,max_amount,approver_mode,approver_user_id,created_by)
       VALUES('waste',$1,0,100,'user',$2,$2)`,
      [branchId, selectedApprover],
    );
    expect(await canApprove(selectedApprover, 50)).toBe(true);
    expect(await canApprove(otherApprover, 50)).toBe(false);
  });

  it('denies uncovered amounts once policies exist instead of falling back', async () => {
    expect(await canApprove(selectedApprover, 150)).toBe(false);
    expect(await canApprove(otherApprover, 150)).toBe(false);
  });
});
