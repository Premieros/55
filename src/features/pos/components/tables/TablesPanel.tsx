import { useMemo, useState } from 'react';
import { Banknote, Search, UtensilsCrossed, Users, User, X } from 'lucide-react';
import { useLanguage } from '@/context/LanguageContext';
import { useAuth } from '@/context/AuthContext';
import { Button } from '@/components/Button';
import { Modal } from '@/components/Modal';
import { formatCurrency } from '@/lib/format';
import type { DiningTable, Order } from '@/lib/types';

type TableFilter = 'all' | 'available' | 'occupied';

interface TablesPanelProps {
  open: boolean;
  onClose: () => void;
  tables: DiningTable[];
  ordersByTable: Record<string, Order[]>;
  currency: string;
  onResume: (order: Order) => void;
  onPay: (order: Order) => void;
  onStart: (table: DiningTable, guests: number) => void;
}

export function TablesPanel({ open, onClose, tables, ordersByTable, currency, onResume, onPay, onStart }: TablesPanelProps) {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';
  const { user } = useAuth();
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<TableFilter>('all');
  const [selected, setSelected] = useState<DiningTable | null>(null);
  const [guests, setGuests] = useState(2);

  const isManager = useMemo(() => {
    if (!user) return false;
    return (
      user.role === 'super_admin' ||
      user.role === 'branch_manager' ||
      Boolean((user as { permissions?: string[] }).permissions?.includes('pos.order.transfer'))
    );
  }, [user]);

  const occupiedCount = useMemo(
    () => tables.filter((table) => (ordersByTable[table.id] || []).length > 0 || table.status === 'occupied').length,
    [tables, ordersByTable],
  );
  const availableCount = Math.max(0, tables.length - occupiedCount);

  const visibleTables = useMemo(() => {
    const q = search.trim().toLowerCase();
    return tables.filter((table) => {
      const orders = ordersByTable[table.id] || [];
      const occupied = orders.length > 0 || table.status === 'occupied';
      if (filter === 'available' && occupied) return false;
      if (filter === 'occupied' && !occupied) return false;
      if (!q) return true;
      return table.name.toLowerCase().includes(q) || orders.some((order) => order.order_number?.toLowerCase().includes(q));
    });
  }, [tables, ordersByTable, search, filter]);

  const chooseTable = (table: DiningTable) => {
    setSelected(table);
    setGuests(Math.max(1, table.capacity || 2));
  };

  if (!open) return null;

  const filters: Array<{ id: TableFilter; label: string; count: number }> = [
    { id: 'all', label: isAr ? 'الكل' : 'All', count: tables.length },
    { id: 'available', label: isAr ? 'متاحة' : 'Available', count: availableCount },
    { id: 'occupied', label: isAr ? 'مشغولة' : 'Occupied', count: occupiedCount },
  ];

  return (
    <>
      <div className="fixed inset-0 top-16 z-40 bg-ui-text/40 backdrop-blur-[1px]" onClick={onClose} />
      <aside data-testid="pos-tables-drawer" className="fixed bottom-0 end-0 top-16 z-50 flex w-[430px] max-w-[96vw] flex-col border-s border-ui-border bg-ui-surface shadow-ui-xl">
        <div className="shrink-0 border-b border-ui-border p-3">
          <div className="flex items-center justify-between gap-3">
            <div>
              <h2 className="text-base font-black text-ui-text">{isAr ? 'الطاولات' : 'Tables'}</h2>
              <p className="mt-0.5 text-[10px] font-bold text-ui-subtle">
                {isAr ? 'نفس واجهة الطاولات في شاشة البيع' : 'The same table workspace used by POS'}
              </p>
            </div>
            <button type="button" onClick={onClose} aria-label={isAr ? 'إغلاق' : 'Close'} className="rounded-lg border border-ui-border bg-ui-page p-2 text-ui-muted hover:text-ui-text">
              <X className="h-4 w-4" />
            </button>
          </div>

          <div className="relative mt-3">
            <Search className="absolute start-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-ui-muted" />
            <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={isAr ? 'ابحث برقم الطاولة أو الطلب...' : 'Search table or order...'} className="h-10 w-full rounded-xl border border-ui-border bg-ui-page ps-9 pe-3 text-xs font-bold text-ui-text outline-none focus:border-ui-primary" />
          </div>

          <div className="mt-2 grid grid-cols-3 gap-1.5" data-testid="pos-table-drawer-filters">
            {filters.map((item) => (
              <button key={item.id} type="button" onClick={() => setFilter(item.id)} className={`rounded-lg border px-2 py-2 text-[10px] font-black transition ${filter === item.id ? 'border-ui-primary bg-ui-primary text-ui-primary-fg' : 'border-ui-border bg-ui-page text-ui-muted hover:border-ui-primary'}`}>
                {item.label} <span className="ms-1 opacity-70">{item.count}</span>
              </button>
            ))}
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-y-contain p-3">
          {visibleTables.length > 0 ? (
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              {visibleTables.map((table) => {
                const order = (ordersByTable[table.id] || [])[0];
                const occupied = !!order || table.status === 'occupied';
                return (
                  <button
                    key={table.id}
                    type="button"
                    data-testid={`pos-table-drawer-${table.id}`}
                    onClick={() => chooseTable(table)}
                    className={`min-h-24 rounded-2xl border p-3 text-start shadow-ui-sm transition hover:-translate-y-0.5 ${occupied ? 'border-ui-warning/30 bg-ui-warning/5' : 'border-ui-border bg-ui-surface hover:border-ui-primary'}`}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <span className="truncate text-xs font-black text-ui-text">{table.name}</span>
                      <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${occupied ? 'bg-ui-warning' : 'bg-ui-success'}`} />
                    </div>
                    <p className="mt-2 flex items-center gap-1 text-[10px] font-bold text-ui-subtle"><Users className="h-3 w-3" /> {table.capacity}</p>
                    {order ? (
                      <div className="mt-2 space-y-1">
                        <div className="flex items-center justify-between gap-1">
                          <p className="truncate text-[10px] font-black text-ui-text">#{order.order_number}</p>
                          <p className="truncate text-[10px] font-black text-ui-accent">{formatCurrency(order.total, currency, lang)}</p>
                        </div>
                        {(() => {
                          const cashierName = order.cashier?.full_name || order.cashier?.username;
                          const isMyOrder = !!(user && (order.cashier_id === user.id || order.created_by_user_id === user.id));
                          return (
                            <div className="flex items-center gap-1 truncate text-[9px] font-bold">
                              <span
                                className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 max-w-full truncate ${
                                  isMyOrder
                                    ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400 border border-emerald-500/20'
                                    : 'bg-ui-page text-ui-muted border border-ui-border'
                                }`}
                              >
                                <User className="h-2.5 w-2.5 shrink-0" />
                                <span className="truncate">{cashierName || (isAr ? 'موظف' : 'Staff')}</span>
                                {isMyOrder && <span className="shrink-0 text-[8px] font-black opacity-80">({isAr ? 'لي' : 'Mine'})</span>}
                              </span>
                            </div>
                          );
                        })()}
                      </div>
                    ) : (
                      <p className="mt-2 text-[10px] font-black text-ui-success">{isAr ? 'متاحة' : 'Available'}</p>
                    )}
                  </button>
                );
              })}
            </div>
          ) : (
            <div className="py-12 text-center text-xs font-bold text-ui-muted">{isAr ? 'لا توجد طاولات مطابقة' : 'No matching tables'}</div>
          )}
        </div>
      </aside>

      <Modal open={!!selected} onClose={() => setSelected(null)} title={selected?.name || ''} size="sm">
        {selected && (() => {
          const tableOrders = ordersByTable[selected.id] || [];
          const order = tableOrders[0];
          if (order) {
            const cashierName = order.cashier?.full_name || order.cashier?.username || (isAr ? 'غير محدد' : 'Unknown');
            const isMyOrder = !!(user && (order.cashier_id === user.id || order.created_by_user_id === user.id));
            const canManage = isMyOrder || isManager;
            return (
              <div className="space-y-3">
                <div className="rounded-xl border border-ui-border bg-ui-page-alt p-3 space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-sm font-black text-ui-text">#{order.order_number}</span>
                    <span className="text-sm font-black text-ui-accent">{formatCurrency(order.total, currency, lang)}</span>
                  </div>
                  <div className="flex items-center gap-1.5 text-xs text-ui-muted border-t border-ui-border/60 pt-2">
                    <User className="h-3.5 w-3.5 shrink-0" />
                    <span>{isAr ? 'الموظف المسؤول: ' : 'Staff: '}</span>
                    <span className="font-bold text-ui-text">{cashierName}</span>
                    {isMyOrder && <span className="text-emerald-600 font-black text-[10px]">({isAr ? 'طلبك' : 'Yours'})</span>}
                  </div>
                </div>

                {!canManage && (
                  <div className="rounded-xl border border-amber-500/20 bg-amber-500/10 p-2.5 text-xs font-semibold text-amber-700 dark:text-amber-400">
                    <p>⚠️ {isAr ? `هذه الطاولة تحت مسؤولية الموظف (${cashierName}). يمكنك فتحها للعرض فقط (النقل متاح للمدير).` : `This table is assigned to (${cashierName}). Open in read-only mode.`}</p>
                  </div>
                )}

                <div className="grid grid-cols-2 gap-2">
                  <Button variant="outline" onClick={() => { setSelected(null); onClose(); onResume(order); }}>
                    <UtensilsCrossed className="h-4 w-4" /> {canManage ? (isAr ? 'فتح الطلب' : 'Open order') : (isAr ? 'عرض الطلب' : 'View order')}
                  </Button>
                  <Button
                    variant="success"
                    disabled={!canManage}
                    title={!canManage ? (isAr ? 'الدفع متاح للموظف المسؤول أو المدير فقط' : 'Payment restricted to owner or manager') : undefined}
                    onClick={() => { setSelected(null); onClose(); onPay(order); }}
                  >
                    <Banknote className="h-4 w-4" /> {isAr ? 'الدفع' : 'Pay'}
                  </Button>
                </div>
              </div>
            );
          }
          return (
            <div className="space-y-3">
              <label className="flex items-center justify-between gap-3 text-sm font-bold text-ui-muted">
                <span>{isAr ? 'عدد الأفراد' : 'Guests'}</span>
                <input type="number" min={1} value={guests} onChange={(event) => setGuests(Math.max(1, Number(event.target.value) || 1))} className="w-24 rounded-xl border border-ui-border bg-ui-surface px-3 py-2 text-center font-black text-ui-text" />
              </label>
              <Button className="w-full" onClick={() => { setSelected(null); onClose(); onStart(selected, guests); }}>
                <UtensilsCrossed className="h-4 w-4" /> {isAr ? 'فتح طلب على الطاولة' : 'Start table order'}
              </Button>
            </div>
          );
        })()}
      </Modal>
    </>
  );
}
