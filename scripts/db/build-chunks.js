import { readFileSync, writeFileSync, readdirSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const MIGRATIONS_DIR = resolve('supabase/migrations');
const CHUNKS_DIR = resolve('supabase/chunks');
const FULL_SCHEMA = resolve('supabase/full_schema.sql');

mkdirSync(CHUNKS_DIR, { recursive: true });

const files = readdirSync(MIGRATIONS_DIR)
  .filter((f) => f.endsWith('.sql'))
  .sort();

console.log(`Found ${files.length} migration files.`);

const header = `-- ============================================================================
-- PREMIER / JOHN-S POS & ERP - COMPLETE DATABASE SCHEMA & RPCS
-- Consolidated Build Script generated on ${new Date().toISOString()}
-- Contains all ${files.length} migrations in canonical order
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
`;

let fullContent = header;
const chunksCount = 5;
const chunkSize = Math.ceil(files.length / chunksCount);
const chunks = Array.from({ length: chunksCount }, () => header);

files.forEach((file, index) => {
  const filePath = join(MIGRATIONS_DIR, file);
  const sql = readFileSync(filePath, 'utf8');
  const section = `\n-- ----------------------------------------------------------------------------\n-- MIGRATION: ${file}\n-- ----------------------------------------------------------------------------\n${sql}\n`;
  fullContent += section;

  const chunkIndex = Math.min(Math.floor(index / chunkSize), chunksCount - 1);
  chunks[chunkIndex] += section;
});

writeFileSync(FULL_SCHEMA, fullContent, 'utf8');
console.log(`Wrote full schema to ${FULL_SCHEMA} (${(fullContent.length / 1024).toFixed(1)} KB)`);

const chunkNames = [
  '01_core_schema.sql',
  '02_pos_features_and_kds.sql',
  '03_inventory_and_guards.sql',
  '04_multitenant_and_orders.sql',
  '05_security_and_hardening.sql',
];

chunks.forEach((chunkSql, idx) => {
  const dest = join(CHUNKS_DIR, chunkNames[idx]);
  writeFileSync(dest, chunkSql, 'utf8');
  console.log(`Wrote chunk ${idx + 1} (${chunkNames[idx]}): ${(chunkSql.length / 1024).toFixed(1)} KB`);
});
