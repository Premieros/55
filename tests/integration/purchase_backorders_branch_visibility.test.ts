import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { getDbUrl, openDb } from './db';
import type pg from 'pg';

const dbUrl = getDbUrl();
const skip = !dbUrl;

describe.skipIf(skip)('purchase backorders branch visibility', () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
  });

  afterAll(async () => {
    if (client) await client.end();
  });

  it('returns branch_id and keeps the RPC hardened', async () => {
    const { rows } = await client.query<{
      result: string;
      security_definer: boolean;
      config: string[] | null;
      anon_execute: boolean;
      authenticated_execute: boolean;
    }>(`
      SELECT
        pg_get_function_result('public.get_purchase_backorders(uuid)'::regprocedure) AS result,
        p.prosecdef AS security_definer,
        p.proconfig AS config,
        has_function_privilege('anon', 'public.get_purchase_backorders(uuid)', 'EXECUTE') AS anon_execute,
        has_function_privilege('authenticated', 'public.get_purchase_backorders(uuid)', 'EXECUTE') AS authenticated_execute
      FROM pg_proc p
      WHERE p.oid = 'public.get_purchase_backorders(uuid)'::regprocedure
    `);

    expect(rows).toHaveLength(1);
    expect(rows[0].result).toContain('branch_id uuid');
    expect(rows[0].security_definer).toBe(true);
    expect(rows[0].config?.join(';')).toContain('search_path=public, pg_temp');
    expect(rows[0].anon_execute).toBe(false);
    expect(rows[0].authenticated_execute).toBe(true);
  });
});
