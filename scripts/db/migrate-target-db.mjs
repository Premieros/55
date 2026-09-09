import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve, basename } from 'node:path';
import { createHash } from 'node:crypto';
import pg from 'pg';

const DB_URL = process.env.SUPABASE_DB_URL?.trim();
const PROJECT_REF = 'scpovyrqmsbiduanykod';

function sha256(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

async function run() {
  if (!DB_URL) throw new Error('SUPABASE_DB_URL is required');
  const dbUrl = new URL(DB_URL);
  if (dbUrl.hostname !== `db.${PROJECT_REF}.supabase.co`) {
    throw new Error(`SUPABASE_DB_URL must target ${PROJECT_REF}`);
  }

  console.log('Connecting to database...');
  const client = new pg.Client({
    connectionString: DB_URL.replace(/[?&]sslmode=[^&]+/g, '').replace(/\?$/, ''),
    ssl: { rejectUnauthorized: false }
  });
  await client.connect();
  console.log('Connected successfully!');

  // Step 1: Archive existing tables in public schema into legacy schema
  console.log('Archiving old public tables to legacy schema...');
  await client.query(`
    CREATE SCHEMA IF NOT EXISTS legacy;
    DO $$
    DECLARE
      r RECORD;
    BEGIN
      FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        BEGIN
          EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' SET SCHEMA legacy;';
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'Could not move %: %', r.tablename, SQLERRM;
        END;
      END LOOP;
    END $$;
  `);

  // Step 2: Drop any leftover views, sequences, or functions in public schema to allow clean rebuild
  console.log('Cleaning old routines and views from public schema...');
  await client.query(`
    DO $$
    DECLARE
      r RECORD;
    BEGIN
      FOR r IN (SELECT table_name FROM information_schema.views WHERE table_schema = 'public') LOOP
        EXECUTE 'DROP VIEW IF EXISTS public.' || quote_ident(r.table_name) || ' CASCADE;';
      END LOOP;
      FOR r IN (
        SELECT routine_name, routine_type 
        FROM information_schema.routines 
        WHERE routine_schema = 'public'
      ) LOOP
        BEGIN
          EXECUTE 'DROP ' || r.routine_type || ' IF EXISTS public.' || quote_ident(r.routine_name) || ' CASCADE;';
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END LOOP;
    END $$;
  `);

  // Step 3: Ensure extensions exist
  await client.query(`
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
  `);

  // Step 4: Create schema_migrations table
  await client.query(`
    CREATE TABLE IF NOT EXISTS public.schema_migrations (
      id bigserial PRIMARY KEY,
      version text NOT NULL UNIQUE,
      name text NOT NULL,
      checksum text NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now()
    );
  `);

  // Step 5: Read all migrations
  const migrationsDir = resolve('supabase/migrations');
  const files = readdirSync(migrationsDir)
    .filter(f => f.endsWith('.sql'))
    .sort();

  console.log(`Found ${files.length} migrations to apply.`);

  let appliedCount = 0;
  let skippedCount = 0;

  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    const version = file.replace(/\.sql$/i, '');
    const sql = readFileSync(join(migrationsDir, file), 'utf8');
    const checksum = sha256(sql);

    const existing = await client.query(
      'SELECT id FROM public.schema_migrations WHERE version = $1',
      [version]
    );
    if (existing.rowCount > 0) {
      skippedCount++;
      continue;
    }

    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query(
        'INSERT INTO public.schema_migrations (version, name, checksum) VALUES ($1, $2, $3)',
        [version, file, checksum]
      );
      await client.query('COMMIT');
      appliedCount++;
      if (appliedCount % 10 === 0 || i === files.length - 1) {
        console.log(`[${i + 1}/${files.length}] Applied ${appliedCount} migrations... (current: ${file})`);
      }
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      console.error(`\nFAILED migration: ${file}`);
      console.error('Error message:', err.message);
      console.error('Detail:', err.detail);
      console.error('Hint:', err.hint);
      console.error('Position:', err.position);
      process.exit(1);
    }
  }

  console.log(`\nMigration completed successfully! Applied: ${appliedCount}, Skipped: ${skippedCount}`);

  // Step 6: Reload PostgREST schema cache and grant permissions to anon and authenticated
  console.log('Granting schema usage and reloading PostgREST schema cache...');
  await client.query(`
    GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
    GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
    GRANT ALL ON ALL ROUTINES IN SCHEMA public TO anon, authenticated, service_role;
    GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON ROUTINES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
    NOTIFY pgrst, 'reload schema';
  `);

  await client.end();
  console.log('Done!');
}

run().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
