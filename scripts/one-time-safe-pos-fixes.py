from pathlib import Path
import json, shutil, subprocess

ROOT = Path('.tmp-safe-pos-fixes')
ZIP = Path('johna-s.zip')
if ROOT.exists(): shutil.rmtree(ROOT)
ROOT.mkdir()
subprocess.run(['unzip','-q',str(ZIP),'-d',str(ROOT)], check=True)

# 1) POS availability: product_components is not the authority for manufactured stock.
p = ROOT / 'src/features/pos/components/catalog/ProductBrowser.tsx'
s = p.read_text(encoding='utf-8')
s = s.replace("export function ProductBrowser({ products, categories, stockMap, sellableStock, recipeMap, search, selectedCategory, currency, hasBranch, canModifyOrder, onSearch, onSelectCategory, onAddToCart, onConfigureProduct, inputRef }: ProductBrowserProps) {", "export function ProductBrowser({ products, categories, stockMap, sellableStock, search, selectedCategory, currency, hasBranch, canModifyOrder, onSearch, onSelectCategory, onAddToCart, onConfigureProduct, inputRef }: ProductBrowserProps) {")
s = s.replace("      const aAvailable = aStock > 0 && !(aManufactured && !recipeMap[a.id]?.length);\n      const bAvailable = bStock > 0 && !(bManufactured && !recipeMap[b.id]?.length);\n", "      const aAvailable = aStock > 0;\n      const bAvailable = bStock > 0;\n")
s = s.replace("    }), [products, recipeMap, search, selectedCategory, sellableStock, stockMap]);", "    }), [products, search, selectedCategory, sellableStock, stockMap]);")
s = s.replace("              const noRecipe = manufactured && !recipeMap[product.id]?.length;\n              const stock = manufactured ? sellableStock[product.id] || 0 : stockMap[product.id] || 0;\n              const unavailable = stock <= 0 || noRecipe;\n", "              // The server availability RPC is authoritative. A manufactured product may be backed by\n              // raw-material recipes or inventory-unit links without any product_components rows.\n              const noRecipe = false;\n              const stock = manufactured ? sellableStock[product.id] || 0 : stockMap[product.id] || 0;\n              const unavailable = stock <= 0;\n")
p.write_text(s, encoding='utf-8')

# 2) Printer settings state bug + central terminal toggle + cold station.
p = ROOT / 'src/features/pos/components/settings/PrinterSettingsPanel.tsx'
s = p.read_text(encoding='utf-8')
s = s.replace("  isSinglePrintPolicyEnabled,\n  setSinglePrintPolicyEnabled,\n", "  isSinglePrintPolicyEnabled,\n  setSinglePrintPolicyEnabled,\n  isBranchPrintServer,\n  setBranchPrintServer,\n")
s = s.replace("  const [autoDrawer, setAutoDrawer] = useState(true);\n", "  const [autoDrawer, setAutoDrawer] = useState(true);\n  const [branchPrintServer, setBranchPrintServerState] = useState(false);\n")
s = s.replace("      setSinglePrintPolicyEnabled(isSinglePrintPolicyEnabled());\n", "      setSinglePrintPolicy(isSinglePrintPolicyEnabled());\n      setBranchPrintServerState(isBranchPrintServer());\n")
s = s.replace("    setSinglePrintPolicyEnabled(singlePrintPolicy);\n", "    setSinglePrintPolicyEnabled(singlePrintPolicy);\n    setBranchPrintServer(branchPrintServer);\n")
needle = """    {\n      code: 'dessert',\n      labelAr: 'طابعة الحلويات والمخبوزات',\n      labelEn: 'Dessert Station',\n      descAr: 'تطبع تذاكر الحلويات والكيك والآيس كريم',\n      icon: Cake,\n      badge: 'الحلويات',\n      color: 'text-purple-500 bg-purple-500/10 border-purple-500/20',\n    },\n"""
if "code: 'cold'" not in s:
    s = s.replace(needle, needle + """    {\n      code: 'cold',\n      labelAr: 'طابعة السلطات والمقبلات الباردة',\n      labelEn: 'Cold Kitchen / Salads Station',\n      descAr: 'تطبع تذاكر السلطات والمقبلات والأصناف الباردة',\n      icon: UtensilsCrossed,\n      badge: 'البارد',\n      color: 'text-cyan-500 bg-cyan-500/10 border-cyan-500/20',\n    },\n""")
marker = "      {/* Printer Routing */}\n"
if 'محطة الطباعة المركزية للفرع' not in s and marker in s:
    s = s.replace(marker, """      <div className=\"rounded-2xl border border-ui-border bg-ui-card p-4\">\n        <div className=\"flex items-start justify-between gap-4\">\n          <div>\n            <h3 className=\"text-sm font-bold text-ui-text\">{isAr ? 'محطة الطباعة المركزية للفرع' : 'Branch Central Print Server'}</h3>\n            <p className=\"mt-1 text-xs leading-relaxed text-ui-subtle\">{isAr ? 'فعّلها فقط على جهاز ويندوز الرئيسي الذي سيستقبل مهام الطباعة الخاصة بالفرع.' : 'Enable only on the main Windows terminal that should receive branch print jobs.'}</p>\n          </div>\n          <input type=\"checkbox\" checked={branchPrintServer} onChange={(e) => setBranchPrintServerState(e.target.checked)} className=\"h-5 w-5 cursor-pointer rounded\" />\n        </div>\n      </div>\n\n""" + marker, 1)
p.write_text(s, encoding='utf-8')

# 3) Cloud print relay is disabled by default while backend/RLS is frozen.
p = ROOT / 'src/features/pos/services/localPrintAgent.ts'
s = p.read_text(encoding='utf-8')
if 'CLOUD_PRINT_QUEUE_ENABLED' not in s:
    s = s.replace("const STORAGE_SINGLE_PRINT_POLICY_KEY = 'johns_pos_single_print_policy_enabled';\n", "const STORAGE_SINGLE_PRINT_POLICY_KEY = 'johns_pos_single_print_policy_enabled';\nconst CLOUD_PRINT_QUEUE_ENABLED = import.meta.env.VITE_ENABLE_CLOUD_PRINT_QUEUE === 'true';\n")
    s = s.replace("export function startBranchPrintQueueListener(\n", "export function startBranchPrintQueueListener(\n")
    s = s.replace("export function startBranchPrintQueueListener(\n  branchId: string,", "export function startBranchPrintQueueListener(\n  branchId: string,")
    listener_anchor = "  if (!branchId) {\n"
    idx = s.find(listener_anchor, s.find('export function startBranchPrintQueueListener'))
    if idx != -1:
        s = s[:idx] + "  if (!CLOUD_PRINT_QUEUE_ENABLED) return () => {};\n" + s[idx:]
    s = s.replace("  if (ctx.branchId) {\n", "  if (CLOUD_PRINT_QUEUE_ENABLED && ctx.branchId) {\n", 1)
p.write_text(s, encoding='utf-8')

# 4) Capacitor: bundle local dist instead of temporary Google preview URL.
p = ROOT / 'capacitor.config.json'
obj = json.loads(p.read_text(encoding='utf-8'))
obj.pop('server', None)
obj.setdefault('android', {})['webContentsDebuggingEnabled'] = False
p.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

# 5) Electron: stable published URL, true fullscreen/frameless, no Google preview URL.
p = ROOT / 'electron/main.cjs'
s = p.read_text(encoding='utf-8')
s = s.replace("const DEFAULT_URL = process.env.POS_APP_URL || 'https://ais-pre-utf35dfbelzmbfjp7etxwq-287327909955.europe-west1.run.app';", "const DEFAULT_URL = process.env.POS_APP_URL || 'https://premieros.github.io/55/';")
if 'fullscreen: true' not in s:
    s = s.replace("    title: 'Johns POS',\n    autoHideMenuBar: true,", "    title: 'Johns POS',\n    fullscreen: true,\n    frame: false,\n    autoHideMenuBar: true,")
p.write_text(s, encoding='utf-8')

# 6) Ensure desktop dependencies are reproducible.
p = ROOT / 'package.json'
obj = json.loads(p.read_text(encoding='utf-8'))
obj.setdefault('devDependencies', {})['electron'] = '^38.0.0'
obj.setdefault('devDependencies', {})['electron-builder'] = '^26.0.12'
p.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

# Safety assertions: no DB/migration files changed by this patcher and no preview URL remains.
for rel in ['capacitor.config.json','electron/main.cjs']:
    if 'ais-pre-' in (ROOT/rel).read_text(encoding='utf-8'):
        raise SystemExit(f'preview URL still present in {rel}')

subprocess.run(['node','--check',str(ROOT/'electron/main.cjs')], check=True)
subprocess.run(['node','--check',str(ROOT/'electron/preload.cjs')], check=True)
subprocess.run(['rm','-f',str(ZIP)], check=True)
subprocess.run(['bash','-lc', f"cd {ROOT} && zip -qr ../{ZIP.name} ."], check=True)
shutil.rmtree(ROOT)
print('Safe POS patch complete; database files were not executed or applied.')
