import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const read = (path: string) => readFileSync(resolve(process.cwd(), path), 'utf8');

describe('audit action signature contract', () => {
  it('keeps user and organization audit callers on the current five-argument signature', () => {
    const source = read('supabase/migrations/20260905102945_fix_audit_action_callers.sql');

    expect(source).toContain("public.log_audit_action(\n    p_branch_id,\n    'assign_branch'");
    expect(source).toContain("public.log_audit_action(\n    p_branch_id,\n    'remove_branch'");
    expect(source).toContain("public.log_audit_action(\n    NULL::uuid,\n    'set_branch_access'");
    expect(source).toContain("public.log_audit_action(\n    NULL::uuid,\n    CASE WHEN p_is_active");
    expect(source).not.toContain('NULL, NULL, NULL');
  });
});
