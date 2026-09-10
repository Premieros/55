import * as dotenv from 'dotenv';
import { normalizeAndAssertAuraDatabaseUrl } from '../src/config/databaseIdentity';

dotenv.config();

const rawDatabaseUrl = process.env.DATABASE_URL;
if (!rawDatabaseUrl) {
  console.error('❌ DATABASE_URL not set');
  process.exit(1);
}

try {
  process.env.DATABASE_URL = normalizeAndAssertAuraDatabaseUrl(rawDatabaseUrl);
  console.log('✅ AuraOS database identity lock passed.');
  void import('./migrate');
} catch (error) {
  console.error('❌ AuraOS database identity lock failed:', error instanceof Error ? error.message : error);
  process.exit(1);
}
