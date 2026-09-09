import { useMemo } from 'react';
import {
  Utensils,
  Clock,
  ArrowRightLeft,
  ChefHat,
  Banknote,
  Pause,
  Printer,
  UserPlus,
  ShoppingBag,
  Bike,
  User,
  Lock,
} from 'lucide-react';
import { useLanguage } from '@/context/LanguageContext';
import { formatCurrency } from '@/lib/format';
import type { DiningTable, OrderType } from '@/lib/types';
import type { OrderKitchenSend } from '../../types';
import { orderTypeLabel } from '../../utils/format';
import { usePosPermissions } from '../../hooks/usePosPermissions';

interface PosOrderHeaderBarProps {
  orderNumber: string | null;
  orderId: string | null;
  activeTable: DiningTable | null;
  orderType: OrderType;
  itemsCount: number;
  total: number;
  currency: string;
  createdAt: string | null;
  kitchenSends: OrderKitchenSend[];
  kitchenSending: boolean;
  completing: boolean;
  hasUnsentItems: boolean;
  customerName?: string | null;
  cashierName?: string | null;
  isReadOnly?: boolean;
  onOpenTransferModal?: () => void;
  onOpenCustomer: () => void;
  onHoldOrder: () => void;
  onSendKitchen: () => void;
  onPrint: () => void;
  onPay: () => void;
}

export function PosOrderHeaderBar({
  orderNumber,
  orderId,
  activeTable,
  orderType,
  itemsCount,
  total,
  currency,
  createdAt,
  kitchenSends,
  kitchenSending,
  completing,
  hasUnsentItems,
  customerName,
  cashierName,
  isReadOnly,
  onOpenTransferModal,
  onOpenCustomer,
  onHoldOrder,
  onSendKitchen,
  onPrint,
  onPay,
}: PosOrderHeaderBarProps) {
  const { t, lang } = useLanguage();
  const isAr = lang === 'ar';
  const perms = usePosPermissions();

  const elapsedText = useMemo(() => {
    if (!createdAt) return null;
    const diff = Math.max(1, Math.round((Date.now() - new Date(createdAt).getTime()) / (1000 * 60)));
    return isAr ? `منذ ${diff} دقيقة` : `${diff}m ago`;
  }, [createdAt, isAr]);

  const hasSent = kitchenSends.length > 0;

  return (
    <div data-testid="pos-top-action-bar" className="flex flex-wrap items-center justify-between gap-2 border-b border-ui-border bg-ui-page px-3 py-2 text-xs select-none">
      <div className="flex items-center gap-2 flex-wrap min-w-0">
        {activeTable ? (
          <div className="flex items-center gap-1.5 rounded-xl bg-ui-primary px-2.5 py-1 text-ui-primary-fg font-black shadow-ui-xs shrink-0">
            <Utensils className="h-3.5 w-3.5" />
            <span>{activeTable.name}</span>
          </div>
        ) : (
          <div className="flex items-center gap-1.5 rounded-xl bg-ui-page-alt border border-ui-border px-2.5 py-1 text-ui-text font-black shrink-0">
            {orderType === 'delivery' ? <Bike className="h-3.5 w-3.5" /> : <ShoppingBag className="h-3.5 w-3.5" />}
            <span>{orderTypeLabel(t, orderType)}</span>
          </div>
        )}
        <div className="flex items-center gap-1 text-ui-text font-black">
          <span>{orderNumber ? `#${orderNumber}` : t('newOrder')}</span>
        </div>
        <span className="text-ui-muted">·</span>
        <span className="text-ui-muted font-bold">{itemsCount} {isAr ? 'صنف' : 'items'}</span>
        <span className="text-ui-muted">·</span>
        <span className="text-ui-text font-black tabular-nums">{formatCurrency(total, currency, lang)}</span>
        {cashierName && (
          <>
            <span className="text-ui-muted">·</span>
            <span className="flex items-center gap-1 rounded-md bg-ui-page-alt px-1.5 py-0.5 text-[10px] font-bold text-ui-text border border-ui-border">
              <User className="h-3 w-3 text-ui-muted" />
              <span>{cashierName}</span>
            </span>
          </>
        )}
        {isReadOnly && (
          <span className="flex items-center gap-1 rounded-md bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-black text-amber-700 dark:text-amber-400 border border-amber-500/30">
            <Lock className="h-3 w-3" />
            <span>{isAr ? 'عرض فقط' : 'Read-only'}</span>
          </span>
        )}
        {elapsedText && <><span className="text-ui-muted">·</span><span className="flex items-center gap-1 text-ui-subtle font-semibold"><Clock className="h-3 w-3" />{elapsedText}</span></>}
        {hasSent && (
          <span className={`flex items-center gap-1 rounded-lg px-2 py-0.5 text-[10px] font-black border ${hasUnsentItems ? 'bg-amber-500/15 text-amber-700 border-amber-500/30 animate-pulse' : 'bg-sky-500/10 text-sky-600 border-sky-500/20'}`}>
            <ChefHat className="h-3 w-3" />
            {hasUnsentItems ? (isAr ? 'تعديلات جديدة' : 'New Additions') : (isAr ? 'تم الإرسال' : 'Sent to Kitchen')}
          </span>
        )}
      </div>

      <div className="flex items-center gap-1.5 flex-wrap shrink-0">
        {!isReadOnly && perms.canManageCustomer && perms.canEditOrder && (
          <button
            data-testid="pos-top-action-customer"
            type="button"
            onClick={onOpenCustomer}
            className="flex items-center gap-1 rounded-xl border border-ui-border bg-ui-surface px-2.5 py-1.5 font-black text-ui-text hover:border-ui-primary hover:text-ui-primary hover:bg-ui-primary-soft transition active:scale-95 shadow-ui-xs"
          >
            <UserPlus className="h-3.5 w-3.5 text-ui-primary" />
            <span className="max-w-[140px] truncate">{customerName || (isAr ? 'إضافة عميل' : 'Customer')}</span>
          </button>
        )}

        {perms.canTransferOrder && orderId && onOpenTransferModal && (
          <button
            data-testid="pos-top-action-merge-transfer"
            type="button"
            onClick={onOpenTransferModal}
            title={isAr ? 'نقل الطاولة أو تحويل مسؤولية الطلب لموظف آخر' : 'Transfer table or reassign order staff'}
            className="flex items-center gap-1 rounded-xl border border-ui-border bg-ui-surface px-2.5 py-1.5 font-black text-ui-text hover:border-ui-primary hover:text-ui-primary hover:bg-ui-primary-soft transition active:scale-95 shadow-ui-xs"
          >
            <ArrowRightLeft className="h-3.5 w-3.5 text-ui-primary" />
            <span className="hidden sm:inline">{isAr ? 'نقل / إدارة' : 'Transfer'}</span>
          </button>
        )}

        {perms.canPrintKitchen && itemsCount > 0 && (
          <button
            data-testid="pos-action-print"
            type="button"
            onClick={onPrint}
            className="flex items-center gap-1 rounded-xl border border-ui-border bg-ui-surface px-2.5 py-1.5 font-black text-ui-text hover:bg-ui-page-alt transition active:scale-95 shadow-ui-xs"
          >
            <Printer className="h-3.5 w-3.5 text-ui-primary" />
            <span className="hidden sm:inline">{isAr ? 'طباعة' : 'Print'}</span>
          </button>
        )}

        {!isReadOnly && perms.canHoldOrder && itemsCount > 0 && (
          <button
            data-testid="pos-action-hold"
            type="button"
            onClick={onHoldOrder}
            className="flex items-center gap-1 rounded-xl border border-ui-border bg-ui-surface px-2.5 py-1.5 font-black text-ui-text hover:bg-ui-page-alt transition active:scale-95 shadow-ui-xs"
          >
            <Pause className="h-3.5 w-3.5 text-amber-600" />
            <span className="hidden sm:inline">{isAr ? 'تعليق' : 'Hold'}</span>
          </button>
        )}

        {!isReadOnly && perms.canSendKitchen && itemsCount > 0 && (
          <button
            data-testid="pos-action-send-kitchen"
            type="button"
            onClick={onSendKitchen}
            disabled={kitchenSending}
            className="flex items-center gap-1 rounded-xl bg-amber-500 px-2.5 py-1.5 font-black text-xs text-white transition hover:bg-amber-600 active:scale-95 shadow-ui-xs shadow-amber-500/20 disabled:cursor-wait disabled:opacity-50"
          >
            <ChefHat className="h-3.5 w-3.5" />
            <span>{kitchenSending ? (isAr ? 'جارٍ الإرسال...' : 'Sending...') : hasSent ? (isAr ? 'إرسال الجديد' : 'Send New') : (isAr ? 'إرسال للمطبخ' : 'Kitchen')}</span>
          </button>
        )}

        {!isReadOnly && perms.canPay && itemsCount > 0 && (
          <button
            data-testid="pos-action-pay"
            type="button"
            onClick={onPay}
            disabled={completing}
            className="flex items-center gap-1 rounded-xl bg-emerald-600 text-white hover:bg-emerald-700 px-3 py-1.5 font-black text-xs transition active:scale-95 shadow-ui-xs disabled:opacity-40"
          >
            <Banknote className="h-3.5 w-3.5" />
            <span>{isAr ? 'دفع' : 'Pay'}</span>
          </button>
        )}
      </div>
    </div>
  );
}
