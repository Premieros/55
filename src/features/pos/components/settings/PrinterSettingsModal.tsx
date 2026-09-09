import { Modal } from '@/components/Modal';
import { useLanguage } from '@/context/LanguageContext';
import { PrinterSettingsPanel } from './PrinterSettingsPanel';

interface PrinterSettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  branchId: string;
  branchName?: string;
}

export function PrinterSettingsModal({
  isOpen,
  onClose,
  branchId,
  branchName,
}: PrinterSettingsModalProps) {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';

  return (
    <Modal
      open={isOpen}
      onClose={onClose}
      title={isAr ? 'إعدادات الطباعة السريعة والصامتة' : 'Fast & Silent Printing Settings'}
      size="xl"
    >
      <div className="max-h-[75vh] overflow-y-auto px-1 py-1">
        <PrinterSettingsPanel branchId={branchId} branchName={branchName} />
      </div>
    </Modal>
  );
}
