import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

describe('V2 routing source contract', () => {
  it('does not route production traffic into partial V2 POS or shift implementations', () => {
    const routesSource = fs.readFileSync(path.resolve(process.cwd(), 'src/app/routes.tsx'), 'utf8');

    expect(routesSource).toContain("const V2GatewayPage = lazy(");
    expect(routesSource).not.toContain("const V2PosPage = lazy(");
    expect(routesSource).not.toContain("const V2ShiftsPage = lazy(");
    expect(routesSource).toContain('<Navigate to={APP_ROUTES.pos} replace />');
    expect(routesSource).toContain('<Navigate to={APP_ROUTES.shifts} replace />');
  });

  it('supports approval-only and waste-only accounts in landing route resolution', () => {
    const routesSource = fs.readFileSync(path.resolve(process.cwd(), 'src/app/routes.tsx'), 'utf8');

    expect(routesSource).toContain("['approvals.review', APP_ROUTES.approvals]");
    expect(routesSource).toContain("['waste.view', APP_ROUTES.wasteCenter]");
  });
});
