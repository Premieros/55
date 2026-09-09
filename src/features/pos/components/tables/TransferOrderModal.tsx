import { useEffect, useMemo, useState } from 'react';
import { ArrowRightLeft, AlertTriangle, GitMerge, ShieldCheck, Users, User, UserCheck, RefreshCw } from 'lucide-react';
import { supabase } from '@/api';
import * as api from '@/api';
import { useLanguage } from '@/context/LanguageContext';
import { useAuth } from '@/context/AuthContext';
import { Button } from '@/components/Button';
import { Modal } from '@/components/Modal';
import { fetchBranchStaff, type BranchStaffMember } from '@/features/pos/services/posOrders';
import type { DiningArea, DiningTable, Order } from '@/lib/types';

interface TransferOrderModalProps {
  open: boolean;
  onClose: () => void;
  order: Order | null;
  sourceTable: DiningTable | null;
  tables: DiningTable[];
  areas?: DiningArea[];
  ordersByTable: Record<string, Order[]>;
  onConfirmTransfer?: (orderId: string, fromTableId: string, toTableId: string) => Promise<boolean>;
  onOrderTransferred?: () => void;
}

export function TransferOrderModal({
  open,
  onClose,
  order,
  sourceTable,
  tables,
  areas = [],
  ordersByTable,
  onOrderTransferred,
}: TransferOrderModalProps) {
  const { t, lang } = useLanguage();
  const isAr = lang === 'ar';
  const { user } = useAuth();

  const [mode, setMode] = useState<'table' | 'staff'>('table');
  const [selectedTargetId, setSelectedTargetId] = useState<string | null>(null);
  const [activeAreaFilter, setActiveAreaFilter] = useState<'all' | 'indoor' | 'outdoor'>('all');
  const [selectedStaffId, setSelectedStaffId] = useState<string | null>(null);
  const [staffList, setStaffList] = useState<BranchStaffMember[]>([]);
  const [staffLoading, setStaffLoading] = useState(false);
  const [reason, setReason] = useState('');
  const [loading, setLoading] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [pendingRequestId, setPendingRequestId] = useState<string | null>(null);
  const [pendingStatus, setPendingStatus] = useState<string | null>(null);

  const isManager = useMemo(() => {
    if (!user) return false;
    return (
      user.role === 'super_admin' ||
      user.role === 'branch_manager' ||
      Boolean((user as { permissions?: string[] }).permissions?.includes('pos.order.transfer'))
    );
  }, [user]);

  useEffect(() => {
    if (!open) return;
    setMode('table');
    setSelectedTargetId(null);
    setSelectedStaffId(null);
    setReason('');
    setErrorMsg(null);
    setPendingRequestId(null);
    setPendingStatus(null);
  }, [open, order?.id]);

  useEffect(() => {
    if (!open || !order?.branch_id) return;
    let cancelled = false;
    setStaffLoading(true);
    fetchBranchStaff(order.branch_id)
      .then((list) => {
        if (!cancelled) setStaffList(list);
      })
      .catch(() => {
        if (!cancelled) setStaffList([]);
      })
      .finally(() => {
        if (!cancelled) setStaffLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [open, order?.branch_id]);

  const availableTargetTables = useMemo(
    () => tables.filter((tb) => tb.id !== sourceTable?.id),
    [tables, sourceTable],
  );

  const filteredTables = useMemo(() => {
    return availableTargetTables.filter((tb) => {
      if (activeAreaFilter === 'all') return true;
      const areaName = areas.find((a) => a.id === tb.area_id)?.name?.toLowerCase() || '';
      const tableName = tb.name.toLowerCase();
      const isOutdoor =
        areaName.includes('outdoor') ||
        areaName.includes('خارج') ||
        areaName.includes('تراس') ||
        areaName.includes('terrace') ||
        areaName.includes('patio') ||
        tableName.includes('outdoor') ||
        tableName.includes('خارج');
      return activeAreaFilter === 'outdoor' ? isOutdoor : !isOutdoor;
    });
  }, [availableTargetTables, activeAreaFilter, areas]);

  const selectedTargetTable = useMemo(
    () => tables.find((tb) => tb.id === selectedTargetId) || null,
    [tables, selectedTargetId],
  );
  const targetOrder = selectedTargetTable ? ordersByTable[selectedTargetTable.id]?.[0] || null : null;
  const targetHasOrder = !!targetOrder;
  const tableActionType = targetHasOrder ? 'merge_order' : 'transfer_order';

  const currentCashierName =
    order?.cashier?.full_name || order?.cashier?.username || (isAr ? 'غير محدد' : 'Unassigned');

  const selectedStaff = useMemo(
    () => staffList.find((s) => s.id === selectedStaffId) || null,
    [staffList, selectedStaffId],
  );

  const perform = async () => {
    if (!order || loading) return;
    if (reason.trim().length < 3) {
      setErrorMsg(isAr ? 'اكتب سبب العملية للمدير أو لسجل التدقيق.' : 'Enter a reason for the audit trail.');
      return;
    }

    if (mode === 'table') {
      if (!sourceTable || !selectedTargetId) return;
    } else {
      if (!selectedStaffId) {
        setErrorMsg(isAr ? 'اختر الموظف المستهدف لنقل الطلب إليه.' : 'Select the destination staff member.');
        return;
      }
      if (selectedStaffId === order.cashier_id) {
        setErrorMsg(isAr ? 'الطلب مسند بالفعل لهذا الموظف.' : 'Order is already assigned to this staff member.');
        return;
      }
    }

    setLoading(true);
    setErrorMsg(null);
    try {
      const actionType = mode === 'staff' ? 'transfer_staff' : tableActionType;
      const payload =
        mode === 'staff'
          ? { target_user_id: selectedStaffId }
          : targetHasOrder
            ? { target_order_id: targetOrder!.id, target_table_id: selectedTargetId }
            : { target_table_id: selectedTargetId };

      const { data, error } = await api.pos.performOrderAction({
        p_action_type: actionType,
        p_order_id: order.id,
        p_payload: payload,
        p_reason: reason.trim(),
      });

      if (error) {
        setErrorMsg(error.message);
        return;
      }

      if (data?.success) {
        setPendingRequestId(null);
        setPendingStatus(null);
        setSelectedTargetId(null);
        setSelectedStaffId(null);
        onOrderTransferred?.();
        onClose();
        return;
      }

      if (data?.error === 'MANAGER_APPROVAL_REQUIRED' && data.request_id) {
        setPendingRequestId(data.request_id);
        setPendingStatus(data.status || 'pending');
        return;
      }

      setErrorMsg(
        data?.error === 'SOURCE_HAS_SENT_ITEMS'
          ? isAr
            ? 'لا يمكن دمج طلب يحتوي أصنافًا مرسلة للمطبخ حاليًا حتى لا يتغير سجل KDS. استخدم نقل الطاولة للطلب كاملًا أو أكمل الطلب كما هو.'
            : 'A source order with sent kitchen items cannot currently be merged because the KDS snapshot is immutable. Transfer the whole table order instead or finish it separately.'
          : data?.error === 'NOT_AUTHORIZED'
            ? isAr
              ? 'غير مصرح: نقل الطلبات بين الموظفين متاح للمدير فقط.'
              : 'Unauthorized: Transferring orders between staff requires manager permission.'
            : data?.detail || data?.error || (isAr ? 'تعذر تنفيذ العملية.' : 'Could not execute the action.'),
      );
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!open || !pendingRequestId) return;
    let cancelled = false;
    const check = async () => {
      const { data } = await supabase
        .from('approval_requests')
        .select('status')
        .eq('id', pendingRequestId)
        .maybeSingle();
      if (cancelled || !data) return;
      const status = (data as { status: string }).status;
      setPendingStatus(status);
      if (status === 'approved') {
        setPendingRequestId(null);
        await perform();
      } else if (status === 'rejected' || status === 'expired') {
        setPendingRequestId(null);
        setErrorMsg(
          status === 'rejected'
            ? isAr
              ? 'رفض المدير العملية.'
              : 'The manager rejected the action.'
            : isAr
              ? 'انتهت صلاحية طلب الموافقة. أعد المحاولة.'
              : 'The approval request expired. Try again.',
        );
      }
    };
    const id = window.setInterval(() => void check(), 2000);
    void check();
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, pendingRequestId]);

  if (!open || !order) return null;

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={isAr ? 'إدارة ونقل الطلب' : 'Manage & Transfer Order'}
      size="lg"
    >
      <div className="space-y-4">
        {/* Order Header Summary */}
        <div className="flex items-center justify-between rounded-2xl border border-ui-border bg-ui-page p-3.5">
          <div>
            <p className="text-xs text-ui-subtle">{isAr ? 'الطلب الحالي' : 'Active Order'}</p>
            <p className="text-sm font-black text-ui-text">
              #{order.order_number} {sourceTable ? `· ${sourceTable.name}` : ''}
            </p>
          </div>
          <div className="text-end">
            <span className="text-xs text-ui-subtle">{isAr ? 'الموظف الحالي:' : 'Assigned Staff:'}</span>
            <div className="flex items-center gap-1 text-xs font-black text-ui-accent">
              <User className="h-3.5 w-3.5" />
              <span>{currentCashierName}</span>
            </div>
          </div>
        </div>

        {/* Mode Selector Tabs: Table vs Staff */}
        <div className="grid grid-cols-2 gap-1 rounded-xl bg-ui-page-alt p-1">
          <button
            type="button"
            onClick={() => {
              setMode('table');
              setErrorMsg(null);
            }}
            className={`flex items-center justify-center gap-2 rounded-lg py-2 text-xs font-black transition ${
              mode === 'table'
                ? 'bg-ui-surface text-ui-text shadow-ui-xs'
                : 'text-ui-muted hover:text-ui-text'
            }`}
          >
            <ArrowRightLeft className="h-4 w-4" />
            <span>{isAr ? 'نقل / دمج طاولة' : 'Transfer / Merge Table'}</span>
          </button>

          <button
            type="button"
            onClick={() => {
              setMode('staff');
              setErrorMsg(null);
            }}
            className={`flex items-center justify-center gap-2 rounded-lg py-2 text-xs font-black transition ${
              mode === 'staff'
                ? 'bg-ui-surface text-ui-text shadow-ui-xs'
                : 'text-ui-muted hover:text-ui-text'
            }`}
          >
            <UserCheck className="h-4 w-4" />
            <span>{isAr ? 'نقل الموظف المسؤول (المدير)' : 'Transfer Staff (Manager)'}</span>
          </button>
        </div>

        {mode === 'table' ? (
          <>
            {/* Area Filter */}
            <div className="flex items-center gap-1 rounded-xl bg-ui-page-alt p-1">
              {(['all', 'indoor', 'outdoor'] as const).map((filter) => (
                <button
                  key={filter}
                  type="button"
                  onClick={() => setActiveAreaFilter(filter)}
                  className={`flex-1 rounded-lg py-1.5 text-xs font-black transition ${
                    activeAreaFilter === filter
                      ? 'bg-ui-surface text-ui-text shadow-ui-xs'
                      : 'text-ui-muted hover:text-ui-text'
                  }`}
                >
                  {filter === 'all'
                    ? isAr
                      ? `كل الطاولات (${availableTargetTables.length})`
                      : `All (${availableTargetTables.length})`
                    : filter === 'indoor'
                      ? isAr
                        ? 'داخلية'
                        : 'Indoor'
                      : isAr
                        ? 'خارجية'
                        : 'Outdoor'}
                </button>
              ))}
            </div>

            {/* Target Tables Grid */}
            <div className="max-h-[260px] space-y-2 overflow-y-auto pr-1">
              <p className="text-xs font-bold text-ui-subtle">
                {isAr ? 'اختر الطاولة المستهدفة:' : 'Select destination table:'}
              </p>
              <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 md:grid-cols-4">
                {filteredTables.map((tb) => {
                  const hasOrd = (ordersByTable[tb.id]?.length || 0) > 0;
                  const selected = selectedTargetId === tb.id;
                  return (
                    <button
                      key={tb.id}
                      type="button"
                      data-testid={`pos-structure-target-${tb.id}`}
                      onClick={() => {
                        setSelectedTargetId(tb.id);
                        setErrorMsg(null);
                      }}
                      className={`flex flex-col items-start justify-between rounded-xl border p-2.5 text-start transition ${
                        selected
                          ? 'border-ui-primary bg-ui-primary-soft ring-2 ring-ui-ring'
                          : hasOrd
                            ? 'border-amber-500/30 bg-amber-500/5 hover:border-amber-500/60'
                            : 'border-ui-border bg-ui-surface hover:border-emerald-500'
                      }`}
                    >
                      <div className="flex w-full items-center justify-between">
                        <span className="text-sm font-black text-ui-text">{tb.name}</span>
                        <span className="flex items-center gap-0.5 text-[10px] text-ui-muted">
                          <Users className="h-2.5 w-2.5" /> {tb.capacity}
                        </span>
                      </div>
                      <span
                        className={`mt-2 block w-full rounded px-1.5 py-0.5 text-center text-[10px] font-bold ${
                          hasOrd ? 'bg-amber-500/10 text-amber-600' : 'bg-emerald-500/10 text-emerald-600'
                        }`}
                      >
                        {hasOrd
                          ? isAr
                            ? 'مشغولة — Merge'
                            : 'Occupied — Merge'
                          : isAr
                            ? 'فارغة — Transfer'
                            : 'Vacant — Transfer'}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>

            {selectedTargetTable && (
              <div
                className={`rounded-xl border p-3 text-xs font-semibold ${
                  targetHasOrder
                    ? 'border-amber-500/20 bg-amber-500/5 text-amber-700 dark:text-amber-400'
                    : 'border-emerald-500/20 bg-emerald-500/5 text-emerald-700 dark:text-emerald-400'
                }`}
              >
                {targetHasOrder
                  ? isAr
                    ? `Merge: سيتم ضم الطلب #${order.order_number} إلى الطلب #${targetOrder?.order_number} على ${selectedTargetTable.name}.`
                    : `Merge order #${order.order_number} into #${targetOrder?.order_number} on ${selectedTargetTable.name}.`
                  : isAr
                    ? `Transfer: سيتم نقل الطلب كاملًا من ${sourceTable?.name || ''} إلى ${selectedTargetTable.name}.`
                    : `Transfer the whole order from ${sourceTable?.name || ''} to ${selectedTargetTable.name}.`}
              </div>
            )}
          </>
        ) : (
          /* Staff Selection Mode */
          <div className="space-y-3">
            {!isManager && (
              <div className="flex items-center gap-2 rounded-xl border border-amber-500/30 bg-amber-500/10 p-3 text-xs font-bold text-amber-700 dark:text-amber-400">
                <AlertTriangle className="h-4 w-4 shrink-0" />
                <span>
                  {isAr
                    ? 'تنبيه: نقل مسؤولية الطلب يتطلب صلاحية المدير. سيتم إرسال طلب للموافقة في حال عدم توفر الصلاحية المباشرة.'
                    : 'Notice: Reassigning orders requires manager authorization. An approval request will be dispatched if unauthorized.'}
                </span>
              </div>
            )}

            <div className="flex items-center justify-between">
              <p className="text-xs font-bold text-ui-subtle">
                {isAr ? 'اختر الموظف الجديد للطلب / الطاولة:' : 'Select new assignee for order/table:'}
              </p>
              {staffLoading && <RefreshCw className="h-3.5 w-3.5 animate-spin text-ui-muted" />}
            </div>

            <div className="max-h-[260px] space-y-2 overflow-y-auto pr-1">
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                {staffList.map((st) => {
                  const isCurrent = st.id === order.cashier_id;
                  const isSelected = selectedStaffId === st.id;
                  return (
                    <button
                      key={st.id}
                      type="button"
                      disabled={isCurrent}
                      onClick={() => {
                        setSelectedStaffId(st.id);
                        setErrorMsg(null);
                      }}
                      className={`flex items-center justify-between rounded-xl border p-3 text-start transition ${
                        isCurrent
                          ? 'border-ui-border bg-ui-page-alt opacity-50 cursor-not-allowed'
                          : isSelected
                            ? 'border-ui-primary bg-ui-primary-soft ring-2 ring-ui-ring'
                            : 'border-ui-border bg-ui-surface hover:border-ui-primary'
                      }`}
                    >
                      <div className="flex items-center gap-2.5">
                        <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-ui-primary/10 text-xs font-black text-ui-primary">
                          {st.full_name?.charAt(0) || st.username?.charAt(0) || 'U'}
                        </div>
                        <div>
                          <p className="text-xs font-black text-ui-text">
                            {st.full_name || st.username}
                          </p>
                          <p className="text-[10px] font-bold text-ui-muted">@{st.username}</p>
                        </div>
                      </div>
                      <div className="text-end">
                        <span className="rounded-md bg-ui-page-alt px-1.5 py-0.5 text-[9px] font-black text-ui-subtle uppercase">
                          {st.role}
                        </span>
                        {isCurrent && (
                          <span className="mt-1 block text-[9px] font-bold text-amber-600">
                            {isAr ? '(المسؤول الحالي)' : '(Current)'}
                          </span>
                        )}
                      </div>
                    </button>
                  );
                })}
              </div>
            </div>

            {selectedStaff && (
              <div className="rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-3 text-xs font-semibold text-emerald-700 dark:text-emerald-400">
                {isAr
                  ? `سيتم تحويل ملكية الطلب #${order.order_number} والطاولة إلى الموظف (${selectedStaff.full_name || selectedStaff.username}) مع تسجيل العملية في سجل التدقيق.`
                  : `Ownership of order #${order.order_number} and table will be transferred to (${selectedStaff.full_name || selectedStaff.username}) with an audit log record.`}
              </div>
            )}
          </div>
        )}

        {/* Reason Input */}
        <label className="block">
          <span className="mb-1 block text-[11px] font-black text-ui-muted">
            {isAr ? 'سبب العملية — مسجل في تدقيق العمليات' : 'Reason — recorded in audit trail'}
          </span>
          <input
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder={
              mode === 'staff'
                ? isAr
                  ? 'مثال: تبديل الوردية أو استراحة الموظف'
                  : 'e.g. Shift switch or break cover'
                : isAr
                  ? 'مثال: رغبة الزبون في طاولة عائلية أكبر'
                  : 'e.g. Guest moved to a larger table'
            }
            className="h-11 w-full rounded-xl border border-ui-border bg-ui-surface px-3 text-sm font-bold text-ui-text outline-none focus:border-ui-primary"
          />
        </label>

        {pendingRequestId && (
          <div className="flex items-center gap-3 rounded-2xl border border-ui-warning/30 bg-ui-warning/10 p-3 text-ui-warning">
            <ShieldCheck className="h-5 w-5 shrink-0" />
            <div>
              <p className="text-xs font-black">{isAr ? 'بانتظار موافقة المدير' : 'Waiting for manager approval'}</p>
              <p className="mt-0.5 text-[10px] font-bold opacity-80">
                {isAr ? 'سيتم التنفيذ تلقائيًا فور الموافقة.' : 'It will execute automatically after approval.'} ·{' '}
                {pendingStatus || 'pending'}
              </p>
            </div>
          </div>
        )}

        {errorMsg && (
          <div className="flex items-center gap-2 rounded-xl border border-rose-500/20 bg-rose-500/10 p-3 text-xs font-bold text-rose-600">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            <span>{errorMsg}</span>
          </div>
        )}

        {/* Footer Actions */}
        <div className="flex items-center justify-end gap-2 border-t border-ui-border pt-3">
          <Button variant="secondary" onClick={onClose} disabled={loading}>
            {t('cancel')}
          </Button>
          <Button
            variant="primary"
            onClick={() => void perform()}
            disabled={
              loading ||
              !!pendingRequestId ||
              reason.trim().length < 3 ||
              (mode === 'table' ? !selectedTargetId : !selectedStaffId)
            }
          >
            {mode === 'staff' ? (
              <UserCheck className="h-4 w-4" />
            ) : targetHasOrder ? (
              <GitMerge className="h-4 w-4" />
            ) : (
              <ArrowRightLeft className="h-4 w-4" />
            )}
            <span>
              {pendingRequestId
                ? isAr
                  ? 'بانتظار المدير'
                  : 'Waiting'
                : mode === 'staff'
                  ? isAr
                    ? 'تأكيد نقل الموظف'
                    : 'Confirm Staff Transfer'
                  : targetHasOrder
                    ? isAr
                      ? 'طلب Merge'
                      : 'Request Merge'
                    : isAr
                      ? 'طلب Transfer'
                      : 'Request Transfer'}
            </span>
          </Button>
        </div>
      </div>
    </Modal>
  );
}
