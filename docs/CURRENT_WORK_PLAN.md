# CURRENT WORK PLAN — Premieros/55

> Source of Truth للمشروع الحالي. أي نموذج أو مطور يبدأ من هذا الملف.

## الهوية الثابتة

- Repository الوحيد: `Premieros/55`
- Production branch: `main`
- Development branch: `development/opencode`
- Production Supabase الوحيد: `scpovyrqmsbiduanykod`
- Production URL: `https://scpovyrqmsbiduanykod.supabase.co`
- Local integration DB فقط: `localhost` / `127.0.0.1`

أي reference إلى `azzdesuowpdcoflmyezn` أو أي Supabase remote آخر داخل هذا المشروع يعتبر خطأً محظورًا.

## قواعد غير قابلة للتفاوض

1. Super Admin فقط يملك implicit bypass.
2. باقي النظام Permission-First + branch/RLS؛ أسماء الأدوار Labels فقط.
3. لا weakening لـRLS أو tests.
4. لا Force Push.
5. لا تعديل مباشر على `main` أثناء الإصلاح.
6. لا Production migration قبل Full Verify أخضر ومراجعة migration.
7. المستودع Source-Based مباشرة (`src/`, `tests/`, `supabase/`)؛ لا ZIP كمصدر أو build path.
8. لا تعديل Production logic لإرضاء fixture قديم؛ أصلح Root Cause الحقيقي.

## الحالة الحالية — 2026-09-09

- تم تحويل `development/opencode` إلى Source-Based repository.
- `johna-s.zip` حُذف ولم يعد جزءًا من التطوير أو النشر.
- Pages workflow يبني من ملفات المصدر مباشرة.
- Database identity verifier مقفل على `scpovyrqmsbiduanykod` فقط.
- إصلاحات Inventory/Purchases TypeScript موجودة.
- إصلاح duplicate held POS orders موجود.
- `transfer_staff` منفذ ومغطى integration.
- إصلاح shift sales/user totals موجود في baseline الإنتاج السابق.
- migrations توحيد warehouse inventory وإغلاق integration drift موجودة على فرع التطوير فقط حتى اجتياز Release Gate.
- Permission-first release closure أغلقت raw materials / print jobs / process_purchase drift محليًا.
- recipe_items: القراءة branch-scoped، والكتابة permission-gated بـ`recipes.manage`.

## Release Gate الحالي

المطلوب قبل التسليم:

1. Fresh local PostgreSQL + `supabase/ci/stub_auth.sql`.
2. تطبيق جميع migrations محليًا بدون skip أو error.
3. Schema/API contract verification PASS.
4. Full Integration = 0 FAIL.
5. TypeScript `typecheck:all` PASS.
6. Unit/Component/Feature tests PASS.
7. Lint PASS.
8. Production build PASS.
9. مراجعة migrations النهائية وعدم وجود RLS/permission regressions.
10. Production read-only parity على `scpovyrqmsbiduanykod`.
11. بعد موافقة صريحة على Production DB write: تطبيق migrations المطلوبة فقط على `scpovyrqmsbiduanykod`.
12. Merge verified code إلى `main` ثم GitHub Pages deploy.
13. Runtime smoke على الموقع المنشور قبل إعلان التسليم.

## معيار READY FOR DELIVERY

لا نعلن الجاهزية إلا عندما يكون:

- Source tree verified ✅
- Database identity locked ✅
- Fresh DB migrations ✅
- Schema/API contract ✅
- Integration 0 FAIL ✅
- Typecheck ✅
- Unit/Component/Feature ✅
- Lint ✅
- Build ✅
- Production DB parity ✅
- Published `main` ✅
- Runtime smoke ✅

الهدف النهائي:

**Published Site = Verified Main = `scpovyrqmsbiduanykod` Contract = Zero Known Regression**
