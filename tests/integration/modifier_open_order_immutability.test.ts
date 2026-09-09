import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';

let client: pg.Client;
let canRun = false;

beforeAll(async () => {
  const dbUrl = getDbUrl();
  if (!dbUrl) return;
  try {
    client = openDb(dbUrl);
    await client.connect();
    canRun = true;
  } catch {
    canRun = false;
  }
}, 30_000);

afterAll(async () => {
  if (client) await client.end().catch(() => {});
});

describe('modifier open-order immutability', () => {
  it('installs delete and identity-update protection triggers', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT tgname
      FROM pg_trigger
      WHERE NOT tgisinternal
        AND tgname IN (
          'trg_protect_modifier_option_open_order_delete',
          'trg_protect_modifier_option_open_order_update'
        )
      ORDER BY tgname
    `);
    expect(result.rows.map((r) => r.tgname)).toEqual([
      'trg_protect_modifier_option_open_order_delete',
      'trg_protect_modifier_option_open_order_update',
    ]);
  });

  it('checks open and held order-item modifier arrays before catalogue identity changes', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        pg_get_functiondef('public._protect_modifier_option_open_order_reference()'::regprocedure) AS delete_def,
        pg_get_functiondef('public._protect_modifier_option_open_order_update()'::regprocedure) AS update_def
    `);
    const deleteDef = String(result.rows[0].delete_def);
    const updateDef = String(result.rows[0].update_def);
    for (const def of [deleteDef, updateDef]) {
      expect(def).toContain("o.status IN ('open', 'held')");
      expect(def).toContain('modifier_option_ids');
      expect(def).toContain('MODIFIER_OPTION_IN_OPEN_ORDER');
    }
    expect(updateDef).toContain('NEW.group_id');
    expect(updateDef).toContain('NEW.branch_id');
  });

  it('keeps protection helpers private from browser roles', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        has_function_privilege('authenticated', 'public._protect_modifier_option_open_order_reference()', 'EXECUTE') AS auth_delete,
        has_function_privilege('authenticated', 'public._protect_modifier_option_open_order_update()', 'EXECUTE') AS auth_update,
        has_function_privilege('anon', 'public._protect_modifier_option_open_order_reference()', 'EXECUTE') AS anon_delete
    `);
    expect(result.rows[0]).toMatchObject({ auth_delete: false, auth_update: false, anon_delete: false });
  });
});
