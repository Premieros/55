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

describe('product modifier branch consistency', () => {
  it('installs database-level branch consistency triggers', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT tgname
      FROM pg_trigger
      WHERE NOT tgisinternal
        AND tgname IN (
          'trg_modifier_group_branch_consistency',
          'trg_modifier_option_branch_consistency',
          'trg_modifier_effect_branch_consistency'
        )
      ORDER BY tgname
    `);
    expect(result.rows.map((r) => r.tgname)).toEqual([
      'trg_modifier_effect_branch_consistency',
      'trg_modifier_group_branch_consistency',
      'trg_modifier_option_branch_consistency',
    ]);
  });

  it('keeps trigger helpers unavailable as client RPC helpers', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        has_function_privilege('authenticated', 'public._enforce_modifier_group_branch()', 'EXECUTE') AS auth_group,
        has_function_privilege('authenticated', 'public._enforce_modifier_option_branch()', 'EXECUTE') AS auth_option,
        has_function_privilege('authenticated', 'public._enforce_modifier_effect_branch()', 'EXECUTE') AS auth_effect,
        has_function_privilege('anon', 'public._enforce_modifier_group_branch()', 'EXECUTE') AS anon_group
    `);
    expect(result.rows[0]).toMatchObject({
      auth_group: false,
      auth_option: false,
      auth_effect: false,
      anon_group: false,
    });
  });

  it('checks product, group, option, and inventory target branches in trigger definitions', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        pg_get_functiondef('public._enforce_modifier_group_branch()'::regprocedure) AS group_def,
        pg_get_functiondef('public._enforce_modifier_option_branch()'::regprocedure) AS option_def,
        pg_get_functiondef('public._enforce_modifier_effect_branch()'::regprocedure) AS effect_def
    `);
    expect(String(result.rows[0].group_def)).toContain('MODIFIER_GROUP_BRANCH_MISMATCH');
    expect(String(result.rows[0].option_def)).toContain('MODIFIER_OPTION_BRANCH_MISMATCH');
    expect(String(result.rows[0].effect_def)).toContain('MODIFIER_EFFECT_TARGET_BRANCH_MISMATCH');
  });
});
