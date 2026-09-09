import { useEffect, useMemo, useState, useCallback } from 'react';
import { useLocation } from 'react-router-dom';
import { Factory, PackageCheck, Play, RefreshCw } from 'lucide-react';
import * as api from '@/api';
import { supabase } from '@/api';
import { useLanguage } from '@/context/LanguageContext';
import { useToast } from '@/components/Toast';
import { useAuth } from '@/context/AuthContext';
import { useBranchFilter } from '@/lib/useBranchFilter';
import { useCan } from '@/lib/permissions';
import { DesignSurface, DesignPageHeader, DesignPanel } from '@/components/design';
import { Button } from '@/components/Button';
import { Input, Select } from '@/components/Input';
import { formatNumber } from '@/lib/format';
import { logAudit } from '@/lib/audit';
import { useOperationalGuard, PrerequisiteAlertBanner, PREREQUISITE_STEPS } from '@/core/guard';
import type { InventoryUnit, Warehouse } from '@/lib/types';

type RecipeRow = { raw_material_id: string; quantity: number; wastage_percent: number; raw_material?: { name: string } | null };
type ProductionRow = { id: string; unit_id: string; warehouse_id: string; quantity: number; total_cost: number; status: string; created_at: string };

type RecipeQueryRow = {
  raw_material_id: string;
  quantity: number;
  wastage_percent: number;
  raw_material?: { name: string } | { name: string }[] | null;
};

export function UnitProductionPage() {
  const { lang } = useLanguage();
  const { show } = useToast();
  const { user } = useAuth();
  const branchFilter = useBranchFilter();
  const can = useCan();
  const location = useLocation();
  const isAr = lang === 'ar';
  const {
    guardProduction,
    interceptDbError,
    startGuidance,
  } = useOperationalGuard();

  const [units, setUnits] = useState<InventoryUnit[]>([]);
  const [warehouses, setWarehouses] = useState<Warehouse[]>([]);
  const [recipes, setRecipes] = useState<RecipeRow[]>([]);
  const [recent, setRecent] = useState<ProductionRow[]>([]);
  const [unitId, setUnitId] = useState('');
  const [warehouseId, setWarehouseId] = useState('');
  const [quantity, setQuantity] = useState(1);
  const [loading, setLoading] = useState(false);
  const [metaLoading, setMetaLoading] = useState(false);

  const branchId = branchFilter || user?.branch_id || '';

  const loadMeta = useCallback(async () => {
    setMetaLoading(true);
    const unitQuery = supabase.from('inventory_units').select('*').eq('is_active', true).eq('unit_type', 'manufactured').order('name');
    if (branchId) unitQuery.eq('branch_id', branchId);
    const warehouseQuery = supabase.from('warehouses').select('*').eq('is_active', true).order('name');
    if (branchId) warehouseQuery.eq('branch_id', branchId);
    const recentQuery = supabase.from('inventory_unit_productions').select('*').order('created_at', { ascending: false }).limit(20);
    if (branchId) recentQuery.eq('branch_id', branchId);
    const [u, w, r] = await Promise.all([unitQuery, warehouseQuery, recentQuery]);
    setUnits((u.data as InventoryUnit[]) || []);
    setWarehouses((w.data as Warehouse[]) || []);
    setRecent((r.data as ProductionRow[]) || []);
    setMetaLoading(false);
  }, [branchId]);

  useEffect(() => { void loadMeta(); }, [loadMeta]);

  // Restore draft if returning from guided prerequisite setup
  useEffect(() => {
    const state = location.state as { restoredDraft?: { unitId?: string; warehouseId?: string; quantity?: number }; fromGuidance?: boolean } | null;
    if (state?.fromGuidance && state?.restoredDraft) {
      if (state.restoredDraft.unitId) setUnitId(state.restoredDraft.unitId);
      if (state.restoredDraft.warehouseId) setWarehouseId(state.restoredDraft.warehouseId);
      if (state.restoredDraft.quantity) setQuantity(state.restoredDraft.quantity);
    }
  }, [location.state]);

  const selectedUnit = useMemo(() => units.find((u) => u.id === unitId) || null, [units, unitId]);

  const loadRecipe = useCallback(async (id: string) => {
    if (!id) { setRecipes([]); return; }
    const { data, error } = await supabase.from('inventory_unit_recipes')
      .select('raw_material_id, quantity, wastage_percent, raw_material:raw_materials(name)')
      .eq('unit_id', id)
      .order('created_at');
    if (error) { show(error.message, 'error'); return; }
    const rows = (data ?? []) as RecipeQueryRow[];
    setRecipes(rows.map((row) => ({
      raw_material_id: row.raw_material_id,
      quantity: Number(row.quantity),
      wastage_percent: Number(row.wastage_percent),
      raw_material: Array.isArray(row.raw_material) ? row.raw_material[0] ?? null : row.raw_material ?? null,
    })));
  }, [show]);

  useEffect(() => { void loadRecipe(unitId); }, [loadRecipe, unitId]);

  const produce = async () => {
    if (!can('production.manage')) {
      show(isAr ? 'ليس لديك صلاحية لإدارة الإنتاج' : 'No permission for production management', 'error');
      return;
    }
    const allowed = guardProduction({
      warehousesCount: warehouses.length,
      recipesCount: recipes.length,
      formData: { unitId, warehouseId, quantity },
    });
    if (!allowed) return;

    if (!unitId || !warehouseId || quantity <= 0) {
      show(isAr ? 'اختر الوحدة والمخزن والكمية' : 'Select unit, warehouse and quantity', 'error');
      return;
    }
    if (!recipes.length) {
      show(isAr ? 'الوحدة لا تحتوي Recipe' : 'This unit has no recipe', 'error');
      return;
    }
    setLoading(true);
    try {
      const productionId = await api.catalog.produceInventoryUnit(unitId, quantity, warehouseId, isAr ? 'إنتاج وحدة من شاشة إنتاج الوحدات' : 'Unit production');
      await logAudit('create', 'inventory_unit_productions', String(productionId), { unit_id: unitId, quantity, warehouse_id: warehouseId });
      show(isAr ? 'تم تصنيع الوحدة وتحديث المخزون' : 'Unit produced and inventory updated', 'success');
      await loadMeta();
    } catch (e) {
      const handled = interceptDbError(e, 'production_create', 'أمر تصنيع وحدة', 'Manufacture Unit', { unitId, warehouseId, quantity });
      if (!handled) {
        show(e instanceof Error ? e.message : String(e), 'error');
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <DesignSurface testId="unit-production-page">
      <DesignPageHeader
        title={isAr ? 'إنتاج الوحدات' : 'Unit Production'}
        subtitle={isAr ? 'الخامات → Recipe الوحدة → تصنيع الوحدة → مخزون الوحدة' : 'Raw materials → unit recipe → production → unit inventory'}
        actions={<Button variant="outline" size="sm" onClick={() => void loadMeta()} disabled={metaLoading}><RefreshCw className="w-4 h-4" /> {isAr ? 'تحديث' : 'Refresh'}</Button>}
      />

      {warehouses.length === 0 && !metaLoading && (
        <PrerequisiteAlertBanner
          step={PREREQUISITE_STEPS.create_warehouse}
          onAction={() =>
            startGuidance(
              PREREQUISITE_STEPS.create_warehouse,
              'production_create',
              location.pathname,
              { unitId, warehouseId, quantity },
              'إنتاج الوحدات',
              'Unit Production'
            )
          }
        />
      )}

      {units.length === 0 && !metaLoading && (
        <PrerequisiteAlertBanner
          step={PREREQUISITE_STEPS.create_unit}
          onAction={() =>
            startGuidance(
              PREREQUISITE_STEPS.create_unit,
              'production_create',
              location.pathname,
              { unitId, warehouseId, quantity },
              'إنتاج الوحدات',
              'Unit Production'
            )
          }
        />
      )}

      <div className="grid gap-4 xl:grid-cols-[1.1fr_0.9fr]">
        <DesignPanel>
          <div className="mb-4 flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-ui-primary-soft text-ui-primary"><Factory className="h-5 w-5" /></div>
            <div><h2 className="font-bold text-ui-text">{isAr ? 'أمر تصنيع وحدة' : 'Manufacture Unit'}</h2><p className="text-sm text-ui-muted">{isAr ? 'هذا المسار يستهلك الخامات ويزيد مخزون الوحدة فقط.' : 'This flow consumes raw materials and increases unit stock only.'}</p></div>
          </div>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Select label={isAr ? 'الوحدة المصنّعة' : 'Manufactured unit'} value={unitId} onChange={(e) => setUnitId(e.target.value)}>
              <option value="">--</option>{units.map((u) => <option key={u.id} value={u.id}>{u.name} · {u.code}</option>)}
            </Select>
            <Select label={isAr ? 'مخزن الإخراج' : 'Output warehouse'} value={warehouseId} onChange={(e) => setWarehouseId(e.target.value)}>
              <option value="">--</option>{warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
            </Select>
            <Input label={isAr ? 'الكمية' : 'Quantity'} type="number" min={0.0001} step="0.0001" value={quantity} onChange={(e) => setQuantity(Number(e.target.value) || 0)} />
          </div>

          {selectedUnit && (
            <div className="mt-5 rounded-xl border border-ui-border bg-ui-surface p-4">
              <div className="mb-3 flex items-center justify-between"><div><p className="font-semibold text-ui-text">{selectedUnit.name}</p><p className="text-xs text-ui-muted">{selectedUnit.code} · {isAr ? 'مصنّعة' : 'Manufactured'}</p></div><PackageCheck className="h-5 w-5 text-ui-primary" /></div>
              <div className="space-y-2">
                {recipes.map((r, i) => <div key={`${r.raw_material_id}-${i}`} className="flex items-center justify-between rounded-lg bg-ui-bg px-3 py-2 text-sm"><span className="text-ui-text">{r.raw_material?.name || r.raw_material_id}</span><span className="font-semibold text-ui-text">× {formatNumber(Number(r.quantity) * quantity * (1 + Number(r.wastage_percent) / 100), 4)}</span></div>)}
                {!recipes.length && <p className="text-sm text-ui-muted">{isAr ? 'لا توجد Recipe لهذه الوحدة.' : 'No recipe configured for this unit.'}</p>}
              </div>
            </div>
          )}

          <div className="mt-5 flex justify-end"><Button onClick={produce} disabled={loading || !selectedUnit || !recipes.length}><Play className="w-4 h-4" /> {loading ? '...' : (isAr ? 'تنفيذ التصنيع' : 'Produce Unit')}</Button></div>
        </DesignPanel>

        <DesignPanel>
          <div className="mb-4"><h2 className="font-bold text-ui-text">{isAr ? 'آخر عمليات التصنيع' : 'Recent production'}</h2><p className="text-sm text-ui-muted">{isAr ? 'دفعات الوحدات الناتجة من التصنيع.' : 'Recent unit production batches.'}</p></div>
          <div className="space-y-2">
            {recent.map((r) => { const unit = units.find((u) => u.id === r.unit_id); const warehouse = warehouses.find((w) => w.id === r.warehouse_id); return <div key={r.id} className="rounded-lg border border-ui-border p-3"><div className="flex items-center justify-between"><span className="font-medium text-ui-text">{unit?.name || r.unit_id}</span><span className="text-xs text-ui-muted">{r.status}</span></div><div className="mt-1 text-xs text-ui-muted">{warehouse?.name || r.warehouse_id} · {formatNumber(Number(r.quantity), 4)} · {formatNumber(Number(r.total_cost), 2)}</div></div>; })}
            {!recent.length && <p className="text-sm text-ui-muted">{isAr ? 'لا توجد عمليات تصنيع بعد.' : 'No production runs yet.'}</p>}
          </div>
        </DesignPanel>
      </div>
    </DesignSurface>
  );
}
