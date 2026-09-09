import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';
import { canImpersonate, runAs, seedRlsFixture, type RlsIds } from './rls';

const dbUrl = getDbUrl();
const skip = !dbUrl;

const REPORT_RPC_NAMES = [
  'get_journals',
  'get_general_ledger',
  'get_trial_balance',
  'get_trial_balance_summary',
  'get_income_statement',
  'get_balance_sheet',
  'get_ar_aging',
  'get_ap_aging',
  'get_aging_summary',
  'get_cash_flow',
  'get_party_statement',
  'get_treasury_balances',
  'get_bank_reconciliation',
] as const;

describe.skipIf(skip)('financial reporting RPC visibility', () => {
  let client: pg.Client;
  let ids: RlsIds;
  let imp = false;

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');
    ids = await seedRlsFixture(client);
    imp = await canImpersonate(client);
  });

  afterAll(async () => {
    if (client) {
      await client.query('ROLLBACK').catch(() => {});
      await client.end();
    }
  });

  it('every existing allowlisted report RPC is SECURITY INVOKER', async () => {
    const result = await client.query<{ proname: string; prosecdef: boolean }>(
      `SELECT p.proname, p.prosecdef
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.proname = ANY($1::text[])
       ORDER BY p.proname`,
      [REPORT_RPC_NAMES],
    );

    expect(result.rows.length).toBeGreaterThan(0);
    expect(result.rows.filter((row) => row.prosecdef)).toEqual([]);
  });

  it('anon cannot execute report RPCs while authenticated callers retain execute', async () => {
    const result = await client.query<{ proname: string; anon_exec: boolean; authenticated_exec: boolean }>(
      `SELECT p.proname,
              has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
              has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_exec
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.proname = ANY($1::text[])
       ORDER BY p.proname`,
      [REPORT_RPC_NAMES],
    );

    expect(result.rows.length).toBeGreaterThan(0);
    // A PUBLIC EXECUTE grant would also make has_function_privilege('anon', ...)
    // true, so this assertion catches both direct anon and inherited PUBLIC grants.
    expect(result.rows.every((row) => !row.anon_exec && row.authenticated_exec)).toBe(true);
  });

  it('income statement remains callable by an authenticated owner under invoker mode', async (ctx: { skip?: () => unknown }) => {
    if (!imp) return typeof ctx.skip === 'function' ? ctx.skip() : undefined;

    const result = await runAs(
      client,
      ids.users.owner,
      'SELECT public.get_income_statement($1, CURRENT_DATE - 30, CURRENT_DATE) AS report',
      [ids.branchA],
    );

    expect(result.error).toBeUndefined();
    expect(result.rowCount).toBe(1);
  });

  it('income statement remains callable by a restricted authenticated role and therefore runs under its RLS context', async (ctx: { skip?: () => unknown }) => {
    if (!imp) return typeof ctx.skip === 'function' ? ctx.skip() : undefined;

    const result = await runAs(
      client,
      ids.users.accountant,
      'SELECT public.get_income_statement($1, CURRENT_DATE - 30, CURRENT_DATE) AS report',
      [ids.branchA],
    );

    expect(result.error).toBeUndefined();
    expect(result.rowCount).toBe(1);
  });
});
