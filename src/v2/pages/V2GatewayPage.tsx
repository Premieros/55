import { Link } from 'react-router-dom';
import { ArrowLeft, ArrowRight, Building2, ShieldCheck } from 'lucide-react';
import { useLanguage } from '@/context/LanguageContext';
import { useCan } from '@/lib/permissions';
import { V2BranchProvider, useV2Branch } from '@/v2/context/V2BranchContext';
import { V2_MODULES } from '@/v2/core/capabilityRegistry';

function V2GatewayContent() {
  const { lang } = useLanguage();
  const isAr = lang === 'ar';
  const can = useCan();
  const { branches, selectedBranchId, selectedBranch, setSelectedBranchId, loading, error } = useV2Branch();

  const visibleModules = V2_MODULES.filter((module) => can(module.viewPermission));

  return (
    <div dir={isAr ? 'rtl' : 'ltr'} className="min-h-screen bg-ui-page text-ui-text">
      <header className="sticky top-0 z-20 border-b border-ui-border bg-ui-surface/95 backdrop-blur">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3 px-4 py-3 sm:px-6">
          <div>
            <div className="text-lg font-black">Premier</div>
            <div className="text-xs text-ui-muted">{isAr ? 'بوابة مساحات العمل' : 'Workspace gateway'}</div>
          </div>

          <div className="ms-auto flex min-w-0 items-center gap-2">
            <Building2 className="h-4 w-4 shrink-0 text-ui-primary" />
            <select
              value={selectedBranchId ?? ''}
              onChange={(event) => setSelectedBranchId(event.target.value)}
              disabled={loading || branches.length === 0}
              className="h-10 max-w-[240px] rounded-xl border border-ui-border bg-ui-surface px-3 text-sm font-semibold outline-none focus:border-ui-primary"
              aria-label={isAr ? 'الفرع الحالي' : 'Current branch'}
            >
              {branches.length === 0 && <option value="">{isAr ? 'لا يوجد فرع متاح' : 'No accessible branch'}</option>}
              {branches.map((branch) => (
                <option key={branch.id} value={branch.id}>{branch.name || branch.name_en || branch.id}</option>
              ))}
            </select>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-7xl p-4 sm:p-6">
        <section className="mb-6 rounded-3xl border border-ui-border bg-ui-surface p-5 shadow-ui-sm">
          <div className="flex items-start gap-3">
            <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-ui-primary-soft text-ui-primary">
              <ShieldCheck className="h-5 w-5" />
            </div>
            <div>
              <h1 className="text-xl font-black">{isAr ? 'المساحات المسموح بها' : 'Your workspaces'}</h1>
              <p className="mt-1 text-sm text-ui-muted">
                {isAr
                  ? `كل بطاقة تفتح مساحة التشغيل الأصلية بنفس صلاحيات الخادم والفرع${selectedBranch?.name ? ` — الفرع الحالي: ${selectedBranch.name}` : ''}.`
                  : `Every card opens the canonical production workspace with the same server and branch permissions${selectedBranch?.name_en || selectedBranch?.name ? ` — current branch: ${selectedBranch?.name_en || selectedBranch?.name}` : ''}.`}
              </p>
            </div>
          </div>
        </section>

        {error && (
          <div className="mb-4 rounded-2xl border border-ui-danger/30 bg-ui-danger-soft p-4 text-sm text-ui-danger">{error}</div>
        )}

        {visibleModules.length === 0 ? (
          <div className="rounded-3xl border border-ui-border bg-ui-surface p-8 text-center text-ui-muted">
            {isAr ? 'لا توجد مساحة تشغيل مسموح بها لهذا الحساب.' : 'No workspace is allowed for this account.'}
          </div>
        ) : (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {visibleModules.map((module) => (
              <Link
                key={module.key}
                to={module.route}
                className="group rounded-3xl border border-ui-border bg-ui-surface p-5 shadow-ui-sm transition hover:-translate-y-0.5 hover:border-ui-primary/40 hover:shadow-ui-md"
              >
                <div className="flex items-start gap-3">
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-ui-page-alt text-xs font-black uppercase text-ui-primary">
                    {module.key.slice(0, 2)}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <h2 className="font-black">{isAr ? module.labelAr : module.labelEn}</h2>
                      {isAr ? <ArrowLeft className="ms-auto h-4 w-4 text-ui-muted transition group-hover:-translate-x-1" /> : <ArrowRight className="ms-auto h-4 w-4 text-ui-muted transition group-hover:translate-x-1" />}
                    </div>
                    <p className="mt-2 text-sm leading-6 text-ui-muted">{isAr ? module.descriptionAr : module.descriptionEn}</p>
                    <div className="mt-3 text-[11px] font-semibold text-ui-subtle">{module.viewPermission}</div>
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </main>
    </div>
  );
}

export function V2GatewayPage() {
  return (
    <V2BranchProvider>
      <V2GatewayContent />
    </V2BranchProvider>
  );
}
