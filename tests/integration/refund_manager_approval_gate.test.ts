import { describe, it, expect, beforeAll, afterAll } from 'vitest';
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

describe('refund manager approval gate', () => {
  it('canonical refund wrapper delegates to a core that preserves approval and original payment semantics', async () => {
    if (!canRun) return;
    const r = await client.query(`
      SELECT
        pg_get_functiondef('public.process_refund(uuid,jsonb,text)'::regprocedure) AS wrapper_def,
        pg_get_functiondef('public._process_refund_single_core(uuid,jsonb,text)'::regprocedure) AS core_def
    `);
    expect(r.rowCount).toBe(1);
    const wrapperDef = String(r.rows[0].wrapper_def || '');
    const coreDef = String(r.rows[0].core_def || '');
    expect(wrapperDef).toContain('_process_refund_single_core');
    expect(coreDef).toContain("action_type = 'refund'");
    expect(coreDef).toContain("entity_type = 'sale'");
    expect(coreDef).toContain('requester_id = auth.uid()');
    expect(coreDef).toContain('APPROVAL_REQUIRED');
    expect(coreDef).toContain('FOR UPDATE SKIP LOCKED');
    expect(coreDef).toContain("status = 'consumed'");
    expect(coreDef).toContain('REFUND_APPROVAL_CONSUME_FAILED');
    expect(coreDef).toContain('payment_method');
    expect(coreDef).toContain("COALESCE(v_sale.payment_method, 'cash')");
  });

  it('approval_requests schema accepts refund and exposes the canonical requester/entity columns', async () => {
    if (!canRun) return;
    const constraintRows = await client.query(`
      SELECT pg_get_constraintdef(c.oid) AS def
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = 'public'
        AND t.relname = 'approval_requests'
        AND c.contype = 'c'
    `);
    const defs = constraintRows.rows.map((row) => String(row.def || '')).join('\n');
    expect(defs).toContain('refund');

    const columnRows = await client.query(`
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'approval_requests'
        AND column_name IN ('requester_id','entity_type','entity_id')
    `);
    expect(columnRows.rows.map((row) => row.column_name).sort()).toEqual(['entity_id','entity_type','requester_id']);
  });
});
