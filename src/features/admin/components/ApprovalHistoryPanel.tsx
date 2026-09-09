import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  CheckCircle2,
  Clock,
  Download,
  Eye,
  RefreshCw,
  Search,
  ShieldCheck,
  XCircle,
} from 'lucide-react';
import { supabase } from '@/api';
import { Button } from '@/components/Button';
import { Input, Select } from '@/components/Input';
import { DesignPanel } from '@/components/design/DesignPanel';
import {
  ApprovalDetailsModal,
  ApprovalHistoryItem,
} from './ApprovalDetailsModal';

interface ApprovalHistoryPanelProps {
  ar: boolean;
  branchId: string;
  branches: Array<{ id: string; name: string }>;
}

const ACTION_LABELS: Record<string, { ar: string; en: string }> = {
  discount: { ar: 'طلب خصم كاشير', en: 'Cashier Discount' },
  reprint: { ar: 'إعادة طباعة فاتورة', en: 'Receipt Reprint' },
  void_order: { ar: 'إلغاء طلب معتمد', en: 'Void Order' },
  cancel_sent_item: { ar: 'إلغاء صنف للمطبخ', en: 'Cancel Sent Item' },
  refund: { ar: 'استرجاع مالي / مرتجع', en: 'Order Refund' },
  open_drawer: { ar: 'فتح درج النقدية', en: 'Open Drawer' },
  change_payment_method: { ar: 'تعديل وسيلة الدفع', en: 'Change Payment' },
  force_close_shift: { ar: 'إغلاق شيفت إجباري', en: 'Force Close Shift' },
  split_order: { ar: 'فصل طلب', en: 'Split Order' },
  merge_order: { ar: 'دمج طلب', en: 'Merge Order' },
  transfer_order: { ar: 'تحويل طاولة', en: 'Transfer Order' },
  waste: { ar: 'اعتماد هالك', en: 'Waste Entry' },
  stock_count: { ar: 'اعتماد جرد', en: 'Stock Count' },
  warehouse_transfer: { ar: 'مناقلة مستودع', en: 'Warehouse Transfer' },
};

export function ApprovalHistoryPanel({
  ar,
  branchId,
  branches,
}: ApprovalHistoryPanelProps) {
  const [items, setItems] = useState<ApprovalHistoryItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [actionFilter, setActionFilter] = useState('all');
  const [dateRange, setDateRange] = useState<'today' | '7days' | '30days' | 'all'>('30days');
  const [selectedDetail, setSelectedDetail] = useState<ApprovalHistoryItem | null>(null);

  const loadHistory = useCallback(async () => {
    setLoading(true);
    try {
      let query = supabase
        .from('approval_requests')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(300);

      if (branchId) {
        query = query.eq('branch_id', branchId);
      }

      if (dateRange === 'today') {
        const startOfDay = new Date();
        startOfDay.setHours(0, 0, 0, 0);
        query = query.gte('created_at', startOfDay.toISOString());
      } else if (dateRange === '7days') {
        const date7 = new Date();
        date7.setDate(date7.getDate() - 7);
        query = query.gte('created_at', date7.toISOString());
      } else if (dateRange === '30days') {
        const date30 = new Date();
        date30.setDate(date30.getDate() - 30);
        query = query.gte('created_at', date30.toISOString());
      }

      const [requestsRes, usersRes] = await Promise.all([
        query,
        supabase.from('users').select('id, full_name, email, role'),
      ]);

      const userMap = new Map((usersRes.data || []).map((u) => [u.id, u]));
      const branchMap = new Map(branches.map((b) => [b.id, b.name]));

      const mapped = ((requestsRes.data || []) as ApprovalHistoryItem[]).map((r) => {
        const requester = userMap.get(r.requester_id);
        const approver = r.approver_id ? userMap.get(r.approver_id) : null;
        return {
          ...r,
          requester_name: requester?.full_name || requester?.email || (ar ? 'غير محدد' : 'Unknown'),
          requester_role: requester?.role || '',
          approver_name: approver?.full_name || approver?.email || (r.approver_id ? (ar ? 'المدير' : 'Manager') : '-'),
          approver_role: approver?.role || '',
          branch_name: branchMap.get(r.branch_id) || (ar ? 'الفرع' : 'Branch'),
        };
      });

      setItems(mapped);
    } catch (err) {
      console.error('Failed to load approval requests history', err);
    } finally {
      setLoading(false);
    }
  }, [branchId, branches, dateRange, ar]);

  useEffect(() => {
    void loadHistory();
  }, [loadHistory]);

  // Real-time updates subscription
  useEffect(() => {
    const channel = supabase
      .channel('approval_requests_history_changes')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'approval_requests' },
        () => {
          void loadHistory();
        }
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [loadHistory]);

  const filteredItems = useMemo(() => {
    return items.filter((item) => {
      if (statusFilter !== 'all') {
        if (statusFilter === 'approved' && item.status !== 'approved') return false;
        if (statusFilter === 'consumed' && item.status !== 'consumed') return false;
        if (statusFilter === 'rejected' && item.status !== 'rejected') return false;
        if (statusFilter === 'expired' && item.status !== 'expired') return false;
        if (statusFilter === 'pending' && item.status !== 'pending') return false;
      }
      if (actionFilter !== 'all' && item.action_type !== actionFilter) {
        return false;
      }
      if (search.trim()) {
        const q = search.trim().toLowerCase();
        const inRequester = (item.requester_name || '').toLowerCase().includes(q);
        const inApprover = (item.approver_name || '').toLowerCase().includes(q);
        const inReason = (item.reason || '').toLowerCase().includes(q);
        const inNote = (item.decision_note || '').toLowerCase().includes(q);
        const inAction = (item.action_type || '').toLowerCase().includes(q);
        const inId = (item.id || '').toLowerCase().includes(q);
        if (!inRequester && !inApprover && !inReason && !inNote && !inAction && !inId) {
          return false;
        }
      }
      return true;
    });
  }, [items, statusFilter, actionFilter, search]);

  // KPI statistics calculation
  const stats = useMemo(() => {
    const total = items.length;
    const approved = items.filter((i) => i.status === 'approved' || i.status === 'consumed').length;
    const rejected = items.filter((i) => i.status === 'rejected').length;
    const expired = items.filter((i) => i.status === 'expired').length;
    const pending = items.filter((i) => i.status === 'pending').length;
    const approvalRate = total > 0 ? Math.round((approved / total) * 100) : 0;
    return { total, approved, rejected, expired, pending, approvalRate };
  }, [items]);

  const exportCsv = () => {
    const headers = [
      ar ? 'معرف الطلب' : 'Request ID',
      ar ? 'التاريخ والوقت' : 'Timestamp',
      ar ? 'الفرع' : 'Branch',
      ar ? 'نوع الإجراء' : 'Action Type',
      ar ? 'مقدم الطلب' : 'Requester',
      ar ? 'دور مقدم الطلب' : 'Requester Role',
      ar ? 'سبب الطلب' : 'Stated Reason',
      ar ? 'الحالة' : 'Status',
      ar ? 'المعتمد' : 'Approver',
      ar ? 'ملاحظة الاعتماد / سبب الرفض' : 'Decision Note',
      ar ? 'تاريخ القرار' : 'Decided At',
    ];

    const rows = filteredItems.map((i) => [
      i.id,
      new Date(i.created_at).toLocaleString(),
      i.branch_name || '',
      ACTION_LABELS[i.action_type]?.[ar ? 'ar' : 'en'] || i.action_type,
      i.requester_name || '',
      i.requester_role || '',
      `"${(i.reason || '').replace(/"/g, '""')}"`,
      i.status,
      i.approver_name || '',
      `"${(i.decision_note || '').replace(/"/g, '""')}"`,
      i.decided_at ? new Date(i.decided_at).toLocaleString() : '',
    ]);

    const csvContent =
      '\uFEFF' + [headers.join(','), ...rows.map((e) => e.join(','))].join('\n');
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', `approvals_audit_log_${new Date().toISOString().slice(0, 10)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const getStatusBadge = (status: string) => {
    switch (status) {
      case 'approved':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-bold text-emerald-600 dark:text-emerald-400">
            <CheckCircle2 className="h-3 w-3" />
            {ar ? 'معتمدة' : 'Approved'}
          </span>
        );
      case 'consumed':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-blue-500/10 px-2 py-0.5 text-xs font-bold text-blue-600 dark:text-blue-400">
            <CheckCircle2 className="h-3 w-3" />
            {ar ? 'مطبقة' : 'Consumed'}
          </span>
        );
      case 'rejected':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-rose-500/10 px-2 py-0.5 text-xs font-bold text-rose-600 dark:text-rose-400">
            <XCircle className="h-3 w-3" />
            {ar ? 'مرفوضة' : 'Rejected'}
          </span>
        );
      case 'expired':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/10 px-2 py-0.5 text-xs font-bold text-amber-600 dark:text-amber-400">
            <Clock className="h-3 w-3" />
            {ar ? 'منتهية' : 'Expired'}
          </span>
        );
      default:
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-slate-500/10 px-2 py-0.5 text-xs font-bold text-slate-600 dark:text-slate-400">
            <Clock className="h-3 w-3" />
            {ar ? 'معلقة' : 'Pending'}
          </span>
        );
    }
  };

  return (
    <div className="space-y-4" data-testid="approval-history-panel">
      {/* KPI Cards */}
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
        <div className="rounded-xl border border-ui-border bg-ui-surface p-3.5 shadow-xs">
          <span className="text-xs font-semibold text-ui-muted block">
            {ar ? 'إجمالي الطلبات' : 'Total Requests'}
          </span>
          <span className="text-2xl font-bold text-ui-text mt-1 block">
            {stats.total}
          </span>
        </div>

        <div className="rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-3.5 shadow-xs">
          <span className="text-xs font-semibold text-emerald-600 dark:text-emerald-400 block">
            {ar ? 'معتمدة ومطبقة' : 'Approved'}
          </span>
          <span className="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1 block">
            {stats.approved}
          </span>
        </div>

        <div className="rounded-xl border border-rose-500/20 bg-rose-500/5 p-3.5 shadow-xs">
          <span className="text-xs font-semibold text-rose-600 dark:text-rose-400 block">
            {ar ? 'مرفوضة' : 'Rejected'}
          </span>
          <span className="text-2xl font-bold text-rose-600 dark:text-rose-400 mt-1 block">
            {stats.rejected}
          </span>
        </div>

        <div className="rounded-xl border border-amber-500/20 bg-amber-500/5 p-3.5 shadow-xs">
          <span className="text-xs font-semibold text-amber-600 dark:text-amber-400 block">
            {ar ? 'منتهية الصلاحية' : 'Expired'}
          </span>
          <span className="text-2xl font-bold text-amber-600 dark:text-amber-400 mt-1 block">
            {stats.expired}
          </span>
        </div>

        <div className="col-span-2 sm:col-span-1 rounded-xl border border-ui-border bg-ui-surface p-3.5 shadow-xs">
          <span className="text-xs font-semibold text-ui-muted block">
            {ar ? 'معدل القبول' : 'Approval Rate'}
          </span>
          <span className="text-2xl font-bold text-ui-primary mt-1 block">
            {stats.approvalRate}%
          </span>
        </div>
      </div>

      {/* Filters Bar */}
      <DesignPanel>
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-3">
          <div className="flex flex-wrap items-center gap-2 flex-1">
            <div className="relative flex-1 min-w-[200px] max-w-xs">
              <Search className="absolute start-3 top-1/2 -translate-y-1/2 h-4 w-4 text-ui-muted" />
              <Input
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder={ar ? 'بحث بالموظف، المدير، السبب...' : 'Search requester, approver, reason...'}
                className="ps-9 h-9 text-xs"
              />
            </div>

            <Select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="h-9 text-xs min-w-[130px]"
            >
              <option value="all">{ar ? 'جميع الحالات' : 'All Statuses'}</option>
              <option value="approved">{ar ? 'معتمدة فقط' : 'Approved'}</option>
              <option value="consumed">{ar ? 'مطبقة ومستهلكة' : 'Consumed'}</option>
              <option value="rejected">{ar ? 'مرفوضة فقط' : 'Rejected'}</option>
              <option value="expired">{ar ? 'منتهية الصلاحية' : 'Expired'}</option>
              <option value="pending">{ar ? 'معلقة' : 'Pending'}</option>
            </Select>

            <Select
              value={actionFilter}
              onChange={(e) => setActionFilter(e.target.value)}
              className="h-9 text-xs min-w-[150px]"
            >
              <option value="all">{ar ? 'جميع أنواع الإجراءات' : 'All Action Types'}</option>
              {Object.entries(ACTION_LABELS).map(([k, v]) => (
                <option key={k} value={k}>
                  {ar ? v.ar : v.en}
                </option>
              ))}
            </Select>

            <Select
              value={dateRange}
              onChange={(e) => setDateRange(e.target.value as 'today' | '7days' | '30days' | 'all')}
              className="h-9 text-xs min-w-[120px]"
            >
              <option value="today">{ar ? 'اليوم فقط' : 'Today'}</option>
              <option value="7days">{ar ? 'آخر 7 أيام' : 'Last 7 Days'}</option>
              <option value="30days">{ar ? 'آخر 30 يوماً' : 'Last 30 Days'}</option>
              <option value="all">{ar ? 'كل الفترات' : 'All Time'}</option>
            </Select>
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={exportCsv}
              disabled={filteredItems.length === 0}
              className="h-9 text-xs"
            >
              <Download className="h-3.5 w-3.5" />
              {ar ? 'تصدير CSV' : 'Export CSV'}
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => void loadHistory()}
              disabled={loading}
              className="h-9 text-xs"
            >
              <RefreshCw className={`h-3.5 w-3.5 ${loading ? 'animate-spin' : ''}`} />
              {ar ? 'تحديث' : 'Refresh'}
            </Button>
          </div>
        </div>
      </DesignPanel>

      {/* History Data Table */}
      <DesignPanel title={ar ? 'سجل تتبع الموافقات التاريخي' : 'Approvals Audit Trail & History'}>
        {loading ? (
          <div className="p-8 text-center text-ui-muted text-sm">
            {ar ? 'جاري تحميل سجل الموافقات والاعتمادات...' : 'Loading approvals history...'}
          </div>
        ) : filteredItems.length === 0 ? (
          <div className="p-8 text-center text-ui-muted text-sm">
            {ar ? 'لا توجد طلبات سابقة مطابقة لمعايير البحث' : 'No approval records found'}
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="border-b border-ui-border text-ui-muted">
                  <th className="p-3 text-start">{ar ? 'النوع والعملية' : 'Action Type'}</th>
                  <th className="p-3 text-start">{ar ? 'الفرع' : 'Branch'}</th>
                  <th className="p-3 text-start">{ar ? 'مقدم الطلب' : 'Requester'}</th>
                  <th className="p-3 text-start">{ar ? 'السبب المذكور' : 'Reason'}</th>
                  <th className="p-3 text-start">{ar ? 'الحالة' : 'Status'}</th>
                  <th className="p-3 text-start">{ar ? 'المعتمد والقرار' : 'Approver'}</th>
                  <th className="p-3 text-start">{ar ? 'التوقيت' : 'Time'}</th>
                  <th className="p-3 text-end">{ar ? 'الإجراء' : 'Action'}</th>
                </tr>
              </thead>
              <tbody>
                {filteredItems.map((item) => (
                  <tr
                    key={item.id}
                    className="border-b border-ui-border/60 hover:bg-ui-page-alt/40 transition-colors"
                  >
                    <td className="p-3 font-semibold text-ui-text">
                      <div className="flex items-center gap-1.5">
                        <ShieldCheck className="h-3.5 w-3.5 text-ui-primary" />
                        <span>{ACTION_LABELS[item.action_type]?.[ar ? 'ar' : 'en'] || item.action_type}</span>
                      </div>
                    </td>
                    <td className="p-3 text-ui-muted whitespace-nowrap">
                      {item.branch_name}
                    </td>
                    <td className="p-3">
                      <div className="font-semibold text-ui-text">{item.requester_name}</div>
                      {item.requester_role && (
                        <div className="text-[11px] text-ui-muted">{item.requester_role}</div>
                      )}
                    </td>
                    <td className="p-3 max-w-xs truncate text-ui-text" title={item.reason}>
                      {item.reason || '-'}
                    </td>
                    <td className="p-3 whitespace-nowrap">
                      {getStatusBadge(item.status)}
                    </td>
                    <td className="p-3">
                      <div className="font-medium text-ui-text">{item.approver_name}</div>
                      {item.decision_note && (
                        <div className="text-[11px] text-ui-muted truncate max-w-[180px]" title={item.decision_note}>
                          {item.decision_note}
                        </div>
                      )}
                    </td>
                    <td className="p-3 whitespace-nowrap text-ui-muted">
                      <div>{new Date(item.created_at).toLocaleDateString(ar ? 'ar-EG' : 'en')}</div>
                      <div className="text-[11px]">{new Date(item.created_at).toLocaleTimeString(ar ? 'ar-EG' : 'en', { hour: '2-digit', minute: '2-digit' })}</div>
                    </td>
                    <td className="p-3 text-end whitespace-nowrap">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setSelectedDetail(item)}
                        className="h-7 text-xs"
                      >
                        <Eye className="h-3.5 w-3.5" />
                        {ar ? 'التفاصيل' : 'Details'}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </DesignPanel>

      {/* Details Inspector Modal */}
      {selectedDetail && (
        <ApprovalDetailsModal
          item={selectedDetail}
          onClose={() => setSelectedDetail(null)}
          ar={ar}
        />
      )}
    </div>
  );
}
