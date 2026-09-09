import { useState } from 'react';
import {
  Calendar,
  Copy,
  FileCode,
  Info,
  Layers,
  MapPin,
  Shield,
  User,
  X,
} from 'lucide-react';
import { Button } from '@/components/Button';
import { useToast } from '@/components/Toast';
import type { AuditLog } from '@/lib/types';
import type { AuditSystemModule } from '@/lib/audit';

interface AuditDetailModalProps {
  item: AuditLog | null;
  moduleName?: AuditSystemModule;
  branchName?: string;
  onClose: () => void;
  ar: boolean;
}

const MODULE_TITLES: Record<AuditSystemModule, { ar: string; en: string }> = {
  pos: { ar: 'المبيعات ونقاط البيع', en: 'Sales & POS' },
  inventory: { ar: 'المخزون والمستودعات', en: 'Inventory & Warehousing' },
  shifts: { ar: 'الورديات والخزينة', en: 'Shifts & Cash' },
  products: { ar: 'المنتجات والتسعير والوصفات', en: 'Products & Pricing' },
  approvals: { ar: 'الموافقات والاعتمادات', en: 'Approvals & Overrides' },
  users: { ar: 'المستخدمين والصلاحيات والأمان', en: 'Users & Security' },
  accounting: { ar: 'المحاسبة والمالية', en: 'Accounting & Finance' },
  settings: { ar: 'الإعدادات والتهيئة والفروع', en: 'Settings & System' },
  general: { ar: 'النظام العام', en: 'General System' },
};

const ACTION_LABELS: Record<string, { ar: string; en: string }> = {
  create: { ar: 'إضافة جديدة', en: 'Create' },
  update: { ar: 'تعديل وتحديث', en: 'Update' },
  delete: { ar: 'حذف', en: 'Delete' },
  approve: { ar: 'موافقة واعتماد', en: 'Approve' },
  reject: { ar: 'رفض طلب', en: 'Reject' },
  void: { ar: 'إلغاء', en: 'Void' },
  refund: { ar: 'استرجاع مالي', en: 'Refund' },
  reprint: { ar: 'إعادة طباعة', en: 'Reprint' },
  import: { ar: 'استيراد جماعي', en: 'Import' },
  export: { ar: 'تصدير بيانات', en: 'Export' },
};

export function AuditDetailModal({
  item,
  moduleName = 'general',
  branchName,
  onClose,
  ar,
}: AuditDetailModalProps) {
  const { show } = useToast();
  const [showRawJson, setShowRawJson] = useState(false);

  if (!item) return null;

  const copyJson = () => {
    try {
      navigator.clipboard.writeText(JSON.stringify(item, null, 2));
      show(ar ? 'تم نسخ بيانات السجل إلى الحافظة' : 'Audit entry copied to clipboard', 'success');
    } catch {
      show(ar ? 'فشل نسخ البيانات' : 'Failed to copy', 'error');
    }
  };

  const actionKey = (item.action || '').toLowerCase();
  const actionLabel = ACTION_LABELS[actionKey]?.[ar ? 'ar' : 'en'] || item.action;
  const moduleInfo = MODULE_TITLES[moduleName] || MODULE_TITLES.general;

  const detailsObj = (item.details || {}) as Record<string, unknown>;
  const cleanDetails = { ...detailsObj };
  delete cleanDetails._module;

  const getActionBadgeClass = (action: string) => {
    const a = action.toLowerCase();
    if (a.includes('create') || a.includes('add') || a.includes('approve')) {
      return 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border-emerald-500/20';
    }
    if (a.includes('delete') || a.includes('void') || a.includes('reject')) {
      return 'bg-rose-500/10 text-rose-600 dark:text-rose-400 border-rose-500/20';
    }
    if (a.includes('update') || a.includes('edit')) {
      return 'bg-blue-500/10 text-blue-600 dark:text-blue-400 border-blue-500/20';
    }
    return 'bg-slate-500/10 text-slate-600 dark:text-slate-400 border-slate-500/20';
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      data-testid="audit-detail-modal"
    >
      <div className="w-full max-w-2xl max-h-[90vh] overflow-y-auto rounded-2xl border border-ui-border bg-ui-surface p-6 shadow-2xl animate-in fade-in zoom-in-95 duration-150">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-ui-border pb-4">
          <div className="flex items-center gap-3">
            <div className="rounded-xl bg-ui-primary/10 p-2.5 text-ui-primary">
              <Shield className="h-6 w-6" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-lg font-bold text-ui-text">
                  {ar ? 'تفاصيل العملية المسجلة في السجل' : 'Audit Log Entry Inspection'}
                </h2>
                <span
                  className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-bold border ${getActionBadgeClass(
                    item.action
                  )}`}
                >
                  {actionLabel}
                </span>
              </div>
              <p className="text-xs text-ui-muted mt-0.5">
                {ar ? 'النظام التابع:' : 'System:'}{' '}
                <span className="font-semibold text-ui-text">
                  {ar ? moduleInfo.ar : moduleInfo.en}
                </span>
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

        {/* Content */}
        <div className="mt-5 space-y-4">
          {/* Metadata Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {/* Actor */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <User className="h-4 w-4" />
                <span>{ar ? 'المستخدم / المنفذ للعملية' : 'Actor / User'}</span>
              </div>
              <p className="font-bold text-sm text-ui-text break-all">
                {item.user_email || (ar ? 'مجهول أو نظام تلقائي' : 'System / Anonymous')}
              </p>
              {item.user_id && (
                <span className="font-mono text-[10px] text-ui-muted truncate block">
                  UID: {item.user_id}
                </span>
              )}
            </div>

            {/* Target Entity */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <Layers className="h-4 w-4" />
                <span>{ar ? 'الكيان المتأثر' : 'Target Entity'}</span>
              </div>
              <p className="font-bold text-sm text-ui-text font-mono">
                {item.entity || '-'}
              </p>
              {item.entity_id && (
                <span className="font-mono text-[10px] text-ui-muted truncate block">
                  ID: {item.entity_id}
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
                {branchName || (ar ? 'عام / غير مرتبط بفرع' : 'Global / Not branch-specific')}
              </p>
            </div>

            {/* Timestamp */}
            <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3.5 space-y-1">
              <div className="flex items-center gap-2 text-xs font-semibold text-ui-muted">
                <Calendar className="h-4 w-4" />
                <span>{ar ? 'تاريخ ووقت التنفيذ' : 'Timestamp'}</span>
              </div>
              <p className="font-semibold text-xs text-ui-text">
                {new Date(item.created_at).toLocaleString(ar ? 'ar-EG' : 'en')}
              </p>
            </div>
          </div>

          {/* Structured Details Breakdown */}
          <div className="rounded-xl border border-ui-border bg-ui-surface p-4">
            <h3 className="text-xs font-bold uppercase tracking-wider text-ui-muted mb-3 flex items-center gap-1.5">
              <Info className="h-4 w-4" />
              {ar ? 'بيانات وحقول العملية (Details)' : 'Event Payload & Changes'}
            </h3>

            {Object.keys(cleanDetails).length === 0 ? (
              <p className="text-xs text-ui-muted italic py-2">
                {ar ? 'لا توجد تفاصيل إضافية مسجلة لهذه العملية' : 'No additional parameters logged'}
              </p>
            ) : (
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs">
                {Object.entries(cleanDetails).map(([key, val]) => (
                  <div
                    key={key}
                    className="rounded-lg border border-ui-border bg-ui-page-alt p-2.5"
                  >
                    <span className="text-[11px] font-semibold text-ui-muted block font-mono">
                      {key}:
                    </span>
                    <span className="text-xs font-medium text-ui-text break-words">
                      {typeof val === 'object' && val !== null
                        ? JSON.stringify(val)
                        : String(val)}
                    </span>
                  </div>
                ))}
              </div>
            )}

            {/* Raw JSON toggle */}
            <div className="mt-4 pt-3 border-t border-ui-border">
              <div className="flex items-center justify-between">
                <button
                  type="button"
                  onClick={() => setShowRawJson(!showRawJson)}
                  className="text-xs font-semibold text-ui-primary hover:underline flex items-center gap-1"
                >
                  <FileCode className="h-3.5 w-3.5" />
                  {showRawJson
                    ? (ar ? 'إخفاء كود JSON الخام' : 'Hide raw JSON')
                    : (ar ? 'عرض كود JSON الخام' : 'Inspect raw JSON')}
                </button>
                <Button size="sm" variant="outline" onClick={copyJson} className="h-7 text-xs">
                  <Copy className="h-3.5 w-3.5" />
                  {ar ? 'نسخ السجل' : 'Copy Record'}
                </Button>
              </div>

              {showRawJson && (
                <pre className="mt-2.5 max-h-48 overflow-y-auto rounded-lg bg-ui-page-alt p-3 text-[11px] font-mono text-ui-text border border-ui-border">
                  {JSON.stringify(item, null, 2)}
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
