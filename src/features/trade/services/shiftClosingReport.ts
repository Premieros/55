import { supabase } from '@/api';
import { formatCurrency, formatDateTime, escapeHtml } from '@/lib/format';
import type { Language } from '@/lib/types';

export interface ShiftActiveUserSummary {
  userId: string;
  userName: string;
  userEmail: string;
  role?: string;
  invoicesCount: number;
  grossSales: number;
  totalDiscounts: number;
  totalRefunds: number;
  refundsCount: number;
  netSales: number;
  cashSales: number;
  cardSales: number;
  otherSales: number;
  firstActiveAt: string | null;
  lastActiveAt: string | null;
}

export interface ShiftClosingSummary {
  shiftId: string;
  branchId: string;
  branchName: string;
  cashierId: string;
  cashierName: string;
  openedAt: string;
  closedAt: string | null;
  openingAmount: number;
  expectedAmount: number;
  actualAmount: number;
  difference: number;
  notes: string | null;

  // Sales metrics
  totalInvoices: number;
  grossSales: number;
  totalDiscounts: number;
  totalRefunds: number;
  totalTaxes: number;
  netSales: number;
  avgTicket: number;

  // Active users in shift
  activeUsers: ShiftActiveUserSummary[];

  // Order types
  orderTypes: {
    type: string;
    label: string;
    count: number;
    total: number;
  }[];

  // Payment methods
  paymentMethods: {
    method: string;
    label: string;
    count: number;
    total: number;
  }[];

  // Products sold
  productsSold: {
    productId: string;
    productName: string;
    quantity: number;
    unitName: string;
    total: number;
  }[];

  // Raw materials / ingredients consumed
  ingredientsConsumed: {
    materialId: string;
    materialName: string;
    quantity: number;
    unit: string;
    estimatedCost: number;
  }[];
}

export async function fetchShiftClosingDetails(shiftId: string, branchId?: string): Promise<ShiftClosingSummary> {
  // 1. Fetch shift
  const { data: shift, error: shiftErr } = await supabase
    .from('shifts')
    .select('*')
    .eq('id', shiftId)
    .single();

  if (shiftErr || !shift) {
    throw new Error(shiftErr?.message || 'Shift not found');
  }

  const effectiveBranchId = shift.branch_id || branchId || '';

  // 2. Fetch Branch & Cashier Info
  const [branchRes, cashierRes] = await Promise.all([
    effectiveBranchId ? supabase.from('branches').select('name, name_en').eq('id', effectiveBranchId).maybeSingle() : Promise.resolve({ data: null }),
    shift.cashier_id ? supabase.from('users').select('full_name, email').eq('id', shift.cashier_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const branchName = branchRes.data?.name || branchRes.data?.name_en || 'الفرع الرئيسي';
  const cashierName = cashierRes.data?.full_name || cashierRes.data?.email || 'كاشير';

  // 3. Resolve the sales that belong to this shift through shift_operations.
  // sales intentionally has no shift_id column; shift_operations is the authoritative
  // audit link between a shift and every sale/refund recorded in that drawer.
  const { data: shiftOperations, error: operationsErr } = await supabase
    .from('shift_operations')
    .select('operation_type, amount, payment_method, reference_type, reference_id, created_by, created_at')
    .eq('shift_id', shiftId);

  if (operationsErr) {
    throw new Error(operationsErr.message || 'Could not load shift operations');
  }

  const operationsList = (shiftOperations || []) as Array<{
    operation_type: string;
    amount: number;
    payment_method?: string | null;
    reference_type?: string | null;
    reference_id?: string | null;
    created_by?: string | null;
    created_at?: string;
  }>;

  const saleIds = Array.from(new Set(
    operationsList
      .filter((op) => op.operation_type === 'sale' && op.reference_type === 'sale' && op.reference_id)
      .map((op) => op.reference_id as string),
  ));

  type ShiftSaleRow = {
    id: string;
    invoice_number: string;
    subtotal: number;
    discount_amount: number;
    tax_amount: number;
    total: number;
    payment_method: string;
    order_type: string;
    cashier_id?: string;
    created_by?: string;
    created_at?: string;
    status?: string;
    sale_items?: Array<{
      product_id: string;
      unit_name?: string;
      quantity: number;
      unit_price: number;
      total: number;
      product?: { name?: string; name_en?: string };
    }>;
  };

  let salesList: ShiftSaleRow[] = [];
  if (saleIds.length > 0) {
    const { data: sales, error: salesErr } = await supabase
      .from('sales')
      .select('*, sale_items(*, product:products(*))')
      .in('id', saleIds)
      .eq('branch_id', effectiveBranchId);

    if (salesErr) {
      throw new Error(salesErr.message || 'Could not load shift sales');
    }

    salesList = (sales || []) as ShiftSaleRow[];
  }

  // Compute sales stats
  let grossSales = 0;
  let totalDiscounts = 0;
  let totalTaxes = 0;
  let netSales = 0;

  const paymentMap = new Map<string, { count: number; total: number }>();
  const orderTypeMap = new Map<string, { count: number; total: number }>();
  const productMap = new Map<string, { name: string; quantity: number; unitName: string; total: number }>();

  for (const s of salesList) {
    grossSales += Number(s.subtotal || s.total || 0);
    totalDiscounts += Number(s.discount_amount || 0);
    totalTaxes += Number(s.tax_amount || 0);
    netSales += Number(s.total || 0);

    // Payment methods
    const pMethod = s.payment_method || 'cash';
    const currPay = paymentMap.get(pMethod) || { count: 0, total: 0 };
    currPay.count += 1;
    currPay.total += Number(s.total || 0);
    paymentMap.set(pMethod, currPay);

    // Order types
    const oType = s.order_type || 'takeaway';
    const currOT = orderTypeMap.get(oType) || { count: 0, total: 0 };
    currOT.count += 1;
    currOT.total += Number(s.total || 0);
    orderTypeMap.set(oType, currOT);

    // Sale items
    if (s.sale_items && Array.isArray(s.sale_items)) {
      for (const it of s.sale_items) {
        const pId = it.product_id || 'unknown';
        const pName = it.product?.name || it.product?.name_en || 'منتج';
        const currP = productMap.get(pId) || { name: pName, quantity: 0, unitName: it.unit_name || 'قطعة', total: 0 };
        currP.quantity += Number(it.quantity || 0);
        currP.total += Number(it.total || (it.quantity * it.unit_price) || 0);
        productMap.set(pId, currP);
      }
    }
  }

  // 4. Fetch Recipes and calculate Raw Material / Ingredients Consumption
  const ingredientsMap = new Map<string, { name: string; quantity: number; unit: string; estimatedCost: number }>();

  if (productMap.size > 0 && effectiveBranchId) {
    const productIds = Array.from(productMap.keys()).filter((id) => id !== 'unknown');
    if (productIds.length > 0) {
      const { data: recipes } = await supabase
        .from('recipes')
        .select('product_id, yield_quantity, recipe_items(raw_material_id, quantity, wastage_percent, raw_material:raw_materials(name, unit_id, default_cost, unit:units(name, name_en, symbol)))')
        .in('product_id', productIds)
        .eq('branch_id', effectiveBranchId);

      if (recipes && Array.isArray(recipes)) {
        for (const recipe of recipes) {
          const soldProd = productMap.get(recipe.product_id);
          if (!soldProd) continue;

          const yieldQty = Number(recipe.yield_quantity) || 1;
          const soldCount = soldProd.quantity;
          const multiplier = soldCount / yieldQty;

          if (recipe.recipe_items && Array.isArray(recipe.recipe_items)) {
            for (const rItem of recipe.recipe_items) {
              const raw = rItem.raw_material as { name?: string; default_cost?: number; unit?: { name?: string; symbol?: string } } | null;
              const matId = rItem.raw_material_id;
              const matName = raw?.name || 'مادة خام';
              const unitStr = raw?.unit?.symbol || raw?.unit?.name || 'جرام/كجم';
              const unitCost = Number(raw?.default_cost) || 0;

              const baseQty = Number(rItem.quantity) * multiplier;
              const wastagePct = Number(rItem.wastage_percent) || 0;
              const totalConsumed = baseQty * (1 + wastagePct / 100);
              const cost = totalConsumed * unitCost;

              const currMat = ingredientsMap.get(matId) || { name: matName, quantity: 0, unit: unitStr, estimatedCost: 0 };
              currMat.quantity += totalConsumed;
              currMat.estimatedCost += cost;
              ingredientsMap.set(matId, currMat);
            }
          }
        }
      }
    }
  }

  // Payment method labels map
  const methodLabelMap: Record<string, string> = {
    cash: 'نقدي (Cash)',
    card: 'بطاقة مدى / ائتمان (Card)',
    credit: 'آجل / ذمم (Credit)',
    instapay: 'إنستاباي / محفظة (InstaPay)',
    bank_transfer: 'تحويل بنكي (Bank Transfer)',
  };

  const orderTypeLabelMap: Record<string, string> = {
    dine_in: 'صالة (Dine-in)',
    takeaway: 'سفري / تيك أواي (Takeaway)',
    delivery: 'توصيل (Delivery)',
    drive_thru: 'خدمة السيارات (Drive-thru)',
  };

  // 5. Active Users Breakdown & Detailed Shift Activity
  const activeUserMap = new Map<string, {
    userId: string;
    invoicesCount: number;
    grossSales: number;
    totalDiscounts: number;
    totalRefunds: number;
    refundsCount: number;
    netSales: number;
    cashSales: number;
    cardSales: number;
    otherSales: number;
    firstActiveAt: string | null;
    lastActiveAt: string | null;
  }>();

  let shiftTotalRefunds = 0;

  for (const s of salesList) {
    const uId = s.cashier_id || s.created_by || shift.cashier_id || 'unknown';
    const entry = activeUserMap.get(uId) || {
      userId: uId,
      invoicesCount: 0,
      grossSales: 0,
      totalDiscounts: 0,
      totalRefunds: 0,
      refundsCount: 0,
      netSales: 0,
      cashSales: 0,
      cardSales: 0,
      otherSales: 0,
      firstActiveAt: s.created_at || null,
      lastActiveAt: s.created_at || null,
    };

    const sSubtotal = Number(s.subtotal || s.total || 0);
    const sDisc = Number(s.discount_amount || 0);
    const sNet = Number(s.total || 0);
    const pMethod = s.payment_method || 'cash';

    entry.invoicesCount += 1;
    entry.grossSales += sSubtotal;
    entry.totalDiscounts += sDisc;
    entry.netSales += sNet;

    if (pMethod === 'cash') {
      entry.cashSales += sNet;
    } else if (pMethod === 'card' || pMethod === 'visa' || pMethod === 'mada') {
      entry.cardSales += sNet;
    } else {
      entry.otherSales += sNet;
    }

    if (s.created_at) {
      if (!entry.firstActiveAt || s.created_at < entry.firstActiveAt) entry.firstActiveAt = s.created_at;
      if (!entry.lastActiveAt || s.created_at > entry.lastActiveAt) entry.lastActiveAt = s.created_at;
    }

    if (s.status === 'refunded' || sNet < 0) {
      entry.refundsCount += 1;
      entry.totalRefunds += Math.abs(sNet);
      shiftTotalRefunds += Math.abs(sNet);
    }

    activeUserMap.set(uId, entry);
  }

  // Reuse the same authoritative operation list for refunds so the report does
  // not issue a second, potentially divergent shift query.
  for (const op of operationsList) {
    if (op.operation_type === 'refund') {
      const opUserId = op.created_by || shift.cashier_id || 'unknown';
      const refundAmt = Math.abs(Number(op.amount || 0));
      shiftTotalRefunds += refundAmt;
      const entry = activeUserMap.get(opUserId) || {
        userId: opUserId,
        invoicesCount: 0,
        grossSales: 0,
        totalDiscounts: 0,
        totalRefunds: 0,
        refundsCount: 0,
        netSales: 0,
        cashSales: 0,
        cardSales: 0,
        otherSales: 0,
        firstActiveAt: op.created_at || null,
        lastActiveAt: op.created_at || null,
      };
      entry.totalRefunds += refundAmt;
      entry.refundsCount += 1;
      activeUserMap.set(opUserId, entry);
    }
  }

  // Ensure shift opener is tracked even if 0 sales
  if (shift.cashier_id && !activeUserMap.has(shift.cashier_id)) {
    activeUserMap.set(shift.cashier_id, {
      userId: shift.cashier_id,
      invoicesCount: 0,
      grossSales: 0,
      totalDiscounts: 0,
      totalRefunds: 0,
      refundsCount: 0,
      netSales: 0,
      cashSales: 0,
      cardSales: 0,
      otherSales: 0,
      firstActiveAt: shift.opened_at,
      lastActiveAt: shift.opened_at,
    });
  }

  // Fetch users details
  const uniqueUserIds = Array.from(activeUserMap.keys()).filter((id) => id && id !== 'unknown');
  const { data: userProfiles } = uniqueUserIds.length > 0
    ? await supabase.from('users').select('id, full_name, email, role').in('id', uniqueUserIds)
    : { data: [] };

  const userProfileMap = new Map((userProfiles || []).map((u) => [u.id, u]));

  const activeUsers: ShiftActiveUserSummary[] = Array.from(activeUserMap.values()).map((entry) => {
    const prof = userProfileMap.get(entry.userId);
    return {
      userId: entry.userId,
      userName: prof?.full_name || prof?.email || (entry.userId === shift.cashier_id ? cashierName : 'موظف'),
      userEmail: prof?.email || '',
      role: prof?.role || 'cashier',
      invoicesCount: entry.invoicesCount,
      grossSales: entry.grossSales,
      totalDiscounts: entry.totalDiscounts,
      totalRefunds: entry.totalRefunds,
      refundsCount: entry.refundsCount,
      netSales: entry.netSales,
      cashSales: entry.cashSales,
      cardSales: entry.cardSales,
      otherSales: entry.otherSales,
      firstActiveAt: entry.firstActiveAt,
      lastActiveAt: entry.lastActiveAt,
    };
  }).sort((a, b) => b.grossSales - a.grossSales);

  const totalInvoices = salesList.length;
  const avgTicket = totalInvoices > 0 ? netSales / totalInvoices : 0;

  return {
    shiftId: shift.id,
    branchId: effectiveBranchId,
    branchName,
    cashierId: shift.cashier_id,
    cashierName,
    openedAt: shift.opened_at,
    closedAt: shift.closed_at || null,
    openingAmount: Number(shift.opening_amount || 0),
    expectedAmount: Number(shift.expected_amount || shift.opening_amount || 0),
    actualAmount: Number(shift.actual_amount || 0),
    difference: Number(shift.difference || 0),
    notes: shift.notes || null,

    totalInvoices,
    grossSales,
    totalDiscounts,
    totalRefunds: shiftTotalRefunds,
    totalTaxes,
    netSales,
    avgTicket,

    activeUsers,

    orderTypes: Array.from(orderTypeMap.entries()).map(([type, data]) => ({
      type,
      label: orderTypeLabelMap[type] || type,
      count: data.count,
      total: data.total,
    })),

    paymentMethods: Array.from(paymentMap.entries()).map(([method, data]) => ({
      method,
      label: methodLabelMap[method] || method,
      count: data.count,
      total: data.total,
    })),

    productsSold: Array.from(productMap.entries()).map(([productId, data]) => ({
      productId,
      productName: data.name,
      quantity: data.quantity,
      unitName: data.unitName,
      total: data.total,
    })),

    ingredientsConsumed: Array.from(ingredientsMap.entries()).map(([materialId, data]) => ({
      materialId,
      materialName: data.name,
      quantity: parseFloat(data.quantity.toFixed(3)),
      unit: data.unit,
      estimatedCost: parseFloat(data.estimatedCost.toFixed(2)),
    })),
  };
}

/**
 * Generates an 80mm / 58mm Thermal Z-Report Receipt HTML
 */
export function buildThermalZReportHtml(summary: ShiftClosingSummary, currency = 'EGP', lang: Language = 'ar'): string {
  const isAr = lang === 'ar';
  const dir = isAr ? 'rtl' : 'ltr';

  const diffColor = Math.abs(summary.difference) > 0.01 ? '#dc2626' : '#16a34a';

  return `<!doctype html>
<html dir="${dir}" lang="${isAr ? 'ar' : 'en'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${isAr ? 'تقرير إغلاق الوردية Z-Report' : 'Shift Z-Report'}</title>
<style>
  @page {
    size: auto;
    margin: 0mm !important;
  }
  * {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    -webkit-print-color-adjust: exact;
    print-color-adjust: exact;
  }
  html, body {
    background: #f8fafc;
    color: #000000;
    font-family: 'Cairo', 'Segoe UI', Tahoma, Arial, sans-serif;
    font-size: 11px;
    line-height: 1.35;
    -webkit-font-smoothing: antialiased;
  }
  /* Screen Presentation */
  @media screen {
    body {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 16px 8px;
      min-height: 100vh;
    }
    .screen-bar {
      position: sticky;
      top: 10px;
      z-index: 100;
      background: #0f172a;
      color: #ffffff;
      padding: 8px 14px;
      border-radius: 10px;
      display: flex;
      align-items: center;
      gap: 10px;
      box-shadow: 0 4px 14px rgba(0,0,0,0.25);
      margin-bottom: 12px;
      font-size: 12px;
      font-weight: 600;
    }
    .screen-bar button {
      cursor: pointer;
      border: none;
      border-radius: 6px;
      padding: 6px 14px;
      font-weight: 700;
      font-size: 12px;
      font-family: inherit;
      transition: transform 0.1s, opacity 0.2s;
    }
    .btn-print {
      background: #16a34a;
      color: #ffffff;
    }
    .btn-close {
      background: #334155;
      color: #ffffff;
    }
    .btn-print:hover { background: #15803d; }
    .btn-close:hover { background: #475569; }
    .thermal-paper {
      background: #ffffff;
      width: 100%;
      max-width: 72mm;
      padding: 3mm 2.5mm;
      border-radius: 6px;
      border: 1px solid #cbd5e1;
      box-shadow: 0 4px 20px rgba(0,0,0,0.12);
    }
  }
  /* Thermal Printer Output */
  @media print {
    .no-print, .screen-bar {
      display: none !important;
    }
    html, body {
      background: #ffffff !important;
      padding: 0 !important;
      margin: 0 !important;
      width: 100% !important;
    }
    .thermal-paper {
      background: #ffffff !important;
      width: 100% !important;
      max-width: 72mm !important;
      margin: 0 auto !important;
      padding: 1.5mm 2.5mm !important;
      border: none !important;
      box-shadow: none !important;
      border-radius: 0 !important;
      page-break-after: avoid;
    }
  }

  .text-center { text-align: center; }
  .text-end { text-align: ${isAr ? 'left' : 'right'}; }
  .font-bold { font-weight: 700; }
  .font-black { font-weight: 900; }
  
  .divider {
    border-top: 1px dashed #000000;
    margin: 4px 0;
    width: 100%;
  }
  .divider-solid {
    border-top: 1.5px solid #000000;
    margin: 5px 0;
    width: 100%;
  }
  .divider-double {
    border-bottom: 3px double #000000;
    margin: 6px 0;
    width: 100%;
  }

  .row-line {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    padding: 2px 0;
    gap: 4px;
    width: 100%;
  }
  .row-label {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    color: #000;
  }
  .row-value {
    font-weight: 700;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
    text-align: end;
  }
  
  .section-title {
    font-size: 11px;
    font-weight: 800;
    text-align: center;
    background: #000000;
    color: #ffffff !important;
    padding: 2px 4px;
    margin: 6px 0 3px 0;
    letter-spacing: 0.5px;
  }
  
  table {
    width: 100%;
    table-layout: fixed;
    border-collapse: collapse;
    margin-top: 2px;
  }
  th, td {
    font-size: 10px;
    padding: 2px 1px;
    vertical-align: top;
    word-break: break-word;
  }
  th {
    border-bottom: 1.5px solid #000;
    font-weight: 800;
  }
  td.num, th.num {
    text-align: end;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
</style>
</head>
<body>
  <div class="screen-bar no-print">
    <span>🖨️ ${isAr ? 'معاينة تقرير إغلاق الوردية (طابعة كاشير)' : 'Z-Report Thermal Preview'}</span>
    <button type="button" class="btn-print" onclick="window.print();">${isAr ? 'طباعة الآن' : 'Print Now'}</button>
    <button type="button" class="btn-close" onclick="window.close();">${isAr ? 'إغلاق' : 'Close'}</button>
  </div>

  <div class="thermal-paper">
    <div class="text-center">
      <h2 class="font-black" style="font-size: 15px; margin-bottom: 2px;">${escapeHtml(summary.branchName)}</h2>
      <p class="font-black" style="font-size: 12px; letter-spacing: 0.5px;">*** ${isAr ? 'تقرير إغلاق الوردية Z-REPORT' : 'SHIFT Z-REPORT'} ***</p>
      <p style="font-size: 9px; font-weight: bold; margin-top: 1px;">#${summary.shiftId.slice(0, 8).toUpperCase()}</p>
    </div>

    <div class="divider"></div>

    <div class="row-line">
      <span class="row-label">${isAr ? 'الكاشير:' : 'Cashier:'}</span>
      <span class="row-value font-bold">${escapeHtml(summary.cashierName)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'تاريخ الفتح:' : 'Opened:'}</span>
      <span class="row-value" style="font-size: 10px;">${formatDateTime(summary.openedAt, lang)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'تاريخ الإغلاق:' : 'Closed:'}</span>
      <span class="row-value" style="font-size: 10px;">${summary.closedAt ? formatDateTime(summary.closedAt, lang) : (isAr ? 'مستمر' : 'Active')}</span>
    </div>

    <div class="divider-solid"></div>

    <!-- Sales Summary -->
    <div class="section-title">${isAr ? 'ملخص المبيعات' : 'SALES SUMMARY'}</div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'عدد الفواتير:' : 'Invoices Count:'}</span>
      <span class="row-value font-black">${summary.totalInvoices}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'إجمالي المبيعات:' : 'Gross Sales:'}</span>
      <span class="row-value">${formatCurrency(summary.grossSales, currency, lang)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'إجمالي الخصومات:' : 'Discounts:'}</span>
      <span class="row-value">-${formatCurrency(summary.totalDiscounts, currency, lang)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'إجمالي الضرائب:' : 'Taxes:'}</span>
      <span class="row-value">+${formatCurrency(summary.totalTaxes, currency, lang)}</span>
    </div>
    <div class="divider"></div>
    <div class="row-line font-black" style="font-size: 12.5px;">
      <span class="row-label">${isAr ? 'صافي المبيعات:' : 'Net Sales:'}</span>
      <span class="row-value">${formatCurrency(summary.netSales, currency, lang)}</span>
    </div>

    <!-- Payment Methods Breakdown -->
    <div class="section-title">${isAr ? 'طرق الدفع' : 'PAYMENT METHODS'}</div>
    ${summary.paymentMethods.map((pm) => `
      <div class="row-line">
        <span class="row-label">${escapeHtml(pm.label)} (${pm.count}):</span>
        <span class="row-value font-bold">${formatCurrency(pm.total, currency, lang)}</span>
      </div>
    `).join('')}

    <!-- Cash Drawer Balancing -->
    <div class="section-title">${isAr ? 'تسوية الدرج والنقدية' : 'CASH RECONCILIATION'}</div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'رصيد الافتتاح:' : 'Opening Cash:'}</span>
      <span class="row-value">${formatCurrency(summary.openingAmount, currency, lang)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'المتوقع بالدرج:' : 'Expected Cash:'}</span>
      <span class="row-value font-bold">${formatCurrency(summary.expectedAmount, currency, lang)}</span>
    </div>
    <div class="row-line">
      <span class="row-label">${isAr ? 'الفعلي بالدرج:' : 'Actual Counted:'}</span>
      <span class="row-value font-bold">${formatCurrency(summary.actualAmount, currency, lang)}</span>
    </div>
    <div class="divider"></div>
    <div class="row-line font-black" style="font-size: 11.5px; color: ${diffColor};">
      <span class="row-label">${isAr ? 'الفارق (عجز / زيادة):' : 'Difference:'}</span>
      <span class="row-value">${formatCurrency(summary.difference, currency, lang)}</span>
    </div>

    <!-- Active Shift Operators Breakdown -->
    ${summary.activeUsers && summary.activeUsers.length > 0 ? `
      <div class="section-title">${isAr ? 'أداء الموظفين بالوردية' : 'ACTIVE OPERATORS'}</div>
      <table>
        <thead>
          <tr>
            <th style="width: 44%; text-align: ${isAr ? 'right' : 'left'};">${isAr ? 'الموظف' : 'Staff'}</th>
            <th class="num" style="width: 18%; text-align: center;">${isAr ? 'فواتير' : 'Bills'}</th>
            <th class="num" style="width: 38%;">${isAr ? 'الصافي' : 'Net'}</th>
          </tr>
        </thead>
        <tbody>
          ${summary.activeUsers.map((u) => `
            <tr>
              <td>
                <div class="font-bold">${escapeHtml(u.userName)}</div>
                ${u.totalDiscounts > 0 ? `<div style="font-size: 8.5px; color: #dc2626;">-${formatCurrency(u.totalDiscounts, currency, lang)}</div>` : ''}
              </td>
              <td style="text-align: center;" class="font-bold">${u.invoicesCount}</td>
              <td class="num font-bold">${formatCurrency(u.netSales, currency, lang)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    ` : ''}

    <!-- Products Sold -->
    ${summary.productsSold.length > 0 ? `
      <div class="section-title">${isAr ? 'المنتجات المباعة' : 'PRODUCTS SOLD'}</div>
      <table>
        <thead>
          <tr>
            <th style="width: 50%; text-align: ${isAr ? 'right' : 'left'};">${isAr ? 'الصنف' : 'Item'}</th>
            <th class="num" style="width: 20%; text-align: center;">${isAr ? 'الكمية' : 'Qty'}</th>
            <th class="num" style="width: 30%;">${isAr ? 'الإجمالي' : 'Total'}</th>
          </tr>
        </thead>
        <tbody>
          ${summary.productsSold.map((p) => `
            <tr>
              <td>${escapeHtml(p.productName)}</td>
              <td style="text-align: center;" class="font-bold">${p.quantity}</td>
              <td class="num font-bold">${formatCurrency(p.total, currency, lang)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    ` : ''}

    <!-- Ingredients Consumed -->
    ${summary.ingredientsConsumed.length > 0 ? `
      <div class="section-title">${isAr ? 'المكونات والمواد المستهلكة' : 'INGREDIENTS CONSUMED'}</div>
      <table>
        <thead>
          <tr>
            <th style="width: 48%; text-align: ${isAr ? 'right' : 'left'};">${isAr ? 'المادة' : 'Material'}</th>
            <th class="num" style="width: 24%; text-align: center;">${isAr ? 'الكمية' : 'Qty'}</th>
            <th class="num" style="width: 28%;">${isAr ? 'التكلفة' : 'Cost'}</th>
          </tr>
        </thead>
        <tbody>
          ${summary.ingredientsConsumed.map((m) => `
            <tr>
              <td>${escapeHtml(m.materialName)}</td>
              <td style="text-align: center;" class="font-bold">${m.quantity} ${escapeHtml(m.unit)}</td>
              <td class="num">${formatCurrency(m.estimatedCost, currency, lang)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    ` : ''}

    <div class="divider-double"></div>
    <div class="text-center" style="font-size: 9.5px; font-weight: bold; margin-top: 4px;">
      <p>${isAr ? 'تم استخراج التقرير بواسطة النظام' : 'Generated by ERP System'}</p>
      <p style="direction: ltr; margin-top: 1px;">${new Date().toLocaleString(isAr ? 'ar-EG' : 'en-US')}</p>
    </div>
  </div>

  <script>
    function triggerAutoPrint() {
      window.focus();
      try {
        window.print();
      } catch (err) {
        console.warn('Print trigger warning:', err);
      }
    }
    if (document.readyState === 'complete') {
      setTimeout(triggerAutoPrint, 250);
    } else {
      window.addEventListener('load', function() {
        setTimeout(triggerAutoPrint, 250);
      });
    }
  </script>
</body>
</html>`;
}

/**
 * Generates an A4 Full Report HTML for Accounting & Management
 */
export function buildA4ZReportHtml(summary: ShiftClosingSummary, currency = 'EGP', lang: Language = 'ar'): string {
  const isAr = lang === 'ar';
  const dir = isAr ? 'rtl' : 'ltr';
  const diffColor = Math.abs(summary.difference) > 0.01 ? '#dc2626' : '#16a34a';

  return `<!doctype html>
<html dir="${dir}" lang="${isAr ? 'ar' : 'en'}">
<head>
<meta charset="utf-8">
<title>${isAr ? 'تقرير إغلاق الوردية واليوم' : 'Day & Shift Closing Report'}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Cairo", sans-serif;
    color: #1e293b;
    background: #f8fafc;
    padding: 24px;
    font-size: 13px;
    line-height: 1.5;
  }
  .container {
    max-width: 900px;
    margin: 0 auto;
    background: #fff;
    padding: 32px;
    border-radius: 16px;
    box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1);
  }
  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 2px solid #e2e8f0;
    padding-bottom: 20px;
    margin-bottom: 24px;
  }
  .header h1 { font-size: 22px; font-weight: 900; color: #0f172a; }
  .grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 24px; }
  .card {
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-radius: 12px;
    padding: 14px;
  }
  .card .label { font-size: 11px; font-weight: 700; color: #64748b; margin-bottom: 4px; }
  .card .val { font-size: 16px; font-weight: 900; color: #0f172a; }
  .section-heading {
    font-size: 15px;
    font-weight: 800;
    color: #0f172a;
    margin: 20px 0 10px 0;
    border-bottom: 1px solid #e2e8f0;
    padding-bottom: 6px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 20px;
  }
  th {
    background: #f1f5f9;
    text-align: ${isAr ? 'right' : 'left'};
    padding: 10px 12px;
    font-size: 12px;
    font-weight: 800;
    color: #475569;
    border: 1px solid #e2e8f0;
  }
  td {
    padding: 8px 12px;
    font-size: 12px;
    border: 1px solid #e2e8f0;
  }
  .text-end { text-align: ${isAr ? 'left' : 'right'}; }
  .text-center { text-align: center; }
  @media print {
    body { background: #fff; padding: 0; }
    .container { box-shadow: none; padding: 0; width: 100%; max-width: 100%; }
  }
</style>
</head>
<body onload="window.print();">
  <div class="container">
    <div class="header">
      <div>
        <h1>${escapeHtml(summary.branchName)}</h1>
        <p style="font-weight: 700; color: #64748b; margin-top: 4px;">
          ${isAr ? 'تقرير إغلاق الوردية واليوم الشامل' : 'Comprehensive Day & Shift Closing Report'} (Z-Report)
        </p>
      </div>
      <div style="text-align: ${isAr ? 'left' : 'right'}; font-size: 12px;">
        <p><strong>${isAr ? 'رقم الوردية:' : 'Shift ID:'}</strong> #${summary.shiftId.slice(0, 8).toUpperCase()}</p>
        <p><strong>${isAr ? 'الكاشير:' : 'Cashier:'}</strong> ${escapeHtml(summary.cashierName)}</p>
        <p><strong>${isAr ? 'تاريخ الفتح:' : 'Opened:'}</strong> ${formatDateTime(summary.openedAt, lang)}</p>
        <p><strong>${isAr ? 'تاريخ الإغلاق:' : 'Closed:'}</strong> ${summary.closedAt ? formatDateTime(summary.closedAt, lang) : '-'}</p>
      </div>
    </div>

    <!-- Top KPI Cards -->
    <div class="grid-4">
      <div class="card">
        <div class="label">${isAr ? 'صافي المبيعات' : 'Net Sales'}</div>
        <div class="val" style="color: #2563eb;">${formatCurrency(summary.netSales, currency, lang)}</div>
      </div>
      <div class="card">
        <div class="label">${isAr ? 'عدد الفواتير' : 'Invoices Count'}</div>
        <div class="val">${summary.totalInvoices}</div>
      </div>
      <div class="card">
        <div class="label">${isAr ? 'متوسط الفاتورة' : 'Avg Ticket'}</div>
        <div class="val">${formatCurrency(summary.avgTicket, currency, lang)}</div>
      </div>
      <div class="card">
        <div class="label">${isAr ? 'فارق الصندوق' : 'Drawer Difference'}</div>
        <div class="val" style="color: ${diffColor};">${formatCurrency(summary.difference, currency, lang)}</div>
      </div>
    </div>

    <!-- Sales & Drawer Reconciliation Tables Grid -->
    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
      <div>
        <h3 class="section-heading">${isAr ? 'ملخص الإيرادات والضرائب' : 'Revenue & Tax Summary'}</h3>
        <table>
          <tbody>
            <tr><td>${isAr ? 'إجمالي المبيعات (Gross):' : 'Gross Sales:'}</td><td class="text-end font-bold">${formatCurrency(summary.grossSales, currency, lang)}</td></tr>
            <tr><td>${isAr ? 'إجمالي الخصومات:' : 'Total Discounts:'}</td><td class="text-end font-bold" style="color: #dc2626;">-${formatCurrency(summary.totalDiscounts, currency, lang)}</td></tr>
            <tr><td>${isAr ? 'إجمالي الضرائب:' : 'Total Taxes:'}</td><td class="text-end font-bold">+${formatCurrency(summary.totalTaxes, currency, lang)}</td></tr>
            <tr style="background: #f1f5f9; font-weight: 900;"><td>${isAr ? 'صافي الإيراد (Net):' : 'Net Revenue:'}</td><td class="text-end font-bold">${formatCurrency(summary.netSales, currency, lang)}</td></tr>
          </tbody>
        </table>
      </div>

      <div>
        <h3 class="section-heading">${isAr ? 'تسوية عهدة النقدية' : 'Cash Reconciliation'}</h3>
        <table>
          <tbody>
            <tr><td>${isAr ? 'رصيد الافتتاح:' : 'Opening Cash:'}</td><td class="text-end">${formatCurrency(summary.openingAmount, currency, lang)}</td></tr>
            <tr><td>${isAr ? 'المتوقع بالدرج:' : 'Expected Cash:'}</td><td class="text-end font-bold">${formatCurrency(summary.expectedAmount, currency, lang)}</td></tr>
            <tr><td>${isAr ? 'الفعلي بالدرج (العد):' : 'Actual Counted:'}</td><td class="text-end font-bold">${formatCurrency(summary.actualAmount, currency, lang)}</td></tr>
            <tr style="background: #f8fafc; font-weight: 900; color: ${diffColor};"><td>${isAr ? 'الفارق (عجز / زيادة):' : 'Difference:'}</td><td class="text-end">${formatCurrency(summary.difference, currency, lang)}</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Payment Methods -->
    <h3 class="section-heading">${isAr ? 'تفصيل طرق الدفع المحصلة' : 'Payment Methods Breakdown'}</h3>
    <table>
      <thead>
        <tr>
          <th>${isAr ? 'طريقة الدفع' : 'Payment Method'}</th>
          <th class="text-center">${isAr ? 'عدد العمليات' : 'Transactions'}</th>
          <th class="text-end">${isAr ? 'إجمالي المبلغ' : 'Total Amount'}</th>
        </tr>
      </thead>
      <tbody>
        ${summary.paymentMethods.map((pm) => `
          <tr>
            <td style="font-weight: 700;">${escapeHtml(pm.label)}</td>
            <td class="text-center">${pm.count}</td>
            <td class="text-end font-bold">${formatCurrency(pm.total, currency, lang)}</td>
          </tr>
        `).join('')}
      </tbody>
    </table>

    <!-- Active Shift Operators & Staff Breakdown -->
    ${summary.activeUsers && summary.activeUsers.length > 0 ? `
      <h3 class="section-heading">${isAr ? 'المستخدمين النشطين في الوردية وتفاصيل مبيعاتهم' : 'Active Shift Operators & Detailed Activity'}</h3>
      <table>
        <thead>
          <tr>
            <th>${isAr ? 'الموظف / الكاشير' : 'Staff / Cashier'}</th>
            <th class="text-center">${isAr ? 'الدور' : 'Role'}</th>
            <th class="text-center">${isAr ? 'عدد الفواتير' : 'Invoices'}</th>
            <th class="text-end">${isAr ? 'إجمالي المبيعات' : 'Gross Sales'}</th>
            <th class="text-end">${isAr ? 'الخصومات' : 'Discounts'}</th>
            <th class="text-end">${isAr ? 'المرتجعات' : 'Refunds'}</th>
            <th class="text-end">${isAr ? 'نقدي' : 'Cash'}</th>
            <th class="text-end">${isAr ? 'شبكة / بطاقة' : 'Card'}</th>
            <th class="text-end">${isAr ? 'صافي المبيعات' : 'Net Sales'}</th>
          </tr>
        </thead>
        <tbody>
          ${summary.activeUsers.map((u) => `
            <tr>
              <td>
                <strong>${escapeHtml(u.userName)}</strong>
                ${u.userEmail ? `<div style="font-size: 10px; color: #64748b;">${escapeHtml(u.userEmail)}</div>` : ''}
              </td>
              <td class="text-center"><span style="font-size: 11px; padding: 2px 6px; background: #e2e8f0; border-radius: 4px;">${escapeHtml(u.role || 'cashier')}</span></td>
              <td class="text-center font-bold">${u.invoicesCount}</td>
              <td class="text-end">${formatCurrency(u.grossSales, currency, lang)}</td>
              <td class="text-end" style="color: #dc2626;">${u.totalDiscounts > 0 ? `-${formatCurrency(u.totalDiscounts, currency, lang)}` : '0.00'}</td>
              <td class="text-end" style="color: #ea580c;">${u.totalRefunds > 0 ? `-${formatCurrency(u.totalRefunds, currency, lang)}` : '0.00'}</td>
              <td class="text-end">${formatCurrency(u.cashSales, currency, lang)}</td>
              <td class="text-end">${formatCurrency(u.cardSales, currency, lang)}</td>
              <td class="text-end font-bold" style="color: #16a34a;">${formatCurrency(u.netSales, currency, lang)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    ` : ''}

    <!-- Products Sold -->
    <h3 class="section-heading">${isAr ? 'المنتجات والأصناف المباعة' : 'Products Sold Summary'}</h3>
    <table>
      <thead>
        <tr>
          <th>${isAr ? 'اسم المنتج' : 'Product Name'}</th>
          <th class="text-center">${isAr ? 'الكمية المباعة' : 'Qty Sold'}</th>
          <th class="text-end">${isAr ? 'إجمالي المبيعات' : 'Total Sales'}</th>
        </tr>
      </thead>
      <tbody>
        ${summary.productsSold.map((p) => `
          <tr>
            <td>${escapeHtml(p.productName)}</td>
            <td class="text-center font-bold">${p.quantity} ${escapeHtml(p.unitName)}</td>
            <td class="text-end font-bold">${formatCurrency(p.total, currency, lang)}</td>
          </tr>
        `).join('')}
      </tbody>
    </table>

    <!-- Ingredients Consumed -->
    ${summary.ingredientsConsumed.length > 0 ? `
      <h3 class="section-heading">${isAr ? 'المكونات والمواد الخام المستهلكة (الخصم التلقائي للوصفات)' : 'Raw Materials & Ingredients Consumed (Recipe Deductions)'}</h3>
      <table>
        <thead>
          <tr>
            <th>${isAr ? 'المادة الخام / المكون' : 'Raw Material'}</th>
            <th class="text-center">${isAr ? 'الكمية المستهلكة' : 'Consumed Qty'}</th>
            <th class="text-end">${isAr ? 'التكلفة التقديرية' : 'Estimated Cost'}</th>
          </tr>
        </thead>
        <tbody>
          ${summary.ingredientsConsumed.map((m) => `
            <tr>
              <td>${escapeHtml(m.materialName)}</td>
              <td class="text-center font-bold">${m.quantity} ${escapeHtml(m.unit)}</td>
              <td class="text-end font-bold">${formatCurrency(m.estimatedCost, currency, lang)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    ` : ''}

    ${summary.notes ? `
      <div style="margin-top: 16px; padding: 12px; background: #f8fafc; border-radius: 8px; border: 1px solid #e2e8f0;">
        <strong style="color: #475569;">${isAr ? 'ملاحظات الإغلاق:' : 'Closing Notes:'}</strong>
        <p style="margin-top: 4px;">${escapeHtml(summary.notes)}</p>
      </div>
    ` : ''}

    <div style="margin-top: 40px; display: flex; justify-content: space-between; padding-top: 20px; border-top: 1px dashed #cbd5e1; font-size: 12px; color: #64748b;">
      <div>${isAr ? 'توقيع الكاشير: _______________________' : 'Cashier Signature: _______________________'}</div>
      <div>${isAr ? 'توقيع مدير الفرع / المحاسب: _______________________' : 'Manager Signature: _______________________'}</div>
    </div>
  </div>
</body>
</html>`;
}
