import type { Language, Settings } from '@/lib/types';
import { formatCurrency, escapeHtml } from '@/lib/format';
import { generateQRCodeDataURL } from '@/lib/barcode';
import { supabase } from '@/api';

export interface ReceiptData {
  invoice: string;
  branchName: string;
  items: { name: string; qty: number; price: number; total: number }[];
  subtotal: number;
  discount: number;
  tax: number;
  total: number;
  paid: number;
  change: number;
  date: string;
  customerName: string;
  orderNumber?: string;
  tableName?: string;
  orderTypeLabel?: string;
  guestCount?: number | null;
}

type PrintAuthorizationResult = {
  success?: boolean;
  error?: string;
  action?: string;
  print_number?: number;
  is_reprint?: boolean;
};

type ApprovalRow = {
  id: string;
  status: 'pending' | 'approved' | 'rejected' | 'expired' | 'consumed';
  expires_at: string;
};

export class ReceiptPrintApprovalError extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'ReceiptPrintApprovalError';
    this.code = code;
  }
}

export async function checkSalePrintCount(invoice: string): Promise<{ count: number; saleId: string | null }> {
  const inv = invoice?.trim();
  if (!inv) return { count: 0, saleId: null };
  try {
    const { data: sale } = await supabase
      .from('sales')
      .select('id')
      .eq('invoice_number', inv)
      .maybeSingle();

    if (!sale?.id) return { count: 0, saleId: null };

    const { count } = await supabase
      .from('sale_print_events')
      .select('id', { count: 'exact', head: true })
      .eq('sale_id', sale.id);

    return { count: count ?? 0, saleId: sale.id };
  } catch {
    return { count: 0, saleId: null };
  }
}

/**
 * Authorize every official receipt print.
 *
 * Strict Single-Print Policy:
 * - First print (print_number = 1) proceeds immediately upon sale completion.
 * - Any subsequent print of the same sale (print_number > 1) STRICTLY REQUIRES
 *   prior manager approval. A request is created in approval_requests and once approved,
 *   it can be printed exactly once with an AUTHORIZED REPRINT watermark!
 */
async function authorizeReceiptPrint(receipt: ReceiptData): Promise<{ isReprint: boolean; printNumber: number }> {
  const invoice = receipt.invoice?.trim();
  if (!invoice) {
    throw new ReceiptPrintApprovalError('INVALID_INVOICE', 'Receipt invoice number is required');
  }

  const { data: sale, error: saleError } = await supabase
    .from('sales')
    .select('id')
    .eq('invoice_number', invoice)
    .maybeSingle();

  if (saleError) throw saleError;
  if (!sale?.id) {
    throw new ReceiptPrintApprovalError('SALE_NOT_FOUND', 'Sale was not found for receipt printing');
  }

  // Check how many times this sale has been printed before
  const { count: priorCount, error: countError } = await supabase
    .from('sale_print_events')
    .select('id', { count: 'exact', head: true })
    .eq('sale_id', sale.id);

  if (countError) throw countError;
  const isReprint = (priorCount ?? 0) > 0;

  const tryAuthorize = async (approvalRequestId: string | null) => {
    const { data, error } = await supabase.rpc('authorize_sale_print', {
      p_sale_id: sale.id,
      p_approval_request_id: approvalRequestId,
    });
    if (error) throw error;
    return (data ?? {}) as PrintAuthorizationResult;
  };

  // If this is a reprint (already printed once), STRICTLY require manager approval:
  if (isReprint) {
    const nowIso = new Date().toISOString();
    const { data: existing, error: existingError } = await supabase
      .from('approval_requests')
      .select('id,status,expires_at')
      .eq('action_type', 'reprint')
      .eq('entity_type', 'sale')
      .eq('entity_id', sale.id)
      .in('status', ['pending', 'approved'])
      .gt('expires_at', nowIso)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existingError) throw existingError;
    const request = existing as ApprovalRow | null;

    if (request?.status === 'approved') {
      const authorized = await tryAuthorize(request.id);
      if (authorized.success) {
        return { isReprint: true, printNumber: (priorCount ?? 1) + 1 };
      }
      throw new ReceiptPrintApprovalError(authorized.error || 'INVALID_APPROVAL', authorized.error || 'Reprint approval is invalid');
    }

    if (request?.status === 'pending') {
      throw new ReceiptPrintApprovalError(
        'REPRINT_APPROVAL_PENDING',
        'تم إرسال طلب إعادة الطباعة للمدير وهو قيد المراجعة حالياً. بعد الموافقة اضغط طباعة مرة أخرى.',
      );
    }

    // Create approval request for manager
    const { data: created, error: createError } = await supabase.rpc('request_manager_approval', {
      p_action_type: 'reprint',
      p_entity_type: 'sale',
      p_entity_id: sale.id,
      p_payload: {
        invoice_number: invoice,
        total: receipt.total,
        prior_print_count: priorCount ?? 1,
      },
      p_reason: `طلب إعادة طباعة فاتورة (${invoice}) للمرة ${(priorCount ?? 1) + 1}`,
    });

    if (createError) throw createError;
    const createdResult = (created ?? {}) as { success?: boolean; error?: string };
    if (!createdResult.success) {
      throw new ReceiptPrintApprovalError(
        createdResult.error || 'APPROVAL_REQUEST_FAILED',
        createdResult.error || 'تعذر إرسال طلب موافقة إعادة الطباعة للمدير',
      );
    }

    throw new ReceiptPrintApprovalError(
      'REPRINT_APPROVAL_PENDING',
      'هذا الإيصال تمت طباعته مسبقاً! تم إرسال طلب موافقة للمدير للسماح بإعادة الطباعة.',
    );
  }

  // First print attempt
  const initial = await tryAuthorize(null);
  if (initial.success) {
    return { isReprint: false, printNumber: 1 };
  }

  if (initial.error === 'MANAGER_APPROVAL_REQUIRED') {
    throw new ReceiptPrintApprovalError('REPRINT_APPROVAL_PENDING', 'مطلوب موافقة المدير لإتمام عملية الطباعة');
  }

  throw new ReceiptPrintApprovalError(initial.error || 'PRINT_NOT_AUTHORIZED', initial.error || 'Receipt print is not authorized');
}

export function openPrintWindow(html: string, widthMm = 80): boolean {
  const safeWidth = Math.min(500, Math.max(380, widthMm + 80));
  const win = window.open('', '_blank', `width=${safeWidth},height=700,menubar=no,toolbar=no,location=no,status=no`);
  if (!win) return false;
  win.document.write(html);
  win.document.close();
  try {
    win.focus();
  } catch {
    // Window focus may be restricted in some browsers
  }
  return true;
}

export async function buildReceiptHtml(receipt: ReceiptData, s: Settings, lang: Language, isAr: boolean): Promise<string> {
  // The receipt HTML is only produced after the server records/authorizes the
  // print attempt. This keeps auto-print and manual printing on the same gate.
  const auth = await authorizeReceiptPrint(receipt);

  const rawWidth = Math.max(50, Math.min(100, s.receipt_width_mm || 80));
  // Standard thermal printheads: 80mm rolls have 72mm printable width; 58mm rolls have 48mm.
  const safeThermalWidth = rawWidth <= 60 ? 48 : 72;
  const copies = Math.max(1, Math.min(5, s.receipt_copies || 1));
  const showTax = s.receipt_show_tax !== false;
  const showQr = s.receipt_show_qr !== false;
  const currency = s.currency || 'EGP';

  let qrImg = '';
  if (showQr) {
    try {
      qrImg = await generateQRCodeDataURL(
        JSON.stringify({ inv: receipt.invoice, total: receipt.total, date: receipt.date })
      );
    } catch {
      qrImg = '';
    }
  }

  const single = `
    <div class="thermal-receipt">
      ${auth.isReprint ? `
        <div style="margin:2px 0 6px 0;padding:4px;background:#000;color:#fff;font-weight:900;font-size:12px;text-align:center;letter-spacing:1px;border-radius:3px;">
          *** ${isAr ? 'نسخة مكررة - مُصرّح بها' : 'AUTHORIZED REPRINT'} (#${auth.printNumber}) ***
        </div>
      ` : ''}
      ${s.logo_url ? `<div class="center logo-wrap"><img src="${escapeHtml(s.logo_url)}" alt="logo" style="max-width:${Math.min(safeThermalWidth * 1.5, 110)}px;max-height:65px;display:block;margin:0 auto 4px auto;" /></div>` : ''}
      <div class="center store-title">${escapeHtml(s.store_name)}</div>
      ${s.store_address ? `<div class="center sub-text">${escapeHtml(s.store_address)}</div>` : ''}
      ${s.store_phone ? `<div class="center sub-text">${isAr ? 'هاتف' : 'Tel'}: ${escapeHtml(s.store_phone)}</div>` : ''}
      ${s.receipt_header ? `<div class="center sub-text header-note">${escapeHtml(s.receipt_header)}</div>` : ''}
      <div class="center sub-text bold">${isAr ? 'الفرع' : 'Branch'}: ${escapeHtml(receipt.branchName)}</div>
      
      <div class="divider-solid"></div>
      
      <div class="row"><span class="lbl">${isAr ? 'رقم الفاتورة' : 'Invoice'}:</span><span class="val bold">#${escapeHtml(receipt.invoice)}</span></div>
      <div class="row"><span class="lbl">${isAr ? 'التاريخ' : 'Date'}:</span><span class="val">${new Date(receipt.date).toLocaleString(isAr ? 'ar-EG' : 'en-US')}</span></div>
      ${receipt.orderTypeLabel ? `<div class="row"><span class="lbl">${isAr ? 'النوع' : 'Type'}:</span><span class="val bold">${escapeHtml(receipt.orderTypeLabel)}</span></div>` : ''}
      ${receipt.orderNumber ? `<div class="row"><span class="lbl">${isAr ? 'رقم الطلب' : 'Order'}:</span><span class="val bold">#${escapeHtml(receipt.orderNumber)}</span></div>` : ''}
      ${receipt.tableName ? `<div class="row"><span class="lbl">${isAr ? 'طاولة' : 'Table'}:</span><span class="val bold">${escapeHtml(receipt.tableName)}</span></div>` : ''}
      ${receipt.guestCount ? `<div class="row"><span class="lbl">${isAr ? 'الضيوف' : 'Guests'}:</span><span class="val">${receipt.guestCount}</span></div>` : ''}
      ${receipt.customerName ? `<div class="row"><span class="lbl">${isAr ? 'العميل' : 'Customer'}:</span><span class="val bold">${escapeHtml(receipt.customerName)}</span></div>` : ''}
      
      <div class="divider"></div>

      <!-- Items Section -->
      <div class="items-container">
        ${receipt.items.map((i) => `
          <div class="item-block">
            <div class="item-name">${escapeHtml(i.name)}</div>
            <div class="row item-detail">
              <span class="item-calc">${i.qty} × ${formatCurrency(i.price, currency, lang)}</span>
              <span class="item-total font-black">${formatCurrency(i.total, currency, lang)}</span>
            </div>
          </div>
        `).join('')}
      </div>

      <div class="divider"></div>

      <!-- Totals Section -->
      <div class="row"><span class="lbl">${isAr ? 'المجموع الفرعي' : 'Subtotal'}:</span><span class="val">${formatCurrency(receipt.subtotal, currency, lang)}</span></div>
      ${receipt.discount > 0 ? `<div class="row"><span class="lbl">${isAr ? 'الخصم' : 'Discount'}:</span><span class="val">-${formatCurrency(receipt.discount, currency, lang)}</span></div>` : ''}
      ${showTax && receipt.tax > 0 ? `<div class="row"><span class="lbl">${isAr ? 'الضريبة' : 'Tax'} (${escapeHtml(s.tax_rate ?? 0)}%):</span><span class="val">+${formatCurrency(receipt.tax, currency, lang)}</span></div>` : ''}
      
      <div class="divider-double"></div>
      
      <div class="row total-row">
        <span class="lbl">${isAr ? 'الإجمالي النهائي' : 'TOTAL'}:</span>
        <span class="val">${formatCurrency(receipt.total, currency, lang)}</span>
      </div>
      
      <div class="divider"></div>
      
      <div class="row"><span class="lbl">${isAr ? 'المدفوع' : 'Paid'}:</span><span class="val bold">${formatCurrency(receipt.paid, currency, lang)}</span></div>
      ${receipt.change > 0 ? `<div class="row"><span class="lbl">${isAr ? 'المتبقي / الباقي' : 'Change'}:</span><span class="val bold">${formatCurrency(receipt.change, currency, lang)}</span></div>` : ''}
      
      ${qrImg ? `
        <div class="center qr-wrap" style="margin-top:6px;">
          <img src="${qrImg}" style="max-width:42mm;display:block;margin:0 auto;" alt="QR" />
        </div>
      ` : ''}
      
      <div class="divider"></div>
      ${s.receipt_footer ? `<div class="center footer-custom">${escapeHtml(s.receipt_footer)}</div>` : ''}
      <div class="center footer-thanks">${isAr ? 'شكراً لزيارتكم • نسعد بخدمتكم دائماً' : 'Thank you for your visit!'}</div>
    </div>`;

  const pages = Array.from({ length: copies }, () => `<div class="page">${single}</div>`).join('\n');
  return `<!DOCTYPE html>
    <html dir="${isAr ? 'rtl' : 'ltr'}" lang="${isAr ? 'ar' : 'en'}">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${escapeHtml(receipt.invoice)}</title>
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
        }
        .btn-print { background: #16a34a; color: #ffffff; }
        .btn-close { background: #334155; color: #ffffff; }
        .thermal-receipt {
          background: #ffffff;
          width: 100%;
          max-width: ${safeThermalWidth}mm;
          padding: 3mm 2.5mm;
          border-radius: 6px;
          border: 1px solid #cbd5e1;
          box-shadow: 0 4px 20px rgba(0,0,0,0.12);
        }
      }
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
        .thermal-receipt {
          background: #ffffff !important;
          width: 100% !important;
          max-width: ${safeThermalWidth}mm !important;
          margin: 0 auto !important;
          padding: 1.5mm 2.5mm !important;
          border: none !important;
          box-shadow: none !important;
          border-radius: 0 !important;
        }
      }
      .page { page-break-after: always; }
      .page:last-child { page-break-after: auto; }
      .center { text-align: center; }
      .bold { font-weight: 700; }
      .font-black { font-weight: 900; }
      
      .store-title {
        font-size: 15px;
        font-weight: 900;
        margin-bottom: 2px;
      }
      .sub-text {
        font-size: 10px;
        color: #111;
        margin-bottom: 2px;
      }
      .header-note {
        font-style: italic;
        margin-bottom: 4px;
      }
      .divider {
        border-top: 1px dashed #000000;
        margin: 4px 0;
        width: 100%;
      }
      .divider-solid {
        border-top: 1.5px solid #000000;
        margin: 4px 0;
        width: 100%;
      }
      .divider-double {
        border-bottom: 2.5px double #000000;
        margin: 5px 0;
        width: 100%;
      }
      .row {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        padding: 1.5px 0;
        gap: 4px;
        width: 100%;
      }
      .lbl {
        flex: 1;
        overflow: hidden;
        text-overflow: ellipsis;
        color: #000;
      }
      .val {
        font-weight: 600;
        white-space: nowrap;
        font-variant-numeric: tabular-nums;
        text-align: end;
      }
      .item-block {
        margin: 3.5px 0;
        width: 100%;
      }
      .item-name {
        font-weight: 800;
        font-size: 11.5px;
        word-break: break-word;
      }
      .item-detail {
        font-size: 10.5px;
      }
      .item-calc {
        color: #222;
      }
      .item-total {
        font-size: 11px;
      }
      .total-row {
        font-size: 14px;
        font-weight: 900;
        padding: 3px 0;
      }
      .footer-custom {
        margin-top: 6px;
        font-size: 10px;
        font-weight: 600;
      }
      .footer-thanks {
        margin-top: 3px;
        font-size: 9.5px;
        font-weight: 700;
      }
    </style></head>
    <body>
      <div class="screen-bar no-print">
        <span>🖨️ ${isAr ? 'معاينة إيصال الكاشير الحراري' : 'Cashier Receipt Preview'}</span>
        <button type="button" class="btn-print" onclick="window.print();">${isAr ? 'طباعة الآن' : 'Print Now'}</button>
        <button type="button" class="btn-close" onclick="window.close();">${isAr ? 'إغلاق' : 'Close'}</button>
      </div>
      ${pages}
      <script>
        function doPrint() {
          window.focus();
          try { window.print(); } catch (e) { console.warn(e); }
        }
        if (document.readyState === 'complete') {
          setTimeout(doPrint, 250);
        } else {
          window.addEventListener('load', function() { setTimeout(doPrint, 250); });
        }
      </script>
    </body>
    </html>`;
}

export function buildKitchenTicketHtml(params: {
  orderNumber: string | null;
  tableName: string | null;
  orderTypeLabel: string;
  guestCount: number | null;
  items: { name: string; qty: number; unit_name?: string | null }[];
  s: Settings;
  isAr: boolean;
}): string {
  const rawWidth = Math.max(50, Math.min(100, params.s.receipt_width_mm || 80));
  const safeThermalWidth = rawWidth <= 60 ? 48 : 72;
  const { orderNumber, tableName, orderTypeLabel, guestCount, items, isAr } = params;
  const now = new Date().toLocaleString(isAr ? 'ar-EG' : 'en-US');
  const rows = items
    .map(
      (i) => `
        <div class="kitchen-item">
          <div class="item-header">
            <span class="item-name">${escapeHtml(i.name)}${i.unit_name && i.unit_name !== 'piece' ? ` (${escapeHtml(i.unit_name)})` : ''}</span>
            <span class="item-qty">[ ${i.qty} ]</span>
          </div>
        </div>
      `
    )
    .join('');

  return `<!DOCTYPE html>
    <html dir="${isAr ? 'rtl' : 'ltr'}" lang="${isAr ? 'ar' : 'en'}">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${isAr ? 'تذكرة المطبخ' : 'Kitchen Ticket'}</title>
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
        font-size: 12px;
        line-height: 1.35;
        -webkit-font-smoothing: antialiased;
      }
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
        }
        .btn-print { background: #16a34a; color: #ffffff; }
        .btn-close { background: #334155; color: #ffffff; }
        .kitchen-ticket {
          background: #ffffff;
          width: 100%;
          max-width: ${safeThermalWidth}mm;
          padding: 3mm 2.5mm;
          border-radius: 6px;
          border: 1px solid #cbd5e1;
          box-shadow: 0 4px 20px rgba(0,0,0,0.12);
        }
      }
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
        .kitchen-ticket {
          background: #ffffff !important;
          width: 100% !important;
          max-width: ${safeThermalWidth}mm !important;
          margin: 0 auto !important;
          padding: 1.5mm 2.5mm !important;
          border: none !important;
          box-shadow: none !important;
          border-radius: 0 !important;
        }
      }
      .center { text-align: center; }
      .header { font-size: 16px; font-weight: 900; margin-bottom: 2px; }
      .sub-title { font-size: 13px; font-weight: 900; letter-spacing: 0.5px; margin-bottom: 4px; }
      .divider-solid { border-top: 2px solid #000000; margin: 5px 0; width: 100%; }
      .divider-dashed { border-top: 1.5px dashed #000000; margin: 4px 0; width: 100%; }
      .row { display: flex; justify-content: space-between; margin: 2px 0; font-size: 11px; }
      .bold { font-weight: 800; }
      .badge-order { font-size: 15px; font-weight: 900; }
      
      .kitchen-item {
        margin: 6px 0;
        padding-bottom: 4px;
        border-bottom: 1px dotted #666;
      }
      .kitchen-item:last-child {
        border-bottom: none;
      }
      .item-header {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 6px;
      }
      .item-name {
        font-size: 14px;
        font-weight: 900;
        flex: 1;
        word-break: break-word;
      }
      .item-qty {
        font-size: 16px;
        font-weight: 900;
        white-space: nowrap;
      }
    </style></head>
    <body>
      <div class="screen-bar no-print">
        <span>🍳 ${isAr ? 'معاينة بون المطبخ' : 'Kitchen Ticket Preview'}</span>
        <button type="button" class="btn-print" onclick="window.print();">${isAr ? 'طباعة الآن' : 'Print Now'}</button>
        <button type="button" class="btn-close" onclick="window.close();">${isAr ? 'إغلاق' : 'Close'}</button>
      </div>

      <div class="kitchen-ticket">
        <div class="center header">${escapeHtml(params.s.store_name)}</div>
        <div class="center sub-title">*** ${isAr ? 'طلب تشغيل مطبخ' : 'KITCHEN ORDER'} ***</div>
        <div class="divider-solid"></div>
        
        <div class="row"><span>${isAr ? 'التاريخ' : 'Date'}:</span><span class="bold">${now}</span></div>
        <div class="row"><span>${isAr ? 'النوع' : 'Type'}:</span><span class="bold">${escapeHtml(orderTypeLabel)}</span></div>
        ${orderNumber ? `<div class="row badge-order"><span>${isAr ? 'الطلب' : 'Order'}:</span><span>#${escapeHtml(orderNumber)}</span></div>` : ''}
        ${tableName ? `<div class="row badge-order"><span>${isAr ? 'طاولة' : 'Table'}:</span><span>${escapeHtml(tableName)}</span></div>` : ''}
        ${guestCount ? `<div class="row"><span>${isAr ? 'الضيوف' : 'Guests'}:</span><span>${guestCount}</span></div>` : ''}
        
        <div class="divider-solid"></div>
        
        <div class="items-list">${rows}</div>
        
        <div class="divider-solid"></div>
        <div class="center bold" style="font-size: 10px; margin-top: 4px;">${isAr ? 'جاهز للتحضير السريع' : 'READY TO PREPARE'}</div>
      </div>

      <script>
        function doPrint() {
          window.focus();
          try { window.print(); } catch (e) { console.warn(e); }
        }
        if (document.readyState === 'complete') {
          setTimeout(doPrint, 250);
        } else {
          window.addEventListener('load', function() { setTimeout(doPrint, 250); });
        }
      </script>
    </body>
    </html>`;
}
