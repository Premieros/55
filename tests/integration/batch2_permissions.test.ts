/**
 * Batch 2 — Permissions + Super Admin Console
 * Integration tests for tenant isolation and the canonical permission model.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';
import { canImpersonate, runAs, runAsPersist, seedRlsFixture, type RlsIds } from './rls';

let client: pg.Client;
let ids: RlsIds;
let canRun = false;

const dbUrl = getDbUrl();

beforeAll(async () => {
  if (!dbUrl) return;
  try {
    client = openDb(dbUrl);
    await client.connect();
    await client.query('BEGIN');
    canRun = await canImpersonate(client);
    if (canRun) ids = await seedRlsFixture(client);
  } catch {
    canRun = false;
  }
}, 30_000);

afterAll(async () => {
  if (canRun && client) {
    await client.query('ROLLBACK').catch(() => {});
    await client.end().catch(() => {});
  }
});

function skip() {
  return !canRun;
}

describe('Batch 2: Owner sees own organization', () => {
  it('owner can query organizations they belong to', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.owner,
      `SELECT id FROM public.organizations WHERE id IN (SELECT public.user_organization_ids())`);
    expect(r.rowCount).toBeGreaterThanOrEqual(1);
  });

  it('owner sees own branches via user_may_access_branch', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.owner,
      `SELECT public.user_may_access_branch($1)`, [ids.branchA]);
    expect(r.rows[0].user_may_access_branch).toBe(true);
  });
});

describe('Batch 2: Owner cannot see another organization', () => {
  it('owner of org A cannot access org B branches directly', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.owner,
      `SELECT public.user_may_access_branch($1)`, [ids.branchB]);
    expect(r.rows[0].user_may_access_branch).toBe(false);
  });

  it('owner of org A cannot read org B products', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.owner,
      `SELECT count(*) FROM public.products WHERE branch_id = $1`, [ids.branchB]);
    expect(r.rowCount).toBe(1);
    expect(Number(r.rows[0].count)).toBe(0);
  });
});

describe('Batch 2: Owner creates branch', () => {
  it('owner can call create_organization_branch for their org', async () => {
    if (skip()) return;
    const orgId = (await client.query(
      `SELECT organization_id FROM public.branches WHERE id = $1`, [ids.branchA]
    )).rows[0].organization_id;
    const r = await runAsPersist(client, ids.users.owner,
      `SELECT public.create_organization_branch($1, 'Owner Branch', 'en', null, null)`, [orgId]);
    const result = typeof r.rows[0].create_organization_branch === 'string'
      ? JSON.parse(r.rows[0].create_organization_branch)
      : r.rows[0].create_organization_branch;
    expect(result.success).toBe(true);
  });
});

describe('Batch 2: Owner cannot create branch in another org', () => {
  it('org A member cannot create branch in org B', async () => {
    if (skip()) return;
    const orgB = (await client.query(`SELECT id FROM public.organizations WHERE slug = 'org-b'`)).rows[0].id;
    const r = await runAsPersist(client, ids.users.branch_manager,
      `SELECT public.create_organization_branch($1, 'Unauthorized Branch', null, null, null)`, [orgB]);
    const result = typeof r.rows[0].create_organization_branch === 'string'
      ? JSON.parse(r.rows[0].create_organization_branch)
      : r.rows[0].create_organization_branch;
    expect(result.success).toBe(false);
    expect(result.error).toBe('FORBIDDEN');
  });
});

describe('Batch 2: Branch Manager sees allowed branches only', () => {
  it('branch_manager can access their assigned branch', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.branch_manager,
      `SELECT public.user_may_access_branch($1)`, [ids.branchA]);
    expect(r.rows[0].user_may_access_branch).toBe(true);
  });

  it('branch_manager cannot access org B branch', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.branch_manager,
      `SELECT public.user_may_access_branch($1)`, [ids.branchB]);
    expect(r.rows[0].user_may_access_branch).toBe(false);
  });

  it('branch_manager can read own branch products', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.branch_manager,
      `SELECT count(*) FROM public.products WHERE branch_id = $1`, [ids.branchA]);
    expect(Number(r.rows[0].count)).toBeGreaterThanOrEqual(1);
  });
});

describe('Batch 2: Cashier cannot access owner screens', () => {
  it('cashier cannot manage settings', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.can_permission('settings.manage')`);
    expect(r.rows[0].can_permission).toBe(false);
  });

  it('cashier cannot access organization management', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.can_permission('branches.manage')`);
    expect(r.rows[0].can_permission).toBe(false);
  });
});

describe('Batch 2: Warehouse uses canonical catalog and inventory capabilities', () => {
  it('warehouse_manager cannot manage accounts', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.warehouse_manager,
      `SELECT public.can_permission('accounts.manage')`);
    expect(r.rows[0].can_permission).toBe(false);
  });

  it('warehouse_manager receives the granular product and inventory template', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.warehouse_manager, `
      SELECT
        public.can_permission('products.create') AS product_create,
        public.can_permission('products.edit') AS product_edit,
        public.can_permission('products.delete') AS product_delete,
        public.can_permission('inventory.adjust') AS inventory_adjust,
        public.can_permission('inventory.count.create') AS count_create,
        public.can_permission('inventory.count.approve') AS count_approve,
        public.can_permission('inventory.transfer.create') AS transfer_create,
        public.can_permission('inventory.transfer.approve') AS transfer_approve,
        public.can_permission('products.manage') AS legacy_products,
        public.can_permission('inventory.manage') AS legacy_inventory
    `);
    expect(r.rows[0]).toMatchObject({
      product_create: true,
      product_edit: true,
      product_delete: true,
      inventory_adjust: true,
      count_create: true,
      count_approve: true,
      transfer_create: true,
      transfer_approve: true,
      legacy_products: false,
      legacy_inventory: false,
    });
  });
});

describe('Batch 2: Accountant cannot access platform administration', () => {
  it('accountant cannot manage settings', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.accountant,
      `SELECT public.can_permission('settings.manage')`);
    expect(r.rows[0].can_permission).toBe(false);
  });

  it('accountant can view financial reports', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.accountant,
      `SELECT public.can_permission('reports.financial') AS reports_ok, public.can_permission('accounts.manage') AS accounts_ok`);
    expect(r.rows[0].reports_ok).toBe(true);
    expect(r.rows[0].accounts_ok).toBe(true);
  });
});

describe('Batch 2: Super Admin can see all tenants', () => {
  it('super_admin can see all branches across all orgs', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.super_admin,
      `SELECT public.user_may_access_branch($1)`, [ids.branchA]);
    expect(r.rows[0].user_may_access_branch).toBe(true);
    const r2 = await runAs(client, ids.users.super_admin,
      `SELECT public.user_may_access_branch($1)`, [ids.branchB]);
    expect(r2.rows[0].user_may_access_branch).toBe(true);
  });

  it('super_admin can read all organizations', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.super_admin, `SELECT count(*) FROM public.organizations`);
    expect(Number(r.rows[0].count)).toBeGreaterThanOrEqual(2);
  });
});

describe('Batch 2: Normal user cannot see super admin console', () => {
  it('cashier is not platform admin', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier, `SELECT public.is_platform_admin()`);
    expect(r.rows[0].is_platform_admin).toBe(false);
  });

  it('cashier is not pos_admin', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier, `SELECT public.is_pos_admin()`);
    expect(r.rows[0].is_pos_admin).toBe(false);
  });
});

describe('Batch 2: User branch assignment enforced', () => {
  it('user_branch_access table exists and has rows', async () => {
    if (skip()) return;
    const r = await client.query(`SELECT count(*) FROM public.user_branch_access`);
    expect(Number(r.rows[0].count)).toBeGreaterThanOrEqual(1);
  });

  it('cashier A has branch A access', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.user_may_access_branch($1)`, [ids.branchA]);
    expect(r.rows[0].user_may_access_branch).toBe(true);
  });

  it('cashier A cannot access branch B (different org)', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.user_may_access_branch($1)`, [ids.branchB]);
    expect(r.rows[0].user_may_access_branch).toBe(false);
  });
});

describe('Batch 2: Sales use the controlled RPC boundary', () => {
  it('blocks direct authenticated inserts even for super_admin', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.super_admin,
      `INSERT INTO public.sales (invoice_number, branch_id, warehouse_id, subtotal, discount_amount, tax_amount, total, paid_amount, payment_method, status)
       VALUES ('DISABLED-TEST', (SELECT id FROM public.branches WHERE name = 'RLS A' LIMIT 1), $1, 0, 0, 0, 0, 0, 'cash', 'completed')`,
      [ids.whA]);
    expect(r.error).toBeTruthy();
  });
});

describe('Batch 2: organization_id cannot be changed directly', () => {
  it('attempting to change organization_id on branches is blocked', async () => {
    if (skip()) return;
    const orgB = (await client.query(`SELECT id FROM public.organizations WHERE slug = 'org-b'`)).rows[0].id;
    const r = await runAs(client, ids.users.super_admin,
      `UPDATE public.branches SET organization_id = $1 WHERE id = $2`, [orgB, ids.branchA]);
    expect(r.error).toContain('ORG_CHANGE_FORBIDDEN');
  });
});

describe('Batch 2: cross-tenant RPC access denied', () => {
  it('org A member cannot use RPCs targeting org B branches', async () => {
    if (skip()) return;
    const r = await runAsPersist(client, ids.users.branch_manager,
      `SELECT public.update_branch($1, 'Hacked Name')`, [ids.branchB]);
    const result = typeof r.rows[0].update_branch === 'string'
      ? JSON.parse(r.rows[0].update_branch)
      : r.rows[0].update_branch;
    expect(result.success).toBe(false);
    expect(result.error).toBe('FORBIDDEN');
  });
});

describe('Batch 2: RPC authorization checks', () => {
  it('assign_user_to_branch requires admin or org owner', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.assign_user_to_branch($1, $2)`, [ids.users.cashier, ids.branchA]);
    const result = r.rows[0] as Record<string, unknown>;
    expect(result.assign_user_to_branch).toBeDefined();
    const parsed = typeof result.assign_user_to_branch === 'string'
      ? JSON.parse(result.assign_user_to_branch as string)
      : result.assign_user_to_branch;
    expect(parsed.success).toBe(false);
    expect(parsed.error).toBe('PERMISSION_DENIED');
  });

  it('remove_user_from_branch requires admin or org owner', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.cashier,
      `SELECT public.remove_user_from_branch($1, $2)`, [ids.users.cashier, ids.branchA]);
    const result = r.rows[0] as Record<string, unknown>;
    const parsed = typeof result.remove_user_from_branch === 'string'
      ? JSON.parse(result.remove_user_from_branch as string)
      : result.remove_user_from_branch;
    expect(parsed.success).toBe(false);
  });

  it('get_user_branch_access returns branches for a user', async () => {
    if (skip()) return;
    const r = await runAs(client, ids.users.super_admin,
      `SELECT count(*) FROM public.get_user_branch_access($1)`, [ids.users.cashier]);
    expect(Number(r.rows[0].count)).toBeGreaterThanOrEqual(1);
  });
});
