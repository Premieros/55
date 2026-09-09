import { useState, useEffect } from 'react';
import { 
  X, Printer, FileText, Users, DollarSign, 
  ShoppingBag, AlertTriangle, 
  Clock, Calendar, User, TrendingUp, RefreshCw,
  Coins
} from 'lucide-react';
import { Button } from '@/components/Button';
import { useLanguage } from '@/context/LanguageContext';
import { formatCurrency, formatDateTime } from '@/lib/format';
import { 
  fetchShiftClosingDetails, 
  buildThermalZReportHtml, 
  buildA4ZReportHtml, 
  type ShiftClosingSummary 
} from '../services/shiftClosingReport';

interface ShiftComprehensiveCloseReportModalProps {
  shiftId: string;
  isOpen: boolean;
  onClose: () => void;
  currency?: string;
  isInitialClosing?: boolean;
  branchId?: string;
}

export function ShiftComprehensiveCloseReportModal({
  shiftId,
  isOpen,
  onClose,
  currency = 'EGP',
  isInitialClosing = false,
}: ShiftComprehensiveCloseReportModalProps) {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [summary, setSummary] = useState<ShiftClosingSummary | null>(null);
  const [activeTab, setActiveTab] = useState<'overview' | 'users' | 'products' | 'ingredients'>('overview');

  useEffect(() => {
    if (!isOpen || !shiftId) return;

    let mounted = true;
    setLoading(true);
    setError(null);

    fetchShiftClosingDetails(shiftId)
      .then((data) => {
        if (mounted) {
          setSummary(data);
          setLoading(false);
        }
      })
      .catch((err) => {
        if (mounted) {
          console.error('Error fetching shift closing details:', err);
          setError(err?.message || (isAr ? 'فشل تحميل بيانات تقرير الوردية' : 'Failed to load shift report'));
          setLoading(false);
        }
      });

    return () => {
      mounted = false;
    };
  }, [isOpen, shiftId, isAr]);

  if (!isOpen) return null;

  const handlePrintThermal = () => {
    if (!summary) return;
    const html = buildThermalZReportHtml(summary, currency, lang);
    const win = window.open('', '_blank', 'width=420,height=750,toolbar=0,menubar=0,location=0');
    if (win) {
      win.document.open();
      win.document.write(html);
      win.document.close();
    }
  };

  const handlePrintA4 = () => {
    if (!summary) return;
    const html = buildA4ZReportHtml(summary, currency, lang);
    const win = window.open('', '_blank', 'width=950,height=900,toolbar=0,menubar=0,location=0');
    if (win) {
      win.document.open();
      win.document.write(html);
      win.document.close();
    }
  };

  const diffColor = summary 
    ? Math.abs(summary.difference) > 0.01 
      ? summary.difference < 0 
        ? 'text-red-500 bg-red-50 dark:bg-red-950/40 border-red-200 dark:border-red-900/60' 
        : 'text-amber-500 bg-amber-50 dark:bg-amber-950/40 border-amber-200 dark:border-amber-900/60'
      : 'text-emerald-500 bg-emerald-50 dark:bg-emerald-950/40 border-emerald-200 dark:border-emerald-900/60'
    : '';

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4 bg-black/60 backdrop-blur-sm overflow-y-auto">
      <div 
        className="relative w-full max-w-4xl bg-ui-card border border-ui-border rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[92vh] animate-in fade-in zoom-in-95 duration-200"
        dir={isAr ? 'rtl' : 'ltr'}
      >
        {/* Top Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-ui-border bg-ui-card-header/50">
          <div className="flex items-center gap-3">
            <div className={`p-2.5 rounded-xl ${isInitialClosing ? 'bg-emerald-500/10 text-emerald-600' : 'bg-brand-500/10 text-brand-600'}`}>
              <FileText className="w-5 h-5" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-base sm:text-lg font-black text-ui-text">
                  {isInitialClosing
                    ? (isAr ? 'تم إغلاق الوردية بنجاح - التقرير الشامل (Z-Report)' : 'Shift Closed Successfully - Full Z-Report')
                    : (isAr ? 'التقرير الشامل للوردية (Z-Report)' : 'Comprehensive Shift Report (Z-Report)')}
                </h3>
                {summary?.closedAt ? (
                  <span className="px-2 py-0.5 rounded-full text-[10px] font-bold bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400 border border-zinc-200 dark:border-zinc-700">
                    {isAr ? 'مغلقة' : 'Closed'}
                  </span>
                ) : (
                  <span className="px-2 py-0.5 rounded-full text-[10px] font-bold bg-emerald-100 dark:bg-emerald-950 text-emerald-600 dark:text-emerald-400 border border-emerald-200 dark:border-emerald-800 animate-pulse">
                    {isAr ? 'وردية جارية نشطة' : 'Active Shift'}
                  </span>
                )}
              </div>
              <p className="text-xs text-ui-subtle mt-0.5">
                {summary?.branchName ? `${summary.branchName} • ` : ''}
                {isAr ? `معرف الوردية: #${shiftId.slice(0, 8).toUpperCase()}` : `Shift ID: #${shiftId.slice(0, 8).toUpperCase()}`}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={handlePrintThermal}
              disabled={loading || !summary}
              className="hidden sm:flex items-center gap-1.5 text-xs font-bold"
              title={isAr ? 'طباعة إيصال طابعة الكاشير 80 مم' : 'Print 80mm Cashier Thermal Slip'}
            >
              <Printer className="w-4 h-4 text-emerald-600" />
              <span>{isAr ? 'إيصال كاشير' : 'Thermal'}</span>
            </Button>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={handlePrintA4}
              disabled={loading || !summary}
              className="flex items-center gap-1.5 text-xs font-bold"
              title={isAr ? 'طباعة تقرير A4 مفصل رسمياً' : 'Print Official A4 Sheet'}
            >
              <FileText className="w-4 h-4 text-brand-600" />
              <span>{isAr ? 'تقرير A4' : 'A4 Report'}</span>
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

        {/* Modal Navigation Tabs */}
        <div className="flex items-center gap-2 px-6 pt-3 border-b border-ui-border bg-ui-surface/30 overflow-x-auto scrollbar-none">
          <button
            onClick={() => setActiveTab('overview')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition whitespace-nowrap ${
              activeTab === 'overview'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <DollarSign className="w-4 h-4" />
            <span>{isAr ? 'الملخص المالي وتسوية الدرج' : 'Financial & Cash'}</span>
          </button>
          <button
            onClick={() => setActiveTab('users')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition whitespace-nowrap ${
              activeTab === 'users'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <Users className="w-4 h-4" />
            <span>{isAr ? 'المستخدمين النشطين ومبيعاتهم' : 'Active Staff & Sales'}</span>
            {summary?.activeUsers && (
              <span className="px-1.5 py-0.5 rounded-full text-[10px] bg-brand-100 dark:bg-brand-900/60 text-brand-700 dark:text-brand-300">
                {summary.activeUsers.length}
              </span>
            )}
          </button>
          <button
            onClick={() => setActiveTab('products')}
            className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition whitespace-nowrap ${
              activeTab === 'products'
                ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                : 'border-transparent text-ui-subtle hover:text-ui-text'
            }`}
          >
            <ShoppingBag className="w-4 h-4" />
            <span>{isAr ? 'الأصناف المباعة' : 'Products Sold'}</span>
            {summary?.productsSold && (
              <span className="px-1.5 py-0.5 rounded-full text-[10px] bg-ui-surface border border-ui-border text-ui-subtle">
                {summary.productsSold.length}
              </span>
            )}
          </button>
          {summary?.ingredientsConsumed && summary.ingredientsConsumed.length > 0 && (
            <button
              onClick={() => setActiveTab('ingredients')}
              className={`flex items-center gap-2 px-4 py-2.5 text-xs font-bold border-b-2 transition whitespace-nowrap ${
                activeTab === 'ingredients'
                  ? 'border-brand-500 text-brand-600 dark:text-brand-400'
                  : 'border-transparent text-ui-subtle hover:text-ui-text'
              }`}
            >
              <Coins className="w-4 h-4" />
              <span>{isAr ? 'المكونات المستهلكة' : 'Ingredients'}</span>
            </button>
          )}
        </div>

        {/* Content Body */}
        <div className="flex-1 overflow-y-auto p-6 space-y-6">
          {loading && (
            <div className="py-16 flex flex-col items-center justify-center gap-3 text-ui-subtle">
              <RefreshCw className="w-8 h-8 animate-spin text-brand-500" />
              <p className="text-sm font-bold">{isAr ? 'جاري تجميع وحساب بيانات الوردية...' : 'Calculating shift figures...'}</p>
            </div>
          )}

          {error && (
            <div className="p-4 rounded-xl bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-800 text-red-600 dark:text-red-400 flex items-center gap-3 text-sm">
              <AlertTriangle className="w-5 h-5 flex-shrink-0" />
              <p>{error}</p>
            </div>
          )}

          {!loading && !error && summary && (
            <>
              {/* Opener & Operational Timestamps banner */}
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 p-3.5 rounded-xl bg-ui-surface/60 border border-ui-border text-xs">
                <div className="space-y-1">
                  <span className="text-ui-subtle flex items-center gap-1">
                    <User className="w-3.5 h-3.5" />
                    {isAr ? 'فُتحت بواسطة:' : 'Opened By:'}
                  </span>
                  <p className="font-black text-ui-text truncate">{summary.cashierName}</p>
                </div>
                <div className="space-y-1">
                  <span className="text-ui-subtle flex items-center gap-1">
                    <Clock className="w-3.5 h-3.5" />
                    {isAr ? 'وقت الفتح:' : 'Opened At:'}
                  </span>
                  <p className="font-bold text-ui-text">{formatDateTime(summary.openedAt, lang)}</p>
                </div>
                <div className="space-y-1">
                  <span className="text-ui-subtle flex items-center gap-1">
                    <Calendar className="w-3.5 h-3.5" />
                    {isAr ? 'وقت الإغلاق:' : 'Closed At:'}
                  </span>
                  <p className="font-bold text-ui-text">
                    {summary.closedAt ? formatDateTime(summary.closedAt, lang) : (isAr ? 'لا تزال مفتوحة' : 'Still Active')}
                  </p>
                </div>
                <div className="space-y-1">
                  <span className="text-ui-subtle flex items-center gap-1">
                    <TrendingUp className="w-3.5 h-3.5" />
                    {isAr ? 'متوسط الفاتورة:' : 'Avg Ticket:'}
                  </span>
                  <p className="font-bold text-brand-600 dark:text-brand-400">
                    {formatCurrency(summary.avgTicket, currency, lang)}
                  </p>
                </div>
              </div>

              {/* TAB 1: Financial & Drawer Overview */}
              {activeTab === 'overview' && (
                <div className="space-y-6">
                  {/* Top Key Metrics */}
                  <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
                    <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-1">
                      <span className="text-xs font-bold text-ui-subtle">{isAr ? 'صافي المبيعات' : 'Net Sales'}</span>
                      <p className="text-xl font-black text-ui-text">{formatCurrency(summary.netSales, currency, lang)}</p>
                      <span className="text-[11px] text-ui-subtle">{summary.totalInvoices} {isAr ? 'فاتورة' : 'Invoices'}</span>
                    </div>

                    <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-1">
                      <span className="text-xs font-bold text-ui-subtle">{isAr ? 'إجمالي الخصومات' : 'Total Discounts'}</span>
                      <p className="text-xl font-black text-red-500">
                        {summary.totalDiscounts > 0 ? `-${formatCurrency(summary.totalDiscounts, currency, lang)}` : formatCurrency(0, currency, lang)}
                      </p>
                      <span className="text-[11px] text-ui-subtle">{isAr ? 'مجموع التخفيضات' : 'Price reductions'}</span>
                    </div>

                    <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-1">
                      <span className="text-xs font-bold text-ui-subtle">{isAr ? 'إجمالي المرتجعات' : 'Total Refunds'}</span>
                      <p className="text-xl font-black text-amber-500">
                        {summary.totalRefunds > 0 ? `-${formatCurrency(summary.totalRefunds, currency, lang)}` : formatCurrency(0, currency, lang)}
                      </p>
                      <span className="text-[11px] text-ui-subtle">{isAr ? 'عمليات الإرجاع' : 'Returned sales'}</span>
                    </div>

                    <div className={`p-4 rounded-xl border space-y-1 ${diffColor}`}>
                      <span className="text-xs font-bold">{isAr ? 'فارق الصندوق (عجز/زيادة)' : 'Drawer Discrepancy'}</span>
                      <p className="text-xl font-black">{formatCurrency(summary.difference, currency, lang)}</p>
                      <span className="text-[11px] font-bold">
                        {Math.abs(summary.difference) <= 0.01 
                          ? (isAr ? 'الدرج متطابق تماماً' : 'Balanced perfectly') 
                          : summary.difference < 0 
                            ? (isAr ? 'عجز بالنقدية' : 'Shortage') 
                            : (isAr ? 'زيادة بالنقدية' : 'Overage')}
                      </span>
                    </div>
                  </div>

                  {/* Cash Drawer Reconciliation Box */}
                  <div className="p-4 rounded-xl bg-ui-surface/60 border border-ui-border space-y-3">
                    <h4 className="text-sm font-bold text-ui-text flex items-center gap-2">
                      <Coins className="w-4 h-4 text-brand-500" />
                      {isAr ? 'تفاصيل عهدة وتسوية النقدية' : 'Cash Drawer Balancing'}
                    </h4>
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
                      <div className="p-3 rounded-lg bg-ui-card border border-ui-border">
                        <span className="text-ui-subtle">{isAr ? 'رصيد الافتتاح:' : 'Opening Cash:'}</span>
                        <p className="text-sm font-bold text-ui-text mt-0.5">{formatCurrency(summary.openingAmount, currency, lang)}</p>
                      </div>
                      <div className="p-3 rounded-lg bg-ui-card border border-ui-border">
                        <span className="text-ui-subtle">{isAr ? 'المتوقع بالدرج:' : 'Expected Cash:'}</span>
                        <p className="text-sm font-bold text-ui-text mt-0.5">{formatCurrency(summary.expectedAmount, currency, lang)}</p>
                      </div>
                      <div className="p-3 rounded-lg bg-ui-card border border-ui-border">
                        <span className="text-ui-subtle">{isAr ? 'الفعلي بالدرج (العد):' : 'Actual Counted:'}</span>
                        <p className="text-sm font-bold text-ui-text mt-0.5">{formatCurrency(summary.actualAmount, currency, lang)}</p>
                      </div>
                      <div className="p-3 rounded-lg bg-ui-card border border-ui-border">
                        <span className="text-ui-subtle">{isAr ? 'الضرائب المحصلة:' : 'Taxes Collected:'}</span>
                        <p className="text-sm font-bold text-ui-text mt-0.5">{formatCurrency(summary.totalTaxes, currency, lang)}</p>
                      </div>
                    </div>
                  </div>

                  {/* Payment Methods & Order Types Grid */}
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-3">
                      <h4 className="text-sm font-bold text-ui-text">{isAr ? 'طرق الدفع' : 'Payment Methods'}</h4>
                      <div className="space-y-2">
                        {summary.paymentMethods.map((pm) => (
                          <div key={pm.method} className="flex items-center justify-between text-xs py-1.5 border-b border-ui-border/50 last:border-0">
                            <span className="font-bold text-ui-text">{pm.label} ({pm.count})</span>
                            <span className="font-black text-ui-text">{formatCurrency(pm.total, currency, lang)}</span>
                          </div>
                        ))}
                      </div>
                    </div>

                    <div className="p-4 rounded-xl bg-ui-surface border border-ui-border space-y-3">
                      <h4 className="text-sm font-bold text-ui-text">{isAr ? 'أنواع الطلبات' : 'Order Types'}</h4>
                      <div className="space-y-2">
                        {summary.orderTypes.map((ot) => (
                          <div key={ot.type} className="flex items-center justify-between text-xs py-1.5 border-b border-ui-border/50 last:border-0">
                            <span className="font-bold text-ui-text">{ot.label} ({ot.count})</span>
                            <span className="font-black text-ui-text">{formatCurrency(ot.total, currency, lang)}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* TAB 2: ACTIVE USERS IN SHIFT */}
              {activeTab === 'users' && (
                <div className="space-y-4">
                  <div className="flex items-center justify-between">
                    <div>
                      <h4 className="text-sm font-black text-ui-text">
                        {isAr ? 'المستخدمين النشطين في الوردية وتفاصيل عملهم' : 'Active Shift Staff & Performance Breakdown'}
                      </h4>
                      <p className="text-xs text-ui-subtle mt-0.5">
                        {isAr 
                          ? 'يعرض جميع الكاشيرات وموظفي الويترز الذين أنشأوا طلبات أو فواتير خلال هذه الوردية بالتفصيل'
                          : 'Shows all cashiers and waiters who generated orders or sales during this shift'}
                      </p>
                    </div>
                  </div>

                  <div className="overflow-x-auto rounded-xl border border-ui-border">
                    <table className="w-full text-xs text-start">
                      <thead className="bg-ui-surface border-b border-ui-border text-ui-subtle font-bold">
                        <tr>
                          <th className="p-3 text-start">{isAr ? 'الموظف / الكاشير' : 'Employee'}</th>
                          <th className="p-3 text-center">{isAr ? 'الدور' : 'Role'}</th>
                          <th className="p-3 text-center">{isAr ? 'الفواتير' : 'Invoices'}</th>
                          <th className="p-3 text-end">{isAr ? 'إجمالي المبيعات' : 'Gross'}</th>
                          <th className="p-3 text-end">{isAr ? 'الخصومات' : 'Discounts'}</th>
                          <th className="p-3 text-end">{isAr ? 'المرتجعات' : 'Refunds'}</th>
                          <th className="p-3 text-end">{isAr ? 'نقدي (كاش)' : 'Cash'}</th>
                          <th className="p-3 text-end">{isAr ? 'شبكة / بطاقة' : 'Card'}</th>
                          <th className="p-3 text-end">{isAr ? 'الصافي' : 'Net Sales'}</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-ui-border">
                        {summary.activeUsers.map((u) => {
                          const isOpener = u.userId === summary.cashierId;
                          return (
                            <tr key={u.userId} className="hover:bg-ui-surface/50 transition">
                              <td className="p-3">
                                <div className="flex items-center gap-2">
                                  <div className="w-7 h-7 rounded-lg bg-brand-500/10 text-brand-600 flex items-center justify-center font-bold text-xs flex-shrink-0">
                                    {u.userName.charAt(0)}
                                  </div>
                                  <div>
                                    <div className="font-bold text-ui-text flex items-center gap-1.5">
                                      {u.userName}
                                      {isOpener && (
                                        <span className="px-1.5 py-0.5 rounded text-[9px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-700 dark:text-amber-300">
                                          {isAr ? 'فاتح الوردية' : 'Opener'}
                                        </span>
                                      )}
                                    </div>
                                    {u.userEmail && <span className="text-[10px] text-ui-subtle">{u.userEmail}</span>}
                                  </div>
                                </div>
                              </td>
                              <td className="p-3 text-center">
                                <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-ui-surface border border-ui-border text-ui-subtle">
                                  {u.role || 'cashier'}
                                </span>
                              </td>
                              <td className="p-3 text-center font-bold text-ui-text">{u.invoicesCount}</td>
                              <td className="p-3 text-end font-bold text-ui-text">{formatCurrency(u.grossSales, currency, lang)}</td>
                              <td className="p-3 text-end text-red-500 font-bold">
                                {u.totalDiscounts > 0 ? `-${formatCurrency(u.totalDiscounts, currency, lang)}` : '0.00'}
                              </td>
                              <td className="p-3 text-end text-amber-500 font-bold">
                                {u.totalRefunds > 0 ? `-${formatCurrency(u.totalRefunds, currency, lang)}` : '0.00'}
                              </td>
                              <td className="p-3 text-end text-ui-text">{formatCurrency(u.cashSales, currency, lang)}</td>
                              <td className="p-3 text-end text-ui-text">{formatCurrency(u.cardSales, currency, lang)}</td>
                              <td className="p-3 text-end font-black text-emerald-600 dark:text-emerald-400">
                                {formatCurrency(u.netSales, currency, lang)}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              {/* TAB 3: PRODUCTS SOLD */}
              {activeTab === 'products' && (
                <div className="space-y-4">
                  <div className="flex items-center justify-between">
                    <h4 className="text-sm font-black text-ui-text">{isAr ? 'قائمة الأصناف المباعة' : 'Sold Products Summary'}</h4>
                    <span className="text-xs text-ui-subtle font-bold">{summary.productsSold.length} {isAr ? 'صنف مختلف' : 'distinct items'}</span>
                  </div>

                  <div className="overflow-x-auto rounded-xl border border-ui-border">
                    <table className="w-full text-xs text-start">
                      <thead className="bg-ui-surface border-b border-ui-border text-ui-subtle font-bold">
                        <tr>
                          <th className="p-3 text-start">{isAr ? 'اسم المنتج' : 'Product Name'}</th>
                          <th className="p-3 text-center">{isAr ? 'الكمية المباعة' : 'Quantity'}</th>
                          <th className="p-3 text-end">{isAr ? 'إجمالي المبيعات' : 'Total Revenue'}</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-ui-border">
                        {summary.productsSold.map((p) => (
                          <tr key={p.productId} className="hover:bg-ui-surface/50 transition">
                            <td className="p-3 font-bold text-ui-text">{p.productName}</td>
                            <td className="p-3 text-center font-bold text-ui-text">{p.quantity} {p.unitName}</td>
                            <td className="p-3 text-end font-black text-ui-text">{formatCurrency(p.total, currency, lang)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              {/* TAB 4: INGREDIENTS CONSUMED */}
              {activeTab === 'ingredients' && (
                <div className="space-y-4">
                  <div className="flex items-center justify-between">
                    <h4 className="text-sm font-black text-ui-text">{isAr ? 'المكونات والمواد الخام المستهلكة آلياً' : 'Ingredients & Raw Materials Consumed'}</h4>
                  </div>

                  <div className="overflow-x-auto rounded-xl border border-ui-border">
                    <table className="w-full text-xs text-start">
                      <thead className="bg-ui-surface border-b border-ui-border text-ui-subtle font-bold">
                        <tr>
                          <th className="p-3 text-start">{isAr ? 'المادة الخام' : 'Raw Material'}</th>
                          <th className="p-3 text-center">{isAr ? 'الكمية المستهلكة' : 'Consumed Qty'}</th>
                          <th className="p-3 text-end">{isAr ? 'التكلفة التقديرية' : 'Estimated Cost'}</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-ui-border">
                        {summary.ingredientsConsumed.map((m) => (
                          <tr key={m.materialId} className="hover:bg-ui-surface/50 transition">
                            <td className="p-3 font-bold text-ui-text">{m.materialName}</td>
                            <td className="p-3 text-center font-bold text-ui-text">{m.quantity} {m.unit}</td>
                            <td className="p-3 text-end font-bold text-ui-text">{formatCurrency(m.estimatedCost, currency, lang)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </>
          )}
        </div>

        {/* Modal Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-ui-border bg-ui-card-header/50">
          <div className="text-xs text-ui-subtle">
            {summary && (
              <span>{isAr ? 'تقرير رسمي معتمد Z-Report' : 'Official Z-Report Generated'}</span>
            )}
          </div>
          <div className="flex items-center gap-2">
            <Button
              type="button"
              variant="outline"
              onClick={handlePrintThermal}
              disabled={loading || !summary}
              className="text-xs font-bold flex items-center gap-1.5"
            >
              <Printer className="w-4 h-4 text-emerald-600" />
              <span>{isAr ? 'طباعة كاشير 80 مم' : 'Print Thermal'}</span>
            </Button>
            <Button
              type="button"
              variant="primary"
              onClick={handlePrintA4}
              disabled={loading || !summary}
              className="text-xs font-bold flex items-center gap-1.5"
            >
              <FileText className="w-4 h-4" />
              <span>{isAr ? 'طباعة A4 كامل' : 'Print A4'}</span>
            </Button>
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
    </div>
  );
}
