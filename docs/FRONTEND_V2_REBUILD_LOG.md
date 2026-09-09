# FRONTEND V2 REBUILD LOG — john-s

> السجل التنفيذي التفصيلي لإعادة بناء الواجهة فوق قاعدة البيانات الحالية. المرجع المختصر وSource of Truth الحالي هو `docs/CURRENT_WORK_PLAN.md`.

آخر تحديث: **2026-09-04 — Africa/Cairo**

---

## 0) القرار المعماري الحالي

- Production branch: `main`.
- فرع التطوير الوحيد: `development/frontend-v2`.
- Draft PR: #6 — `feat: rebuild frontend v2 from database contract`.
- Supabase Production `azzdesuowpdcoflmyezn` هو Source of Truth للـbackend.
- لا Production migration من PR #6 بدون طلب صريح وVerify مناسب.
- Frontend V2 يبنى تدريجيًا فوق RPCs/RLS الحالية، ولا يوجد زر شكلي بدون Backend حقيقي.
- العربية RTL هي الأساس، الإنجليزية LTR.

### قرار المستخدم الملزم — Branch Access + Permission First

هذا القرار supersedes أي نص أقدم في هذا السجل يقول إن `owner` implicit/global admin أو إن اسم الدور هو مصدر السماح.

1. المستخدم يعمل على **أي فرع لديه Access فعلي عليه**.
2. لا يتم حبسه في `users.branch_id` فقط؛ المرجع هو `user_may_access_branch()` + RLS + branch grants.
3. وجود Branch Access وحده لا يسمح بتنفيذ Action؛ يجب وجود Permission المطلوبة.
4. وجود Permission وحدها لا تسمح بالعمل على فرع غير مخول.
5. **الصلاحيات هي الأساس، والأدوار أصبحت Labels/Templates.**
6. إذا كانت للمستخدم Permission فعالة فلا يجوز حجبها بسبب اسم Role.
7. `owner` ليس implicit admin.
8. `branch_manager` ليس implicit admin.
9. **Super Admin فقط** implicit/platform admin/full-access bypass.
10. كل المستخدمين الآخرين يعتمدون على Effective Permissions + Branch Access.
11. Server-side check إلزامي لكل Action حساس؛ UI gate وحده لا يكفي.
12. Permission resolver لغير Super Admin يجب أن يفشل مغلقًا إذا لم تتوفر DB permission map؛ لا fallback إلى defaults القديمة.

ملاحظة: التخزين الحالي للصلاحيات يعتمد أساسًا على `roles.permissions` المرتبطة بالمستخدم. إذا تقرر لاحقًا دعم Direct User Permission Overrides مستقلة، يجب أن تدخل في Effective Permission resolver نفسه، مع بقاء Role label غير قادر على حجب Permission ممنوحة للمستخدم.

---

## 1) نقطة البداية والتنظيم

- `main` عند بدء V2: `4e63ce21597958dc9ee9852ca2ff00e4e14c86a3`.
- PR #3 وPR #5 أغلقا وتم اعتبارهما superseded.
- كل التطوير الجديد ينتقل فقط عبر `development/frontend-v2` وPR #6.
- لا يعاد فتح عمل مغلق بدون Regression مثبت.

---

## 2) Production snapshot — قراءة فقط

فحص 2026-09-04:

- Public tables: 100
- Public functions: 243
- RLS policies: 331
- Active branches: 2
- Active users: 8
- Active products: 335
- Active warehouses: 2

Canonical backend المستخدم في V2 يشمل:

- Identity/scope: `users`, `roles`, `branches`, `user_branch_access`, `user_may_access_branch`.
- POS/KDS: orders/order_items, create/update order, `send_to_kitchen`, KDS queue/status, sale processing.
- Shifts: `open_shift`, `close_shift`, `get_active_shift`, closing reports.
- Catalog/modifiers.
- Inventory/units/counts/transfers.
- Procurement/suppliers.
- Waste/approvals.
- Accounting/treasury/reports.

Legacy/compatibility layers تبقى موجودة في Production ولا تبنى لها واجهة تلقائيًا، وأي إزالة لاحقة تحتاج dependency proof + migration + Fresh DB/regression.

---

## 3) Foundation V2 — تم ✅

- RTL-first App Shell.
- Sidebar قابل للطي + mobile drawer.
- Header مع branch selector وshift state.
- branch context من الفروع التي تسمح بها RLS.
- selected branch per-user.
- capability registry موحد.
- `/v2` Home/status surface.
- `useV2Can()` لقراءة permission strings من DB-backed permissions.

---

## 4) Permission-first / Multi-branch refactor — تم كأساس ✅

### Migration

`20260904046000_permission_first_roles_branch_access.sql`

### ما تغير فعليًا

- `can_permission()`:
  - Super Admin فقط implicit bypass.
  - باقي المستخدمين يقرأون Permissions من DB role permissions.
- `user_may_access_branch()`:
  - Super Admin أو explicit `user_branch_access` أو primary branch grant.
  - لا Role-name أو organization label يمنح وصولًا تلقائيًا لكل الفروع.
- `owner` خرج من implicit admin behavior في المسارات التي تم تحويلها.
- V2-sensitive RPCs التي كانت تعتمد `is_pos_admin()` تم تحويل bypass فيها إلى `is_platform_admin()` حيث استهدفتها migration.
- `create_user` / `delete_user` / `update_user_password` أصبحت تعتمد `users.manage` + branch scope.
- `set_user_branch_access` يسمح بإدارة فروع المستخدم في نطاق فروع المانح وبصلاحية `users.manage`.
- Role templates يمكن إدارتها بصلاحية مناسبة، لكن غير Super Admin لا يستطيع منح Permission لا يملكها.
- Super Admin role محمي platform-only.
- frontend permission resolver أصبح fail-closed لغير Super Admin بدل fallback إلى Default Role map.
- Permission Matrix أصبح Super Admin-only immutable full access؛ `owner` لم يعد كذلك.
- `UsersPage` أصبحت Permission-first وتتعامل مع المستخدمين/الفروع التي تسمح بها RLS بدل حصر الإدارة في primary branch.

### Commits الأساسية

- `63ba58088c68663903aab3fd9bec05bc124bb8af` — permission-first roles and branch access.
- `d0178def69fee4333763555aaf27b200331961b5` — tests for permission-first branch authorization.
- `2739fbca9396e373c2bfc018fa9b170d12105164` — Super Admin-only implicit V2 permissions.
- `9ab758d74f95c31a95f03318e71b9f37a99c57f0` — fail closed on DB-backed permissions.
- `25e7366341327440b0fc931257acf3abba4218be` — app permission resolver from DB roles.
- `8c44122ac8b61aaa900d18e51b4f649d895c4bb4` — only Super Admin immutable full-access role.
- `751f737633fcf8a620c4996e0f4069290a59d0a8` — Permission Matrix Super Admin-only implicit.
- `e1de2ea340b56c30d4b9124b5575b3904823e528` — users management across granted branches.
- `c7f6d7276b934e9d5f3114e270edbff139fab322` — unit tests aligned with DB-backed authorization.

### مهم

الأدوار في V2 لا تستخدم كحاجز مستقل. Role label قد يحدد template الصلاحيات، لكن **القرار الوظيفي النهائي هو Permission + Branch Access**.

---

## 5) POS V2 — منفذ جزئيًا

تم:

- `/v2/pos`.
- Table-first للصالة.
- Takeaway / Delivery / Drive Thru.
- تحميل المنتجات/التصنيفات/الطاولات/الطلبات المفتوحة حسب الفرع.
- Cart/kinds/remove.
- required modifiers min/max.
- availability.
- `create_order`.
- `update_order` والاستئناف.
- branch scope عبر `user_may_access_branch`.
- Send to Kitchen داخل POS V2.
- dedicated Permission `pos.send_kitchen`.
- canonical `send_to_kitchen(uuid, uuid DEFAULT NULL)`.
- delta KDS send؛ لا يعيد إرسال الكمية التي أرسلت سابقًا.

Commits:

- `9ad0dd7fc2dab9120fbb837c78008579e6ab44a9` — V2 send to kitchen.
- `0d5b19021e9bcda7df65e1b033bc01f1b8c1e0f8` — permission contract alignment.
- `d20b4e70cc8fa3bf2af56332d182a395828a144f` — kitchen wiring tests.

متبقي POS:

- Payment.
- Split Payment.
- Discount/void/cancel/transfer/split UI + approvals.
- Print/reprint.
- **قرار المستخدم: خصم المخزون عند Send to Kitchen. الـRPC الحالي في HEAD يسجل KDS delta فقط ولا ينفذ inventory effect؛ لذلك هذا القرار ما زال Implementation + Regression مطلوبين، ولا يوثق كمكتمل حتى يصبح idempotent ويمنع الخصم المكرر.**

---

## 6) Shifts / Closing V2 — تم الربط الحالي ✅

تم:

- multi-branch `open_shift`/`close_shift` permission contract.
- شفت مفتوح واحد للمستخدم عبر الفروع المخولة.
- Header يكتشف الشفت عبر الفروع ويعرض الانتقال للفرع الصحيح.
- `shifts.open`, `shifts.close`, `shifts.manage` حسب العملية.
- `V2ShiftsPage.tsx`.
- `/v2/shifts` route.
- V2 Sidebar navigation.
- user/shift/day closing reports.

Commits:

- `6bd3b2a71cfb0bb94f22d2f08f03237abae06cc6`
- `8e6f23dac4ea9a0c77c90ab765fac71c11d4fc50`
- `5b39f08874a3fe1b5b3ed6b118a680a9aa1b1385`
- `f207fd2295e3a483ef51c0acbef3edd1a44c18bc`
- `387313f0e0ff92b343953b273b41aa2b5aaff0b7`
- `1bafbc5cef6b1be93b8f4382ee4fc47606a5037d`
- `9c6dc03c82176ff704fcdc64371069980f305ad5`

---

## 7) Unified Approval Center — منفذ جزئيًا

تم:

- Queue موحدة للmanager approvals + waste + stock counts + warehouse transfers.
- `decide_operational_approval` يوجه للـRPC الحقيقي.
- `required_permission` per row بدل hard-code لاسم Role.
- self approval يحتاج `approvals.override`.
- waste/count/transfer approval targets hardened مع Permission + Branch Access.

متبقي:

- route visibility النهائي حسب Permissions الاعتماد الفعلية بدل Gate عام قديم.
- assigned-manager / policy configuration الكامل لكل Action type.

---

## 8) Waste Center — fixes الحالية مكتملة ✅

- تحميل واختيار المنتجات حسب الفرع.
- `p_product_id` إلى `create_waste_entry`.
- test user حقيقي بصلاحية `production.waste` بدل service-role bypass.
- canonical waste type `finished_good` في الاختبارات.

---

## 9) Checkpoint تاريخي — Verify #543

Run: `33850444754`
Head: `8c819f67ecef4012ca4cca4fb43da92475116d22`

Frontend:

- API contract ✅
- lint ✅
- typecheck ✅
- typecheck:all ✅
- unit ✅
- build ✅

Fresh DB/Security:

- 200 migrations / 0 skipped ✅
- schema ✅
- 60/60 expected tables ✅
- 65/65 expected functions ✅
- 107/107 contract RPCs ✅
- 61/61 contract tables ✅
- 57/57 integration files ✅
- 444/444 integration/security/RLS ✅

Browser:

- 50 passed / 5 failed.
- الخمس failures معروفة في legacy `tests/e2e/pos-actions.spec.ts` بسبب stale direct-add selector قبل وصول السيناريو إلى kitchen/payment logic.
- الإصلاح التاريخي Test-only: `8d5fb44cd3da3b67b753cc4bd14e8ce3a58a1859`.
- ممنوع تغيير POS الحقيقي فقط لإسكات selector قديم.

---

## 10) آخر Checkpoint — Verify #559

Run: `33866122650`
Head: `c7f6d7276b934e9d5f3114e270edbff139fab322`

### Frontend ✅

- API contract ✅
- lint ✅
- typecheck ✅
- typecheck:all ✅
- unit ✅
- build ✅

هذا يثبت أن Unit tests القديمة التي كانت تتوقع `owner = admin` أو Default Role fallback تم تعديلها بما يطابق العقد الجديد.

### DB / Security ❌ عند Integration step

نجح:

- DB/container setup ✅
- auth stub ✅
- canonical migrations ✅
- schema verification ✅
- integration fixture setup ✅

فشل:

- `Run integration and security/RLS regression tests` ❌

Browser Smoke:

- skipped لأن DB job فشل قبل فتح Browser gate.

**لا يوجد في jobs API المستخدم هنا نص failing assertions نفسه؛ لذلك لا نسجل Root Cause تخمينيًا. الخطوة الصحيحة هي قراءة failure details ثم تصنيفها.**

قاعدة الإصلاح:

- إذا failure اختبار قديم يتوقع owner/admin bypass أو Role-name authorization القديم → يعدل الاختبار إلى Permission-first.
- إذا failure يثبت تسرب branch أو تجاوز Permission → يصلح الكود/RLS.
- ممنوع إعادة `owner` implicit admin أو إضافة bypass فقط لإخضرار الاختبارات.

---

## 11) ما تم وما تبقى الآن

### تم ✅

- Foundation/App Shell/RTL/branch selector.
- Multi-branch context من RLS-visible branches.
- Permission-first core contract.
- Super Admin-only implicit full access.
- Owner أصبح Role عاديًا من ناحية authorization.
- DB-backed permission resolver fail-closed.
- Users management بـ`users.manage` عبر granted branches.
- Permission Matrix Super Admin-only immutable role behavior.
- POS V2 create/update/cart/modifiers/availability.
- Send to Kitchen V2 + `pos.send_kitchen` + canonical delta KDS send.
- Shifts/Closing page + route + navigation + permission checks.
- Approval Center backend/queue/security core.
- Waste fixes الحالية.
- Frontend gate في Verify #559 أخضر بالكامل.

### المتبقي — بالترتيب

1. **إغلاق Integration/Security/RLS failures في Verify #559** بدون تراجع عن Permission-first أو RLS.
2. إعادة Verify حتى DB gate أخضر ثم Browser Smoke.
3. Approval Center final route visibility + assigned-manager/policy config.
4. **تنفيذ خصم المخزون عند Send to Kitchen بصورة idempotent مع delta inventory effects ومنع double deduction.**
5. Payment + Split Payment.
6. POS discount/void/cancel/transfer/split + approval flow.
7. Receipt print/reprint.
8. Waste final UX/regression.
9. Inventory / warehouses / counts / transfers V2.
10. Catalog / products / modifiers V2.
11. Procurement / suppliers V2.
12. Sales / customers / refunds V2.
13. Accounting / treasury / reconciliation V2.
14. Unified table-first Reports.
15. Users / Roles / granular Permission Matrix / Settings / Audit final UX.
16. إذا طُلب Direct per-user Permission Override مستقل عن Role template: إضافته إلى Effective Permission resolver + UI + tests.
17. إغلاق known legacy Browser helper regression بإصلاح Test-only قبل الدمج النهائي.
18. Final Verify كامل.
19. Merge فقط بعد اكتمال gates المطلوبة وطلب الدمج.

---

## 12) ممنوعات خلال الاستكمال

- ممنوع Role-name gate يمنع Permission فعالة.
- ممنوع اعتبار `owner` أو `branch_manager` implicit admin.
- ممنوع استخدام `users.branch_id` وحده كحد فروع المستخدم.
- ممنوع Branch Access bypass.
- ممنوع Permission bypass.
- ممنوع RLS weakening.
- ممنوع منح المستخدم Action في فرع غير مخول.
- ممنوع منع المستخدم من Action داخل فرع مخول إذا كانت Permission الفعالة تسمح به بسبب اسم Role فقط.
- ممنوع fallback إلى Default Role permissions عند غياب DB map لغير Super Admin.
- ممنوع تعديل Production مباشرة أثناء بناء V2 إلا بطلب صريح وبعد Verify.
- ممنوع زر Placeholder يوحي بأنه يعمل.
- ممنوع نسخ الحسابات المالية authoritative إلى client.
- ممنوع تغيير POS behavior الحقيقي فقط لإسكات legacy test selector.

---

## 13) Definition of Done

أي Module لا يعتبر مكتملًا حتى:

- backend action حقيقي.
- Permission gate فعالة في UI وserver عند الحاجة.
- Branch Access صحيح عبر RLS/`user_may_access_branch`.
- Role label لا يحجب Permission فعالة.
- loading/empty/error/success states.
- RTL/LTR + desktop/tablet/mobile.
- unit/contract tests.
- integration regression لأي DB mutation.
- browser smoke للمسار الأساسي أو توثيق known legacy failure غير مرتبط.
- لا Regression على KDS/inventory/accounting.

> المطور التالي يبدأ بقراءة `docs/CURRENT_WORK_PLAN.md` ثم هذا الملف، ويعيد قراءة HEAD/PR #6 قبل أي تعديل.