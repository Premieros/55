import { useEffect, useMemo, useState } from 'react'
import toast from 'react-hot-toast'
import api, { getErrorMessage } from '../api'
import Button from '../components/Button'
import Card from '../components/Card'
import Input from '../components/Input'
import Loading from '../components/Loading'
import { PlusIcon, TrashIcon, BeakerIcon } from '@heroicons/react/24/outline'

interface Ingredient {
  id: string
  name: string
  unit: string
  current_stock: number | string
  reorder_level: number | string
  cost_per_unit: number | string
}
interface MenuItem { id: string; name: string; price: number | string }
interface RecipeLine { ingredient_id: string; quantity: number }

const Recipes: React.FC = () => {
  const isAr = document.documentElement.lang === 'ar'
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [ingredients, setIngredients] = useState<Ingredient[]>([])
  const [menuItems, setMenuItems] = useState<MenuItem[]>([])
  const [selected, setSelected] = useState('')
  const [lines, setLines] = useState<RecipeLine[]>([])
  const [recipeCost, setRecipeCost] = useState(0)
  const [newIngredient, setNewIngredient] = useState({ name: '', unit: 'g', current_stock: '0', reorder_level: '0', cost_per_unit: '0' })

  const t = (ar: string, en: string) => isAr ? ar : en
  const money = (n: number) => `${n.toLocaleString(isAr ? 'ar-EG' : 'en-EG', { maximumFractionDigits: 2 })} L.E`

  async function loadBase() {
    try {
      const [ir, mr] = await Promise.all([
        api.get('/menus/recipes/ingredients'),
        api.get('/menus/items'),
      ])
      setIngredients(ir.data.data || [])
      const items = mr.data.data || []
      setMenuItems(items)
      if (!selected && items[0]?.id) setSelected(items[0].id)
    } catch (e) { toast.error(getErrorMessage(e)) }
    finally { setLoading(false) }
  }

  useEffect(() => { loadBase() }, [])

  useEffect(() => {
    if (!selected) return
    api.get(`/menus/recipes/${selected}`)
      .then((r) => {
        const data = r.data.data
        setLines((data.ingredients || []).map((x: any) => ({ ingredient_id: x.ingredient_id, quantity: Number(x.quantity) })))
        setRecipeCost(Number(data.recipe_cost || 0))
      })
      .catch((e) => toast.error(getErrorMessage(e)))
  }, [selected])

  const calculatedCost = useMemo(() => lines.reduce((sum, l) => {
    const ing = ingredients.find(i => i.id === l.ingredient_id)
    return sum + Number(ing?.cost_per_unit || 0) * Number(l.quantity || 0)
  }, 0), [lines, ingredients])

  async function addIngredient(e: React.FormEvent) {
    e.preventDefault()
    try {
      const r = await api.post('/menus/recipes/ingredients', {
        name: newIngredient.name,
        unit: newIngredient.unit,
        current_stock: Number(newIngredient.current_stock),
        reorder_level: Number(newIngredient.reorder_level),
        cost_per_unit: Number(newIngredient.cost_per_unit),
      })
      setIngredients(p => [...p, r.data.data].sort((a,b) => a.name.localeCompare(b.name)))
      setNewIngredient({ name: '', unit: 'g', current_stock: '0', reorder_level: '0', cost_per_unit: '0' })
      toast.success(t('تمت إضافة المكوّن', 'Ingredient added'))
    } catch (e) { toast.error(getErrorMessage(e)) }
  }

  async function saveRecipe() {
    if (!selected) return
    setSaving(true)
    try {
      const r = await api.put(`/menus/recipes/${selected}`, { ingredients: lines })
      setRecipeCost(Number(r.data.data.recipe_cost || calculatedCost))
      toast.success(t('تم حفظ الوصفة', 'Recipe saved'))
    } catch (e) { toast.error(getErrorMessage(e)) }
    finally { setSaving(false) }
  }

  if (loading) return <Loading text={t('جاري تحميل المكونات…', 'Loading ingredients…')} />

  return <div className="space-y-5 animate-fade-in" dir={isAr ? 'rtl' : 'ltr'}>
    <div>
      <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2"><BeakerIcon className="w-7 h-7" />{t('المكونات والوصفات', 'Ingredients & Recipes')}</h1>
      <p className="text-sm text-gray-500 mt-1">{t('عرّف الخامات ثم اربط كمية كل خامة بمنتج المنيو. عند اكتمال صنف المطبخ تُخصم الخامات مرة واحدة تلقائيًا.', 'Define raw ingredients, then attach quantities to menu items. Ingredients are deducted once when the kitchen item is completed.')}</p>
    </div>

    <Card>
      <h2 className="font-semibold text-gray-900 mb-4">{t('إضافة خامة', 'Add ingredient')}</h2>
      <form onSubmit={addIngredient} className="grid grid-cols-1 md:grid-cols-6 gap-3 items-end">
        <Input label={t('الاسم', 'Name')} value={newIngredient.name} onChange={e=>setNewIngredient({...newIngredient,name:e.target.value})} required />
        <Input label={t('الوحدة', 'Unit')} value={newIngredient.unit} onChange={e=>setNewIngredient({...newIngredient,unit:e.target.value})} placeholder="g / kg / ml / unit" required />
        <Input label={t('الرصيد', 'Stock')} type="number" step="0.0001" value={newIngredient.current_stock} onChange={e=>setNewIngredient({...newIngredient,current_stock:e.target.value})} />
        <Input label={t('حد الطلب', 'Reorder level')} type="number" step="0.0001" value={newIngredient.reorder_level} onChange={e=>setNewIngredient({...newIngredient,reorder_level:e.target.value})} />
        <Input label={t('تكلفة الوحدة', 'Unit cost')} type="number" step="0.0001" value={newIngredient.cost_per_unit} onChange={e=>setNewIngredient({...newIngredient,cost_per_unit:e.target.value})} />
        <Button type="submit" leftIcon={<PlusIcon className="w-4 h-4" />}>{t('إضافة', 'Add')}</Button>
      </form>
    </Card>

    <Card>
      <div className="flex flex-col md:flex-row md:items-end gap-4 justify-between mb-5">
        <div className="min-w-[280px]">
          <label className="block text-sm font-medium text-gray-700 mb-1">{t('منتج المنيو', 'Menu item')}</label>
          <select className="form-select w-full" value={selected} onChange={e=>setSelected(e.target.value)}>
            {menuItems.map(i=><option key={i.id} value={i.id}>{i.name}</option>)}
          </select>
        </div>
        <div className="text-sm">
          <span className="text-gray-500">{t('تكلفة الوصفة:', 'Recipe cost:')} </span>
          <strong>{money(calculatedCost || recipeCost)}</strong>
        </div>
      </div>

      <div className="space-y-3">
        {lines.map((line, idx) => <div key={`${line.ingredient_id}-${idx}`} className="grid grid-cols-[1fr_160px_44px] gap-3 items-end">
          <div>
            <label className="block text-xs text-gray-500 mb-1">{t('الخامة', 'Ingredient')}</label>
            <select className="form-select w-full" value={line.ingredient_id} onChange={e=>setLines(p=>p.map((x,i)=>i===idx?{...x,ingredient_id:e.target.value}:x))}>
              <option value="">{t('اختر خامة', 'Choose ingredient')}</option>
              {ingredients.map(i=><option key={i.id} value={i.id}>{i.name} ({i.unit}) — {t('متاح', 'stock')} {Number(i.current_stock).toLocaleString()}</option>)}
            </select>
          </div>
          <Input label={t('الكمية/منتج', 'Qty / item')} type="number" min="0.0001" step="0.0001" value={line.quantity} onChange={e=>setLines(p=>p.map((x,i)=>i===idx?{...x,quantity:Number(e.target.value)}:x))} />
          <button type="button" onClick={()=>setLines(p=>p.filter((_,i)=>i!==idx))} className="h-10 rounded-lg text-red-600 hover:bg-red-50 flex items-center justify-center"><TrashIcon className="w-5 h-5" /></button>
        </div>)}
      </div>

      <div className="flex flex-wrap gap-3 mt-5">
        <Button variant="outline" onClick={()=>setLines(p=>[...p,{ingredient_id:ingredients[0]?.id || '',quantity:1}])} disabled={!ingredients.length} leftIcon={<PlusIcon className="w-4 h-4" />}>{t('إضافة مكوّن للوصفة', 'Add recipe ingredient')}</Button>
        <Button onClick={saveRecipe} loading={saving} disabled={!selected}>{t('حفظ الوصفة', 'Save recipe')}</Button>
      </div>
    </Card>

    <Card>
      <h2 className="font-semibold mb-3">{t('الخامات الحالية', 'Ingredient stock')}</h2>
      <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="border-b text-gray-500"><th className="text-start py-2">{t('الخامة','Ingredient')}</th><th className="text-start">{t('الوحدة','Unit')}</th><th className="text-start">{t('الرصيد','Stock')}</th><th className="text-start">{t('حد الطلب','Reorder')}</th><th className="text-start">{t('التكلفة','Cost')}</th></tr></thead><tbody>
        {ingredients.map(i=><tr key={i.id} className="border-b last:border-0"><td className="py-2 font-medium">{i.name}</td><td>{i.unit}</td><td className={Number(i.current_stock)<=Number(i.reorder_level)?'text-red-600 font-semibold':''}>{Number(i.current_stock).toLocaleString()}</td><td>{Number(i.reorder_level).toLocaleString()}</td><td>{money(Number(i.cost_per_unit))}</td></tr>)}
      </tbody></table></div>
    </Card>
  </div>
}

export default Recipes
