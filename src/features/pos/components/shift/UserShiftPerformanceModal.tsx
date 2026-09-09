import { useState, useEffect, useMemo } from 'react';
import { 
  X, User, Tag, RotateCcw, 
  CreditCard, Banknote, 
  Clock, CheckCircle2, Printer, RefreshCw 
} from 'lucide-react';
import { Button } from '@/components/Button';
import { useLanguage } from '@/context/LanguageContext';
import { useAuth } from '@/context/AuthContext';
import { supabase } from '@/api';
import { formatCurrency, formatDateTime, escapeHtml } from '@/lib/format';

interface UserShiftPerformanceModalProps {
  isOpen: boolean;
  onClose: () => void;
  branchId: string;
  shiftId?: string | null;
  currency?: string;
}

interface PersonalSaleItem {
  id: string;
  invoiceNumber: string;
  createdAt: string;
  orderType: string;
  subtotal: number;
  discountAmount: number;
  taxAmount: number;
  total: number;
  paymentMethod: string;
  status: string;
}

interface PersonalPendingOrder {
  id: string;
  orderNumber: string;
  tableName?: string;
  orderType: string;
  status: string;
  createdAt: string;
  total: number;
  discountAmount: number;
  itemsCount: number;
}

export function UserShiftPerformanceModal({
  isOpen,
  onClose,
  branchId,
  shiftId,
  currency = 'EGP',
}: UserShiftPerformanceModalProps) {
  const { lang } = useLanguage();
  const { user } = useAuth();
  const isAr = lang === 'ar';

  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<'after_payment' | 'before_payment' | 'discounts_refunds'>('after_payment');
  
  const [completedSales, setCompletedSales] = useState<PersonalSaleItem[]>([]);
  const [pendingOrders, setPendingOrders] = useState<PersonalPendingOrder[]>([]);

  useEffect(() => {
    if (!isOpen || !user?.id) return;

    let mounted = true;
    setLoading(true);

    const fetchData = async () => {
      try {
        // 1. Fetch completed sales where this user is cashier or salesperson
        let salesQuery = supabase
          .from('sales')
          .select('id, invoice_number, created_at, order_type, subtotal, discount_amount, tax_amount, total, payment_method, status, cashier_id, salesperson_id')
          .or(`cashier_id.eq.${user.id},salesperson_id.eq.${user.id}`);

        if (shiftId) {
          salesQuery = salesQuery.eq('shift_id', shiftId);
        } else if (branchId) {
          salesQuery = salesQuery.eq('branch_id', branchId);
        }

        const { data: salesData, error: salesErr } = await salesQuery.order('created_at', { ascending: false });
        if (salesErr) throw salesErr;

        // 2. Fetch pending / active orders before payment created or handled by this user
        let ordersQuery = supabase
          .from('orders')
          .select('id, order_number, table_id, order_type, status, created_at, total, discount_amount, order_items(id), tables(name)')
          .neq('status', 'paid')
          .neq('status', 'completed')
          .neq('status', 'cancelled');

        if (branchId) {
          ordersQuery = ordersQuery.eq('branch_id', branchId);
        }

        const { data: ordersData, error: ordersErr } = await ordersQuery.order('created_at', { ascending: false });
        if (ordersErr) throw ordersErr;

        if (!mounted) return;

        interface RawSaleRecord {
          id: string;
          invoice_number?: string;
          created_at: string;
          order_type?: string;
          subtotal?: number;
          discount_amount?: number;
          tax_amount?: number;
          total?: number;
          payment_method?: string;
          status?: string;
        }

        interface RawOrderRecord {
          id: string;
          order_number?: string;
          order_type?: string;
          status: string;
          created_at: string;
          total?: number;
          discount_amount?: number;
          order_items?: unknown[];
          tables?: { name?: string };
        }

        const mappedSales: PersonalSaleItem[] = (salesData as unknown as RawSaleRecord[] || []).map((s) => ({
          id: s.id,
          invoiceNumber: s.invoice_number || `#${s.id.slice(0, 6)}`,
          createdAt: s.created_at,
          orderType: s.order_type || 'takeaway',
          subtotal: Number(s.subtotal || s.total || 0),
          discountAmount: Number(s.discount_amount || 0),
          taxAmount: Number(s.tax_amount || 0),
          total: Number(s.total || 0),
          paymentMethod: s.payment_method || 'cash',
          status: s.status || 'completed',
        }));

        const mappedOrders: PersonalPendingOrder[] = (ordersData as unknown as RawOrderRecord[] || []).map((o) => ({
          id: o.id,
          orderNumber: o.order_number || `#${o.id.slice(0, 6)}`,
          tableName: o.tables?.name || (o.order_type === 'dine_in' ? 'طاولة' : undefined),
          orderType: o.order_type || 'dine_in',
          status: o.status,
          createdAt: o.created_at,
          total: Number(o.total || 0),
          discountAmount: Number(o.discount_amount || 0),
          itemsCount: Array.isArray(o.order_items) ? o.order_items.length : 0,
        }));

        setCompletedSales(mappedSales);
        setPendingOrders(mappedOrders);
      } catch (err) {
        console.error('Failed to load user shift performance:', err);
      } finally {
        if (mounted) setLoading(false);
      }
    };

    fetchData();

    return () => {
      mounted = false;
    };
  }, [isOpen, user?.id, shiftId, branchId]);

  // Aggregate Metrics
  const stats = useMemo(() => {
    let grossPaid = 0;
    let netPaid = 0;
    let discountsPaid = 0;
    let refundsTotal = 0;
    let cashPaid = 0;
    let cardPaid = 0;

    for (const s of completedSales) {
      if (s.status === 'refunded' || s.total < 0) {
        refundsTotal += Math.abs(s.total);
      } else {
        grossPaid += s.subtotal;
        netPaid += s.total;
        discountsPaid += s.discountAmount;

        if (s.paymentMethod === 'cash') {
          cashPaid += s.total;
        } else if (s.paymentMethod === 'card' || s.paymentMethod === 'visa' || s.paymentMethod === 'mada') {
          cardPaid += s.total;
        } else {
          cardPaid += s.total;
        }
      }
    }

    let pendingTotal = 0;
    let pendingDiscounts = 0;
    for (const o of pendingOrders) {
      pendingTotal += o.total;
      pendingDiscounts += o.discountAmount;
    }

    return {
      grossPaid,
      netPaid,
      discountsPaid,
      refundsTotal,
      cashPaid,
      cardPaid,
      paidCount: completedSales.length,
      pendingTotal,
      pendingDiscounts,
      pendingCount: pendingOrders.length,
    };
  }, [completedSales, pendingOrders]);

  if (!isOpen) return null;

  const handlePrintPersonalReceipt = () => {
    const html = `<!doctype html>
<html dir="${isAr ? 'rtl' : 'ltr'}" lang="${isAr ? 'ar' : 'en'}">
<head>
  <meta charset="utf-8">
  <title>${isAr ? 'تقرير مبيعات الموظف' : 'Staff Sales Report'}</title>
  <style>
    body { font-family: 'Cairo', Arial, sans-serif; font-size: 12px; margin: 0; padding: 12px; }
    .title { text-align: center; font-weight: bold; font-size: 15px; margin-bottom: 4px; }
    .subtitle { text-align: center; font-size: 11px; margin-bottom: 12px; color: #555; }
    .line { display: flex; justify-content: space-between; margin-bottom: 4px; }
    .bold { font-weight: bold; }
    .divider { border-top: 1px dashed #000; margin: 8px 0; }
    .section { font-weight: bold; margin-top: 8px; border-bottom: 1px solid #000; padding-bottom: 2px; }
  </style>
</head>
<body onload="window.print()">
  <div class="title">${isAr ? 'بيان مبيعات وأداء الموظف' : 'Staff Performance Slip'}</div>
  <div class="subtitle">${escapeHtml(user?.full_name || user?.username || user?.email || 'الموظف')}</div>
  <div class="divider"></div>
  <div class="line"><span>${isAr ? 'التاريخ والوقت:' : 'Date & Time:'}</span><span>${new Date().toLocaleString(isAr ? 'ar-EG' : 'en-US')}</span></div>
  <div class="line"><span>${isAr ? 'الوردية:' : 'Shift:'}</span><span>#${shiftId ? shiftId.slice(0, 8).toUpperCase() : 'الحالية'}</span></div>
  
  <div class="section">${isAr ? 'المبيعات بعد الدفع (المحصلة)' : 'Settled Sales'}</div>
  <div class="line"><span>${isAr ? 'عدد الفواتير:' : 'Invoices Count:'}</span><span class="bold">${stats.paidCount}</span></div>
  <div class="line"><span>${isAr ? 'إجمالي المبيعات:' : 'Gross Sales:'}</span><span>${formatCurrency(stats.grossPaid, currency, lang)}</span></div>
  <div class="line"><span>${isAr ? 'الخصومات الممنوحة:' : 'Discounts:'}</span><span style="color: red;">-${formatCurrency(stats.discountsPaid, currency, lang)}</span></div>
  <div class="line"><span>${isAr ? 'المرتجعات:' : 'Refunds:'}</span><span>-${formatCurrency(stats.refundsTotal, currency, lang)}</span></div>
  <div class="line bold" style="font-size: 13px;"><span>${isAr ? 'صافي المبيعات المحصلة:' : 'Net Collected:'}</span><span>${formatCurrency(stats.netPaid, currency, lang)}</span></div>
  
  <div class="divider"></div>
  <div class="line"><span>${isAr ? 'نقدي (كاش):' : 'Cash:'}</span><span>${formatCurrency(stats.cashPaid, currency, lang)}</span></div>
  <div class="line"><span>${isAr ? 'شبكة / بطاقة:' : 'Card / Digital:'}</span><span>${formatCurrency(stats.cardPaid, currency, lang)}</span></div>

  <div class="section">${isAr ? 'الطلبات الجارية قبل الدفع' : 'Pending Orders'}</div>
  <div class="line"><span>${isAr ? 'عدد الطلبات المفتوحة:' : 'Active Orders:'}</span><span class="bold">${stats.pendingCount}</span></div>
  <div class="line"><span>${isAr ? 'قيمة الطلبات المعلقة:' : 'Pending Total:'}</span><span>${formatCurrency(stats.pendingTotal, currency, lang)}</span></div>
  
  <div class="divider"></div>
  <div style="text-align: center; font-size: 10px; color: #777; margin-top: 10px;">
    ${isAr ? 'نظام إدارة نقاط البيع والمطاعم' : 'POS & ERP System'}
  </div>
</body>
</html>`;
    const win = window.open('', '_blank', 'width=400,height=600');
    if (win) {
      win.document.open();
      win.document.write(html);
      win.document.close();
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4 bg-black/60 backdrop-blur-sm overflow-y-auto">
      <div 
        className="relative w-full max-w-3xl bg-ui-card border border-ui-border rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[92vh] animate-in fade-in zoom-in-95 duration-200"
        dir={isAr ? 'rtl' : 'ltr'}
      >
        {/* Top Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-ui-border bg-ui-card-header/50">
          <div className="flex items-center gap-3">
            <div className="p-2.5 rounded-xl bg-brand-500/10 text-brand-600 dark:text-brand-400">
              <User className="w-5 h-5" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-base sm:text-lg font-black text-ui-text">
                  {isAr ? 'تقرير مبيعاتي بالوردية (قبل وبعد الدفع)' : 'My Shift Sales (Before & After Payment)'}
                </h3>
                <span className="px-2 py-0.5 rounded-full text-[10px] font-bold bg-brand-100 dark:bg-brand-900/40 text-brand-700 dark:text-brand-300">
                  {user?.full_name || user?.username || user?.email || (isAr ? 'المستخدم الحالي' : 'Current User')}
                </span>
              </div>
              <p className="text-xs text-ui-subtle mt-0.5">
                {isAr ? 'استعراض فوري للمبيعات المحصلة والطلبات المعلقة والخصومات والمرتجعات الخاصة بك' : 'Live overview of your paid sales, active orders, discounts, and refunds'}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={handlePrintPersonalReceipt}
              disabled={loading}
              className="flex items-center gap-1.5 text-xs font-bold"
            >
              <Printer className="w-4 h-4 text-brand-600" />
              <span>{isAr ? 'طباعة بيان' : 'Print Slip'}</span>
            </Button>
            <button
              onClick={onClose}
              className="p-2 text-ui-subtle hover:text-ui-text hover:bg-ui-surface rounded-xl transition"
              aria-label={isAr ? 'إغلاق' : 'Close'}
            >
              <X className="w-5 h-5" />
            </button>
          </div>
        </div>

        {/* 6 Key Stat Cards */}
        <div className="p-6 bg-ui-surface/40 border-b border-ui-border">
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-6 gap-3">
            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <CheckCircle2 className="w-3.5 h-3.5 text-emerald-500" />
                {isAr ? 'بعد الدفع' : 'Net Paid'}
              </span>
              <p className="text-base font-black text-emerald-600 dark:text-emerald-400">
                {formatCurrency(stats.netPaid, currency, lang)}
              </p>
              <span className="text-[10px] text-ui-subtle">{stats.paidCount} {isAr ? 'فاتورة' : 'bills'}</span>
            </div>

            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <Clock className="w-3.5 h-3.5 text-amber-500" />
                {isAr ? 'قبل الدفع' : 'Pending'}
              </span>
              <p className="text-base font-black text-amber-600 dark:text-amber-400">
                {formatCurrency(stats.pendingTotal, currency, lang)}
              </p>
              <span className="text-[10px] text-ui-subtle">{stats.pendingCount} {isAr ? 'طلب مفتوح' : 'open'}</span>
            </div>

            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <Tag className="w-3.5 h-3.5 text-red-500" />
                {isAr ? 'الخصومات' : 'Discounts'}
              </span>
              <p className="text-base font-black text-red-500">
                {stats.discountsPaid > 0 ? `-${formatCurrency(stats.discountsPaid, currency, lang)}` : '0.00'}
              </p>
              <span className="text-[10px] text-ui-subtle">{isAr ? 'تخفيضات' : 'Applied'}</span>
            </div>

            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <RotateCcw className="w-3.5 h-3.5 text-orange-500" />
                {isAr ? 'المرتجعات' : 'Refunds'}
              </span>
              <p className="text-base font-black text-orange-500">
                {stats.refundsTotal > 0 ? `-${formatCurrency(stats.refundsTotal, currency, lang)}` : '0.00'}
              </p>
              <span className="text-[10px] text-ui-subtle">{isAr ? 'مرتجع' : 'Returned'}</span>
            </div>

            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <Banknote className="w-3.5 h-3.5 text-brand-500" />
                {isAr ? 'نقدي (كاش)' : 'Cash'}
              </span>
              <p className="text-base font-black text-ui-text">
                {formatCurrency(stats.cashPaid, currency, lang)}
              </p>
              <span className="text-[10px] text-ui-subtle">{isAr ? 'بالدرج' : 'Cash'}</span>
            </div>

            <div className="p-3 rounded-xl bg-ui-card border border-ui-border space-y-1">
              <span className="text-[11px] font-bold text-ui-subtle flex items-center gap-1">
                <CreditCard className="w-3.5 h-3.5 text-blue-500" />
                {isAr ? 'شبكة / بطاقة' : 'Card'}
              </span>
              <p className="text-base font-black text-ui-text">
                {formatCurrency(stats.cardPaid, currency, lang)}
              </p>
              <span className="text-[10px] text-ui-subtle">{isAr ? 'إلكتروني' : 'Card'}</span>
            </div>
          </div>
        </div>

        {/* Tab Navigation */}
        <div className="flex items-center gap-2 px-6 pt-3 border-b border-ui-border bg-ui-surface/30">
          <button
            onClick={() => setActiveTab('after_payment')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition ${
              activeTab === 'after_payment'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <CheckCircle2 className="w-4 h-4 text-emerald-500" />
            <span>{isAr ? 'المبيعات المحصلة (بعد الدفع)' : 'Settled Invoices (After Payment)'}</span>
            <span className="px-1.5 py-0.5 rounded-full text-[10px] bg-ui-surface border border-ui-border font-bold">
              {completedSales.length}
            </span>
          </button>
          <button
            onClick={() => setActiveTab('before_payment')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition ${
              activeTab === 'before_payment'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <Clock className="w-4 h-4 text-amber-500" />
            <span>{isAr ? 'الطلبات المعلقة (قبل الدفع)' : 'Pending Orders (Before Payment)'}</span>
            <span className="px-1.5 py-0.5 rounded-full text-[10px] bg-ui-surface border border-ui-border font-bold">
              {pendingOrders.length}
            </span>
          </button>
          <button
            onClick={() => setActiveTab('discounts_refunds')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition ${
              activeTab === 'discounts_refunds'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <Tag className="w-4 h-4 text-red-500" />
            <span>{isAr ? 'الخصومات والمرتجعات' : 'Discounts & Refunds'}</span>
          </button>
        </div>

        {/* Tab Content */}
        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          {loading && (
            <div className="py-12 flex flex-col items-center justify-center gap-2 text-ui-subtle">
              <RefreshCw className="w-7 h-7 animate-spin text-brand-500" />
              <p className="text-xs font-bold">{isAr ? 'جاري تحميل مبيعاتك...' : 'Loading sales data...'}</p>
            </div>
          )}

          {!loading && activeTab === 'after_payment' && (
            <div className="space-y-3">
              {completedSales.length === 0 ? (
                <div className="py-12 text-center text-ui-subtle text-xs">
                  {isAr ? 'لم تقم بتحصيل أي فواتير بعد في هذه الوردية' : 'No settled invoices recorded for you yet in this shift'}
                </div>
              ) : (
                <div className="overflow-x-auto rounded-xl border border-ui-border">
                  <table className="w-full text-xs text-start">
                    <thead className="bg-ui-surface border-b border-ui-border text-ui-subtle font-bold">
                      <tr>
                        <th className="p-3 text-start">{isAr ? 'رقم الفاتورة' : 'Invoice #'}</th>
                        <th className="p-3 text-start">{isAr ? 'الوقت' : 'Time'}</th>
                        <th className="p-3 text-center">{isAr ? 'النوع' : 'Type'}</th>
                        <th className="p-3 text-end">{isAr ? 'المجموع' : 'Subtotal'}</th>
                        <th className="p-3 text-end">{isAr ? 'الخصم' : 'Discount'}</th>
                        <th className="p-3 text-center">{isAr ? 'الدفع' : 'Payment'}</th>
                        <th className="p-3 text-end">{isAr ? 'الصافي' : 'Net Total'}</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-ui-border">
                      {completedSales.map((s) => (
                        <tr key={s.id} className="hover:bg-ui-surface/50 transition">
                          <td className="p-3 font-bold text-ui-text">{s.invoiceNumber}</td>
                          <td className="p-3 text-ui-subtle">{formatDateTime(s.createdAt, lang)}</td>
                          <td className="p-3 text-center">
                            <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-ui-surface border border-ui-border text-ui-subtle">
                              {s.orderType}
                            </span>
                          </td>
                          <td className="p-3 text-end text-ui-text">{formatCurrency(s.subtotal, currency, lang)}</td>
                          <td className="p-3 text-end text-red-500 font-bold">
                            {s.discountAmount > 0 ? `-${formatCurrency(s.discountAmount, currency, lang)}` : '0.00'}
                          </td>
                          <td className="p-3 text-center font-bold text-ui-text">
                            {s.paymentMethod === 'cash' ? (isAr ? 'نقدي' : 'Cash') : (isAr ? 'بطاقة' : 'Card')}
                          </td>
                          <td className="p-3 text-end font-black text-emerald-600 dark:text-emerald-400">
                            {formatCurrency(s.total, currency, lang)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}

          {!loading && activeTab === 'before_payment' && (
            <div className="space-y-3">
              {pendingOrders.length === 0 ? (
                <div className="py-12 text-center text-ui-subtle text-xs">
                  {isAr ? 'لا توجد طلبات جارية معلقة حالياً' : 'No active pending orders open right now'}
                </div>
              ) : (
                <div className="overflow-x-auto rounded-xl border border-ui-border">
                  <table className="w-full text-xs text-start">
                    <thead className="bg-ui-surface border-b border-ui-border text-ui-subtle font-bold">
                      <tr>
                        <th className="p-3 text-start">{isAr ? 'رقم الطلب' : 'Order #'}</th>
                        <th className="p-3 text-start">{isAr ? 'الطاولة / النوع' : 'Table / Type'}</th>
                        <th className="p-3 text-center">{isAr ? 'الأصناف' : 'Items'}</th>
                        <th className="p-3 text-start">{isAr ? 'الوقت' : 'Time'}</th>
                        <th className="p-3 text-center">{isAr ? 'الحالة' : 'Status'}</th>
                        <th className="p-3 text-end">{isAr ? 'المبلغ المعلق' : 'Pending Amount'}</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-ui-border">
                      {pendingOrders.map((o) => (
                        <tr key={o.id} className="hover:bg-ui-surface/50 transition">
                          <td className="p-3 font-bold text-ui-text">{o.orderNumber}</td>
                          <td className="p-3 font-bold text-ui-text">
                            {o.tableName ? `${o.tableName} (${o.orderType})` : o.orderType}
                          </td>
                          <td className="p-3 text-center font-bold text-ui-subtle">{o.itemsCount}</td>
                          <td className="p-3 text-ui-subtle">{formatDateTime(o.createdAt, lang)}</td>
                          <td className="p-3 text-center">
                            <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-600 border border-amber-200 dark:border-amber-800">
                              {o.status}
                            </span>
                          </td>
                          <td className="p-3 text-end font-black text-amber-600 dark:text-amber-400">
                            {formatCurrency(o.total, currency, lang)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}

          {!loading && activeTab === 'discounts_refunds' && (
            <div className="space-y-4">
              <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-2">
                <h4 className="text-xs font-bold text-ui-text flex items-center gap-1.5">
                  <Tag className="w-4 h-4 text-red-500" />
                  {isAr ? 'ملخص الخصومات الممنوحة بالوردية' : 'Shift Discounts Overview'}
                </h4>
                <div className="flex items-center justify-between text-xs py-1">
                  <span className="text-ui-subtle">{isAr ? 'إجمالي الخصومات في الفواتير المدفوعة:' : 'Discounts in Paid Invoices:'}</span>
                  <span className="font-black text-red-500">-{formatCurrency(stats.discountsPaid, currency, lang)}</span>
                </div>
                <div className="flex items-center justify-between text-xs py-1">
                  <span className="text-ui-subtle">{isAr ? 'خصومات في طلبات جارية معلقة:' : 'Discounts in Pending Orders:'}</span>
                  <span className="font-bold text-amber-500">-{formatCurrency(stats.pendingDiscounts, currency, lang)}</span>
                </div>
              </div>

              <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-2">
                <h4 className="text-xs font-bold text-ui-text flex items-center gap-1.5">
                  <RotateCcw className="w-4 h-4 text-orange-500" />
                  {isAr ? 'ملخص المرتجعات بالوردية' : 'Shift Refunds Overview'}
                </h4>
                <div className="flex items-center justify-between text-xs py-1">
                  <span className="text-ui-subtle">{isAr ? 'إجمالي مبالغ المرتجعات:' : 'Total Refund Amount:'}</span>
                  <span className="font-black text-orange-500">-{formatCurrency(stats.refundsTotal, currency, lang)}</span>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Modal Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-ui-border bg-ui-card-header/50">
          <div className="text-xs text-ui-subtle">
            {isAr ? 'البيانات تُحدّث فورياً مع كل حركة دفع أو طلب' : 'Data synchronizes in real-time with each transaction'}
          </div>
          <Button
            type="button"
            variant="ghost"
            onClick={onClose}
            className="text-xs font-bold"
          >
            {isAr ? 'إغلاق' : 'Close'}
          </Button>
        </div>
      </div>
    </div>
  );
}
