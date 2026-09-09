# UI VISIBILITY AUDIT — john-s

آخر تحديث: 2026-09-02

## الهدف
هذا الملف يراجع النظام من منظور المستخدم النهائي: هل الوظيفة الموجودة فعلاً في النظام لها مدخل/زر واضح؟ وهل توجد عناصر قديمة أو تجريبية يجب ألا تظهر في Production؟

## الحالة العامة
الواجهة الأساسية مرتبطة بالوظائف الحقيقية وليست مجرد صفحات شكلية. تم إغلاق فجوات ظهور مهمة أثناء هذا التدقيق.

## POS — ظاهر ومتاح حسب الصلاحية ✅
- إنشاء طلب جديد.
- عداد الطلبات النشطة ظاهر في أعلى POS.
- عداد الدليفري ظاهر في أعلى POS.
- عداد الطاولات المشغولة ظاهر في أعلى POS.
- عداد KDS/طلبات المطبخ ظاهر في أعلى POS.
- Discount.
- Hold / Resume.
- Send to Kitchen.
- Print.
- Pay.
- نقل الطاولة.
- تعديل/إلغاء صنف مرسل للمطبخ عبر مسار الموافقة المخصص.
- فتح/إغلاق الوردية.
- Z-Report وطباعة Thermal/A4.
- فتح درج النقدية عبر مسار الإذن/موافقة المدير.
- Force Close Shift عبر مسار موافقة المدير.
- Offline status + pending sync indicator.

ملاحظة ثابتة: فتح الدرج الفيزيائي يحتاج Printer/Native Hardware Bridge؛ النظام الحالي يعرض ويطبق الإذن والتدقيق فقط ولا يدعي إرسال نبضة Hardware بدون bridge.

## KDS / Kitchen ✅
- Kitchen Display لها Route وصفحة مستقلة.
- تبويب "المطبخ" في الـHeader أصبح يفتح KDS الحقيقي بدل POS.
- Kitchen Display موجودة في القائمة حسب الصلاحية.
- Kitchen Stations أصبحت ظاهرة في قسم الإدارة لمستخدم `settings.manage` بدل أن تكون Route مخفية.
- KDS لا يخصم المخزون؛ البيع هو نقطة الخصم الوحيدة.

## Manager Approvals ✅
- `ApprovalInbox` ظاهر في الـHeader.
- Refund ظاهر في Sales للمستخدم المسموح أو عبر طلب موافقة الكاشير.
- Change Payment Method ظاهر في Sales ويستخدم مسار الموافقة عند الحاجة.
- Open Drawer ظاهر في Shift modal.
- Force Close Shift ظاهر في Shift modal.
- Discount / Reprint / Cancel sent item مرتبطة بمسارات الصلاحية/الموافقة.

## المشتريات والمخزون ✅
الصفحات الثانوية ليست مخفية؛ يتم الوصول إليها من مراكز الإدارة:
- Inventory Center → المخزون، المخازن، التحويلات، الجرد، الدفعات، حركة المخزون، التقييم، تنبيهات النقص.
- Procurement Center → أوامر الشراء، طلبات الشراء، RFQ، الاستلام.
- Operations Center → POS / Active Orders / التشغيل.

## الإدارة ✅
- Users / Roles / Audit / Settings / Super Admin لها مداخل واضحة حسب الصلاحية.
- System Diagnostics ظاهر داخل Super Admin؛ وجود Route تشخيص مستقل لا يعني أن الوظيفة مخفية عن Super Admin.
- Kitchen Stations أضيفت للقائمة.

## تنظيف Production الذي تم في هذا التدقيق ✅
- حذف صفحة `RegisterPage` العامة.
- `/register` يحول إلى Login.
- حذف رابط "إنشاء حساب" من شاشة Login واستبداله بتوضيح أن الحسابات تنشأ من الإدارة.
- إزالة زر "Seed Branch Demo Data" من Super Admin في Production.
- تصحيح نص مفتاح إنشاء المستخدمين: التحكم في إنشاء حسابات الموظفين داخلياً فقط؛ التسجيل العام للزوار مغلق.
- إزالة علامة "جديد" الثابتة من تبويب المطبخ.
- إزالة كارت placeholder "Premier Assistant — Coming soon" من الـSidebar.
- إخفاء تبويبات Header عن المستخدم الذي لا يملك الصلاحية بدل إظهار زر ينتهي برفض Route.

## Routes توافقية غير ظاهرة — مقصود ✅
هذه ليست صفحات ناقصة؛ هي aliases للحفاظ على الروابط القديمة:
- `/production` و`/production/units` → Recipes.
- `/accounting` → Financial Reports.
- `/employees` → Users.
- مسارات subscription القديمة تتحول للمكان الإداري الحالي.

## فجوات ليست "زر مخفي" ⚠️
تم البحث في الواجهة/المسارات الحالية ولم يظهر تنفيذ فعلي مكتمل لـ:
- Split Bill.
- Merge Tables.

لا يجب إضافة زر شكلي لهما قبل وجود عقد Backend/دورة تشغيل واختبارات واضحة. إذا تقرر تنفيذهما، فهما Feature work جديد وليس مجرد UI visibility fix.

## قاعدة العمل بعد هذا التدقيق
1. لا توجد وظيفة تشغيلية مكتملة نتركها بلا مدخل واضح للمستخدم المناسب.
2. لا نظهر زرًا لمستخدم لا يملك الصلاحية ثم ننتظر أن يرفضه الـRoute.
3. لا نضع أدوات Demo/Seed في واجهة Production.
4. لا نضيف أزرارًا لوظائف غير مكتملة Backend-side.
5. أي إضافة جديدة يجب أن تحدد: Route + Permission + User entry point + E2E/contract coverage.
