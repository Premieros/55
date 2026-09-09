import { useCallback, useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, Package, Edit2, AlertTriangle, Layers } from 'lucide-react';
import { supabase } from '@/api';
import { useLanguage } from '@/context/LanguageContext';
import { useToast } from '@/components/Toast';
import { useCan } from '@/lib/permissions';
import { useSettings } from '@/context/SettingsContext';
import { useBranchFilter } from '@/lib/useBranchFilter';
import { DesignSurface, DesignPageHeader, DesignPanel } from '@/components/design';
import { Button } from '@/components/Button';
import { Input, Select } from '@/components/Input';
import { Modal } from '@/components/Modal';
import { ConfirmDialog } from '@/components/ConfirmDialog';
import { formatCurrency, formatNumber } from '@/lib/format';
import { logAudit } from '@/lib/audit';
import type { Product, ProductComponent } from '@/lib/types';

interface ComponentWithProduct extends ProductComponent {
  component_product?: Product;
}

export function ComponentsPage() {
  const { t, lang } = useLanguage();
  const isAr = lang === 'ar';
  const { show } = useToast();
  const can = useCan();
  const branchFilter = useBranchFilter();
  const { effectiveSettings } = useSettings();
  const currency = effectiveSettings(branchFilter)?.currency || 'EGP';
  const [products, setProducts] = useState<Product[]>([]);
  const [selectedProductId, setSelectedProductId] = useState('');
  const [components, setComponents] = useState<ComponentWithProduct[]>([]);
  const [inventoryMap, setInventoryMap] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [modalOpen, setModalOpen] = useState(false);
  const [editModal, setEditModal] = useState<{ id: string; quantity: number } | null>(null);
  const [deleteId, setDeleteId] = useState<string | null>(null);
  const [form, setForm] = useState({ component_product_id: '', quantity: 1 });

  const availableComponents = useMemo(() => products.filter(
    (p) => p.id !== selectedProductId && !components.some((c) => c.component_product_id === p.id)
  ), [components, products, selectedProductId]);

  const loadProducts = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    let productQuery = supabase.from('products').select('*').eq('is_active', true);
    if (branchFilter) productQuery = productQuery.eq('branch_id', branchFilter);
    const inventoryQuery = supabase.from('inventory').select('product_id, quantity, warehouse:warehouses(branch_id)');

    const [{ data: p, error: productError }, { data: inv, error: inventoryError }] = await Promise.all([
      productQuery.order('name'),
      inventoryQuery,
    ]);

    if (productError) {
      setProducts([]);
      setLoadError(productError.message);
      setLoading(false);
      return;
    }

    setProducts((p as Product[]) || []);
    const map: Record<string, number> = {};
    if (!inventoryError) {
      for (const r of (inv || []) as unknown as { product_id: string; quantity: number; warehouse?: { branch_id?: string | null } | null }[]) {
        if (branchFilter && r.warehouse?.branch_id !== branchFilter) continue;
        map[r.product_id] = (map[r.product_id] || 0) + Number(r.quantity || 0);
      }
    }
    setInventoryMap(map);
    setLoading(false);
  }, [branchFilter]);

  const loadComponents = useCallback(async (productId: string) => {
    if (!productId) { setComponents([]); return; }
    const { data, error } = await supabase
      .from('product_components')
      .select('*, component_product:products(*)')
      .eq('product_id', productId)
      .order('created_at');
    if (error) { show(error.message, 'error'); setComponents([]); return; }
    setComponents((data as ComponentWithProduct[]) || []);
  }, [show]);

  useEffect(() => { void loadProducts(); }, [loadProducts]);
  useEffect(() => {
    if (selectedProductId && !products.some((p) => p.id === selectedProductId)) setSelectedProductId('');
  }, [products, selectedProductId]);
  useEffect(() => {
    if (!selectedProductId) return;
    void loadComponents(selectedProductId);
  }, [loadComponents, selectedProductId]);

  const addComponent = async () => {
    if (!selectedProductId || !form.component_product_id || form.quantity <= 0) { show(t('required'), 'error'); return; }
    const { error } = await supabase.from('product_components').insert({
      product_id: selectedProductId,
      component_product_id: form.component_product_id,
      quantity: form.quantity,
    });
    if (error) { show(error.message, 'error'); return; }
    await logAudit('create', 'product_components', undefined, { product_id: selectedProductId });
    show(t('saveSuccess'), 'success');
    setModalOpen(false);
    setForm({ component_product_id: '', quantity: 1 });
    await loadComponents(selectedProductId);
  };

  const removeComponent = async () => {
    if (!deleteId) return;
    const { error } = await supabase.from('product_components').delete().eq('id', deleteId);
    if (error) show(error.message, 'error');
    else { show(t('deleteSuccess'), 'success'); await logAudit('delete', 'product_components', deleteId); }
    setDeleteId(null);
    await loadComponents(selectedProductId);
  };

  const saveEditQty = async () => {
    if (!editModal || editModal.quantity <= 0) { show(t('required'), 'error'); return; }
    const { error } = await supabase.from('product_components').update({ quantity: editModal.quantity }).eq('id', editModal.id);
    if (error) { show(error.message, 'error'); return; }
    await logAudit('update', 'product_components', editModal.id, { quantity: editModal.quantity });
    show(t('saveSuccess'), 'success');
    setEditModal(null);
    await loadComponents(selectedProductId);
  };

  const selectedProduct = products.find((p) => p.id === selectedProductId);
  const componentCost = components.reduce((sum, c) => sum + Number(c.component_product?.cost_price || 0) * Number(c.quantity || 0), 0);

  return (
    <DesignSurface testId="components-page">
      <DesignPageHeader title={t('components')} subtitle={isAr ? 'تركيبة المنتجات من منتجات المخزون الفعلية' : 'Build products from active inventory products'} />

      <DesignPanel testId="components-panel">
        <div className="mb-4">
          <Select label={t('product')} value={selectedProductId} onChange={(e) => setSelectedProductId(e.target.value)} disabled={loading || products.length === 0}>
            <option value="" disabled>{isAr ? '-- اختر منتجاً --' : '-- Select product --'}</option>
            {products.map((p) => <option key={p.id} value={p.id}>{p.name} ({formatCurrency(p.cost_price, currency, lang)})</option>)}
          </Select>
        </div>

        {!loading && loadError && (
          <div className="rounded-xl border border-ui-danger/20 bg-ui-danger-soft p-4 text-sm text-ui-danger">{loadError}</div>
        )}

        {!loading && !loadError && products.length === 0 && (
          <div className="text-center py-16 text-ui-subtle">
            <Package className="w-16 h-16 mx-auto mb-3 opacity-30" />
            <p className="font-semibold text-ui-text">{isAr ? 'لا توجد منتجات نشطة في هذا الفرع' : 'No active products in this branch'}</p>
            <p className="mt-1 text-sm">{isAr ? 'أنشئ منتجاً أولاً ثم عد لإدارة مكوناته.' : 'Create a product first, then return to manage its components.'}</p>
          </div>
        )}

        {!loading && !loadError && selectedProductId && (
          <>
            {components.length === 0 && (
              <div className="flex items-center gap-3 mb-4 p-3 rounded-lg bg-ui-warning-soft border border-ui-warning/20 text-ui-warning text-sm">
                <AlertTriangle className="w-5 h-5 flex-shrink-0" />
                <p>{isAr ? 'لا توجد مكونات لهذا المنتج حتى الآن.' : 'This product has no components yet.'}</p>
              </div>
            )}

            {selectedProduct && (
              <div className="flex items-center gap-4 mb-4 p-3 bg-ui-page-alt rounded-lg">
                <div className="w-10 h-10 rounded-lg bg-brand-100 dark:bg-brand-900/30 flex items-center justify-center"><Package className="w-5 h-5 text-brand-600 dark:text-brand-400" /></div>
                <div className="flex-1 min-w-0">
                  <p className="font-medium text-ui-text truncate">{selectedProduct.name}</p>
                  <p className="text-xs text-ui-subtle">{isAr ? 'سعر البيع' : 'Sale Price'}: {formatCurrency(selectedProduct.sale_price, currency, lang)} · {isAr ? 'التكلفة' : 'Cost'}: {formatCurrency(selectedProduct.cost_price, currency, lang)}</p>
                </div>
                <div className="text-end">
                  <p className="text-xs text-ui-subtle">{isAr ? 'تكلفة المكونات' : 'Component Cost'}</p>
                  <p className={`font-bold ${componentCost > selectedProduct.sale_price ? 'text-ui-danger' : 'text-brand-600'}`}>{formatCurrency(componentCost, currency, lang)}</p>
                </div>
              </div>
            )}

            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-semibold text-ui-muted">{isAr ? 'المكونات' : 'Components'} ({components.length})</h3>
              <Button onClick={() => { setForm({ component_product_id: '', quantity: 1 }); setModalOpen(true); }} disabled={!availableComponents.length || !can('components.manage')}>
                <Plus className="w-4 h-4" /> {t('addComponent')}
              </Button>
            </div>

            {components.length === 0 ? (
              <div className="text-center py-10 text-ui-subtle"><Package className="w-12 h-12 mx-auto mb-2 opacity-30" /><p className="text-sm">{t('noComponents')}</p></div>
            ) : (
              <div className="space-y-2">
                {components.map((c) => (
                  <div key={c.id} className="flex items-center gap-3 p-3 bg-ui-surface rounded-lg border border-ui-border">
                    <div className="w-10 h-10 rounded-lg bg-ui-page-alt flex items-center justify-center overflow-hidden">
                      {c.component_product?.image_url ? <img src={c.component_product.image_url} className="w-full h-full object-cover" alt="" /> : <Package className="w-5 h-5 text-ui-subtle" />}
                    </div>
                    <div className="flex-1 min-w-0"><p className="text-sm font-medium text-ui-text truncate">{c.component_product?.name || '-'}</p><p className="text-xs text-ui-subtle">{formatCurrency(c.component_product?.cost_price || 0, currency, lang)} × {c.quantity}</p></div>
                    <div className="flex items-center gap-1 text-xs" title={t('componentStock')}><Layers className="w-3.5 h-3.5 text-ui-subtle" /><span className={(inventoryMap[c.component_product_id] || 0) > 0 ? 'text-brand-600 font-semibold' : 'text-ui-danger font-semibold'}>{formatNumber(inventoryMap[c.component_product_id] || 0)}</span></div>
                    <span className="text-sm font-bold text-brand-600">{formatCurrency((c.component_product?.cost_price || 0) * Number(c.quantity), currency, lang)}</span>
                    {can('components.manage') && <button onClick={() => setEditModal({ id: c.id, quantity: Number(c.quantity) })} className="p-2 text-ui-subtle hover:text-ui-info"><Edit2 className="w-4 h-4" /></button>}
                    {can('components.manage') && <button onClick={() => setDeleteId(c.id)} className="p-2 text-ui-subtle hover:text-ui-danger"><Trash2 className="w-4 h-4" /></button>}
                  </div>
                ))}
              </div>
            )}
          </>
        )}

        {!loading && !loadError && products.length > 0 && !selectedProductId && (
          <div className="text-center py-16 text-ui-subtle"><Package className="w-16 h-16 mx-auto mb-3 opacity-30" /><p className="text-sm">{isAr ? 'اختر منتجاً لإدارة مكوناته' : 'Select a product to manage its components'}</p></div>
        )}
      </DesignPanel>

      <Modal open={!!editModal} onClose={() => setEditModal(null)} title={t('editComponentQty')} size="sm">
        {editModal && <div className="space-y-4"><Input label={t('componentQuantity')} type="number" value={editModal.quantity} onChange={(e) => setEditModal({ ...editModal, quantity: parseFloat(e.target.value) || 1 })} min={0.001} /><Button className="w-full" onClick={saveEditQty}>{t('save')}</Button></div>}
      </Modal>

      <Modal open={modalOpen} onClose={() => setModalOpen(false)} title={t('addComponent')} size="sm">
        <div className="space-y-4">
          <Select label={t('componentProduct')} value={form.component_product_id} onChange={(e) => setForm({ ...form, component_product_id: e.target.value })}>
            <option value="" disabled>-- {t('selectComponentProduct')} --</option>
            {availableComponents.map((p) => <option key={p.id} value={p.id}>{p.name} ({formatCurrency(p.cost_price, currency, lang)})</option>)}
          </Select>
          <Input label={t('componentQuantity')} type="number" value={form.quantity} onChange={(e) => setForm({ ...form, quantity: parseFloat(e.target.value) || 1 })} min={0.001} />
          <Button className="w-full" onClick={addComponent}>{t('save')}</Button>
        </div>
      </Modal>

      <ConfirmDialog open={!!deleteId} onClose={() => setDeleteId(null)} onConfirm={removeComponent} title={t('delete')} message={isAr ? 'هل أنت متأكد من حذف هذا المكون؟' : 'Are you sure you want to delete this component?'} />
    </DesignSurface>
  );
}
