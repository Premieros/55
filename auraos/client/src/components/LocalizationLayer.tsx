import { useEffect, useState } from 'react'

type Language = 'ar' | 'en'

const STORAGE_KEY = 'auraos-language'

const AR: Record<string, string> = {
  'Restaurant Platform': 'منصة إدارة المطاعم',
  'Dashboard': 'لوحة التحكم',
  'Orders': 'الطلبات',
  'Tables': 'الطاولات',
  'Bookings': 'الحجوزات',
  'Reservations': 'الحجوزات',
  'Menu': 'القائمة',
  'Payments': 'المدفوعات',
  'Kitchen Display': 'شاشة المطبخ',
  'Inventory': 'المخزون',
  'Users': 'المستخدمون',
  'Reports': 'التقارير',
  'QR Settings': 'إعدادات QR',
  'Delivery Zones': 'مناطق التوصيل',
  'Coupons': 'الكوبونات',
  'Loyalty': 'الولاء',
  'Reviews': 'التقييمات',
  'Modifiers': 'الإضافات',
  'Subscription': 'الاشتراك',
  'Features': 'الخصائص',
  'AI Analytics': 'التحليلات الذكية',
  'AI Dashboard': 'لوحة الذكاء الاصطناعي',
  'AI Copilot': 'المساعد الذكي',
  'Forecasts': 'التوقعات',
  'Customer Insights': 'تحليلات العملاء',
  'Recommendations': 'التوصيات',
  'Inventory AI': 'ذكاء المخزون',
  'Wait Time AI': 'توقع وقت الانتظار',
  'AI Reports': 'تقارير الذكاء الاصطناعي',
  'Models': 'النماذج',
  'Events': 'الأحداث',
  'Workflows': 'سير العمل',
  'Autonomous AI': 'الذكاء الذاتي',
  'Agents': 'الوكلاء',
  'Knowledge Base': 'قاعدة المعرفة',
  'System Health': 'صحة النظام',
  'Platform (Owner)': 'المنصة (المالك)',
  'Multi Outlet': 'الفروع المتعددة',
  'Select restaurant': 'اختر المطعم',
  'Live · Connected': 'متصل · مباشر',
  'Reconnecting…': 'جارٍ إعادة الاتصال…',
  'Logout': 'تسجيل الخروج',
  'Sign In': 'تسجيل الدخول',
  'Sign in': 'تسجيل الدخول',
  'Email': 'البريد الإلكتروني',
  'Password': 'كلمة المرور',
  'Forgot password?': 'نسيت كلمة المرور؟',
  'Create account': 'إنشاء حساب',
  'Save': 'حفظ',
  'Cancel': 'إلغاء',
  'Close': 'إغلاق',
  'Delete': 'حذف',
  'Edit': 'تعديل',
  'Add': 'إضافة',
  'Create': 'إنشاء',
  'Update': 'تحديث',
  'Refresh': 'تحديث',
  'Refresh All': 'تحديث الكل',
  'Search': 'بحث',
  'Filter': 'تصفية',
  'All': 'الكل',
  'Active': 'نشط',
  'Inactive': 'غير نشط',
  'Pending': 'قيد الانتظار',
  'Completed': 'مكتمل',
  'Failed': 'فشل',
  'Success': 'نجاح',
  'Status': 'الحالة',
  'Name': 'الاسم',
  'Date': 'التاريخ',
  'Time': 'الوقت',
  'Amount': 'المبلغ',
  'Total': 'الإجمالي',
  'Price': 'السعر',
  'Quantity': 'الكمية',
  'Customer': 'العميل',
  'Phone': 'الهاتف',
  'Address': 'العنوان',
  'Actions': 'الإجراءات',
  'View': 'عرض',
  'Details': 'التفاصيل',
  'Today': 'اليوم',
  'This Week': 'هذا الأسبوع',
  'This Month': 'هذا الشهر',
  'No data available': 'لا توجد بيانات متاحة',
  'Loading...': 'جارٍ التحميل...',
  'Loading…': 'جارٍ التحميل…',
  'Something went wrong': 'حدث خطأ غير متوقع',
  'Try again': 'إعادة المحاولة',
  "Today's Revenue": 'مبيعات اليوم',
  'Tomorrow Forecast': 'توقع الغد',
  'Revenue Growth': 'نمو المبيعات',
  'Prediction Accuracy': 'دقة التوقع',
  'Orders Today': 'طلبات اليوم',
  'Inventory Risk': 'مخاطر المخزون',
  'Customer Churn': 'تسرب العملاء',
  'Avg Wait Time': 'متوسط وقت الانتظار',
  'AI Confidence': 'ثقة التحليل',
  'Model Health': 'صحة النماذج',
  "Today's Insight": 'تحليل اليوم',
  'Recommended Action': 'الإجراء المقترح',
  'AI Analytics Dashboard': 'لوحة التحليلات الذكية',
  'Unified intelligence for your restaurant': 'تحليلات موحدة لأداء مطعمك',
  'Wait Time AI': 'توقع وقت الانتظار',
  'Current Estimated Wait': 'وقت الانتظار المتوقع حاليًا',
  'Current Wait': 'الانتظار الحالي',
  'Predicted Wait': 'الانتظار المتوقع',
  'Kitchen Load': 'ضغط المطبخ',
  'Confidence': 'الثقة',
  'Staff Recommendation': 'توصية العمالة',
  'Model Management': 'إدارة النماذج',
  'Monitor and retrain AI models': 'متابعة وإعادة تدريب نماذج التحليل',
  'AI Recommendations': 'التوصيات الذكية',
  'Total Recommendations': 'إجمالي التوصيات',
  'High Confidence': 'ثقة مرتفعة',
  'AI Copilot': 'المساعد الذكي',
  'Ask questions about your restaurant performance in natural language': 'اسأل عن أداء مطعمك بلغة طبيعية',
  'Send': 'إرسال',
  'Daily': 'يومي',
  'Weekly': 'أسبوعي',
  'History': 'السجل',
  'Critical': 'حرج',
  'Warning': 'تحذير',
  'Safe': 'آمن',
  'Unknown': 'غير معروف',
  'Healthy': 'سليم',
  'Running': 'يعمل',
  'Stopped': 'متوقف',
  'Connected': 'متصل',
  'Disconnected': 'غير متصل',
}

const originalTexts = new WeakMap<Text, string>()
const originalAttrs = new WeakMap<Element, Map<string, string>>()

function translateString(value: string): string {
  const trimmed = value.trim()
  const translated = AR[trimmed]
  if (!translated) return value
  const start = value.slice(0, value.indexOf(trimmed))
  const end = value.slice(value.indexOf(trimmed) + trimmed.length)
  return `${start}${translated}${end}`
}

function excluded(node: Node): boolean {
  const el = node.nodeType === Node.ELEMENT_NODE ? node as Element : node.parentElement
  return !!el?.closest('[data-no-i18n],script,style,code,pre')
}

function translateTree(root: Node, language: Language) {
  if (excluded(root)) return

  const translateText = (node: Text) => {
    if (excluded(node)) return
    if (!originalTexts.has(node)) originalTexts.set(node, node.nodeValue ?? '')
    const original = originalTexts.get(node) ?? ''
    const next = language === 'ar' ? translateString(original) : original
    if (node.nodeValue !== next) node.nodeValue = next
  }

  if (root.nodeType === Node.TEXT_NODE) translateText(root as Text)

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  let current = walker.nextNode()
  while (current) {
    translateText(current as Text)
    current = walker.nextNode()
  }

  const elements: Element[] = []
  if (root.nodeType === Node.ELEMENT_NODE) elements.push(root as Element)
  if ('querySelectorAll' in root) elements.push(...Array.from((root as Element).querySelectorAll('*')))

  for (const el of elements) {
    if (excluded(el)) continue
    for (const attr of ['placeholder', 'title', 'aria-label']) {
      const currentValue = el.getAttribute(attr)
      if (currentValue == null) continue
      let saved = originalAttrs.get(el)
      if (!saved) {
        saved = new Map()
        originalAttrs.set(el, saved)
      }
      if (!saved.has(attr)) saved.set(attr, currentValue)
      const original = saved.get(attr) ?? currentValue
      const next = language === 'ar' ? translateString(original) : original
      if (currentValue !== next) el.setAttribute(attr, next)
    }
  }
}

export default function LocalizationLayer() {
  const [language, setLanguage] = useState<Language>(() => {
    const stored = localStorage.getItem(STORAGE_KEY)
    return stored === 'en' || stored === 'ar' ? stored : 'ar'
  })

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, language)
    document.documentElement.lang = language
    document.documentElement.dir = language === 'ar' ? 'rtl' : 'ltr'
    document.body.dir = language === 'ar' ? 'rtl' : 'ltr'
    translateTree(document.body, language)

    let scheduled = false
    const observer = new MutationObserver((mutations) => {
      if (scheduled) return
      scheduled = true
      requestAnimationFrame(() => {
        scheduled = false
        for (const mutation of mutations) {
          if (mutation.type === 'characterData') translateTree(mutation.target, language)
          mutation.addedNodes.forEach((node) => translateTree(node, language))
        }
      })
    })
    observer.observe(document.body, { childList: true, subtree: true, characterData: true })
    return () => observer.disconnect()
  }, [language])

  return (
    <button
      type="button"
      data-no-i18n
      className="aura-language-toggle"
      onClick={() => setLanguage((value) => value === 'ar' ? 'en' : 'ar')}
      aria-label={language === 'ar' ? 'Switch to English' : 'التبديل إلى العربية'}
      title={language === 'ar' ? 'Switch to English' : 'التبديل إلى العربية'}
    >
      {language === 'ar' ? 'EN' : 'عربي'}
    </button>
  )
}
