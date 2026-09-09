# تقرير حملة التحقق — Permission-First + توحيد المخزون/توفر POS

- **التاريخ:** 2026-09-09
- **الفرع:** `development/opencode` (لم يُلمس `main`)
- **Datbase قيد الاختبار فقط:** `pos55_test` على كلاستر `pg-itest` (port **55432**) — لا تلمس Production/Database Identity Lock.
- **الحالة العامة:** ⚠ **VERIFICATION IN PROGRESS — 477/482** (الجذور C1–C4 مغلقة ومتحققٌ منها؛ متبقٍّ 5 اختبارات فاشلة موزّعة على ملفين، جذورها محصورة بدقة وخطّة إصلاحها جاهزة — غير مطبَّقة بعد).

---

## 1. ملخص تنفيذي

حملة إغلاق الانحرافات في الأمان/الصلاحيات (Permission-First) وتوحيد المخزون وتوفر نقطة البيع. أُغلقت الجذور الأربعة الأوائل بالكامل مع إعادة توليد الدوال ومراجعة العقود، وتمّ تشغيل حزمة integration كاملة. الناتج الحالي:

- **أخضر:** 477 اختبارًا من 482 في حزمة integration عبر `npx vitest run -c vitest.integration.config.ts`.
- **فاشل (5):** 3 داخل `rls_branch_isolation.test.ts` (من أصل 103) + 2 داخل `permission_first_drift.test.ts` (من أصل 5).
- كل فشل من الخمسة **معزول حتى مستوى العبارة** (شاهد القسم 3) بجذر مؤكد وإصلاح مصمَّم.

## 2. الجذور المغلقة (C1–C4) — نتائج التحقق

| # | المشكلة | الجذر المؤكد | الإصلاح | التحقق |
|---|---|---|---|---|
| C1 | (سابق) بوابة/RLS متداخلة | — | هجرات الجولة السابقة | ✅ |
| C2 | (سابق) صراعات سرّة freshness | — | هجرات الجولة السابقة | ✅ |
| C3 | (سابق) طلبات الإنتاج/الوحدات ذات المرجع الذاتي | — | هجرات الجولة السابقة | ✅ |
| C4 | استلام المشتريات: `purchases` **بلا عمود `updated_at`** بينما `receive_purchase_order` المعاد توليده كان يكتب `updated_at = now()` على purchases | فحص حي لأعمدة الجدول: لا `updated_at`؛ بينما `update_purchase_order_status` لا يستخدمه أصلًا (status/approved_by/approved_at فحسب) | هجرة `20260909040000_fix_receive_purchase_order_missing_updated_at` (إعادة توليد الدالة وإزالة `updated_at` من UPDATE على purchases؛ يبقى على products حيث هو موجود) | ✅ |
| C4b | عقد `receive_purchase_order` انحرف عن الأصل: status أصبح `'received'` والـ return يفتقد `status` | الأصل في `075_procurement_workflow.sql` يعيد `status` ويضع `'completed'` | هجرة `20260909050000_fix_receive_purchase_order_status_contract` (status `'completed'`/`'partial'` + return يضم `status`,`items_received`,`fully_received`) | ✅ |
| C4c | `ACCOUNT_NOT_FOUND: accounts_payable` عند ترحيل قيد الاستلام | مفاتيح `account_mappings` الحيـة صحيحة هي `ap` و`vat_receivable` (22 مفتاحًا)؛ لا يوجد `accounts_payable`/`vat_input`؛ لا سنتينل يفحص المفاتيح (جدول mapping حرّ بلا CHECK enum)؛ النسخة الملغومة استخدمت المفاتيح الخاطئة | هجرة `20260909060000_fix_purchase_journal_account_key_aliases` (إضافة aliases `accounts_payable`→2000 و`vat_input`→2110 في `seed_account_mappings` + إعادة بذر الفروع) | ✅ |

**نتائج تشغيل محسومة:**
- `purchase_uom_auto_sale_cycle.test.ts` → **4/4 ✅**
- حزمة الملفات الخمسة (nested_manufactured_units، phase2_production_variance، unit_production_sale_flow، auto_production_sale_availability، purchase_uom_auto_sale_cycle) → **14/14 ✅**
- ملاحظة مصححة: `warehouseInventoryUnifiedContract.test.ts` **غير موجود** في `tests/integration` (glob فارغ) — لا يوجد ملف من هذا القبيل.

## 3. المتبقي: 5 اختبارات فاشلة — الجذر المعزول لكل منها

### 3.1 `rls_branch_isolation.test.ts` (100 ✓ / 3 ✗)

| الفحص | الرسالة الفعلية | الجذر المؤكد | الإصلاح المصمَّم |
|---|---|---|---|
| **recipe_items: writes gated through parent (parentWrite)** | `expected success, got: duplicate key value violates unique constraint "uq_recipe_items_recipe_raw"` | فهرس فريد حي مؤكد: `CREATE UNIQUE INDEX uq_recipe_items_recipe_raw ON recipe_items (recipe_id, raw_material_id)`؛ سطر الرصد يكرر زوج (recipe, raw_material) موجودًا مسبقًا من بذور `rls.ts` → اصطدام بيانات لا فشل RLS. | إصلاح بيانات الاختبار: جعل `paramsA`/`paramsB` لـ recipe_items تستخدم raw_material غير متضاربة (مثل `ids.rm2`/`ids.rmB`). لا تغيير في التأكيدات ولا في السياسات. |
| **writes to master data are admin-only** | `raw_materials INSERT cashier: expected RLS rejection, but statement succeeded (rowCount=1)` | سياسة حيّة `raw_materials_insert_branch_isolated` على `raw_materials` (WITH CHECK: `is_pos_admin() OR (branch_id = get_branch_id())`) تسمح لكاشير فرعه بإدراج سجل رئيسي — تناقض مع العقد admin-only. | هجرة جديدة: **DROP** `raw_materials_insert_branch_isolated` فقط (الحد الأدنى) مع الإبقاء على نسخة `auth_insert_raw_materials` القائمة على الصلاحيات. (كل إدراجات raw_materials في الاختبارات الأخرى تتم كـ postgres عبر `client.query` عبوريًا؛ لا عقد غير RLS يعتمدها.) |
| **guard_role_permissions: branch managers cannot mint admin-only roles (044)** | `roles INSERT bm with owned settings.manage: expected success, got: PERMISSION_DENIED:roles.permissions.manage` | بوابة `guard_role_permissions` في إصداره الأخير `20260905110625...` تشترط `can_permission('roles.permissions.manage')`، بينما العقد (044 + 20260904046000) والاختبارات الحية تعتمد **`settings.manage`** — المفتاح `roles.permissions.manage` غير مستخدم في أي اختبار ويبدو متقاعدًا. | هجرة جديدة: إعادة `CREATE OR REPLACE` للـ guard مع بوابة `settings.manage` (مع الإبقاء على تحسينات 05110625: bypass `is_pos_admin`، تطبيع الفرع، منع منح ما لا يملكه). **قبل التثبيت:** فحص دعاة INSERT roles في الملفات الخضراء (v2_permission_first_branch_access:56، approval_policies:37، rbac_hardening:77، phase4_security_contract:125، production_acceptance:40، v2_pos_kitchen:52، phase2_waste:61، v2_multibranch_shift:54، v2_operational_approval:70) للتأكيد أن لا دعاها غير-super-admin بمفتاح `roles.permissions.manage` دون `settings.manage`. |

### 3.2 `permission_first_drift.test.ts` (3 ✓ / 2 ✗)

| الفحص | الرسالة الفعلية | الجذر المؤكد | الإصلاح المصمَّم |
|---|---|---|---|
| **has no role-label authorization helper or fixed operational role gates** | `expected [] to deeply equal [ { fn: "process_purchase(text,uuid,uuid,uuid,numeric,numeric,numeric,numeric,numeric,text,text,text,jsonb)" } ]` | `process_purchase` (بعد توحيد المخزون) ما زالت تحمل بوابة أدوار ثابتة داخل النص: `IF NOT is_pos_admin() AND get_user_role() NOT IN ('warehouse_manager','branch_manager') THEN RETURN 'NOT_ALLOWED'`. | هجرة جديدة: استبدال السطر بـ `IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN RETURN 'NOT_ALLOWED'`. **قبل التثبيت:** التأكد من أن كل داعٍ متوقع النجاح يملك `purchases.manage` (branch_manager يملكها؛ warehouse_manager يحتاج تدقيقًا — ربما `purchases.manage OR warehouses.manage` إن انكسر عقد). |
| **has no RLS policy authorization based on fixed operational roles** | `expected [] to deeply equal [ 3 policies on public.print_jobs ]` | سياسات `print_jobs` الثلاث (insert/update/select) حية بصيغة أدوار: `u.role = ANY (ARRAY['super_admin','owner','admin']) OR u.branch_id = ...` — لا يوجد اختبار واحد في المستودع يشير إلى print_jobs، فالإصلاح آمن. | هجرة جديدة: **DROP + CREATE** للسياسات الثلاث بصيغة فرع/صلاحية دون role literals: `USING/WITH CHECK user_may_access_branch(print_jobs.branch_id)` (النموذج المعتمد فعلًا في سياسات auth_* لغيره). |

## 4. حقائق داعمة مثبتة حيًّا (بنية التفويض الحالية)

- `is_pos_admin()` = `users.role = 'super_admin'` فحسب.
- `is_platform_admin()` = `users.role = 'super_admin'`.
- `can_permission(p)` = `is_pos_admin() OR EXISTS(JOIN roles WHERE roles.permissions ? p)` — لذا **super_admin هو البايباس الضمني الوحيد** (متوافق مع sentinel drift).
- `user_may_access_branch(b)` = `is_pos_admin() OR user_branch_access OR نفس الفرع`.
- `get_user_role()` = قراءة `users.role` (لا يستخدم لأي تفويض بعد الإصلاح).
- `account_mappings`: 22 مفتاحًا صالحًا فقط؛ لا check constraint ولا sentinel — نُقدّم المفاتيح عبر `_post_journal_entry`/`resolve_account_key`.
- `_post_journal_entry(uuid,text,uuid,text,text,jsonb)`: idempotency بـ (reference_type, reference_id).
- فهرس فريد مؤكد على recipe_items: `uq_recipe_items_recipe_raw`.
- `purchases` بلا `updated_at` (17 عمودًا؛ default status = 'completed').

## 5. خطة التكميل (خطوة واحدة قبل التقرير النهائي الأخضر)

1. التحقق المسبق المذكور في §3 (دعاة roles، ملكية `warehouse_manager` لـ `purchases.manage`، تعريف `auth_select_raw_materials` قبل DROP).
2. هجرة واحدة `20260909*_permission_first_final_closure.sql` تحمل الإصلاحات الأربعة (guard gate، process_purchase gate، print_jobs policies، DROP `raw_materials_insert_branch_isolated`).
3. إصلاح بيانات اختبار recipe_items في `rls_branch_isolation.test.ts` (مواد خام غير متضاربة).
4. تشغيل الملفين المصابين فقط → عند الخضر: full integration suite → `npm run typecheck` ← `npm test` ← `npm run lint` ← `npm run build` ← full integration نهائي.
5. التقرير الختامي النهائي بالعربية. **بلا commit/push/merge/ZIP** ما لم يطلبه المستخدم صراحةً.

## 6. قيود والتزامات الحملة

- الاختبار حصريًا على `pos55_test`/55432 عبر متغير بيئة الجلسة فقط؛ لا تلمس 5432 ولا Production ولا Remote.
- لا تعديل هجرات مطبَّقة — كل إصلاح DB بهجرة مرقّمة جديدة + `scripts/db/apply-migration.js`.
- لا إضعاف RLS ولا حذف/تعطيل اختبارات؛ إصلاحات الاختبارات تقتصر على بيانات fixtures غير المتضاربة.
- لا `any`/`ts-ignore`.
- أداء الاستقصاء: بلا binary `psql`؛ `node -e` يفشل في PowerShell (تشويه الاقتباس) → يُستخدم ملف `.mjs` داخل `app/` (package.json `"type": "module"` → `import { Client } from 'pg'`).

## 7. ملفات ذات صلة

- الهجرات المطبَّقة (C4): `supabase/migrations/20260909040000_fix_receive_purchase_order_missing_updated_at.sql`، `20260909050000_fix_receive_purchase_order_status_contract.sql`، `20260909060000_fix_purchase_journal_account_key_aliases.sql`.
- مصدر المفتاحين الخاطئين: `supabase/migrations/20260908150000_unify_warehouse_inventory_and_pos_availability.sql` (يعيد توليد `process_purchase`/`receive_purchase_order` ويتضمن `settings`-gate للـ guard ومفاتيح `accounts_payable`/`vat_input`).
- عقد الأصل: `supabase/migrations/075_procurement_workflow.sql` (receive_purchase_order)، `020_d2_rpc.sql` (process_purchase الأصلي بمفاتيح `ap`/`vat_receivable`).
- الـ guard عبر الإصدارات: `044_rbac_hardening.sql:487`، `20260904046000_permission_first_roles_branch_access.sql:249` (بوابة `settings.manage`)، `20260905110625_permission_first_regression_closure.sql:38` (البوابة الحالية `roles.permissions.manage`).
- الاختبارات: `tests/integration/rls_branch_isolation.test.ts`، `tests/integration/permission_first_drift.test.ts`، `tests/integration/rls.ts` (البذور)، `tests/integration/batch2_permissions.test.ts` (يؤكد الاسم الحي `settings.manage`).
- مؤقتات للحذف قبل النهاية: `probe_facts_tmp.mjs`، `probe_facts2_tmp.mjs` (وما سبق: `probe_tmp.mjs`، `diag_tmp.mjs`).