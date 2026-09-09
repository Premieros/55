import { useState } from 'react';
import { AlertTriangle, X } from 'lucide-react';
import { Button } from '@/components/Button';
import { Input } from '@/components/Input';

interface RejectReasonModalProps {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: (reason: string) => void;
  title: string;
  sourceTypeLabel?: string;
  ar: boolean;
}

const PRESET_REASONS = {
  ar: [
    'تجاوز الحد المالي أو نسبة الخصم المسموحة',
    'طلب غير مبرر تشغيلياً',
    'عدم اكتمال المستندات أو البيانات المطلوبة',
    'مخالفة لسياسات الفرع المعتمدة',
    'يتطلب مراجعة واعتماد الإدارة العليا',
  ],
  en: [
    'Exceeds authorized financial or discount limit',
    'Operationally unjustified request',
    'Incomplete documentation or required details',
    'Violates branch operational policies',
    'Requires review and decision by senior management',
  ],
};

export function RejectReasonModal({
  isOpen,
  onClose,
  onConfirm,
  title,
  sourceTypeLabel,
  ar,
}: RejectReasonModalProps) {
  const [selectedPreset, setSelectedPreset] = useState<string>('');
  const [customReason, setCustomReason] = useState<string>('');

  if (!isOpen) return null;

  const presets = ar ? PRESET_REASONS.ar : PRESET_REASONS.en;
  const finalReason = (customReason.trim() || selectedPreset).trim();

  const handleConfirm = () => {
    if (!finalReason) return;
    onConfirm(finalReason);
    setCustomReason('');
    setSelectedPreset('');
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      data-testid="reject-reason-modal"
    >
      <div className="w-full max-w-lg rounded-2xl border border-ui-border bg-ui-surface p-6 shadow-2xl animate-in fade-in zoom-in-95 duration-150">
        <div className="flex items-center justify-between border-b border-ui-border pb-4">
          <div className="flex items-center gap-2 text-ui-danger">
            <AlertTriangle className="h-6 w-6" />
            <h2 className="text-lg font-bold text-ui-text">
              {ar ? 'رفض طلب الاعتماد' : 'Reject Approval Request'}
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-ui-muted hover:bg-ui-page-alt hover:text-ui-text transition-colors"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="mt-4 space-y-4">
          <div className="rounded-xl border border-ui-danger-soft bg-ui-danger-soft/20 p-3 text-sm text-ui-text">
            <span className="font-semibold text-ui-danger">
              {sourceTypeLabel ? `[${sourceTypeLabel}] ` : ''}
            </span>
            <span>{title}</span>
          </div>

          <div>
            <label className="block text-xs font-semibold text-ui-muted mb-2">
              {ar ? 'أسباب شائعة للرفض السريع:' : 'Quick Select Preset Reasons:'}
            </label>
            <div className="space-y-1.5">
              {presets.map((preset) => (
                <button
                  key={preset}
                  type="button"
                  onClick={() => {
                    setSelectedPreset(preset);
                    setCustomReason('');
                  }}
                  className={`w-full rounded-lg border p-2.5 text-start text-xs font-medium transition-all ${
                    selectedPreset === preset && !customReason
                      ? 'border-ui-danger bg-ui-danger-soft/40 text-ui-danger font-bold'
                      : 'border-ui-border bg-ui-page-alt hover:border-ui-muted text-ui-text'
                  }`}
                >
                  • {preset}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="block text-xs font-semibold text-ui-muted mb-1">
              {ar ? 'أو اكتب سبب الرفض بالتفصيل (إلزامي):' : 'Or enter custom rejection reason (Required):'}
            </label>
            <Input
              value={customReason}
              onChange={(e) => {
                setCustomReason(e.target.value);
                if (e.target.value) setSelectedPreset('');
              }}
              placeholder={ar ? 'اذكر سبب الرفض ليظهر للموظف مقدم الطلب...' : 'Enter reason to display to the requester...'}
              className="w-full"
            />
          </div>
        </div>

        <div className="mt-6 flex items-center justify-end gap-2 border-t border-ui-border pt-4">
          <Button variant="secondary" onClick={onClose}>
            {ar ? 'إلغاء' : 'Cancel'}
          </Button>
          <Button
            variant="danger"
            disabled={!finalReason}
            onClick={handleConfirm}
          >
            {ar ? 'تأكيد الرفض' : 'Confirm Rejection'}
          </Button>
        </div>
      </div>
    </div>
  );
}
