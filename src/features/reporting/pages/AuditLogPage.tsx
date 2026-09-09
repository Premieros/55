import { useMemo, useState } from 'react';
import {
  BookOpen,
  Boxes,
  CheckCircle2,
  Clock,
  Download,
  Eye,
  Layers,
  RefreshCw,
  ScrollText,
  Search,
  Settings,
  ShieldAlert,
  ShieldCheck,
  ShoppingCart,
  Tag,
  User,
  Users,
  XCircle,
} from 'lucide-react';
import { useLanguage } from '@/context/LanguageContext';
import { DesignSurface, DesignPageHeader } from '@/components/design/DesignSurface';
import { DesignPanel } from '@/components/design/DesignPanel';
import { DesignPagination } from '@/components/design/DesignPagination';
import { DesignLoadingState, DesignEmptyState } from '@/components/design/DesignStates';
import { BranchBadge } from '@/components/BranchBadge';
import { Button } from '@/components/Button';
import { Input, Select } from '@/components/Input';
import { usePaginatedRows } from '@/hooks/usePaginatedRows';
import { useBranches } from '@/hooks/useBranches';
import { useBranchFilter } from '@/lib/useBranchFilter';
import { formatDateTime } from '@/lib/format';
import type { AuditLog } from '@/lib/types';
import { AuditDetailModal } from '../components/AuditDetailModal';
import { AuditSystemModule } from '@/lib/audit';

type SystemTabDef = {
  id: AuditSystemModule | 'all';
  ar: string;
  en: string;
  icon: React.ComponentType<{ className?: string }>;
};

const SYSTEM_TABS: SystemTabDef[] = [
  { id: 'all', ar: 'جميع الأنظمة', en: 'All Systems', icon: Layers },
  { id: 'pos', ar: 'المبيعات ونقاط البيع', en: 'Sales & POS', icon: ShoppingCart },
  { id: 'inventory', ar: 'المخزون والمستودعات', en: 'Inventory', icon: Boxes },
  { id: 'shifts', ar: 'الورديات والخزينة', en: 'Shifts & Cash', icon: Clock },
  { id: 'products', ar: 'المنتجات والتسعير', en: 'Products & Pricing', icon: Tag },
  { id: 'approvals', ar: 'الموافقات والاعتمادات', en: 'Approvals & Overrides', icon: ShieldCheck },
  { id: 'users', ar: 'المستخدمين والصلاحيات', en: 'Users & Roles', icon: Users },
  { id: 'accounting', ar: 'المحاسبة والمالية', en: 'Accounting & Finance', icon: BookOpen },
  { id: 'settings', ar: 'الإعدادات والتهيئة', en: 'Settings & System', icon: Settings },
];

function categorizeAudit(item: AuditLog): AuditSystemModule {
  const details = (item.details || {}) as Record<string, unknown>;
  const explicitModule = details._module as AuditSystemModule | undefined;
  if (explicitModule && explicitModule !== 'general') {
    return explicitModule;
  }

  const entity = (item.entity || '').toLowerCase();
  const action = (item.action || '').toLowerCase();

  // Approvals
  if (
    entity.includes('approval') ||
    action.includes('approval') ||
    action.includes('approve') ||
    action.includes('reject')
  ) {
    return 'approvals';
  }

  // POS & Sales
  if (
    entity.includes('sale') ||
    entity.includes('order') ||
    entity.includes('pos') ||
    entity.includes('receipt') ||
    action.includes('sale') ||
    action.includes('order') ||
    action.includes('void') ||
    action.includes('refund') ||
    action.includes('reprint') ||
    action.includes('discount') ||
    action.includes('drawer')
  ) {
    return 'pos';
  }

  // Shifts & Cash
  if (
    entity.includes('shift') ||
    entity.includes('cash_shift') ||
    entity.includes('treasury') ||
    action.includes('shift')
  ) {
    return 'shifts';
  }

  // Inventory & Stock
  if (
    entity.includes('inventory') ||
    entity.includes('stock') ||
    entity.includes('warehouse') ||
    entity.includes('transfer') ||
    entity.includes('waste') ||
    entity.includes('batch') ||
    entity.includes('unit') ||
    entity.includes('raw_material')
  ) {
    return 'inventory';
  }

  // Products, Catalog, Pricing
  if (
    entity.includes('product') ||
    entity.includes('category') ||
    entity.includes('recipe') ||
    entity.includes('component') ||
    entity.includes('modifier') ||
    action.includes('product') ||
    action.includes('price')
  ) {
    return 'products';
  }

  // Users, Roles, Permissions
  if (
    entity.includes('user') ||
    entity.includes('role') ||
    entity.includes('permission') ||
    action.includes('user') ||
    action.includes('role')
  ) {
    return 'users';
  }

  // Accounting & Finance
  if (
    entity.includes('journal') ||
    entity.includes('account') ||
    entity.includes('reconciliation') ||
    entity.includes('payment') ||
    entity.includes('expense')
  ) {
    return 'accounting';
  }

  // Settings & System
  if (
    entity.includes('setting') ||
    entity.includes('branch') ||
    entity.includes('printer') ||
    action.includes('setting') ||
    action.includes('branch')
  ) {
    return 'settings';
  }

  return 'general';
}

export function AuditLogPage() {
  const { lang } = useLanguage();
  const ar = lang === 'ar';
  const [search, setSearch] = useState('');
  const [selectedSystem, setSelectedSystem] = useState<AuditSystemModule | 'all'>('all');
  const [actionCategory, setActionCategory] = useState<string>('all');
  const [dateFilter, setDateFilter] = useState<'all' | 'today' | 'yesterday' | '7days' | '30days'>('all');
  const [selectedAudit, setSelectedAudit] = useState<AuditLog | null>(null);

  const branchFilter = useBranchFilter();
  const { branches } = useBranches();

  const { rows: items, loading, total, hasMore, loadMore, loadingMore, refresh: refetch } = usePaginatedRows<AuditLog>({
    table: 'audit_log',
    order: { column: 'created_at', ascending: false },
    branch_id: branchFilter,
    pageSize: 300,
  });

  // Categorize and filter items
  const categorizedItems = useMemo(() => {
    return items.map((item) => ({
      item,
      system: categorizeAudit(item),
    }));
  }, [items]);

  const filtered = useMemo(() => {
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const yesterdayStart = todayStart - 86400000;
    const sevenDaysAgo = now.getTime() - 7 * 86400000;
    const thirtyDaysAgo = now.getTime() - 30 * 86400000;

    return categorizedItems.filter(({ item, system }) => {
      // System tab filter
      if (selectedSystem !== 'all' && system !== selectedSystem) {
        return false;
      }

      // Action category filter
      if (actionCategory !== 'all') {
        const a = (item.action || '').toLowerCase();
        if (actionCategory === 'create' && !a.includes('create') && !a.includes('add')) return false;
        if (actionCategory === 'update' && !a.includes('update') && !a.includes('edit')) return false;
        if (actionCategory === 'delete' && !a.includes('delete') && !a.includes('drop')) return false;
        if (actionCategory === 'approval' && !a.includes('approv') && !a.includes('reject')) return false;
        if (actionCategory === 'void' && !a.includes('void') && !a.includes('cancel') && !a.includes('refund')) return false;
      }

      // Date range filter
      if (dateFilter !== 'all') {
        const itemTime = new Date(item.created_at).getTime();
        if (dateFilter === 'today' && itemTime < todayStart) return false;
        if (dateFilter === 'yesterday' && (itemTime < yesterdayStart || itemTime >= todayStart)) return false;
        if (dateFilter === '7days' && itemTime < sevenDaysAgo) return false;
        if (dateFilter === '30days' && itemTime < thirtyDaysAgo) return false;
      }

      // Search text
      if (search.trim()) {
        const q = search.trim().toLowerCase();
        const inAction = (item.action || '').toLowerCase().includes(q);
        const inEntity = (item.entity || '').toLowerCase().includes(q);
        const inEmail = (item.user_email || '').toLowerCase().includes(q);
        const inId = (item.entity_id || '').toLowerCase().includes(q);
        const inDetails = item.details ? JSON.stringify(item.details).toLowerCase().includes(q) : false;
        if (!inAction && !inEntity && !inEmail && !inId && !inDetails) {
          return false;
        }
      }

      return true;
    });
  }, [categorizedItems, selectedSystem, actionCategory, dateFilter, search]);

  // KPI Metrics Calculation
  const stats = useMemo(() => {
    const totalCount = items.length;
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    let todayCount = 0;
    let criticalCount = 0;
    const activeUsers = new Set<string>();

    for (const item of items) {
      const time = new Date(item.created_at).getTime();
      if (time >= todayStart) todayCount++;

      const a = (item.action || '').toLowerCase();
      if (
        a.includes('delete') ||
        a.includes('void') ||
        a.includes('cancel') ||
        a.includes('drop') ||
        a.includes('refund') ||
        a.includes('override')
      ) {
        criticalCount++;
      }

      if (item.user_email) activeUsers.add(item.user_email);
    }

    return {
      total: totalCount,
      today: todayCount,
      critical: criticalCount,
      usersCount: activeUsers.size,
    };
  }, [items]);

  // CSV Export
  const exportCsv = () => {
    const headers = [
      ar ? 'التاريخ والوقت' : 'Timestamp',
      ar ? 'النظام' : 'System Module',
      ar ? 'نوع العملية' : 'Action',
      ar ? 'الكيان' : 'Entity',
      ar ? 'معرّف الكيان' : 'Entity ID',
      ar ? 'المستخدم' : 'User Email',
      ar ? 'الفرع' : 'Branch',
      ar ? 'تفاصيل إضافية' : 'Details',
    ];

    const rows = filtered.map(({ item, system }) => {
      const branchName = branches.find((b) => b.id === item.branch_id)?.name || '';
      const sysName = SYSTEM_TABS.find((s) => s.id === system)?.[ar ? 'ar' : 'en'] || system;
      return [
        new Date(item.created_at).toLocaleString(),
        sysName,
        item.action,
        item.entity || '',
        item.entity_id || '',
        item.user_email || '',
        branchName,
        item.details ? `"${JSON.stringify(item.details).replace(/"/g, '""')}"` : '',
      ];
    });

    const csvContent =
      '\uFEFF' + [headers.join(','), ...rows.map((e) => e.join(','))].join('\n');
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.setAttribute('href', url);
    link.setAttribute('download', `system_audit_trail_${new Date().toISOString().slice(0, 10)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const getActionBadge = (action: string) => {
    const a = action.toLowerCase();
    if (a.includes('create') || a.includes('add') || a.includes('approve')) {
      return (
        <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-bold text-emerald-600 dark:text-emerald-400">
          <CheckCircle2 className="h-3 w-3" />
          {action}
        </span>
      );
    }
    if (a.includes('delete') || a.includes('void') || a.includes('reject') || a.includes('drop')) {
      return (
        <span className="inline-flex items-center gap-1 rounded-full bg-rose-500/10 px-2 py-0.5 text-xs font-bold text-rose-600 dark:text-rose-400">
          <XCircle className="h-3 w-3" />
          {action}
        </span>
      );
    }
    if (a.includes('update') || a.includes('edit')) {
      return (
        <span className="inline-flex items-center gap-1 rounded-full bg-blue-500/10 px-2 py-0.5 text-xs font-bold text-blue-600 dark:text-blue-400">
          {action}
        </span>
      );
    }
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-slate-500/10 px-2 py-0.5 text-xs font-bold text-slate-600 dark:text-slate-400">
        {action}
      </span>
    );
  };

  const getSystemBadge = (system: AuditSystemModule) => {
    const tab = SYSTEM_TABS.find((t) => t.id === system);
    const IconComponent = tab?.icon || Layers;
    return (
      <span className="inline-flex items-center gap-1 rounded-md bg-ui-page-alt px-2 py-1 text-xs font-semibold text-ui-text border border-ui-border">
        <IconComponent className="h-3.5 w-3.5 text-ui-primary" />
        <span>{tab ? (ar ? tab.ar : tab.en) : system}</span>
      </span>
    );
  };

  return (
    <DesignSurface testId="audit-log-page">
      <DesignPageHeader
        title={ar ? 'مركز سجل التدقيق والعمليات لجميع الأنظمة' : 'Enterprise Multi-System Audit Center'}
        description={
          ar
            ? 'سجل تتبع زمني مفصل وشامل لجميع العمليات والأنشطة عبر كافة أنظمة البرنامج (المبيعات، المخزون، الورديات، المنتجات، الموافقات، المستخدمين، والمحاسبة).'
            : 'Comprehensive chronological audit trail across all system modules with deep payload inspection.'
        }
        actions={
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={exportCsv}
              disabled={filtered.length === 0}
            >
              <Download className="h-4 w-4" />
              {ar ? 'تصدير السجل CSV' : 'Export CSV'}
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => void refetch()}
              disabled={loading}
            >
              <RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
              {ar ? 'تحديث' : 'Refresh'}
            </Button>
          </div>
        }
      />

      <div className="space-y-4">
        {/* KPI Summary Cards */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div className="rounded-xl border border-ui-border bg-ui-surface p-3.5 shadow-xs">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-ui-muted">
                {ar ? 'إجمالي السجلات المحفوظة' : 'Total Logged Events'}
              </span>
              <ScrollText className="h-4 w-4 text-ui-primary" />
            </div>
            <span className="text-2xl font-bold text-ui-text mt-1 block">
              {stats.total}
            </span>
          </div>

          <div className="rounded-xl border border-rose-500/20 bg-rose-500/5 p-3.5 shadow-xs">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-rose-600 dark:text-rose-400">
                {ar ? 'عمليات حساسة / حرجة' : 'Critical Operations'}
              </span>
              <ShieldAlert className="h-4 w-4 text-rose-600 dark:text-rose-400" />
            </div>
            <span className="text-2xl font-bold text-rose-600 dark:text-rose-400 mt-1 block">
              {stats.critical}
            </span>
          </div>

          <div className="rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-3.5 shadow-xs">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-emerald-600 dark:text-emerald-400">
                {ar ? 'عمليات اليوم' : "Today's Operations"}
              </span>
              <Clock className="h-4 w-4 text-emerald-600 dark:text-emerald-400" />
            </div>
            <span className="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1 block">
              {stats.today}
            </span>
          </div>

          <div className="rounded-xl border border-ui-border bg-ui-surface p-3.5 shadow-xs">
            <div className="flex items-center justify-between">
              <span className="text-xs font-semibold text-ui-muted">
                {ar ? 'المستخدمين النشطين بالسجل' : 'Active Actors in Log'}
              </span>
              <User className="h-4 w-4 text-ui-muted" />
            </div>
            <span className="text-2xl font-bold text-ui-text mt-1 block">
              {stats.usersCount}
            </span>
          </div>
        </div>

        {/* Multi-System Filter Tabs */}
        <div className="border-b border-ui-border pb-3 overflow-x-auto">
          <div className="flex items-center gap-1.5 min-w-max">
            {SYSTEM_TABS.map((tab) => {
              const TabIcon = tab.icon;
              const isActive = selectedSystem === tab.id;
              return (
                <button
                  key={tab.id}
                  type="button"
                  onClick={() => setSelectedSystem(tab.id)}
                  className={`flex items-center gap-2 px-3.5 py-2 rounded-xl text-xs font-bold transition-all ${
                    isActive
                      ? 'bg-ui-primary text-white shadow-xs'
                      : 'bg-ui-surface border border-ui-border text-ui-text hover:bg-ui-page-alt'
                  }`}
                >
                  <TabIcon className="h-3.5 w-3.5" />
                  <span>{ar ? tab.ar : tab.en}</span>
                </button>
              );
            })}
          </div>
        </div>

        {/* Advanced Filters Toolbar */}
        <DesignPanel>
          <div className="flex flex-col md:flex-row md:items-center justify-between gap-3">
            <div className="flex flex-wrap items-center gap-2 flex-1">
              <div className="relative flex-1 min-w-[200px] max-w-sm">
                <Search className="absolute start-3 top-1/2 -translate-y-1/2 h-4 w-4 text-ui-muted" />
                <Input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder={ar ? 'بحث بالعملية، الكيان، البريد، أو الحقول...' : 'Search action, entity, user email, payload...'}
                  className="ps-9 h-9 text-xs"
                />
              </div>

              <Select
                value={actionCategory}
                onChange={(e) => setActionCategory(e.target.value)}
                className="h-9 text-xs min-w-[140px]"
              >
                <option value="all">{ar ? 'جميع أنواع العمليات' : 'All Action Types'}</option>
                <option value="create">{ar ? 'إضافة وإنشاء (Create)' : 'Create'}</option>
                <option value="update">{ar ? 'تعديل وتحديث (Update)' : 'Update'}</option>
                <option value="delete">{ar ? 'حذف واستبعاد (Delete)' : 'Delete'}</option>
                <option value="approval">{ar ? 'اعتمادات وموافقات (Approvals)' : 'Approvals'}</option>
                <option value="void">{ar ? 'إلغاء ومرتجعات (Voids / Refunds)' : 'Voids / Refunds'}</option>
              </Select>

              <Select
                value={dateFilter}
                onChange={(e) => setDateFilter(e.target.value as 'all' | 'today' | 'yesterday' | '7days' | '30days')}
                className="h-9 text-xs min-w-[130px]"
              >
                <option value="all">{ar ? 'كل الفترات الزمنية' : 'All Time'}</option>
                <option value="today">{ar ? 'اليوم فقط' : 'Today'}</option>
                <option value="yesterday">{ar ? 'أمس' : 'Yesterday'}</option>
                <option value="7days">{ar ? 'آخر 7 أيام' : 'Last 7 Days'}</option>
                <option value="30days">{ar ? 'آخر 30 يوماً' : 'Last 30 Days'}</option>
              </Select>
            </div>

            <div className="text-xs text-ui-muted shrink-0">
              {ar ? `النتائج المعروضة: ${filtered.length}` : `Showing: ${filtered.length}`}
            </div>
          </div>
        </DesignPanel>

        {/* Audit Log Table */}
        <DesignPanel testId="audit-log-table-panel">
          {loading ? (
            <DesignLoadingState />
          ) : filtered.length === 0 ? (
            <DesignEmptyState
              title={ar ? 'لا توجد سجلات مطابقة' : 'No matching audit records'}
              icon={<ScrollText className="h-8 w-8" />}
            />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-xs">
                <thead>
                  <tr className="border-b border-ui-border text-ui-muted">
                    <th className="p-3 text-start">{ar ? 'التاريخ والوقت' : 'Date & Time'}</th>
                    <th className="p-3 text-start">{ar ? 'نظام البرنامج' : 'System Module'}</th>
                    <th className="p-3 text-start">{ar ? 'نوع العملية' : 'Action'}</th>
                    <th className="p-3 text-start">{ar ? 'الكيان المتأثر' : 'Target Entity'}</th>
                    <th className="p-3 text-start">{ar ? 'المستخدم / المنفذ' : 'Actor / User'}</th>
                    <th className="p-3 text-start">{ar ? 'الفرع' : 'Branch'}</th>
                    <th className="p-3 text-start">{ar ? 'ملخص البيانات' : 'Details'}</th>
                    <th className="p-3 text-end">{ar ? 'الفحص' : 'Inspect'}</th>
                  </tr>
                </thead>
                <tbody>
                  {filtered.map(({ item, system }) => {
                    const branchName = branches.find((b) => b.id === item.branch_id)?.name;
                    return (
                      <tr
                        key={item.id}
                        className="border-b border-ui-border/60 hover:bg-ui-page-alt/40 transition-colors"
                      >
                        <td className="p-3 whitespace-nowrap text-ui-text">
                          <div>{formatDateTime(item.created_at, lang)}</div>
                        </td>

                        <td className="p-3 whitespace-nowrap">
                          {getSystemBadge(system)}
                        </td>

                        <td className="p-3 whitespace-nowrap">
                          {getActionBadge(item.action)}
                        </td>

                        <td className="p-3">
                          <span className="font-semibold text-ui-text font-mono">
                            {item.entity || '-'}
                          </span>
                          {item.entity_id && (
                            <span className="block text-[10px] text-ui-muted font-mono truncate max-w-[120px]">
                              {item.entity_id}
                            </span>
                          )}
                        </td>

                        <td className="p-3">
                          <span className="text-ui-text font-medium break-all">
                            {item.user_email || '-'}
                          </span>
                        </td>

                        <td className="p-3 whitespace-nowrap">
                          <BranchBadge name={branchName || (ar ? 'عام' : 'Global')} />
                        </td>

                        <td className="p-3 max-w-xs truncate text-ui-muted font-mono text-[11px]">
                          {item.details ? JSON.stringify(item.details) : '-'}
                        </td>

                        <td className="p-3 text-end whitespace-nowrap">
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => setSelectedAudit(item)}
                            className="h-7 text-xs"
                          >
                            <Eye className="h-3.5 w-3.5" />
                            {ar ? 'عرض' : 'View'}
                          </Button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          <DesignPagination
            loaded={items.length}
            total={total}
            hasMore={hasMore}
            loadingMore={loadingMore}
            onLoadMore={loadMore}
          />
        </DesignPanel>
      </div>

      {/* Audit Detail Inspector Modal */}
      {selectedAudit && (
        <AuditDetailModal
          item={selectedAudit}
          moduleName={categorizeAudit(selectedAudit)}
          branchName={branches.find((b) => b.id === selectedAudit.branch_id)?.name}
          onClose={() => setSelectedAudit(null)}
          ar={ar}
        />
      )}
    </DesignSurface>
  );
}
