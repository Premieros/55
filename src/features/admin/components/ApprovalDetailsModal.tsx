import { useState } from 'react';
import {
  Calendar,
  CheckCircle2,
  Clock,
  Copy,
  FileText,
  MapPin,
  ShieldCheck,
  User,
  X,
  XCircle,
} from 'lucide-react';
import { Button } from '@/components/Button';
import { useToast } from '@/components/Toast';

export interface ApprovalHistoryItem {
  id: string;
  branch_id: string;
  requester_id: string;
  action_type: string;
  entity_type: string;
  entity_id: string | null;
  payload: Record<string, unknown>;
  reason: string;
  status: 'pending' | 'approved' | 'rejected' | 'expired' | 'consumed';
  approver_id: string | null;
  decision_note: string | null;
  created_at: string;
  decided_at: string | null;
  expires_at: string;
  consumed_at: string | null;
  requester_name?: string;
  requester_role?: string;
  approver_name?: string;
  approver_role?: string;
  branch_name?: string;
}

interface ApprovalDetailsModalProps {
  item: ApprovalHistoryItem | null;
  onClose: () => void;
  ar: boolean;
}

export function ApprovalDetailsModal({ item, onClose, ar }: ApprovalDetailsModalProps) {
  const { show } = useToast();
  const [showRawJson, setShowRawJson] = useState(false);

  if (!item) return null;

  const copyJson = () => {
    try {
      navigator.clipboard.writeText(JSON.stringify(item, null, 2));
      show(ar ? 'تم نسخ بيانات الاعتماد إلى الحافظة' : 'Copied approval payload to clipboard', 'success');
    } catch {
      show(ar ? 'فشل نسخ البيانات' : 'Failed to copy', 'error');
    }
  };

  const getStatusBadge = (status: string) => {
    switch (status) {
      case 'approved':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-bold text-emerald-600 dark:text-emerald-400 border border-emerald-500/20">
            <CheckCircle2 className="h-3.5 w-3.5" />
            {ar ? 'معتمدة' : 'Approved'}
          </span>
        );
      case 'consumed':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-blue-500/10 px-2.5 py-1 text-xs font-bold text-blue-600 dark:text-blue-400 border border-blue-500/20">
            <CheckCircle2 className="h-3.5 w-3.5" />
            {ar ? 'مطبقة ومستهلكة' : 'Applied / Consumed'}
          </span>
        );
      case 'rejected':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-rose-500/10 px-2.5 py-1 text-xs font-bold text-rose-600 dark:text-rose-400 border border-rose-500/20">
            <XCircle className="h-3.5 w-3.5" />
            {ar ? 'مرفوضة' : 'Rejected'}
          </span>
        );
      case 'expired':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-bold text-amber-600 dark:text-amber-400 border border-amber-500/20">
            <Clock className="h-3.5 w-3.5" />
            {ar ? 'منتهية الصلاحية' : 'Expired'}
          </span>
        );
      default:
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-slate-500/10 px-2.5 py-1 text-xs font-bold text-slate-600 dark:text-slate-400 border border-slate-500/20">
            <Clock className="h-3.5 w-3.5" />
            {ar ? 'معلقة' : 'Pending'}
          </span>
        );
    }
  };

  const getActionName = (type: string) => {
    const map: Record<string, { ar: string; en: string }> = {
      discount: { ar: 'طلب خصم كاشير', en: 'Cashier Discount' },
      reprint: { ar: 'إعادة طباعة فاتورة', en: 'Receipt Reprint' },
      void_order: { ar: 'إلغاء طلب معتمد', en: 'Void Order' },
      cancel_sent_item: { ar: 'إلغاء صنف مرسل للمطبخ', en: 'Cancel Sent Item' },
      refund: { ar: 'استرجاع مالي / مرتجع', en: 'Order Refund' },
      open_drawer: { ar: 'فتح درج النقدية', en: 'Open Cash Drawer' },
      change_payment_method: { ar: 'تعديل وسيلة الدفع', en: 'Change Payment Method' },
      force_close_shift: { ar: 'إغلاق شيفت إجباري', en: 'Force Close Shift' },
      split_order: { ar: 'فصل طلب', en: 'Split Order' },
      merge_order: { ar: 'دمج طلب', en: 'Merge Order' },
      transfer_order: { ar: 'تحويل طاولة / طلب', en: 'Transfer Order' },
      waste: { ar: 'اعتماد هالك مخزني', en: 'Waste Entry' },
      stock_count: { ar: 'اعتماد تسوية جرد', en: 'Stock Count' },
      warehouse_transfer: { ar: 'اعتماد مناقلة مخزنية', en: 'Warehouse Transfer' },
    };
    return map[type]?.[ar ? 'ar' : 'en'] || type;
  };

  const p = item.payload || {};

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      data-testid="approval-details-modal"
    >
      <div className="w-full max-w-2xl max-h-[90vh] overflow-y-auto rounded-2xl border border-ui-border bg-ui-surface p-6 shadow-2xl animate-in fade-in zoom-in-95 duration-150">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-ui-border pb-4">
          <div className="flex items-center gap-3">
            <div className="rounded-xl bg-ui-primary/10 p-2.5 text-ui-primary">
              <ShieldCheck className="h-6 w-6" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-lg font-bold text-ui-text">
                  {getActionName(item.action_type)}
                </h2>
                {getStatusBadge(item.status)}
              </div>
              <p className="text-xs text-ui-muted mt-0.5">
                {ar ? 'معرّف الطلب:' : 'Request ID:'} <span className="font-mono text-ui-text">{item.id}</span>
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-ui-muted hover:bg-ui-page-alt hover:text-ui-text transition-colors"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="mt-5 space-y-4">
          {/* Key Information Grid */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {/* Requester */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <User className="h-4 w-4" />
                <span>{ar ? 'مقدم الطلب (الكاشير / الموظف)' : 'Requester'}</span>
              </div>
              <p className="font-bold text-sm text-ui-text">
                {item.requester_name || (ar ? 'غير محدد' : 'Unknown')}
              </p>
              {item.requester_role && (
                <span className="inline-block rounded-md bg-ui-border/60 px-2 py-0.5 text-xs text-ui-muted font-medium">
                  {item.requester_role}
                </span>
              )}
            </div>

            {/* Approver */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <ShieldCheck className="h-4 w-4" />
                <span>{ar ? 'المعتمد (المدير المسؤول)' : 'Approver / Manager'}</span>
              </div>
              <p className="font-bold text-sm text-ui-text">
                {item.approver_name || (item.status === 'pending' ? (ar ? 'قيد الانتظار' : 'Pending Review') : '-')}
              </p>
              {item.approver_role && (
                <span className="inline-block rounded-md bg-ui-border/60 px-2 py-0.5 text-xs text-ui-muted font-medium">
                  {item.approver_role}
                </span>
              )}
            </div>

            {/* Branch */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <MapPin className="h-4 w-4" />
                <span>{ar ? 'الفرع' : 'Branch'}</span>
              </div>
              <p className="font-semibold text-sm text-ui-text">
                {item.branch_name || (ar ? 'الفرع الحالي' : 'Current Branch')}
              </p>
            </div>

            {/* Timestamps */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <Calendar className="h-4 w-4" />
                <span>{ar ? 'التوقيت الزمني' : 'Timeline'}</span>
              </div>
              <div className="text-xs text-ui-text space-y-0.5">
                <div>
                  <span className="text-ui-muted">{ar ? 'طلب في: ' : 'Requested: '}</span>
                  {new Date(item.created_at).toLocaleString(ar ? 'ar-EG' : 'en')}
                </div>
                {item.decided_at && (
                  <div>
                    <span className="text-ui-muted">{ar ? 'قُرر في: ' : 'Decided: '}</span>
                    {new Date(item.decided_at).toLocaleString(ar ? 'ar-EG' : 'en')}
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Reason & Decision Notes */}
          <div className="space-y-3">
            <div className="rounded-xl border border-ui-border bg-ui-surface p-3.5">
              <span className="block text-xs font-bold text-ui-muted mb-1">
                {ar ? 'سبب الطلب المقدم من الموظف:' : 'Reason stated by requester:'}
              </span>
              <p className="text-sm font-medium text-ui-text whitespace-pre-wrap">
                {item.reason || (ar ? 'لا يوجد سبب مكتوب' : 'No stated reason')}
              </p>
            </div>

            {item.decision_note && (
              <div className="rounded-xl border border-ui-border bg-ui-surface p-3.5">
                <span className="block text-xs font-bold text-ui-muted mb-1">
                  {ar ? 'ملاحظة أو سبب قرار المدير:' : 'Manager decision note / reason:'}
                </span>
                <p className="text-sm font-medium text-ui-text whitespace-pre-wrap">
                  {item.decision_note}
                </p>
              </div>
            )}
          </div>

          {/* Operational Payload Specifics */}
          <div className="rounded-xl border border-ui-border bg-ui-page-alt p-4">
            <h3 className="text-xs font-bold uppercase tracking-wider text-ui-muted mb-3 flex items-center gap-1.5">
              <FileText className="h-4 w-4" />
              {ar ? 'تفاصيل البيانات التشغيلية والمالية' : 'Operational & Financial Payload Details'}
            </h3>

            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 text-xs">
              {p.amount !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'المبلغ' : 'Amount'}</span>
                  <span className="text-sm font-bold text-ui-text">{String(p.amount)}</span>
                </div>
              )}
              {p.discount_percent !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'نسبة الخصم' : 'Discount %'}</span>
                  <span className="text-sm font-bold text-ui-text">{String(p.discount_percent)}%</span>
                </div>
              )}
              {p.invoice_number !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'رقم الفاتورة' : 'Invoice #'}</span>
                  <span className="text-sm font-mono font-bold text-ui-text">{String(p.invoice_number)}</span>
                </div>
              )}
              {p.order_id !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'معرّف الطلب' : 'Order ID'}</span>
                  <span className="text-xs font-mono font-semibold text-ui-text truncate block">{String(p.order_id)}</span>
                </div>
              )}
              {p.table_name !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'الطاولة' : 'Table'}</span>
                  <span className="text-sm font-bold text-ui-text">{String(p.table_name)}</span>
                </div>
              )}
              {p.customer_name !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'العميل' : 'Customer'}</span>
                  <span className="text-sm font-semibold text-ui-text">{String(p.customer_name)}</span>
                </div>
              )}
              {p.payment_method !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'طريقة الدفع' : 'Payment Method'}</span>
                  <span className="text-sm font-semibold text-ui-text">{String(p.payment_method)}</span>
                </div>
              )}
              {p.reprint_count !== undefined && (
                <div className="rounded-lg border border-ui-border bg-ui-surface p-2.5">
                  <span className="text-ui-muted block">{ar ? 'عدد مرات الطباعة السابقة' : 'Prior Print Count'}</span>
                  <span className="text-sm font-bold text-ui-text">{String(p.reprint_count)}</span>
                </div>
              )}
            </div>

            {/* Raw JSON toggle */}
            <div className="mt-3 pt-3 border-t border-ui-border">
              <div className="flex items-center justify-between">
                <button
                  type="button"
                  onClick={() => setShowRawJson(!showRawJson)}
                  className="text-xs font-semibold text-ui-primary hover:underline"
                >
                  {showRawJson
                    ? (ar ? 'إخفاء الحقول التقنية الخام' : 'Hide raw technical payload')
                    : (ar ? 'عرض الحقول التقنية الخام (JSON)' : 'Show raw technical payload (JSON)')}
                </button>
                <Button size="sm" variant="outline" onClick={copyJson} className="h-7 text-xs">
                  <Copy className="h-3.5 w-3.5" />
                  {ar ? 'نسخ JSON' : 'Copy JSON'}
                </Button>
              </div>

              {showRawJson && (
                <pre className="mt-2.5 max-h-48 overflow-y-auto rounded-lg bg-ui-surface p-3 text-[11px] font-mono text-ui-text border border-ui-border">
                  {JSON.stringify(p, null, 2)}
                </pre>
              )}
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="mt-6 flex items-center justify-end gap-2 border-t border-ui-border pt-4">
          <Button variant="secondary" onClick={onClose}>
            {ar ? 'إغلاق' : 'Close'}
          </Button>
        </div>
      </div>
    </div>
  );
}
