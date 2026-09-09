import { useState, useEffect } from 'react';
import { Timer, X, AlertCircle, CheckCircle2, Printer, FileText, ShoppingBag, Utensils, CreditCard, LockKeyhole, Banknote, ShieldAlert, User } from 'lucide-react';
import { useLanguage } from '@/context/LanguageContext';
import { useAuth } from '@/context/AuthContext';
import { formatCurrency } from '@/lib/format';
import { supabase } from '@/api';
import * as api from '@/api';
import { useToast } from '@/components/Toast';
import { fetchShiftClosingDetails, buildThermalZReportHtml, buildA4ZReportHtml, type ShiftClosingSummary } from '@/features/trade/services/shiftClosingReport';
import { ShiftComprehensiveCloseReportModal } from '@/features/trade/components/ShiftComprehensiveCloseReportModal';

interface ShiftModalProps {
  isOpen: boolean;
  onClose: () => void;
  branchId?: string;
  activeShift: { id: string; expected: number; opened_at: string; opening_amount: number } | null;
  currency: string;
  onShiftClosed: () => void;
}

export function ShiftModal({
  isOpen,
  onClose,
  branchId,
  activeShift,
  currency,
  onShiftClosed,
}: ShiftModalProps) {
  const { t, lang } = useLanguage();
  const { user } = useAuth();
  const isAr = lang === 'ar';
  const { show } = useToast();

  const [closingCash, setClosingCash] = useState<number | ''>('');
  const [notes, setNotes] = useState('');
  const [closing, setClosing] = useState(false);
  const [sensitiveAction, setSensitiveAction] = useState<'force_close' | 'open_drawer' | null>(null);
  const [loadingSummary, setLoadingSummary] = useState(false);
  const [summary, setSummary] = useState<ShiftClosingSummary | null>(null);
  const [comprehensiveReportShiftId, setComprehensiveReportShiftId] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen && activeShift?.id) {
      setLoadingSummary(true);
      fetchShiftClosingDetails(activeShift.id, branchId)
        .then((data) => setSummary(data))
        .catch((err) => console.warn('Could not load live shift summary', err))
        .finally(() => setLoadingSummary(false));
    } else {
      setSummary(null);
    }
  }, [isOpen, activeShift?.id, branchId]);

  if (!isOpen && !comprehensiveReportShiftId) return null;

  const expectedAmount = summary?.expectedAmount ?? (activeShift?.expected || activeShift?.opening_amount || 0);
  const actualAmount = typeof closingCash === 'number' ? closingCash : 0;
  const difference = typeof closingCash === 'number' ? actualAmount - expectedAmount : 0;
  const isOpener = !summary?.cashierId || !user?.id || summary.cashierId === user.id || user.role === 'super_admin' || user.role === 'owner';

  const handlePrintThermal = () => {
    if (!summary) return;
    const effectiveSummary: ShiftClosingSummary = {
      ...summary,
      actualAmount: typeof closingCash === 'number' ? closingCash : summary.actualAmount,
      difference: typeof closingCash === 'number' ? difference : summary.difference,
      notes: notes || summary.notes,
    };
    const html = buildThermalZReportHtml(effectiveSummary, currency, lang);
    const win = window.open('', '_blank', 'width=420,height=700,menubar=no,toolbar=no');
    if (win) {
      win.document.write(html);
      win.document.close();
      try {
        win.focus();
      } catch {
        // Window focus ignored if blocked
      }
    }
  };

  const handlePrintA4 = () => {
    if (!summary) return;
    const effectiveSummary: ShiftClosingSummary = {
      ...summary,
      actualAmount: typeof closingCash === 'number' ? closingCash : summary.actualAmount,
      difference: typeof closingCash === 'number' ? difference : summary.difference,
      notes: notes || summary.notes,
    };
    const html = buildA4ZReportHtml(effectiveSummary, currency, lang);
    const win = window.open('', '_blank', 'width=900,height=800');
    if (win) {
      win.document.write(html);
      win.document.close();
    }
  };

  const requestManagerApproval = async (
    actionType: 'force_close_shift' | 'open_drawer',
    payload: Record<string, unknown>,
    reason: string,
  ) => {
    if (!activeShift) return false;
    const { data, error } = await supabase.rpc('request_manager_approval', {
      p_action_type: actionType,
      p_entity_type: 'shift',
      p_entity_id: activeShift.id,
      p_payload: payload,
      p_reason: reason,
    });
    if (error) {
      show(error.message, 'error');
      return false;
    }
    const result = data as { success?: boolean; error?: string } | null;
    if (!result?.success) {
      show(result?.error || (isAr ? 'تعذر إرسال طلب الموافقة' : 'Could not request manager approval'), 'error');
      return false;
    }
    return true;
  };

  const handleForceClose = async () => {
    if (!activeShift) return;
    if (typeof closingCash !== 'number') {
      show(isAr ? 'أدخل المبلغ الفعلي أولاً' : 'Enter the actual cash amount first', 'error');
      return;
    }
    setSensitiveAction('force_close');
    try {
      const { data, error } = await api.shifts.forceClose({
        p_shift_id: activeShift.id,
        p_actual_amount: actualAmount,
        p_reason: notes.trim() || null,
      });
      if (error) throw error;
      const result = data as { success?: boolean; error?: string; detail?: string } | null;
      if (!result?.success) {
        if (result?.error === 'APPROVAL_REQUIRED') {
          const requested = await requestManagerApproval(
            'force_close_shift',
            { actual_amount: actualAmount, expected_amount: expectedAmount },
            notes.trim() || (isAr ? 'طلب إغلاق إجباري للوردية' : 'Force-close shift request'),
          );
          if (requested) {
            show(isAr ? 'تم إرسال طلب الإغلاق الإجباري للمدير. بعد الموافقة اضغط إغلاق إجباري مرة أخرى.' : 'Force-close approval requested. After approval, press Force Close again.', 'success');
          }
          return;
        }
        show(result?.detail || result?.error || (isAr ? 'فشل الإغلاق الإجباري' : 'Force close failed'), 'error');
        return;
      }
      show(isAr ? 'تم إغلاق الوردية إجباريًا بنجاح' : 'Shift force-closed successfully', 'success');
      onShiftClosed();
      onClose();
    } catch (err: unknown) {
      show(err instanceof Error ? err.message : 'Error force-closing shift', 'error');
    } finally {
      setSensitiveAction(null);
    }
  };

  const handleOpenDrawer = async () => {
    if (!activeShift) return;
    setSensitiveAction('open_drawer');
    try {
      const reason = notes.trim() || (isAr ? 'طلب فتح درج النقدية' : 'Cash drawer open request');
      const { data, error } = await api.shifts.authorizeOpenDrawer({
        p_shift_id: activeShift.id,
        p_reason: reason,
      });
      if (error) throw error;
      const result = data as { success?: boolean; error?: string; detail?: string; hardware_action_required?: boolean } | null;
      if (!result?.success) {
        if (result?.error === 'APPROVAL_REQUIRED') {
          const requested = await requestManagerApproval('open_drawer', {}, reason);
          if (requested) {
            show(isAr ? 'تم إرسال طلب فتح الدرج للمدير. بعد الموافقة اضغط فتح الدرج مرة أخرى.' : 'Drawer approval requested. After approval, press Open Drawer again.', 'success');
          }
          return;
        }
        show(result?.detail || result?.error || (isAr ? 'فشل تفويض فتح الدرج' : 'Drawer authorization failed'), 'error');
        return;
      }
      if (result.hardware_action_required) {
        show(isAr ? 'تمت الموافقة وتسجيل فتح الدرج. يلزم ربط طابعة/جسر أجهزة لإرسال نبضة الفتح الفعلية.' : 'Drawer opening was authorized and audited. A configured printer/native bridge is required for the physical drawer kick.', 'success');
      } else {
        show(isAr ? 'تم تفويض فتح الدرج' : 'Drawer opening authorized', 'success');
      }
    } catch (err: unknown) {
      show(err instanceof Error ? err.message : 'Error authorizing drawer', 'error');
    } finally {
      setSensitiveAction(null);
    }
  };

  const handleCloseShift = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!activeShift) return;
    if (!isOpener) {
      show(
        isAr
          ? `لا يمكن إغلاق الوردية إلا بواسطة الموظف الذي قام بفتحها (${summary?.cashierName || 'المستخدم الأساسي'})`
          : `Only the user who opened this shift (${summary?.cashierName || 'Opener'}) is authorized to close it`,
        'error'
      );
      return;
    }

    if (typeof closingCash !== 'number') {
      show(isAr ? 'يرجى إدخال المبلغ الفعلي في الدرج' : 'Please enter actual cash counted', 'error');
      return;
    }

    const currentShiftId = activeShift.id;
    setClosing(true);
    try {
      const { data, error } = await api.shifts.close({
        p_shift_id: currentShiftId,
        p_actual_amount: actualAmount,
        p_notes: notes.trim() || null,
      });

      if (error) throw error;
      if (data && !(data as { success?: boolean }).success) {
        const d = data as { error?: string; detail?: string };
        throw new Error(d.detail || d.error || 'Failed to close shift');
      }

      show(isAr ? 'تم إغلاق الوردية واليوم بنجاح' : 'Shift & Day closed successfully', 'success');
      onShiftClosed();
      setComprehensiveReportShiftId(currentShiftId);
    } catch (err: unknown) {
      show(err instanceof Error ? err.message : 'Error closing shift', 'error');
    } finally {
      setClosing(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ui-text/50 p-4 backdrop-blur-sm">
      <div className="flex max-h-[92vh] w-full max-w-xl flex-col overflow-hidden rounded-3xl border border-ui-border bg-ui-surface shadow-ui-2xl">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-ui-border px-6 py-4">
            <div className="flex items-center gap-2">
              <Timer className="h-5 w-5 text-ui-accent" />
              <h3 className="text-base font-black text-ui-text">
                {isAr ? 'إدارة وإغلاق اليوم والوردية (Z-Report)' : 'Day & Shift Closing Management'}
              </h3>
              {loadingSummary && (
                <span className="text-[10px] font-bold text-ui-subtle animate-pulse">
                  ({isAr ? 'جاري تجميع البيانات...' : 'Loading summary...'})
                </span>
              )}
            </div>
          <button
            onClick={onClose}
            aria-label={isAr ? 'إغلاق' : 'Close'}
            className="flex h-8 w-8 items-center justify-center rounded-xl text-ui-subtle hover:bg-ui-page-alt"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6 space-y-5">
          {activeShift ? (
            <form onSubmit={handleCloseShift} className="space-y-5">
              {/* Opener Restriction Info */}
              {!isOpener && (
                <div className="flex items-start gap-3 p-4 rounded-2xl bg-amber-500/10 border border-amber-500/30 text-amber-800 dark:text-amber-200">
                  <ShieldAlert className="w-5 h-5 flex-shrink-0 text-amber-500 mt-0.5" />
                  <div className="text-xs space-y-1">
                    <p className="font-black">
                      {isAr ? 'صلاحية الإغلاق محصورة بمُنشئ الوردية' : 'Shift Closing Restriction: Opener Only'}
                    </p>
                    <p className="text-ui-muted dark:text-amber-200/80 leading-relaxed">
                      {isAr
                        ? `تم فتح هذه الوردية بواسطة (${summary?.cashierName || 'الموظف الأساسي'}). النظام يمنع إغلاق الوردية إلا بواسطة نفس المستخدم الذي قام بفتحها حفاظاً على دقة العهدة المالية.`
                        : `This shift was opened by (${summary?.cashierName || 'Primary Staff'}). System policy enforces that only the user who opened the shift can close it.`}
                    </p>
                  </div>
                </div>
              )}

              {/* Shift Stats Card */}
              <div className="rounded-2xl border border-ui-border bg-ui-page-alt p-4 space-y-3">
                <div className="flex items-center justify-between text-xs">
                  <span className="font-bold text-ui-muted">{isAr ? 'مسؤول فتح الوردية' : 'Opened By'}</span>
                  <span className="font-black text-ui-text flex items-center gap-1">
                    <User className="w-3.5 h-3.5 text-ui-primary" />
                    {summary?.cashierName || (isAr ? 'الموظف الحالي' : 'Current Staff')}
                  </span>
                </div>

                <div className="flex items-center justify-between text-xs">
                  <span className="font-bold text-ui-muted">{isAr ? 'تاريخ الفتح' : 'Opened At'}</span>
                  <span className="font-black text-ui-text">
                    {new Date(activeShift.opened_at).toLocaleTimeString(isAr ? 'ar-EG' : 'en-US', {
                      hour: '2-digit',
                      minute: '2-digit',
                      month: 'short',
                      day: 'numeric',
                    })}
                  </span>
                </div>

                <div className="flex items-center justify-between text-xs">
                  <span className="font-bold text-ui-muted">{isAr ? 'رصيد الافتتاح' : 'Opening Amount'}</span>
                  <span className="font-black text-ui-text">
                    {formatCurrency(activeShift.opening_amount, currency, lang)}
                  </span>
                </div>

                {summary && (
                  <>
                    <div className="flex items-center justify-between text-xs">
                      <span className="font-bold text-ui-muted">{isAr ? 'صافي مبيعات الوردية' : 'Shift Net Sales'}</span>
                      <span className="font-black text-ui-primary">
                        {formatCurrency(summary.netSales, currency, lang)} ({summary.totalInvoices} {isAr ? 'فاتورة' : 'inv.'})
                      </span>
                    </div>

                    {summary.paymentMethods.length > 0 && (
                      <div className="border-t border-ui-border/40 pt-2">
                        <div className="mb-1 text-[11px] font-black text-ui-subtle flex items-center gap-1">
                          <CreditCard className="h-3 w-3" />
                          {isAr ? 'طرق الدفع المحصلة:' : 'Payment breakdown:'}
                        </div>
                        <div className="grid grid-cols-2 gap-2 text-[11px]">
                          {summary.paymentMethods.map((pm) => (
                            <div key={pm.method} className="flex justify-between bg-ui-surface p-1.5 rounded-lg border border-ui-border">
                              <span className="text-ui-muted truncate">{pm.label.split(' ')[0]}</span>
                              <span className="font-black text-ui-text">{formatCurrency(pm.total, currency, lang)}</span>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}

                    {/* Products and Ingredients Count Indicators */}
                    <div className="grid grid-cols-2 gap-2 pt-1 text-[11px]">
                      <div className="flex items-center gap-1.5 p-2 rounded-xl bg-ui-surface border border-ui-border">
                        <ShoppingBag className="h-4 w-4 text-ui-accent" />
                        <div>
                          <p className="font-bold text-ui-muted">{isAr ? 'أصناف مباعة' : 'Products sold'}</p>
                          <p className="font-black text-ui-text">{summary.productsSold.length} {isAr ? 'صنف' : 'items'}</p>
                        </div>
                      </div>
                      <div className="flex items-center gap-1.5 p-2 rounded-xl bg-ui-surface border border-ui-border">
                        <Utensils className="h-4 w-4 text-ui-success" />
                        <div>
                          <p className="font-bold text-ui-muted">{isAr ? 'مكونات مستهلكة' : 'Ingredients'}</p>
                          <p className="font-black text-ui-text">{summary.ingredientsConsumed.length} {isAr ? 'مادة خام' : 'materials'}</p>
                        </div>
                      </div>
                    </div>
                  </>
                )}

                <div className="flex items-center justify-between border-t border-ui-border/60 pt-2 text-sm">
                  <span className="font-black text-ui-text">{isAr ? 'المبلغ المتوقع بالدرج' : 'Expected Cash'}</span>
                  <span className="font-black text-ui-accent">
                    {formatCurrency(expectedAmount, currency, lang)}
                  </span>
                </div>
              </div>

              {/* Actual Cash Input */}
              <div>
                <label className="mb-2 block text-xs font-black text-ui-muted">
                  {isAr ? 'المبلغ الفعلي بالدرج (العد الفعلي) *' : 'Actual Cash in Drawer *'}
                </label>
                <input
                  type="number"
                  min={0}
                  step="any"
                  required
                  value={closingCash}
                  onChange={(e) => setClosingCash(e.target.value === '' ? '' : parseFloat(e.target.value))}
                  placeholder="0.00"
                  className="h-14 w-full rounded-2xl border border-ui-border bg-ui-page-alt text-center text-2xl font-black text-ui-text outline-none focus:border-ui-primary focus:ring-2 focus:ring-ui-ring"
                />
              </div>

              {/* Live Difference Indicator */}
              {typeof closingCash === 'number' && (
                <div
                  className={`flex items-center justify-between rounded-2xl p-4 text-xs font-black ${
                    difference === 0
                      ? 'bg-ui-success/10 text-ui-success'
                      : difference > 0
                      ? 'bg-ui-info/10 text-ui-info'
                      : 'bg-ui-danger/10 text-ui-danger'
                  }`}
                >
                  <div className="flex items-center gap-1.5">
                    {difference === 0 ? (
                      <CheckCircle2 className="h-4 w-4" />
                    ) : (
                      <AlertCircle className="h-4 w-4" />
                    )}
                    <span>
                      {difference === 0
                        ? isAr
                          ? 'الدرج متطابق تماماً'
                          : 'Drawer matches exactly'
                        : difference > 0
                        ? isAr
                          ? 'يوجد زيادة في الدرج'
                          : 'Cash Surplus'
                        : isAr
                        ? 'يوجد عجز في الدرج'
                        : 'Cash Shortage'}
                    </span>
                  </div>
                  <span>{formatCurrency(Math.abs(difference), currency, lang)}</span>
                </div>
              )}

              {/* Print buttons */}
              {summary && (
                <div className="flex gap-2">
                  <button
                    type="button"
                    onClick={handlePrintThermal}
                    className="flex-1 flex items-center justify-center gap-2 rounded-xl border border-ui-border bg-ui-surface p-2.5 text-xs font-black text-ui-text hover:bg-ui-page-alt transition"
                  >
                    <Printer className="h-4 w-4 text-ui-accent" />
                    {isAr ? 'طباعة إيصال Z-Report' : 'Print Thermal Z-Report'}
                  </button>
                  <button
                    type="button"
                    onClick={handlePrintA4}
                    className="flex-1 flex items-center justify-center gap-2 rounded-xl border border-ui-border bg-ui-surface p-2.5 text-xs font-black text-ui-text hover:bg-ui-page-alt transition"
                  >
                    <FileText className="h-4 w-4 text-ui-primary" />
                    {isAr ? 'تقرير إغلاق A4 كامل' : 'Full A4 Closing Report'}
                  </button>
                </div>
              )}

              {/* Closing Notes */}
              <div>
                <label className="mb-1.5 block text-xs font-black text-ui-muted">
                  {isAr ? 'ملاحظات إغلاق الوردية واليوم' : 'Closing Notes'}
                </label>
                <textarea
                  rows={2}
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  placeholder={isAr ? 'أي ملاحظات أو توضيحات إضافية حول الإغلاق...' : 'Any closing remarks...'}
                  className="w-full rounded-xl border border-ui-border bg-ui-page-alt p-3 text-xs font-bold text-ui-text outline-none focus:border-ui-primary"
                />
              </div>

              {/* Sensitive manager-approved actions */}
              <div className="grid grid-cols-2 gap-2 rounded-2xl border border-ui-warning/30 bg-ui-warning/5 p-3">
                <button
                  type="button"
                  onClick={handleOpenDrawer}
                  disabled={sensitiveAction !== null}
                  className="flex items-center justify-center gap-2 rounded-xl border border-ui-border bg-ui-surface py-2.5 text-xs font-black text-ui-text hover:bg-ui-page-alt disabled:opacity-50"
                >
                  <Banknote className="h-4 w-4" />
                  {sensitiveAction === 'open_drawer' ? (isAr ? 'جاري الطلب...' : 'Requesting...') : (isAr ? 'فتح الدرج' : 'Open Drawer')}
                </button>
                <button
                  type="button"
                  onClick={handleForceClose}
                  disabled={sensitiveAction !== null || typeof closingCash !== 'number' || !isOpener}
                  className="flex items-center justify-center gap-2 rounded-xl border border-ui-danger/30 bg-ui-danger/5 py-2.5 text-xs font-black text-ui-danger hover:bg-ui-danger/10 disabled:opacity-50"
                  title={!isOpener ? (isAr ? 'الإغلاق الإجباري محصور بمن فتح الوردية أو مدير النظام' : 'Force close allowed only for shift opener or admin') : undefined}
                >
                  <LockKeyhole className="h-4 w-4" />
                  {sensitiveAction === 'force_close' ? (isAr ? 'جاري الطلب...' : 'Requesting...') : (isAr ? 'إغلاق إجباري' : 'Force Close')}
                </button>
              </div>

              {/* Submit Button */}
              <div className="flex gap-2 pt-2">
                <button
                  type="button"
                  onClick={onClose}
                  className="flex-1 rounded-xl border border-ui-border bg-ui-surface py-3 text-xs font-black text-ui-muted hover:bg-ui-page-alt"
                >
                  {t('cancel')}
                </button>
                <button
                  type="submit"
                  disabled={closing || typeof closingCash !== 'number' || !isOpener}
                  className="flex-1 rounded-xl bg-ui-danger py-3 text-xs font-black text-ui-primary-fg shadow-ui-md hover:bg-ui-danger/90 disabled:opacity-50"
                  title={!isOpener ? (isAr ? 'لا يمكن إغلاق الوردية إلا بواسطة من قام بفتحها' : 'Only opener can close this shift') : undefined}
                >
                  {closing ? (isAr ? 'جاري الإغلاق...' : 'Closing...') : (isAr ? 'إغلاق اليوم والوردية' : 'Close Day & Shift')}
                </button>
              </div>
            </form>
          ) : (
            <div className="py-8 text-center text-ui-subtle">
              <Timer className="mx-auto mb-3 h-12 w-12 opacity-20" />
              <p className="text-sm font-bold">{isAr ? 'لا توجد وردية مفتوحة حالياً لهذا الفرع' : 'No open shift for this branch'}</p>
            </div>
          )}
        </div>
      </div>

      {comprehensiveReportShiftId && (
        <ShiftComprehensiveCloseReportModal
          isOpen={true}
          onClose={() => {
            setComprehensiveReportShiftId(null);
            onClose();
          }}
          shiftId={comprehensiveReportShiftId}
          branchId={branchId}
          currency={currency}
          isInitialClosing={true}
        />
      )}
    </div>
  );
}

