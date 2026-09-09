import { describe, expect, it } from 'vitest';
import { getDbUrl, openDb } from './db';

const dbUrl = getDbUrl();
const skip = !dbUrl;

describe.skipIf(skip)('waste view RLS contract', () => {
  it('requires waste.view for authenticated waste reads', async () => {
    const client = openDb(dbUrl!);
    await client.connect();
    try {
      const { rows } = await client.query<{ policyname: string; qual: string | null }>(`
        SELECT policyname, qual
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'waste_entries'
          AND cmd = 'SELECT'
          AND 'authenticated' = ANY (roles)
        ORDER BY policyname
      `);

      expect(rows.map((row) => row.policyname)).toEqual(['waste_entries_select']);
      expect(rows[0]?.qual ?? '').toContain("can_permission('waste.view'::text)");
      expect(rows[0]?.qual ?? '').toContain('user_may_access_branch(branch_id)');
    } finally {
      await client.end();
    }
  });
});
