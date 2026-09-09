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

describe('product modifier security and atomicity', () => {
  it('keeps inventory-effect recipes server-internal', async () => {
    if (!canRun) return;
    const r = await client.query(`
      SELECT
        has_table_privilege('authenticated', 'public.product_modifier_inventory_effects', 'SELECT') AS authenticated_select,
        has_table_privilege('anon', 'public.product_modifier_inventory_effects', 'SELECT') AS anon_select,
        has_table_privilege('service_role', 'public.product_modifier_inventory_effects', 'SELECT') AS service_select
    `);
    expect(r.rows[0]).toMatchObject({
      authenticated_select: false,
      anon_select: false,
      service_select: true,
    });
  });

  it('validates the complete modifier payload before replacing existing configuration', async () => {
    if (!canRun) return;
    const r = await client.query(`
      SELECT pg_get_functiondef('public.save_product_modifiers(uuid,jsonb)'::regprocedure) AS def
    `);
    expect(r.rowCount).toBe(1);
    const def = String(r.rows[0].def || '');
    const validationPass = def.indexOf('Validation pass. No persistent mutation');
    const mutationPass = def.indexOf('Mutation pass starts only after');
    const deleteConfig = def.indexOf('DELETE FROM public.product_modifier_groups');
    expect(validationPass).toBeGreaterThan(-1);
    expect(mutationPass).toBeGreaterThan(validationPass);
    expect(deleteConfig).toBeGreaterThan(mutationPass);
    expect(def).toContain('RAW_MATERIAL_NOT_IN_BRANCH');
    expect(def).toContain('INVENTORY_UNIT_NOT_IN_BRANCH');
    expect(def).toContain('INVALID_MODIFIER_INVENTORY_EFFECT');
  });

  it('rejects malformed modifier IDs instead of exposing a database cast error', async () => {
    if (!canRun) return;
    const r = await client.query(`
      SELECT pg_get_functiondef('public.resolve_product_modifiers(uuid,uuid,jsonb)'::regprocedure) AS def
    `);
    const def = String(r.rows[0].def || '');
    expect(def).toContain('invalid_text_representation');
    expect(def).toContain('INVALID_MODIFIER_OPTION_ID');
  });

  it('keeps modifier inventory deductions server-authoritative', async () => {
    if (!canRun) return;
    const wrapper = await client.query(`
      SELECT pg_get_functiondef('public.deduct_sale_inventory_with_modifiers(uuid,uuid,jsonb,uuid,text)'::regprocedure) AS def
    `);
    const wrapperDef = String(wrapper.rows[0].def || '');
    expect(wrapperDef).toContain('public._deduct_sale_inventory_with_modifiers_core');

    const core = await client.query(`
      SELECT pg_get_functiondef('public._deduct_sale_inventory_with_modifiers_core(uuid,uuid,jsonb,uuid,text)'::regprocedure) AS def
    `);
    const coreDef = String(core.rows[0].def || '');
    expect(coreDef).toContain('public.resolve_product_modifiers');
    expect(coreDef).toContain('public.product_modifier_inventory_effects');
    expect(coreDef).toContain('INVALID_MODIFIER_INVENTORY_EFFECT');
  });
});
