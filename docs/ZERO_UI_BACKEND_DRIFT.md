# Zero UI / Backend Drift — 2026-09-04

## القرار المعماري

واجهة V2 هي بوابة Permission-aware إلى مساحات التشغيل الأصلية المثبتة، وليست تنفيذًا ثانيًا موازيًا للـPOS أو الشفتات أو المخزون أو المشتريات أو التقارير.

## القواعد

- كل Module في `V2_MODULES` يملك `viewPermission` واحدة حقيقية ومسار Production واحدًا حقيقيًا.
- `/v2/pos` يحول إلى `/pos`، و`/v2/shifts` يحول إلى `/shifts`؛ لا توجد دورتا تشغيل لنفس الوظيفة.
- `approvals.review` هو صلاحية عرض مركز الموافقات؛ `settings.manage` لا يمنح المدخل بالنيابة عنها.
- الهالك يعرض فقط بـ`waste.view`، مع RLS مطابق في Production وFresh DB.
- اختيار الفرع في V2 يزامن `premier_active_branch` المستخدم في بقية النظام.
- صلاحيات POS الإجرائية تبقى مستقلة: `pos.order.create`, `pos.order.edit`, `pos.send_kitchen`, `pos.payment.take`, `pos.order.split`, `pos.order.transfer`, `pos.receipt.print`.
- لا يتم إنشاء زر أو Workspace موازٍ إذا كانت الدورة الأصلية المختبرة موجودة بالفعل.

## معنى Zero Drift

Zero Drift هنا يعني أن كل Capability ظاهرة في البوابة تفتح الصفحة الحقيقية التي يحميها نفس Permission المستخدمة في الـRegistry، وأن الصفحات الجزئية القديمة في V2 غير قابلة للوصول من Routing الإنتاجي.

الطباعة المحلية بثلاث محطات `cashier / kitchen / barista` Feature تشغيلية مستقلة وليست انحرافًا بين الواجهة والعقد الحالي، وتنفذ في حزمة منفصلة وفق قرار التشغيل المعتمد.
