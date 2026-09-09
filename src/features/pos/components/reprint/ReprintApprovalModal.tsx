import { useState, useEffect, useCallback } from 'react';
import { ShieldAlert, Printer, CheckCircle2, Clock, Check, X, AlertTriangle } from 'lucide-react';
import { Modal } from '@/components/Modal';
import { Button } from '@/components/Button';
import { useLanguage } from '@/context/LanguageContext';
import { useAuth } from '@/context/AuthContext';
import { useToast } from '@/components/Toast';
import { supabase } from '@/api';
import type { ReceiptData } from '../../utils/printing';
import { formatCurrency } from '@/lib/format';

interface ReprintApprovalModalProps {
  isOpen: boolean;
  onClose: () => void;
  receipt: ReceiptData | null;
  onAuthorizedPrint: () => Promise<void>;
  currency?: string;
}

export function ReprintApprovalModal({
  isOpen,
  onClose,
  receipt,
  onAuthorizedPrint,
  currency = 'EGP',
}: ReprintApprovalModalProps) {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';
  const { user } = useAuth();
  const { show } = useToast();

  const [loading, setLoading] = useState(false);
  const [requestStatus, setRequestStatus] = useState<'none' | 'pending' | 'approved' | 'rejected'>('none');
  const [requestId, setRequestId] = useState<string | null>(null);
  const [managerApproving, setManagerApproving] = useState(false);

  const isManagerOrAbove =
    user?.role === 'branch_manager' ||
    user?.role === 'owner' ||
    user?.role === 'super_admin';

  // Check if there is an active approval request for this sale
  const checkExistingApproval = useCallback(async () => {
    if (!receipt?.invoice) return;
    setLoading(true);
    try {
      const { data: sale } = await supabase
        .from('sales')
        .select('id')
        .eq('invoice_number', receipt.invoice)
        .maybeSingle();

      if (!sale?.id) return;

      const nowIso = new Date().toISOString();
      const { data: req } = await supabase
        .from('approval_requests')
        .select('id,status,expires_at')
        .eq('action_type', 'reprint')
        .eq('entity_type', 'sale')
        .eq('entity_id', sale.id)
        .in('status', ['pending', 'approved', 'rejected'])
        .gt('expires_at', nowIso)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (req) {
        setRequestId(req.id);
        setRequestStatus(req.status as 'pending' | 'approved' | 'rejected');
      } else {
        setRequestStatus('none');
        setRequestId(null);
      }
    } catch (err) {
      console.error('Error checking reprint approval:', err);
    } finally {
      setLoading(false);
    }
  }, [receipt?.invoice]);

  useEffect(() => {
    if (isOpen) {
      void checkExistingApproval();
    }
  }, [isOpen, checkExistingApproval]);

  // Realtime subscription to approval request
  useEffect(() => {
    if (!isOpen || !requestId) return;

    const channel = supabase
      .channel(`reprint-approval-${requestId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'approval_requests', filter: `id=eq.${requestId}` },
        (payload) => {
          const next = payload.new as { status?: string };
          if (next.status === 'approved') {
            setRequestStatus('approved');
            show(isAr ? 'وافق المدير على إعادة الطباعة!' : 'Reprint approved by manager!', 'success');
          } else if (next.status === 'rejected') {
            setRequestStatus('rejected');
            show(isAr ? 'رفض المدير طلب إعادة الطباعة' : 'Reprint request rejected', 'error');
          }
        }
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [isOpen, requestId, isAr, show]);

  // Cashier sends a request to manager
  const handleRequestApproval = async () => {
    if (!receipt?.invoice) return;
    setLoading(true);
    try {
      const { data: sale } = await supabase
        .from('sales')
        .select('id, branch_id')
        .eq('invoice_number', receipt.invoice)
        .maybeSingle();

      if (!sale?.id) {
        show(isAr ? 'لم يتم العثور على الفاتورة' : 'Sale not found', 'error');
        return;
      }

      const { data, error } = await supabase.rpc('request_manager_approval', {
        p_action_type: 'reprint',
        p_entity_type: 'sale',
        p_entity_id: sale.id,
        p_payload: {
          invoice_number: receipt.invoice,
          total: receipt.total,
        },
        p_reason: `طلب إعادة طباعة إيصال للعميل: ${receipt.invoice}`,
      });

      if (error) {
        show(error.message, 'error');
        return;
      }

      const res = data as { success?: boolean; request_id?: string; error?: string } | null;
      if (!res?.success) {
        show(res?.error || (isAr ? 'تعذر إرسال الطلب' : 'Failed to request approval'), 'error');
        return;
      }

      setRequestId(res.request_id || null);
      setRequestStatus('pending');
      show(
        isAr
          ? 'تم إرسال طلب إعادة الطباعة للمدير. يرجى الانتظار حتى تتم الموافقة.'
          : 'Reprint request submitted to manager. Awaiting approval.',
        'success'
      );
    } catch (err) {
      show(err instanceof Error ? err.message : 'Error requesting reprint', 'error');
    } finally {
      setLoading(false);
    }
  };

  // Immediate approval if user has manager role
  const handleDirectManagerApproval = async () => {
    if (!receipt?.invoice) return;
    setManagerApproving(true);
    try {
      const { data: sale } = await supabase
        .from('sales')
        .select('id')
        .eq('invoice_number', receipt.invoice)
        .maybeSingle();

      if (!sale?.id) return;

      // 1. Create approval request
      const { data: reqData, error: reqErr } = await supabase.rpc('request_manager_approval', {
        p_action_type: 'reprint',
        p_entity_type: 'sale',
        p_entity_id: sale.id,
        p_payload: {
          invoice_number: receipt.invoice,
          total: receipt.total,
          direct_approval: true,
        },
        p_reason: `موافقة مباشرة من المدير على إعادة الطباعة: ${receipt.invoice}`,
      });

      if (reqErr) {
        show(reqErr.message, 'error');
        return;
      }

      const reqRes = reqData as { success?: boolean; request_id?: string } | null;
      const targetReqId = reqRes?.request_id;

      if (targetReqId) {
        // 2. Decide and approve immediately
        await supabase.rpc('decide_manager_approval', {
          p_request_id: targetReqId,
          p_approve: true,
          p_note: 'موافقة فورية من شاشة الكاشير',
        });
      }

      setRequestStatus('approved');
      show(isAr ? 'تمت موافقة المدير! جاري الطباعة...' : 'Approved! Printing...', 'success');

      // Execute authorized print
      await onAuthorizedPrint();
      onClose();
    } catch (err) {
      show(err instanceof Error ? err.message : 'Approval error', 'error');
    } finally {
      setManagerApproving(false);
    }
  };

  // Perform approved print
  const handleExecuteApprovedPrint = async () => {
    setLoading(true);
    try {
      await onAuthorizedPrint();
      show(isAr ? 'تمت طباعة النسخة المصرّح بها بنجاح' : 'Authorized reprint completed', 'success');
      onClose();
    } catch (err) {
      show(err instanceof Error ? err.message : 'Print error', 'error');
    } finally {
      setLoading(false);
    }
  };

  if (!receipt) return null;

  return (
    <Modal
      open={isOpen}
      onClose={onClose}
      title={isAr ? 'طلب موافقة لإعادة الطباعة' : 'Reprint Approval Required'}
      size="md"
    >
      <div className="space-y-4">
        {/* Security Warning Banner */}
        <div className="flex items-start gap-3 p-3.5 rounded-xl bg-amber-500/10 border border-amber-500/25 text-amber-900 dark:text-amber-200">
          <AlertTriangle className="w-5 h-5 shrink-0 text-amber-600 dark:text-amber-400 mt-0.5" />
          <div className="text-xs space-y-1 leading-relaxed">
            <p className="font-bold text-sm">
              {isAr ? 'تنبيه أمني: الإيصال تمت طباعته مسبقاً' : 'Security Notice: Receipt Already Printed'}
            </p>
            <p>
              {isAr
                ? 'تُطبع الفاتورة للعميل مرة واحدة فقط عند إتمام البيع. تكرار الطباعة يتطلب موافقة المدير لحماية الإيرادات ومنع أي ازدواجية في الفواتير.'
                : 'Invoices can only be printed once upon sale completion. Multiple prints require manager approval to protect revenue.'}
            </p>
          </div>
        </div>

        {/* Invoice Summary */}
        <div className="p-3 rounded-xl bg-ui-card-subtle border border-ui-border text-xs space-y-2">
          <div className="flex justify-between">
            <span className="text-ui-muted">{isAr ? 'رقم الفاتورة:' : 'Invoice:'}</span>
            <span className="font-bold text-ui-text">#{receipt.invoice}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-ui-muted">{isAr ? 'إجمالي الفاتورة:' : 'Total:'}</span>
            <span className="font-bold text-brand-600 dark:text-brand-400">
              {formatCurrency(receipt.total, currency, lang)}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-ui-muted">{isAr ? 'الفرع:' : 'Branch:'}</span>
            <span className="text-ui-text">{receipt.branchName}</span>
          </div>
        </div>

        {/* Status Indicator */}
        {requestStatus === 'pending' && (
          <div className="flex items-center gap-2 p-3 rounded-xl bg-blue-500/10 border border-blue-500/25 text-blue-700 dark:text-blue-300 text-xs">
            <Clock className="w-4 h-4 animate-spin text-blue-600" />
            <span className="font-semibold">
              {isAr
                ? 'طلب الموافقة قيد انتظار المدير حالياً... سيتم تمكين الطباعة فور الموافقة.'
                : 'Approval pending manager review... Printing will unlock upon approval.'}
            </span>
          </div>
        )}

        {requestStatus === 'approved' && (
          <div className="flex items-center gap-2 p-3 rounded-xl bg-emerald-500/10 border border-emerald-500/25 text-emerald-700 dark:text-emerald-300 text-xs">
            <CheckCircle2 className="w-4 h-4 text-emerald-600" />
            <span className="font-semibold">
              {isAr
                ? 'تمت الموافقة على إعادة الطباعة لمرة واحدة بنجاح!'
                : 'Manager approved this one-time reprint!'}
            </span>
          </div>
        )}

        {requestStatus === 'rejected' && (
          <div className="flex items-center gap-2 p-3 rounded-xl bg-rose-500/10 border border-rose-500/25 text-rose-700 dark:text-rose-300 text-xs">
            <X className="w-4 h-4 text-rose-600" />
            <span className="font-semibold">
              {isAr
                ? 'تم رفض طلب إعادة الطباعة من قِبل المدير.'
                : 'Reprint request was rejected by manager.'}
            </span>
          </div>
        )}

        {/* Action Buttons */}
        <div className="flex flex-col gap-2 pt-2">
          {requestStatus === 'approved' ? (
            <Button
              onClick={() => void handleExecuteApprovedPrint()}
              disabled={loading}
              className="w-full bg-emerald-600 hover:bg-emerald-700 text-white font-bold py-2.5"
            >
              <Printer className="w-4 h-4" />
              <span>{isAr ? 'طباعة النسخة المصرّح بها الآن' : 'Print Authorized Copy Now'}</span>
            </Button>
          ) : requestStatus === 'pending' ? (
            <div className="flex gap-2">
              <Button
                variant="secondary"
                onClick={() => void checkExistingApproval()}
                disabled={loading}
                className="flex-1 text-xs"
              >
                {isAr ? 'تحديث حالة الطلب' : 'Check Status'}
              </Button>
              {isManagerOrAbove && (
                <Button
                  onClick={() => void handleDirectManagerApproval()}
                  disabled={managerApproving}
                  className="flex-1 bg-brand-600 text-white text-xs font-bold"
                >
                  <Check className="w-4 h-4" />
                  <span>{isAr ? 'موافقة وطباعة كمدير' : 'Approve & Print as Manager'}</span>
                </Button>
              )}
            </div>
          ) : (
            <div className="space-y-2">
              <Button
                onClick={() => void handleRequestApproval()}
                disabled={loading}
                className="w-full bg-brand-600 hover:bg-brand-700 text-white font-bold py-2.5 text-xs"
              >
                <ShieldAlert className="w-4 h-4" />
                <span>{isAr ? 'إرسال طلب موافقة للمدير' : 'Send Approval Request to Manager'}</span>
              </Button>

              {isManagerOrAbove && (
                <Button
                  variant="outline"
                  onClick={() => void handleDirectManagerApproval()}
                  disabled={managerApproving}
                  className="w-full text-xs font-bold border-brand-500/40 text-brand-600 hover:bg-brand-500/10"
                >
                  <Check className="w-4 h-4" />
                  <span>{isAr ? 'الموافقة المباشرة كمدير / مشرف' : 'Authorize Immediately as Manager'}</span>
                </Button>
              )}
            </div>
          )}

          <Button variant="ghost" onClick={onClose} className="w-full text-xs text-ui-muted">
            {isAr ? 'إلغاء' : 'Cancel'}
          </Button>
        </div>
      </div>
    </Modal>
  );
}
