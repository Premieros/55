import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { getDbUrl, openDb } from './db';
import { canImpersonate, runAs, runAsPersist, seedRlsFixture, type RlsIds } from './rls';

const dbUrl = getDbUrl();
const skip = !dbUrl;

type ActionResult = {
  success?: boolean;
  error?: string;
  action?: string;
  status?: string;
  request_id?: string;
  approval_request_id?: string;
  source_order_id?: string;
  target_order_id?: string;
  inventory_changed?: boolean;
  kds_changed?: boolean;
};

describe.skipIf(skip)('POS structural actions manager approval', () => {
  let client: pg.Client;
  let ids: RlsIds;
  let imp = false;
  let sourceOrder = '';
  let sourceItem = '';

  beforeAll(async () => {
    client = openDb(dbUrl!);
    await client.connect();
    await client.query('BEGIN');
    ids = await seedRlsFixture(client);
    imp = await canImpersonate(client);

    const product = await client.query<{ id: string }>(
      `INSERT INTO public.products(name, sale_price, cost_price, branch_id, product_type)
       VALUES ('Structural Burger', 100, 40, $1::uuid, 'ready') RETURNING id`,
      [ids.branchA],
    );

    const order = await client.query<{ id: string }>(
      `INSERT INTO public.orders(
         order_number, branch_id, order_type, status, cashier_id,
         subtotal, discount_amount, discount_type, tax_amount, total
       ) VALUES ('STRUCT-SOURCE', $1::uuid, 'takeaway', 'open', $2::uuid, 200, 0, 'amount', 0, 200)
       RETURNING id`,
      [ids.branchA, ids.users.cashier],
    );
    sourceOrder = order.rows[0].id;

    const item = await client.query<{ id: string }>(
      `INSERT INTO public.order_items(order_id, product_id, unit_name, quantity, unit_price, total)
       VALUES ($1::uuid, $2::uuid, 'piece', 2, 100, 200)
       RETURNING id`,
      [sourceOrder, product.rows[0].id],
    );
    sourceItem = item.rows[0].id;
  });

  afterAll(async () => {
    if (client) {
      await client.query('ROLLBACK').catch(() => {});
      await client.end();
    }
  });

  const guarded = (name: string, fn: () => Promise<void>) =>
    it(name, async (ctx: { skip?: () => unknown }) => {
      if (!imp) return typeof ctx.skip === 'function' ? ctx.skip() : undefined;
      await fn();
    });

  it('approval_requests accepts split, merge and transfer actions', async () => {
    const rows = await client.query(`
      SELECT pg_get_constraintdef(c.oid) AS def
      FROM pg_constraint c
      WHERE c.conrelid = 'public.approval_requests'::regclass
        AND c.contype = 'c'
    `);
    const defs = rows.rows.map((row) => String(row.def || '')).join('\n');
    expect(defs).toContain('split_order');
    expect(defs).toContain('merge_order');
    expect(defs).toContain('transfer_order');
  });

  it('keeps structural helpers private while exposing only the guarded action RPC', async () => {
    const row = await client.query(`
      SELECT
        has_function_privilege('authenticated', 'public.perform_pos_order_action(text,uuid,jsonb,text)', 'EXECUTE') AS public_exec,
        has_function_privilege('authenticated', 'public._recalc_open_order_totals(uuid)', 'EXECUTE') AS helper_exec
    `);
    expect(row.rows[0]).toMatchObject({ public_exec: true, helper_exec: false });
  });

  guarded('cashier split is inert while pending and executes once after manager approval', async () => {
    const payload = JSON.stringify({
      order_item_id: sourceItem,
      quantity: 1,
      target_kind: 'quick',
      target_table_id: null,
    });

    const beforeLedger = await client.query<{ count: string }>('SELECT count(*)::text AS count FROM public.inventory_ledger');
    const beforeSends = await client.query<{ count: string }>('SELECT count(*)::text AS count FROM public.order_kitchen_sends');

    const requested = await runAsPersist(
      client,
      ids.users.cashier,
      `SELECT public.perform_pos_order_action('split_order', $1::uuid, $2::jsonb, 'فصل حساب عميل') AS result`,
      [sourceOrder, payload],
    );
    expect(requested.error).toBeUndefined();
    const requestedResult = requested.rows[0].result as ActionResult;
    expect(requestedResult).toMatchObject({
      success: false,
      error: 'MANAGER_APPROVAL_REQUIRED',
      action: 'split_order',
      status: 'pending',
    });
    const requestId = String(requestedResult.request_id || '');
    expect(requestId).toBeTruthy();

    const stillSource = await client.query<{ quantity: string }>(
      'SELECT quantity::text AS quantity FROM public.order_items WHERE id = $1::uuid',
      [sourceItem],
    );
    expect(Number(stillSource.rows[0].quantity)).toBe(2);

    const approved = await runAsPersist(
      client,
      ids.users.branch_manager,
      'SELECT public.decide_manager_approval($1::uuid, true, $2::text) AS result',
      [requestId, 'approved'],
    );
    expect(approved.error).toBeUndefined();
    expect(approved.rows[0].result).toMatchObject({ success: true, status: 'approved' });

    const executed = await runAsPersist(
      client,
      ids.users.cashier,
      `SELECT public.perform_pos_order_action('split_order', $1::uuid, $2::jsonb, 'فصل حساب عميل') AS result`,
      [sourceOrder, payload],
    );
    expect(executed.error).toBeUndefined();
    const executedResult = executed.rows[0].result as ActionResult;
    expect(executedResult).toMatchObject({
      success: true,
      action: 'split_order',
      source_order_id: sourceOrder,
      inventory_changed: false,
      kds_changed: false,
      approval_request_id: requestId,
    });

    const targetOrderId = String(executedResult.target_order_id || '');
    expect(targetOrderId).toBeTruthy();
    expect(targetOrderId).not.toBe(sourceOrder);

    const sourceQty = await client.query<{ quantity: string }>(
      'SELECT quantity::text AS quantity FROM public.order_items WHERE id = $1::uuid',
      [sourceItem],
    );
    expect(Number(sourceQty.rows[0].quantity)).toBe(1);

    const targetQty = await client.query<{ quantity: string }>(
      'SELECT quantity::text AS quantity FROM public.order_items WHERE order_id = $1::uuid',
      [targetOrderId],
    );
    expect(targetQty.rows).toHaveLength(1);
    expect(Number(targetQty.rows[0].quantity)).toBe(1);

    const consumed = await client.query<{ status: string }>('SELECT status FROM public.approval_requests WHERE id = $1::uuid', [requestId]);
    expect(consumed.rows[0].status).toBe('consumed');

    // The consumed approval cannot authorize the same structural mutation twice.
    // Repeating the exact request must return to Pending with a fresh approval id.
    const replay = await runAsPersist(
      client,
      ids.users.cashier,
      `SELECT public.perform_pos_order_action('split_order', $1::uuid, $2::jsonb, 'فصل حساب عميل') AS result`,
      [sourceOrder, payload],
    );
    expect(replay.error).toBeUndefined();
    const replayResult = replay.rows[0].result as ActionResult;
    expect(replayResult).toMatchObject({
      success: false,
      error: 'MANAGER_APPROVAL_REQUIRED',
      action: 'split_order',
      status: 'pending',
    });
    expect(String(replayResult.request_id || '')).toBeTruthy();
    expect(String(replayResult.request_id || '')).not.toBe(requestId);

    const sourceQtyAfterReplay = await client.query<{ quantity: string }>(
      'SELECT quantity::text AS quantity FROM public.order_items WHERE id = $1::uuid',
      [sourceItem],
    );
    expect(Number(sourceQtyAfterReplay.rows[0].quantity)).toBe(1);

    const afterLedger = await client.query<{ count: string }>('SELECT count(*)::text AS count FROM public.inventory_ledger');
    const afterSends = await client.query<{ count: string }>('SELECT count(*)::text AS count FROM public.order_kitchen_sends');
    expect(afterLedger.rows[0].count).toBe(beforeLedger.rows[0].count);
    expect(afterSends.rows[0].count).toBe(beforeSends.rows[0].count);
  });

  guarded('sent kitchen lines cannot be re-parented by split', async () => {
    await client.query(
      `INSERT INTO public.order_kitchen_sends(branch_id, order_id, order_item_id, sent_by)
       VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid)`,
      [ids.branchA, sourceOrder, sourceItem, ids.users.branch_manager],
    );

    const result = await runAs(
      client,
      ids.users.branch_manager,
      `SELECT public.perform_pos_order_action(
         'split_order', $1::uuid,
         jsonb_build_object('order_item_id',$2::uuid,'quantity',1,'target_kind','quick','target_table_id',NULL),
         'manager test'
       ) AS result`,
      [sourceOrder, sourceItem],
    );
    expect(result.error).toBeUndefined();
    expect(result.rows[0].result).toMatchObject({ success: false, error: 'ITEM_ALREADY_SENT' });
  });
});
