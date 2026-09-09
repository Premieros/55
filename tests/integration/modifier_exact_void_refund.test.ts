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

describe('modifier exact-line lifecycle contracts', () => {
  it('targets kitchen void by order_item_id and restores its exact inventory effects', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT pg_get_functiondef(
        'public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)'::regprocedure
      ) AS def
    `);
    const def = String(result.rows[0].def);
    expect(def).toContain('oi.id = p_order_item_id');
    expect(def).toContain("s.order_item_id = oi.id");
    expect(def).toContain('_restore_kitchen_inventory_for_void');
    expect(def).toContain("'inventory_changed'");
    expect(def).toContain('consume_manager_approval');
    expect(def).not.toContain('inventory_batches');
    expect(def).not.toContain('inventory_unit_batches');
  });

  it('makes exact-line void available to authenticated clients without exposing internal helpers', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        has_function_privilege('authenticated', 'public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)', 'EXECUTE') AS exact_exec,
        has_function_privilege('anon', 'public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)', 'EXECUTE') AS anon_exec,
        has_function_privilege('authenticated', 'public.guard_sent_order_item_mutation()', 'EXECUTE') AS guard_exec
    `);
    expect(result.rows[0]).toMatchObject({ exact_exec: true, anon_exec: false, guard_exec: false });
  });

  it('persists inventory effects per sale item so identical products remain disambiguated', async () => {
    if (!canRun) return;
    const columns = await client.query(`
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'sale_item_inventory_effects'
    `);
    const names = new Set(columns.rows.map((r) => r.column_name));
    for (const required of ['sale_item_id', 'sale_id', 'target_type', 'target_id', 'quantity']) {
      expect(names.has(required)).toBe(true);
    }

    const constraints = await client.query(`
      SELECT pg_get_constraintdef(oid) AS def
      FROM pg_constraint
      WHERE conrelid = 'public.sale_item_inventory_effects'::regclass
    `);
    expect(constraints.rows.some((r) => String(r.def).includes('sale_item_id, target_type, target_id'))).toBe(true);
  });

  it('refund helper restores the selected sale-item snapshot proportionally', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT pg_get_functiondef(
        'public._restore_refund_hybrid_inventory(uuid,uuid,uuid,numeric,uuid,uuid,text)'::regprocedure
      ) AS def
    `);
    const def = String(result.rows[0].def);
    expect(def).toContain('WHERE sale_item_id = p_sale_item_id');
    expect(def).toContain('v_effect.quantity * p_refund_qty / v_item_qty');
    expect(def).toContain("v_effect.target_type = 'inventory_unit'");
    expect(def).toContain("v_effect.target_type = 'raw_material'");
    expect(def).toContain("v_effect.target_type = 'product'");
  });

  it('canonical process_refund delegates to the preserved exact-line core', async () => {
    if (!canRun) return;
    const result = await client.query(`
      SELECT
        pg_get_functiondef('public.process_refund(uuid,jsonb,text)'::regprocedure) AS wrapper_def,
        pg_get_functiondef('public._process_refund_single_core(uuid,jsonb,text)'::regprocedure) AS core_def
    `);
    const wrapperDef = String(result.rows[0].wrapper_def);
    const coreDef = String(result.rows[0].core_def);
    expect(wrapperDef).toContain('_process_refund_single_core');
    expect(coreDef).toContain('_restore_refund_hybrid_inventory');
    expect(coreDef).toContain('v_item.id');
  });
});
