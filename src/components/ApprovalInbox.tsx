import { useCallback, useEffect, useState } from 'react';
import { Bell, Check, X } from 'lucide-react';
import { supabase } from '@/api';
import { useAuth } from '@/context/AuthContext';

type ApprovalRequest = {
  id: string;
  action_type: string;
  entity_type: string;
  entity_id: string | null;
  payload: Record<string, unknown>;
  reason: string;
  status: string;
  created_at: string;
  requester_id: string;
};

const labels: Record<string, { ar: string; en: string }> = {
  discount: { ar: 'طلب خصم', en: 'Discount request' },
  reprint: { ar: 'إعادة طباعة', en: 'Reprint request' },
  void_order: { ar: 'إلغاء طلب', en: 'Void order' },
  cancel_sent_item: { ar: 'إلغاء صنف مُرسل', en: 'Cancel sent item' },
  refund: { ar: 'مرتجع', en: 'Refund request' },
  open_drawer: { ar: 'فتح درج النقدية', en: 'Open cash drawer' },
  change_payment_method: { ar: 'تغيير وسيلة الدفع', en: 'Change payment method' },
  force_close_shift: { ar: 'إغلاق وردية إجباري', en: 'Force close shift' },
};

export function ApprovalInbox({ ar }: { ar: boolean }) {
  const { user } = useAuth();
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<ApprovalRequest[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
 const allowed =
  user?.role === 'branch_manager' ||
  user?.role === 'owner' ||
  user?.role === 'super_admin';

  const load = useCallback(async () => {
    if (!allowed || !user?.branch_id) return;
    const { data } = await supabase
      .from('approval_requests')
      .select('id,action_type,entity_type,entity_id,payload,reason,status,created_at,requester_id,expires_at')
      .eq('branch_id', user.branch_id)
      .eq('status', 'pending')
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(30);
    setItems((data ?? []) as ApprovalRequest[]);
  }, [allowed, user?.branch_id]);

  useEffect(() => {
    void load();
    if (!allowed || !user?.branch_id) return;
    const channel = supabase
      .channel(`approval-inbox-${user.branch_id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'approval_requests', filter: `branch_id=eq.${user.branch_id}` },
        () => void load(),
      )
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [allowed, user?.branch_id, load]);

  const decide = async (id: string, approve: boolean) => {
    setBusy(id);
    try {
      await supabase.rpc('decide_manager_approval', {
        p_request_id: id,
        p_approve: approve,
        p_note: null,
      });
      await load();
    } finally {
      setBusy(null);
    }
  };

  if (!allowed) return null;

  return (
    <div className="relative">
      <button
        type="button"
        data-testid="approval-inbox-button"
        onClick={() => setOpen((v) => !v)}
        className="relative rounded-xl p-2 text-ui-muted transition-colors hover:bg-ui-page-alt hover:text-ui-text"
        aria-label={ar ? 'طلبات الموافقة' : 'Approval requests'}
      >
        <Bell className="h-5 w-5" />
        {items.length > 0 && (
          <span data-testid="approval-inbox-count" className="absolute -end-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-ui-danger px-1 text-[9px] font-bold text-ui-primary-fg">
            {items.length}
          </span>
        )}
      </button>

      {open && (
        <div data-testid="approval-inbox-panel" className="absolute end-0 top-full z-[80] mt-2 w-[min(92vw,390px)] overflow-hidden rounded-xl border border-ui-border bg-ui-surface shadow-ui-lg">
          <div className="border-b border-ui-border px-4 py-3">
            <p className="font-semibold text-ui-text">{ar ? 'طلبات موافقة الكاشير' : 'Cashier approval requests'}</p>
            <p className="text-xs text-ui-muted">{ar ? 'الطلبات تنتهي تلقائيًا بعد 10 دقائق' : 'Requests expire automatically after 10 minutes'}</p>
          </div>
          <div className="max-h-96 overflow-y-auto p-2">
            {items.length === 0 ? (
              <p className="px-3 py-6 text-center text-sm text-ui-muted">{ar ? 'لا توجد طلبات معلّقة' : 'No pending requests'}</p>
            ) : items.map((item) => {
              const label = labels[item.action_type];
              return (
                <div key={item.id} className="mb-2 rounded-xl border border-ui-border bg-ui-page-alt p-3 last:mb-0">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="font-semibold text-ui-text">{label ? (ar ? label.ar : label.en) : item.action_type}</p>
                      <p className="mt-1 text-sm text-ui-muted">{item.reason}</p>
                      {item.action_type === 'discount' && (
                        <p className="mt-1 text-xs text-ui-subtle">
                          {ar ? 'قيمة الخصم: ' : 'Discount: '}
                          {String(item.payload.discount_amount ?? '')}
                        </p>
                      )}
                    </div>
                    <span className="shrink-0 text-[10px] text-ui-subtle">
                      {new Date(item.created_at).toLocaleTimeString(ar ? 'ar-EG' : 'en-US', { hour: '2-digit', minute: '2-digit' })}
                    </span>
                  </div>
                  <div className="mt-3 flex gap-2">
                    <button type="button" disabled={busy === item.id} onClick={() => void decide(item.id, true)} className="flex flex-1 items-center justify-center gap-1.5 rounded-lg bg-ui-success px-3 py-2 text-sm font-semibold text-ui-primary-fg disabled:opacity-50">
                      <Check className="h-4 w-4" />{ar ? 'موافقة' : 'Approve'}
                    </button>
                    <button type="button" disabled={busy === item.id} onClick={() => void decide(item.id, false)} className="flex flex-1 items-center justify-center gap-1.5 rounded-lg bg-ui-danger px-3 py-2 text-sm font-semibold text-ui-primary-fg disabled:opacity-50">
                      <X className="h-4 w-4" />{ar ? 'رفض' : 'Reject'}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
