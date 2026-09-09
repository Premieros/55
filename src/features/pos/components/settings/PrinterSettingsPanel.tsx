import { useState, useEffect, useCallback } from 'react';
import {
  Printer,
  RefreshCw,
  Zap,
  ShieldCheck,
  DollarSign,
  Play,
  Flame,
  Coffee,
  UtensilsCrossed,
  Cake,
  Receipt,
  CheckCircle2,
  Sliders,
  Check,
  Save,
} from 'lucide-react';
import { Button } from '@/components/Button';
import { useLanguage } from '@/context/LanguageContext';
import { useToast } from '@/components/Toast';
import {
  getAvailablePrinters,
  getLocalPrinterRoutes,
  saveLocalPrinterRoutes,
  isAutoDrawerKickEnabled,
  setAutoDrawerKick,
  isSilentPrintEnabled,
  setSilentPrintEnabled,
  isSinglePrintPolicyEnabled,
  setSinglePrintPolicyEnabled,
  executeSilentPrint,
  executeCashDrawerKick,
  type DetectedPrinter,
  type PrinterRouteConfig,
} from '../../services/localPrintAgent';

interface PrinterSettingsPanelProps {
  branchId?: string;
  branchName?: string;
  isStandalonePage?: boolean;
}

export function PrinterSettingsPanel({
  branchName,
}: PrinterSettingsPanelProps) {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';
  const { show } = useToast();

  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [printers, setPrinters] = useState<DetectedPrinter[]>([]);
  const [routes, setRoutes] = useState<PrinterRouteConfig>({});
  
  // Core user requirements:
  const [silentPrint, setSilentPrint] = useState(true);
  const [singlePrintPolicy, setSinglePrintPolicy] = useState(true);
  const [customerReceiptOnly, setCustomerReceiptOnly] = useState(true);
  const [autoDrawer, setAutoDrawer] = useState(true);
  
  const [testingStation, setTestingStation] = useState<string | null>(null);
  const [kickingDrawer, setKickingDrawer] = useState(false);
  const [savedSuccess, setSavedSuccess] = useState(false);

  // Load configuration
  const loadConfiguration = useCallback(async () => {
    setLoading(true);
    try {
      const detectedPrinters = await getAvailablePrinters();
      setPrinters(detectedPrinters);

      const localRoutes = getLocalPrinterRoutes();
      setRoutes(localRoutes);

      setAutoDrawer(isAutoDrawerKickEnabled());
      setSilentPrint(isSilentPrintEnabled());
      setSinglePrintPolicyEnabled(isSinglePrintPolicyEnabled());
    } catch (err) {
      console.error('Error loading printer config:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadConfiguration();
  }, [loadConfiguration]);

  const refreshPrinters = async () => {
    setRefreshing(true);
    try {
      const detectedPrinters = await getAvailablePrinters();
      setPrinters(detectedPrinters);
      show(
        isAr
          ? `تم اكتشاف ${detectedPrinters.length} طابعة متاحة`
          : `Found ${detectedPrinters.length} available printers`,
        'success'
      );
    } catch {
      show(isAr ? 'تعذر جلب الطابعات' : 'Failed to query printers', 'error');
    } finally {
      setRefreshing(false);
    }
  };

  const handleRouteChange = (station: string, printerName: string) => {
    setRoutes((prev) => {
      const updated = { ...prev };
      if (!printerName) {
        delete updated[station];
      } else {
        updated[station] = printerName;
      }
      return updated;
    });
  };

  const handleSaveAll = () => {
    saveLocalPrinterRoutes(routes);
    setAutoDrawerKick(autoDrawer);
    setSilentPrintEnabled(silentPrint);
    setSinglePrintPolicyEnabled(singlePrintPolicy);

    setSavedSuccess(true);
    setTimeout(() => setSavedSuccess(false), 2500);

    show(
      isAr
        ? 'تم حفظ إعدادات الطباعة السريعة والصامتة وسياسة عدم التكرار بنجاح'
        : 'Printing preferences saved successfully',
      'success'
    );
  };

  const handleTestPrint = async (station: string, printerName?: string) => {
    const targetPrinter = printerName || routes[station];
    if (!targetPrinter) {
      show(
        isAr ? 'يرجى اختيار طابعة أولاً لاختبارها' : 'Please select a printer first',
        'error'
      );
      return;
    }

    setTestingStation(station);
    try {
      const testTicket = [
        '================================',
        '       JOHNS POS - TEST         ',
        '================================',
        isAr ? `المحطة: ${station.toUpperCase()}` : `Station: ${station.toUpperCase()}`,
        isAr ? `الطابعة: ${targetPrinter}` : `Printer: ${targetPrinter}`,
        isAr ? `الفرع: ${branchName || 'Default'}` : `Branch: ${branchName || 'Default'}`,
        new Date().toLocaleString(isAr ? 'ar-EG' : 'en-US'),
        '--------------------------------',
        isAr ? '✓ الاتصال بالطابعة سليم' : '✓ Printer connection OK',
        isAr ? '✓ الطباعة الصامتة السريعة فعالة' : '✓ Silent Fast Print OK',
        '================================',
        '\r\n\r\n',
      ].join('\r\n');

      const ok = await executeSilentPrint({
        printerName: targetPrinter,
        text: testTicket,
      });

      if (ok) {
        show(
          isAr
            ? `تم إرسال اختبار الطباعة بنجاح إلى: ${targetPrinter}`
            : `Test ticket sent successfully to: ${targetPrinter}`,
          'success'
        );
      } else {
        show(
          isAr
            ? `فشلت الطباعة الصامتة. تأكد من تشغيل الطابعة وتوصيلها.`
            : `Print failed. Ensure printer is turned on and connected.`,
          'error'
        );
      }
    } catch {
      show(isAr ? 'حدث خطأ أثناء محاولة الطباعة' : 'Error during test print', 'error');
    } finally {
      setTestingStation(null);
    }
  };

  const handleTestDrawer = async () => {
    setKickingDrawer(true);
    try {
      const ok = await executeCashDrawerKick();
      if (ok) {
        show(
          isAr ? 'تم إرسال نبضة فتح درج النقدية بنجاح' : 'Drawer kick pulse sent successfully',
          'success'
        );
      } else {
        show(
          isAr
            ? 'تعذر فتح الدرج. تأكد من ربط الدرج بكابل RJ11 مع طابعة الكاشير.'
            : 'Failed to kick drawer. Check cashier printer and RJ11 cable.',
          'error'
        );
      }
    } finally {
      setKickingDrawer(false);
    }
  };

  const STATIONS = [
    {
      code: 'cashier',
      labelAr: 'طابعة الكاشير / فواتير العملاء',
      labelEn: 'Cashier / Customer Receipts Printer',
      descAr: 'تطبع إيصال العميل النهائي فور إتمام البيع بصمت وسرعة دون سؤال الكاشير',
      icon: Receipt,
      badge: 'الأساسية للعميل',
      color: 'text-emerald-500 bg-emerald-500/10 border-emerald-500/20',
    },
    {
      code: 'main',
      labelAr: 'طابعة المطبخ الرئيسي / المأكولات',
      labelEn: 'Main Kitchen Station',
      descAr: 'تستقبل أوامر المطبخ والوجبات الساخنة دون إزعاج شاشة الكاشير',
      icon: UtensilsCrossed,
      badge: 'المطبخ',
      color: 'text-amber-500 bg-amber-500/10 border-amber-500/20',
    },
    {
      code: 'drinks',
      labelAr: 'طابعة المشروبات والبار / الباريستا',
      labelEn: 'Bar & Drinks Station',
      descAr: 'تطبع تذاكر المشروبات الباردة والساخنة',
      icon: Coffee,
      badge: 'البار',
      color: 'text-blue-500 bg-blue-500/10 border-blue-500/20',
    },
    {
      code: 'grill',
      labelAr: 'طابعة محطة المشويات والشواية',
      labelEn: 'Grill Station',
      descAr: 'تطبع تذاكر اللحوم والمشويات المباشرة',
      icon: Flame,
      badge: 'الشواية',
      color: 'text-red-500 bg-red-500/10 border-red-500/20',
    },
    {
      code: 'dessert',
      labelAr: 'طابعة الحلويات والمخبوزات',
      labelEn: 'Dessert Station',
      descAr: 'تطبع تذاكر الحلويات والكيك والآيس كريم',
      icon: Cake,
      badge: 'الحلويات',
      color: 'text-purple-500 bg-purple-500/10 border-purple-500/20',
    },
  ];

  if (loading) {
    return (
      <div className="py-16 flex flex-col items-center justify-center text-xs text-ui-muted gap-2">
        <RefreshCw className="w-6 h-6 animate-spin text-brand-600" />
        <span>{isAr ? 'جاري فحص بيئة الطابعات الحرارية...' : 'Checking thermal printer environment...'}</span>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Top Header & Save Button */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-4 rounded-2xl bg-ui-card border border-ui-border">
        <div>
          <h2 className="text-base font-bold text-ui-text flex items-center gap-2">
            <Printer className="w-5 h-5 text-brand-600 dark:text-brand-400" />
            {isAr ? 'إعدادات الطباعة السريعة والصامتة للطابعات الحرارية' : 'Thermal & Fast Silent Printing Settings'}
          </h2>
          <p className="text-xs text-ui-subtle mt-0.5">
            {isAr
              ? 'تكوين الطباعة الصامتة بدون سؤال الكاشير، توجيه الطابعات، وسياسة عدم تكرار الفواتير إلا بموافقة المدير'
              : 'Configure silent instant receipt printing, station routing, and manager reprint approvals'}
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Button
            onClick={handleSaveAll}
            className="bg-brand-600 hover:bg-brand-700 text-white font-bold gap-2 text-xs py-2 px-4 shadow-sm shadow-brand-500/20"
          >
            {savedSuccess ? <Check className="w-4 h-4" /> : <Save className="w-4 h-4" />}
            <span>{savedSuccess ? (isAr ? 'تم الحفظ!' : 'Saved!') : (isAr ? 'حفظ إعدادات الطباعة' : 'Save Settings')}</span>
          </Button>
        </div>
      </div>

      {/* THREE PRIMARY SYSTEM POLICIES (User Core Directives) */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* Policy 1: Silent & Fast Printing */}
        <div
          onClick={() => setSilentPrint(!silentPrint)}
          className={`cursor-pointer p-4 rounded-2xl border transition-all select-none flex flex-col justify-between ${
            silentPrint
              ? 'bg-emerald-500/10 border-emerald-500/40 text-emerald-950 dark:text-emerald-100 shadow-sm'
              : 'bg-ui-card border-ui-border opacity-70'
          }`}
        >
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <div className="w-8 h-8 rounded-xl bg-emerald-500/20 flex items-center justify-center text-emerald-600 dark:text-emerald-400">
                <Zap className="w-4 h-4" />
              </div>
              <input
                type="checkbox"
                checked={silentPrint}
                onChange={(e) => setSilentPrint(e.target.checked)}
                className="w-4 h-4 rounded text-emerald-600 cursor-pointer"
                onClick={(e) => e.stopPropagation()}
              />
            </div>
            <h3 className="text-sm font-bold">
              {isAr ? 'الطباعة السريعة الصامتة' : 'Fast Silent Printing'}
            </h3>
            <p className="text-xs text-ui-subtle leading-relaxed">
              {isAr
                ? 'طباعة إيصال العميل مباشرة وفوراً للطابعة الحرارية بدون فتح نوافذ منبثقة أو سؤال الكاشير تأكيد الطباعة.'
                : 'Prints receipt immediately to thermal printer with zero popups or confirmation prompts.'}
            </p>
          </div>
          <div className="mt-3 pt-2 border-t border-emerald-500/20 flex items-center gap-1.5 text-[11px] font-semibold text-emerald-600 dark:text-emerald-400">
            <CheckCircle2 className="w-3.5 h-3.5" />
            <span>{silentPrint ? (isAr ? 'مفعلة (بدون سؤال الكاشير)' : 'Active (Zero Prompt)') : (isAr ? 'معطلة' : 'Disabled')}</span>
          </div>
        </div>

        {/* Policy 2: Customer Receipt Only (Not Kitchen) */}
        <div
          onClick={() => setCustomerReceiptOnly(!customerReceiptOnly)}
          className={`cursor-pointer p-4 rounded-2xl border transition-all select-none flex flex-col justify-between ${
            customerReceiptOnly
              ? 'bg-blue-500/10 border-blue-500/40 text-blue-950 dark:text-blue-100 shadow-sm'
              : 'bg-ui-card border-ui-border opacity-70'
          }`}
        >
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <div className="w-8 h-8 rounded-xl bg-blue-500/20 flex items-center justify-center text-blue-600 dark:text-blue-400">
                <Receipt className="w-4 h-4" />
              </div>
              <input
                type="checkbox"
                checked={customerReceiptOnly}
                onChange={(e) => setCustomerReceiptOnly(e.target.checked)}
                className="w-4 h-4 rounded text-blue-600 cursor-pointer"
                onClick={(e) => e.stopPropagation()}
              />
            </div>
            <h3 className="text-sm font-bold">
              {isAr ? 'الطباعة للعميل وليس للمطبخ' : 'Print for Customer Only'}
            </h3>
            <p className="text-xs text-ui-subtle leading-relaxed">
              {isAr
                ? 'تقتصر الطباعة الآلية على إيصال الحساب الخاص بالعميل. أوامر المطبخ تُرسل رقمياً لشاشات KDS والمحطات دون إزعاج الكاشير.'
                : 'Auto-printing is strictly for customer receipts. Kitchen orders flow to KDS screens silently.'}
            </p>
          </div>
          <div className="mt-3 pt-2 border-t border-blue-500/20 flex items-center gap-1.5 text-[11px] font-semibold text-blue-600 dark:text-blue-400">
            <CheckCircle2 className="w-3.5 h-3.5" />
            <span>{customerReceiptOnly ? (isAr ? 'مفعلة (إيصال العميل فقط)' : 'Customer Receipts Only') : (isAr ? 'معطلة' : 'Disabled')}</span>
          </div>
        </div>

        {/* Policy 3: Print Once / Manager Approval on Reprint */}
        <div
          onClick={() => setSinglePrintPolicy(!singlePrintPolicy)}
          className={`cursor-pointer p-4 rounded-2xl border transition-all select-none flex flex-col justify-between ${
            singlePrintPolicy
              ? 'bg-amber-500/10 border-amber-500/40 text-amber-950 dark:text-amber-100 shadow-sm'
              : 'bg-ui-card border-ui-border opacity-70'
          }`}
        >
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <div className="w-8 h-8 rounded-xl bg-amber-500/20 flex items-center justify-center text-amber-600 dark:text-amber-400">
                <ShieldCheck className="w-4 h-4" />
              </div>
              <input
                type="checkbox"
                checked={singlePrintPolicy}
                onChange={(e) => setSinglePrintPolicy(e.target.checked)}
                className="w-4 h-4 rounded text-amber-600 cursor-pointer"
                onClick={(e) => e.stopPropagation()}
              />
            </div>
            <h3 className="text-sm font-bold">
              {isAr ? 'الطباعة لمرة واحدة وموافقة المدير' : 'Strict Single Print Policy'}
            </h3>
            <p className="text-xs text-ui-subtle leading-relaxed">
              {isAr
                ? 'تتم طباعة الفاتورة مرة واحدة فقط للعميل. أي محاولة لطباعة نسخة إضافية تتطلب موافقة المدير وتُوسم بختم (نسخة مكررة مُصرّح بها).'
                : 'Invoice prints once only. Subsequent prints strictly require manager approval with an authorized watermark.'}
            </p>
          </div>
          <div className="mt-3 pt-2 border-t border-amber-500/20 flex items-center gap-1.5 text-[11px] font-semibold text-amber-600 dark:text-amber-400">
            <CheckCircle2 className="w-3.5 h-3.5" />
            <span>{singlePrintPolicy ? (isAr ? 'مفعلة (موافقة المدير للتكرار)' : 'Reprint Approval Required') : (isAr ? 'معطلة' : 'Disabled')}</span>
          </div>
        </div>
      </div>

      {/* Cash Drawer Control */}
      <div className="p-4 rounded-2xl bg-ui-card border border-ui-border flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-emerald-500/10 border border-emerald-500/30 flex items-center justify-center text-emerald-600 dark:text-emerald-400">
            <DollarSign className="w-5 h-5" />
          </div>
          <div>
            <h4 className="text-sm font-bold text-ui-text">
              {isAr ? 'فتح درج النقدية التلقائي (Cash Drawer Kick)' : 'Automatic Cash Drawer Kick'}
            </h4>
            <p className="text-xs text-ui-subtle">
              {isAr
                ? 'إرسال نبضة فتح درج الكاشير آلياً عبر كابل RJ11 عند استلام مدفوعات نقدية'
                : 'Pulse cash drawer open automatically upon receiving cash payments'}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <label className="flex items-center gap-2 cursor-pointer select-none text-xs text-ui-text font-medium">
            <input
              type="checkbox"
              checked={autoDrawer}
              onChange={(e) => setAutoDrawer(e.target.checked)}
              className="w-4 h-4 rounded text-brand-600"
            />
            {isAr ? 'فتح الدرج مع النقدية' : 'Kick Drawer on Cash'}
          </label>

          <Button
            size="sm"
            variant="outline"
            onClick={handleTestDrawer}
            disabled={kickingDrawer}
            className="text-xs gap-1.5"
          >
            <DollarSign className="w-3.5 h-3.5" />
            {isAr ? 'اختبار فتح الدرج' : 'Test Drawer Kick'}
          </Button>
        </div>
      </div>

      {/* Hardware & Printer Routing Section */}
      <div className="p-5 rounded-2xl bg-ui-card border border-ui-border space-y-4">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pb-3 border-b border-ui-border">
          <div>
            <h3 className="text-sm font-bold text-ui-text flex items-center gap-2">
              <Sliders className="w-4 h-4 text-brand-600" />
              {isAr ? 'توجيه الطابعات الحرارية بالمحطات' : 'Thermal Printer Station Routing'}
            </h3>
            <p className="text-xs text-ui-subtle">
              {isAr
                ? 'تعيين الطابعة المناسبة لكل محطة تشغيل (طابعة الكاشير، المطبخ، البار...)'
                : 'Assign physical printers to operational stations (Cashier, Kitchen, Bar...)'}
            </p>
          </div>

          <div className="flex items-center gap-2">
            <span className="text-xs px-2 py-1 rounded-md bg-ui-bg text-ui-text border border-ui-border font-mono">
              {printers.length > 0
                ? `${printers.length} ${isAr ? 'طابعة مكتشفة' : 'printers'}`
                : (isAr ? 'لا توجد طابعات' : 'No printers')}
            </span>
            <Button
              size="sm"
              variant="outline"
              onClick={refreshPrinters}
              disabled={refreshing}
              className="text-xs gap-1.5"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${refreshing ? 'animate-spin' : ''}`} />
              {isAr ? 'إعادة فحص الطابعات' : 'Scan Printers'}
            </Button>
          </div>
        </div>

        {/* Stations List */}
        <div className="space-y-3">
          {STATIONS.map((st) => {
            const Icon = st.icon;
            const assignedPrinter = routes[st.code] || '';
            const isTesting = testingStation === st.code;

            return (
              <div
                key={st.code}
                className="p-3.5 rounded-xl bg-ui-bg border border-ui-border hover:border-brand-500/40 transition-colors flex flex-col md:flex-row md:items-center justify-between gap-3"
              >
                <div className="flex items-center gap-3">
                  <div className={`w-9 h-9 rounded-lg flex items-center justify-center border ${st.color}`}>
                    <Icon className="w-4 h-4" />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-bold text-ui-text">
                        {isAr ? st.labelAr : st.labelEn}
                      </span>
                      <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full bg-ui-surface border border-ui-border text-ui-muted">
                        {st.badge}
                      </span>
                    </div>
                    <p className="text-xs text-ui-subtle mt-0.5">
                      {isAr ? st.descAr : ((st as { descEn?: string; descAr: string }).descEn || st.descAr)}
                    </p>
                  </div>
                </div>

                <div className="flex items-center gap-2 w-full md:w-auto">
                  <select
                    value={assignedPrinter}
                    onChange={(e) => handleRouteChange(st.code, e.target.value)}
                    className="flex-1 md:w-64 text-xs font-medium px-3 py-2 rounded-lg bg-ui-surface border border-ui-border text-ui-text focus:outline-none focus:border-brand-500"
                  >
                    <option value="">
                      {isAr ? '-- بدون طابعة (طباعة صامتة بالمتصفح) --' : '-- None (Silent browser print) --'}
                    </option>
                    {printers.map((p) => (
                      <option key={p.name} value={p.name}>
                        {p.name} {p.isDefault ? (isAr ? '(الافتراضية)' : '(Default)') : ''}
                      </option>
                    ))}
                  </select>

                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => handleTestPrint(st.code, assignedPrinter)}
                    disabled={isTesting}
                    className="text-xs px-2.5 whitespace-nowrap"
                  >
                    <Play className={`w-3.5 h-3.5 ${isTesting ? 'animate-spin' : ''}`} />
                    {isAr ? 'اختبار' : 'Test'}
                  </Button>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
