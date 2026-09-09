import { useEffect, useState, useMemo, useCallback } from 'react';
import { AlertTriangle, Download, Edit2, RefreshCw, Layers, Box, Wheat, PackageCheck } from 'lucide-react';
import { supabase } from '@/api';
import * as api from '@/api';
import { useLanguage } from '@/context/LanguageContext';
import { useToast } from '@/components/Toast';
import { useCan } from '@/lib/permissions';
import { useAuth } from '@/context/AuthContext';
import { DesignSurface, DesignPageHeader, DesignSearch, DesignPanel } from '@/components/design';
import { DataTable, type Column } from '@/components/DataTable';
import { Button } from '@/components/Button';
import { Input, Select } from '@/components/Input';
import { Modal } from '@/components/Modal';
import { BranchBadge } from '@/components/BranchBadge';
import { formatNumber, formatCurrency, formatDate } from '@/lib/format';
import { exportToExcel } from '@/lib/excel';
import { logAudit } from '@/lib/audit';
import { useBranches } from '@/hooks/useBranches';
import { useSettings } from '@/context/SettingsContext';
import type { Warehouse } from '@/lib/types';

export type UnifiedItemType =
  | 'product_ready'
  | 'product_component'
  | 'raw_material'
  | 'inventory_unit_purchased'
  | 'inventory_unit_manufactured';

export interface UnifiedInventoryRow {
  id: string;
  unique_id: string;
  record_id: string;
  item_id: string;
  item_name: string;
  item_code: string | null;
  item_type: UnifiedItemType;
  unit_name: string;
  branch_id: string;
  branch_name: string;
  warehouse_id: string;
  warehouse_name: string;
  stock_quantity: number;
  reserved_quantity: number;
  available_quantity: number;
  min_stock: number;
  unit_cost: number;
  total_value: number;
  updated_at: string | null;
}

export function InventoryPage() {
  const { t, lang } = useLanguage();
  const isAr = lang === 'ar';
  const { show } = useToast();
  const can = useCan();
  const { user } = useAuth();
  const { branches } = useBranches();
  const { effectiveSettings } = useSettings();

  const [rows, setRows] = useState<UnifiedInventoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);

  // Filters
  const [search, setSearch] = useState('');
  const [filterBranch, setFilterBranch] = useState(user?.branch_id || '');
  const [filterWarehouse, setFilterWarehouse] = useState('');
  const [filterType, setFilterType] = useState<string>('all');
  const [filterStatus, setFilterStatus] = useState<'all' | 'in_stock' | 'low_stock' | 'out_of_stock'>('all');

  // Adjustment modal
  const [adjustModal, setAdjustModal] = useState<UnifiedInventoryRow | null>(null);
  const [adjustQty, setAdjustQty] = useState(0);
  const [adjustReason, setAdjustReason] = useState('');
  const [adjusting, setAdjusting] = useState(false);

  const currency = effectiveSettings(filterBranch || user?.branch_id)?.currency || 'EGP';

  // Load warehouses & branches
  useEffect(() => {
    async function loadMeta() {
      const { data: wh } = await supabase.from('warehouses').select('*').order('name');
      setWarehouses((wh as Warehouse[]) || []);
    }
    void loadMeta();
  }, []);

  // Fetch unified inventory data
  const loadInventory = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // 1. Try fetching from the database unified view
      const { data: viewData, error: viewError } = await supabase
        .from('unified_inventory_view')
        .select('*');

      if (!viewError && Array.isArray(viewData) && viewData.length > 0) {
        setRows(
          viewData.map((r: Record<string, unknown>) => {
            const uniqueId = String(r.unique_id || r.record_id || Math.random());
            return {
            id: uniqueId,
            unique_id: uniqueId,
            record_id: String(r.record_id || ''),
            item_id: String(r.item_id || ''),
            item_name: String(r.item_name || '-'),
            item_code: r.item_code ? String(r.item_code) : null,
            item_type: (r.item_type as UnifiedItemType) || 'product_ready',
            unit_name: String(r.unit_name || 'قطعة'),
            branch_id: String(r.branch_id || ''),
            branch_name: String(r.branch_name || '-'),
            warehouse_id: String(r.warehouse_id || ''),
            warehouse_name: String(r.warehouse_name || '-'),
            stock_quantity: Number(r.stock_quantity || 0),
            reserved_quantity: Number(r.reserved_quantity || 0),
            available_quantity: Number(r.available_quantity || 0),
            min_stock: Number(r.min_stock || 0),
            unit_cost: Number(r.unit_cost || 0),
            total_value: Number(r.total_value || 0),
            updated_at: r.updated_at ? String(r.updated_at) : null,
            };
          })
        );
        setLoading(false);
        return;
      }

      // 2. Resilient Client-Side Union Fallback
      const [invRes, rawInvRes, prodCompRes, whRes, brRes, rmRes] = await Promise.all([
        supabase.from('inventory').select('*, product:products(*), warehouse:warehouses(*)'),
        supabase.from('raw_material_inventory').select('*'),
        supabase.from('product_components').select('component_product_id'),
        supabase.from('warehouses').select('*'),
        supabase.from('branches').select('*'),
        supabase.from('raw_materials').select('*, unit:units(*)'),
      ]);

      const compSet = new Set((prodCompRes.data || []).map((c: { component_product_id: string }) => c.component_product_id));
      const whMap = new Map((whRes.data || []).map((w: Warehouse) => [w.id, w]));
      const brMap = new Map((brRes.data || []).map((b: { id: string; name: string }) => [b.id, b]));
      const rmMap = new Map((rmRes.data || []).map((r: { id: string; name: string; code?: string; unit?: { name?: string; symbol?: string } }) => [r.id, r]));

      const unifiedList: UnifiedInventoryRow[] = [];

      // Add finished and component products
      for (const inv of invRes.data || []) {
        const prod = inv.product;
        const wh = inv.warehouse || whMap.get(inv.warehouse_id);
        const br = wh ? brMap.get(wh.branch_id) : brMap.get(inv.branch_id);
        const isComp = compSet.has(inv.product_id);
        const qty = Number(inv.quantity || 0);
        const cost = Number(prod?.cost_price || 0);
        unifiedList.push({
          id: `prod_${inv.id}`,
          unique_id: `prod_${inv.id}`,
          record_id: inv.id,
          item_id: inv.product_id,
          item_name: prod?.name || '-',
          item_code: prod?.barcode || null,
          item_type: isComp ? 'product_component' : 'product_ready',
          unit_name: isAr ? 'قطعة' : 'pc',
          branch_id: wh?.branch_id || inv.branch_id || '',
          branch_name: br?.name || '-',
          warehouse_id: inv.warehouse_id,
          warehouse_name: wh?.name || '-',
          stock_quantity: qty,
          reserved_quantity: 0,
          available_quantity: qty,
          min_stock: Number(prod?.low_stock_threshold || 0),
          unit_cost: cost,
          total_value: qty * cost,
          updated_at: inv.updated_at || null,
        });
      }

      // Add raw materials
      for (const rmi of rawInvRes.data || []) {
        const rm = rmMap.get(rmi.raw_material_id);
        const wh = whMap.get(rmi.warehouse_id);
        const br = rmi.branch_id
          ? brMap.get(rmi.branch_id)
          : wh?.branch_id
            ? brMap.get(wh.branch_id)
            : undefined;
        const qty = Number(rmi.quantity || 0);
        const cost = Number(rmi.avg_cost || 0);
        unifiedList.push({
          id: `raw_${rmi.id}`,
          unique_id: `raw_${rmi.id}`,
          record_id: rmi.id,
          item_id: rmi.raw_material_id,
          item_name: rm?.name || '-',
          item_code: rm?.code || null,
          item_type: 'raw_material',
          unit_name: rm?.unit?.name || rm?.unit?.symbol || (isAr ? 'وحدة' : 'unit'),
          branch_id: rmi.branch_id || wh?.branch_id || '',
          branch_name: br?.name || '-',
          warehouse_id: rmi.warehouse_id || '',
          warehouse_name: wh?.name || (isAr ? 'المستودع الافتراضي' : 'Default Warehouse'),
          stock_quantity: qty,
          reserved_quantity: 0,
          available_quantity: qty,
          min_stock: Number(rmi.min_stock || 0),
          unit_cost: cost,
          total_value: qty * cost,
          updated_at: rmi.updated_at || null,
        });
      }

      setRows(unifiedList);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      setError(msg);
    } finally {
      setLoading(false);
    }
  }, [isAr]);

  useEffect(() => {
    void loadInventory();
  }, [loadInventory]);

  // Available warehouses filtered by branch
  const availableWarehouses = useMemo(() => {
    if (!filterBranch) return warehouses;
    return warehouses.filter((w) => w.branch_id === filterBranch);
  }, [warehouses, filterBranch]);

  // Filtered rows
  const filtered = useMemo(() => {
    return rows.filter((item) => {
      if (filterBranch && item.branch_id !== filterBranch) return false;
      if (filterWarehouse && item.warehouse_id !== filterWarehouse) return false;

      if (filterType !== 'all') {
        if (filterType === 'ready' && item.item_type !== 'product_ready') return false;
        if (filterType === 'components' && item.item_type !== 'product_component') return false;
        if (filterType === 'raw' && item.item_type !== 'raw_material') return false;
        if (filterType === 'units' && !item.item_type.startsWith('inventory_unit')) return false;
      }

      if (filterStatus !== 'all') {
        const isOut = item.stock_quantity <= 0;
        const isLow = item.stock_quantity > 0 && item.stock_quantity <= item.min_stock;
        if (filterStatus === 'out_of_stock' && !isOut) return false;
        if (filterStatus === 'low_stock' && !isLow) return false;
        if (filterStatus === 'in_stock' && (isOut || isLow)) return false;
      }

      if (!search.trim()) return true;
      const query = search.toLowerCase().trim();
      return (
        item.item_name.toLowerCase().includes(query) ||
        (item.item_code && item.item_code.toLowerCase().includes(query)) ||
        item.warehouse_name.toLowerCase().includes(query)
      );
    });
  }, [rows, filterBranch, filterWarehouse, filterType, filterStatus, search]);

  // Summary Metrics
  const summary = useMemo(() => {
    let totalItems = 0;
    let totalValue = 0;
    let lowStockCount = 0;
    let outOfStockCount = 0;

    for (const r of filtered) {
      totalItems += 1;
      totalValue += r.total_value;
      if (r.stock_quantity <= 0) {
        outOfStockCount += 1;
      } else if (r.stock_quantity <= r.min_stock) {
        lowStockCount += 1;
      }
    }

    return { totalItems, totalValue, lowStockCount, outOfStockCount };
  }, [filtered]);

  // Open Adjust Modal
  const openAdjust = (row: UnifiedInventoryRow) => {
    if (!can('inventory.adjust')) return;
    setAdjustModal(row);
    setAdjustQty(row.stock_quantity);
    setAdjustReason('');
  };

  // Save stock adjustment
  const saveAdjust = async () => {
    if (!adjustModal || !can('inventory.adjust')) return;
    if (!adjustReason.trim()) {
      show(isAr ? 'سبب التسوية مطلوب' : 'Adjustment reason is required', 'error');
      return;
    }
    setAdjusting(true);

    try {
      if (adjustModal.item_type === 'raw_material') {
        if (adjustQty === adjustModal.stock_quantity) {
          show(isAr ? 'الكمية لم تتغير' : 'Quantity unchanged', 'info');
          setAdjustModal(null);
          return;
        }

        const { data, error: adjustError } = await api.inventory.adjustRawStock({
          p_raw_material_id: adjustModal.item_id,
          p_branch_id: adjustModal.branch_id,
          p_new_quantity: adjustQty,
          p_reason: adjustReason.trim(),
        });
        if (adjustError) throw adjustError;
        const result = data as { success: boolean; error?: string; detail?: string } | null;
        if (!result?.success) {
          throw new Error(result?.detail || result?.error || t('error'));
        }
      } else {
        // Finished or component product
        const { data, error: adjustError } = await api.inventory.adjustStock({
          p_inventory_id: adjustModal.record_id,
          p_new_quantity: adjustQty,
          p_reason: adjustReason.trim(),
        });
        if (adjustError) throw adjustError;
        const result = data as { success: boolean; error?: string; detail?: string } | null;
        if (!result?.success) {
          throw new Error(result?.detail || result?.error || t('error'));
        }
      }

      await logAudit('update', 'inventory', adjustModal.record_id, {
        item: adjustModal.item_name,
        type: adjustModal.item_type,
        warehouse: adjustModal.warehouse_name,
        from: adjustModal.stock_quantity,
        to: adjustQty,
        reason: adjustReason.trim(),
      });

      show(t('saveSuccess'), 'success');
      setAdjustModal(null);
      void loadInventory();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      show(msg, 'error');
    } finally {
      setAdjusting(false);
    }
  };

  // Export to Excel
  const handleExport = () => {
    exportToExcel(
      filtered.map((r) => ({
        [isAr ? 'الصنف' : 'Item']: r.item_name,
        [isAr ? 'الباركود/الكود' : 'Code']: r.item_code || '',
        [isAr ? 'النوع' : 'Type']:
          r.item_type === 'product_ready'
            ? isAr ? 'منتج جاهز' : 'Ready Product'
            : r.item_type === 'product_component'
            ? isAr ? 'مكوّن منتج' : 'Component'
            : r.item_type === 'raw_material'
            ? isAr ? 'خامة' : 'Raw Material'
            : isAr ? 'وحدة مخزون' : 'Inventory Unit',
        [isAr ? 'الفرع' : 'Branch']: r.branch_name,
        [isAr ? 'المستودع' : 'Warehouse']: r.warehouse_name,
        [isAr ? 'الوحدة' : 'Unit']: r.unit_name,
        [isAr ? 'الرصيد الفعلي' : 'Stock Quantity']: r.stock_quantity,
        [isAr ? 'المتاح' : 'Available']: r.available_quantity,
        [isAr ? 'الحد الأدنى' : 'Min Stock']: r.min_stock,
        [isAr ? 'متوسط التكلفة' : 'Avg Cost']: r.unit_cost,
        [isAr ? 'القيمة الإجمالية' : 'Total Value']: r.total_value,
        [isAr ? 'تاريخ التحديث' : 'Updated At']: r.updated_at ? formatDate(r.updated_at) : '',
      })),
      'unified_inventory'
    );
  };

  // Helper for type badges
  const renderTypeBadge = (type: UnifiedItemType) => {
    switch (type) {
      case 'product_ready':
        return (
          <span className="inline-flex items-center gap-1 rounded-md bg-emerald-50 px-2 py-0.5 text-[11px] font-semibold text-emerald-700 ring-1 ring-inset ring-emerald-600/20 dark:bg-emerald-950/40 dark:text-emerald-400">
            <Box className="h-3 w-3" />
            {isAr ? 'منتج جاهز' : 'Ready'}
          </span>
        );
      case 'product_component':
        return (
          <span className="inline-flex items-center gap-1 rounded-md bg-blue-50 px-2 py-0.5 text-[11px] font-semibold text-blue-700 ring-1 ring-inset ring-blue-700/20 dark:bg-blue-950/40 dark:text-blue-300">
            <Layers className="h-3 w-3" />
            {isAr ? 'مكوّن' : 'Component'}
          </span>
        );
      case 'raw_material':
        return (
          <span className="inline-flex items-center gap-1 rounded-md bg-amber-50 px-2 py-0.5 text-[11px] font-semibold text-amber-700 ring-1 ring-inset ring-amber-600/20 dark:bg-amber-950/40 dark:text-amber-400">
            <Wheat className="h-3 w-3" />
            {isAr ? 'خامة' : 'Raw Material'}
          </span>
        );
      case 'inventory_unit_purchased':
      case 'inventory_unit_manufactured':
        return (
          <span className="inline-flex items-center gap-1 rounded-md bg-purple-50 px-2 py-0.5 text-[11px] font-semibold text-purple-700 ring-1 ring-inset ring-purple-600/20 dark:bg-purple-950/40 dark:text-purple-400">
            <PackageCheck className="h-3 w-3" />
            {isAr ? 'وحدة مخزون' : 'Unit'}
          </span>
        );
    }
  };

  // Table Columns
  const columns: Column<UnifiedInventoryRow>[] = [
    {
      key: 'item_name',
      header: isAr ? 'الصنف / الخامة' : 'Item / Material',
      render: (item) => (
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-ui-page-alt text-xs font-bold text-ui-subtle border border-ui-border">
            {item.item_name ? item.item_name[0] : '?'}
          </div>
          <div>
            <p className="font-semibold text-ui-text leading-tight">{item.item_name}</p>
            <div className="flex items-center gap-2 mt-1">
              {item.item_code && (
                <span className="font-mono text-xs text-ui-subtle">{item.item_code}</span>
              )}
              {renderTypeBadge(item.item_type)}
            </div>
          </div>
        </div>
      ),
    },
    {
      key: 'warehouse',
      header: isAr ? 'المستودع والفرع' : 'Warehouse & Branch',
      render: (item) => (
        <div className="space-y-1">
          <p className="font-medium text-ui-text text-xs">{item.warehouse_name}</p>
          <BranchBadge name={item.branch_name} />
        </div>
      ),
    },
    {
      key: 'stock_quantity',
      header: isAr ? 'الرصيد الفعلي' : 'Stock Quantity',
      render: (item) => {
        const isLow = item.stock_quantity > 0 && item.stock_quantity <= item.min_stock;
        const isOut = item.stock_quantity <= 0;
        return (
          <div className="flex items-center gap-2">
            <span
              className={`font-mono text-sm font-bold ${
                isOut ? 'text-ui-danger' : isLow ? 'text-ui-warning' : 'text-ui-text'
              }`}
            >
              {formatNumber(item.stock_quantity)}
            </span>
            <span className="text-xs text-ui-subtle">{item.unit_name}</span>
            {isLow && <AlertTriangle className="h-4 w-4 text-ui-warning" />}
          </div>
        );
      },
    },
    {
      key: 'min_stock',
      header: isAr ? 'الحد الأدنى' : 'Min Stock',
      render: (item) => (
        <span className="text-xs font-mono text-ui-subtle">
          {item.min_stock > 0 ? `${formatNumber(item.min_stock)} ${item.unit_name}` : '-'}
        </span>
      ),
    },
    {
      key: 'unit_cost',
      header: isAr ? 'متوسط التكلفة' : 'Avg Cost',
      render: (item) => (
        <span className="text-xs font-mono text-ui-text">
          {formatCurrency(item.unit_cost, currency, lang)}
        </span>
      ),
    },
    {
      key: 'total_value',
      header: isAr ? 'القيمة الإجمالية' : 'Total Value',
      render: (item) => (
        <span className="text-xs font-mono font-semibold text-brand-600 dark:text-brand-400">
          {formatCurrency(item.total_value, currency, lang)}
        </span>
      ),
    },
    {
      key: 'status',
      header: isAr ? 'الحالة' : 'Status',
      render: (item) => {
        const isOut = item.stock_quantity <= 0;
        const isLow = item.stock_quantity > 0 && item.stock_quantity <= item.min_stock;
        if (isOut) {
          return (
            <span className="rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900/40 dark:text-red-300">
              {isAr ? 'نفد من المخزن' : 'Out of Stock'}
            </span>
          );
        }
        if (isLow) {
          return (
            <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900/40 dark:text-amber-300">
              {isAr ? 'دون الحد الأدنى' : 'Low Stock'}
            </span>
          );
        }
        return (
          <span className="rounded-full bg-emerald-100 px-2.5 py-0.5 text-xs font-medium text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300">
            {isAr ? 'متوفر' : 'In Stock'}
          </span>
        );
      },
    },
    {
      key: 'actions',
      header: isAr ? 'إجراءات' : 'Actions',
      render: (item) =>
        can('inventory.adjust') ? (
          <button
            onClick={(e) => {
              e.stopPropagation();
              openAdjust(item);
            }}
            className="rounded-md p-1.5 text-ui-info hover:bg-ui-info-soft transition-colors"
            title={isAr ? 'تسوية رصيد المخزن' : 'Adjust Stock'}
          >
            <Edit2 className="h-4 w-4" />
          </button>
        ) : null,
    },
  ];

  return (
    <DesignSurface testId="inventory-page">
      <DesignPageHeader
        title={isAr ? 'إدارة المخزون الموحد' : 'Unified Inventory Management'}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => void loadInventory()} disabled={loading}>
              <RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
              {isAr ? 'تحديث' : 'Refresh'}
            </Button>
            <Button variant="outline" size="sm" onClick={handleExport}>
              <Download className="h-4 w-4" />
              {t('exportExcel')}
            </Button>
          </div>
        }
      />

      {/* Summary KPI Bar */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
        <div className="rounded-xl border border-ui-border bg-ui-card p-3.5 shadow-sm">
          <p className="text-xs text-ui-subtle font-medium">{isAr ? 'إجمالي الأصناف' : 'Total Items'}</p>
          <p className="text-xl font-black text-ui-text mt-1">{formatNumber(summary.totalItems)}</p>
        </div>
        <div className="rounded-xl border border-ui-border bg-ui-card p-3.5 shadow-sm">
          <p className="text-xs text-ui-subtle font-medium">{isAr ? 'القيمة الإجمالية للمخزون' : 'Total Inventory Value'}</p>
          <p className="text-xl font-black text-brand-600 dark:text-brand-400 mt-1">
            {formatCurrency(summary.totalValue, currency, lang)}
          </p>
        </div>
        <div className="rounded-xl border border-ui-border bg-ui-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between">
            <p className="text-xs text-ui-subtle font-medium">{isAr ? 'أصناف دون الحد الأدنى' : 'Low Stock Alerts'}</p>
            {summary.lowStockCount > 0 && <AlertTriangle className="h-4 w-4 text-amber-500" />}
          </div>
          <p className="text-xl font-black text-amber-600 dark:text-amber-400 mt-1">
            {formatNumber(summary.lowStockCount)}
          </p>
        </div>
        <div className="rounded-xl border border-ui-border bg-ui-card p-3.5 shadow-sm">
          <p className="text-xs text-ui-subtle font-medium">{isAr ? 'أصناف نافدة' : 'Out of Stock'}</p>
          <p className="text-xl font-black text-red-600 dark:text-red-400 mt-1">
            {formatNumber(summary.outOfStockCount)}
          </p>
        </div>
      </div>

      {/* Search & Filters */}
      <DesignPanel testId="inventory-search-panel">
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-3 sm:flex-row">
            <DesignSearch
              value={search}
              onChange={setSearch}
              className="flex-1"
              label={t('search')}
              placeholder={isAr ? 'ابحث بالاسم أو الباركود أو المستودع...' : 'Search by item, code or warehouse...'}
              testId="inventory-search"
            />
            {/* Branch Filter */}
            <Select
              value={filterBranch}
              onChange={(e) => {
                setFilterBranch(e.target.value);
                setFilterWarehouse('');
              }}
              className="sm:w-44"
            >
              <option value="">{isAr ? 'جميع الفروع' : 'All Branches'}</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
            </Select>
            {/* Warehouse Filter */}
            <Select
              value={filterWarehouse}
              onChange={(e) => setFilterWarehouse(e.target.value)}
              className="sm:w-48"
            >
              <option value="">{isAr ? 'جميع المستودعات' : 'All Warehouses'}</option>
              {availableWarehouses.map((w) => (
                <option key={w.id} value={w.id}>
                  {w.name}
                </option>
              ))}
            </Select>
          </div>

          <div className="flex flex-wrap items-center gap-2 pt-1 border-t border-ui-border">
            <span className="text-xs font-semibold text-ui-subtle ml-1">{isAr ? 'نوع الصنف:' : 'Item Type:'}</span>
            <button
              onClick={() => setFilterType('all')}
              className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                filterType === 'all'
                  ? 'bg-brand-600 text-white'
                  : 'bg-ui-page-alt text-ui-subtle hover:text-ui-text'
              }`}
            >
              {isAr ? 'الكل' : 'All'}
            </button>
            <button
              onClick={() => setFilterType('ready')}
              className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                filterType === 'ready'
                  ? 'bg-brand-600 text-white'
                  : 'bg-ui-page-alt text-ui-subtle hover:text-ui-text'
              }`}
            >
              {isAr ? 'منتجات جاهزة للبيع' : 'Ready Products'}
            </button>
            <button
              onClick={() => setFilterType('components')}
              className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                filterType === 'components'
                  ? 'bg-brand-600 text-white'
                  : 'bg-ui-page-alt text-ui-subtle hover:text-ui-text'
              }`}
            >
              {isAr ? 'مكوّنات المنتجات' : 'Components'}
            </button>
            <button
              onClick={() => setFilterType('raw')}
              className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                filterType === 'raw'
                  ? 'bg-brand-600 text-white'
                  : 'bg-ui-page-alt text-ui-subtle hover:text-ui-text'
              }`}
            >
              {isAr ? 'خامات ومواد أولية' : 'Raw Materials'}
            </button>
            <button
              onClick={() => setFilterType('units')}
              className={`px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                filterType === 'units'
                  ? 'bg-brand-600 text-white'
                  : 'bg-ui-page-alt text-ui-subtle hover:text-ui-text'
              }`}
            >
              {isAr ? 'وحدات مخزون' : 'Inventory Units'}
            </button>

            <div className="h-4 w-px bg-ui-border mx-2 hidden sm:block" />

            <span className="text-xs font-semibold text-ui-subtle ml-1">{isAr ? 'حالة الرصيد:' : 'Stock Status:'}</span>
            <Select
              value={filterStatus}
              onChange={(e) => setFilterStatus(e.target.value as typeof filterStatus)}
              className="w-36 text-xs h-8"
            >
              <option value="all">{isAr ? 'كل الحالات' : 'All'}</option>
              <option value="in_stock">{isAr ? 'متوفر' : 'In Stock'}</option>
              <option value="low_stock">{isAr ? 'دون الحد الأدنى' : 'Low Stock'}</option>
              <option value="out_of_stock">{isAr ? 'نافد' : 'Out of Stock'}</option>
            </Select>
          </div>
        </div>
      </DesignPanel>

      {/* Table Panel */}
      <DesignPanel testId="inventory-table-panel">
        <DataTable
          columns={columns}
          data={filtered}
          loading={loading}
          error={error}
          emptyMessage={isAr ? 'لا توجد أصناف تطابق معايير البحث في هذا المستودع' : t('noData')}
          onRowClick={can('inventory.adjust') ? openAdjust : undefined}
        />
      </DesignPanel>

      {/* Adjust Stock Modal */}
      <Modal
        open={!!adjustModal}
        onClose={() => !adjusting && setAdjustModal(null)}
        title={isAr ? 'تسوية رصيد المخزن' : t('adjustStock')}
        size="sm"
      >
        {adjustModal && (
          <div className="space-y-4">
            <div className="rounded-lg bg-ui-page-alt p-3 border border-ui-border space-y-1.5">
              <div className="flex items-center justify-between">
                <span className="text-xs text-ui-subtle">{isAr ? 'اسم الصنف:' : 'Item Name:'}</span>
                <span className="text-xs font-bold text-ui-text">{adjustModal.item_name}</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-xs text-ui-subtle">{isAr ? 'النوع:' : 'Type:'}</span>
                {renderTypeBadge(adjustModal.item_type)}
              </div>
              <div className="flex items-center justify-between">
                <span className="text-xs text-ui-subtle">{isAr ? 'المستودع:' : 'Warehouse:'}</span>
                <span className="text-xs font-semibold text-ui-text">{adjustModal.warehouse_name}</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-xs text-ui-subtle">{isAr ? 'الفرع:' : 'Branch:'}</span>
                <span className="text-xs font-semibold text-ui-text">{adjustModal.branch_name}</span>
              </div>
              <div className="flex items-center justify-between pt-1 border-t border-ui-border">
                <span className="text-xs text-ui-subtle">{isAr ? 'الرصيد الحالي:' : 'Current Stock:'}</span>
                <span className="text-xs font-mono font-black text-ui-text">
                  {formatNumber(adjustModal.stock_quantity)} {adjustModal.unit_name}
                </span>
              </div>
            </div>

            <Input
              label={isAr ? 'الرصيد الفعلي الجديد' : t('currentStock')}
              type="number"
              step="0.0001"
              value={adjustQty}
              onChange={(e) => setAdjustQty(parseFloat(e.target.value) || 0)}
              required
            />

            <Input
              label={t('reason')}
              value={adjustReason}
              onChange={(e) => setAdjustReason(e.target.value)}
              placeholder={isAr ? 'مثال: جرد مخزني، تلف مواد، تسوية رصيد' : 'e.g. inventory count, damaged, correction'}
              required
            />

            <div className="flex justify-end gap-2 pt-2">
              <Button variant="secondary" onClick={() => setAdjustModal(null)} disabled={adjusting}>
                {t('cancel')}
              </Button>
              <Button onClick={() => void saveAdjust()} disabled={adjusting}>
                {adjusting ? (isAr ? 'جاري الحفظ...' : 'Saving...') : t('save')}
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </DesignSurface>
  );
}
