import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

describe('shift closing report contract', () => {
  const source = fs.readFileSync(
    path.resolve(process.cwd(), 'src/features/trade/services/shiftClosingReport.ts'),
    'utf8',
  );

  it('links shift sales through shift_operations rather than a nonexistent sales.shift_id', () => {
    expect(source).toContain(".from('shift_operations')");
    expect(source).toContain("op.operation_type === 'sale'");
    expect(source).toContain("op.reference_type === 'sale'");
    expect(source).toContain(".in('id', saleIds)");
    expect(source).not.toContain(".from('sales')\n    .select('*, sale_items(*, product:products(*))')\n    .eq('shift_id', shiftId)");
  });

  it('fails visibly when shift operations or referenced sales cannot be read', () => {
    expect(source).toContain('if (operationsErr)');
    expect(source).toContain('if (salesErr)');
  });
});
