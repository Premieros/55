import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const read = (path: string) => readFileSync(resolve(process.cwd(), path), 'utf8');

describe('printed document branch identity', () => {
  it('prints the actual POS branch on every receipt', () => {
    const printing = read('src/features/pos/utils/printing.ts');
    const posOrder = read('src/features/pos/hooks/usePosOrder.ts');
    const workspace = read('src/features/pos/pages/PosWorkspacePage.tsx');

    expect(printing).toContain('branchName: string');
    expect(printing).toContain("${isAr ? 'الفرع' : 'Branch'}: ${escapeHtml(receipt.branchName)}");
    expect(posOrder).toContain('branchName,');
    expect(workspace).toContain('branchName: currentBranchName');
  });

  it('keeps a completed sale successful while a reprint approval is pending', () => {
    const posOrder = read('src/features/pos/hooks/usePosOrder.ts');
    expect(posOrder).toContain("error.code === 'REPRINT_APPROVAL_PENDING'");
    expect(posOrder).toContain('showReceiptPrintError(error)');

    const saleSuccess = posOrder.indexOf("show(t('saleCompleted'), 'success')");
    const autoPrint = posOrder.indexOf('if (effSettings?.receipt_auto_print)');
    const returnSuccess = posOrder.indexOf('return true;', autoPrint);
    expect(saleSuccess).toBeGreaterThan(-1);
    expect(autoPrint).toBeGreaterThan(saleSuccess);
    expect(returnSuccess).toBeGreaterThan(autoPrint);

    const autoPrintBlock = posOrder.slice(autoPrint, returnSuccess);
    expect(autoPrintBlock).toContain('try {');
    expect(autoPrintBlock).toContain('catch (error)');
    expect(autoPrintBlock).toContain('showReceiptPrintError(error)');
  });

  it('keeps shift closing documents branch-labelled', () => {
    const shiftReport = read('src/features/trade/services/shiftClosingReport.ts');
    expect(shiftReport).toContain('branchName: string');
    expect(shiftReport).toContain('escapeHtml(summary.branchName)');
  });
});
