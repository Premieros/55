#!/usr/bin/env node
// ============================================================================
// Production schema-parity gate.
//
// RPC/table routes are checked through PostgREST with the anon key. A 401/403
// can still prove that an exact route exists. Structural DB requirements are
// verified through a narrow, data-free schema sentinel RPC instead of guessing
// from table SELECT permissions/RLS.
// ============================================================================

import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = resolve(fileURLToPath(import.meta.url), '..');
const ROOT = resolve(__dirname, '..', '..');

const SUPABASE_URL = process.env.VITE_SUPABASE_URL;
const ANON_KEY = process.env.VITE_SUPABASE_ANON_KEY;
const SCHEMA_SENTINEL_RPC = '_production_schema_contract_kitchen_v1';

if (!SUPABASE_URL || !ANON_KEY) {
  console.error('ERROR: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set (as in the build job).');
  process.exit(1);
}

function loadContract() {
  const file = join(ROOT, 'supabase', 'api-contract.json');
  try {
    const c = JSON.parse(readFileSync(file, 'utf8'));
    const rpcs = new Map(c.rpcs.map(({ name, params }) => [name, params]));
    return { rpcs, tables: c.tables };
  } catch (err) {
    console.error(`ERROR: cannot read ${file} (${err.message}). Run \`node scripts/db/gen-contract.js\` first.`);
    process.exit(1);
  }
}

async function readResponse(res) {
  const text = await res.text();
  let code = '';
  let json = null;
  try {
    json = JSON.parse(text);
    code = json?.code || '';
  } catch {
    // Non-JSON responses are classified by HTTP status below.
  }
  return { text, code, json };
}

async function probeRpc(name, params, headers) {
  const body = Object.fromEntries(params.map((p) => [`p_${p}`, null]));
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const { text, code } = await readResponse(res);

  if (res.status === 404 && (code === 'PGRST202' || text.includes('PGRST202'))) return 'missing';
  if (res.ok || res.status === 400 || res.status === 401 || res.status === 403 || res.status >= 500) return 'present';
  return 'unverifiable';
}

async function probeTable(name, headers) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${name}?select=id&limit=1`, {
    method: 'GET',
    headers,
  });
  const { text, code } = await readResponse(res);

  if (res.status === 404 && (code === 'PGRST205' || text.includes('PGRST205'))) return 'missing';
  // 400 can mean the table exists but does not expose an `id` column. The
  // exact PostgREST table route has still resolved, so it proves presence.
  if (res.ok || res.status === 400 || res.status === 401 || res.status === 403) return 'present';
  return 'unverifiable';
}

async function probeSchemaSentinel(headers) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${SCHEMA_SENTINEL_RPC}`, {
    method: 'POST',
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: '{}',
  });
  const { text, code, json } = await readResponse(res);

  if (res.status === 404 && (code === 'PGRST202' || text.includes('PGRST202'))) return 'missing';
  if (!res.ok) return 'unverifiable';
  return json === true ? 'present' : 'missing';
}

async function main() {
  const headers = { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` };
  const { rpcs, tables } = loadContract();

  console.log(`PRODUCTION PARITY CHECK  ${SUPABASE_URL}`);
  console.log(`RPC functions to verify : ${rpcs.size}`);
  console.log(`Tables to verify       : ${tables.length}`);
  console.log(`Schema sentinel        : ${SCHEMA_SENTINEL_RPC}`);
  console.log('');

  const missingRpc = [];
  const missingTables = [];
  const unverifiable = [];

  for (const [name, params] of rpcs) {
    const status = await probeRpc(name, params, headers);
    const signature = `${name}(${params.map((p) => `p_${p}`).join(', ')})`;
    if (status === 'missing') missingRpc.push(signature);
    if (status === 'unverifiable') unverifiable.push(`rpc ${signature}`);
    process.stdout.write(`  ${status === 'present' ? 'ok ' : status === 'missing' ? 'FAIL' : '????'} rpc ${name}\n`);
  }

  for (const name of tables) {
    const status = await probeTable(name, headers);
    if (status === 'missing') missingTables.push(name);
    if (status === 'unverifiable') unverifiable.push(`table ${name}`);
    process.stdout.write(`  ${status === 'present' ? 'ok ' : status === 'missing' ? 'FAIL' : '????'} table ${name}\n`);
  }

  const schemaStatus = await probeSchemaSentinel(headers);
  if (schemaStatus === 'unverifiable') unverifiable.push(`schema sentinel ${SCHEMA_SENTINEL_RPC}`);
  process.stdout.write(`  ${schemaStatus === 'present' ? 'ok ' : schemaStatus === 'missing' ? 'FAIL' : '????'} schema kitchen_inventory_v1\n`);

  console.log('');
  if (missingRpc.length === 0 && missingTables.length === 0 && schemaStatus === 'present' && unverifiable.length === 0) {
    console.log('PARITY OK: frontend API routes and the required Production schema sentinel are verified.');
    process.exit(0);
  }

  console.error('PARITY FAILED: production schema is missing required objects or could not be verified.');
  console.error('Do NOT publish until the database contract is verified.');
  if (missingRpc.length) {
    console.error(`\nMissing RPC functions (${missingRpc.length}):`);
    missingRpc.forEach((f) => console.error(`  - ${f}`));
  }
  if (missingTables.length) {
    console.error(`\nMissing tables (${missingTables.length}):`);
    missingTables.forEach((t) => console.error(`  - ${t}`));
  }
  if (schemaStatus === 'missing') {
    console.error(`\nMissing/failed schema contract: ${SCHEMA_SENTINEL_RPC}`);
  }
  if (unverifiable.length) {
    console.error(`\nUnverifiable schema probes (${unverifiable.length}):`);
    unverifiable.forEach((item) => console.error(`  - ${item}`));
  }
  process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
