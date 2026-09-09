# Main Deviation Closure Log — 2026-09-05

## Verified baseline

- Repository: `Premieros/johna-s`.
- Main baseline before this documentation update: `096b2788c4068131de34fd5c24f55b0d9db17367`.
- Supabase Production Project Ref: `azzdesuowpdcoflmyezn` only.
- Verify main #702: PASS.
  - Database Identity Lock
  - API Contract
  - Lint
  - TypeScript app/tests
  - Unit
  - Build
  - Fresh DB + canonical migrations
  - Schema verification
  - Integration/Security/RLS
  - Browser Smoke
- Deploy #521: PASS.
  - Database Identity Lock
  - Build
  - Production API Parity
  - GitHub Pages Deploy

## Deviations confirmed on main

1. **Permission-First root closure is not final yet.** PR #18 (`fix/permission-first-root-drift-v2`) still carries a large authorization hardening set that has not been merged. Its last full Verify reached frontend green but failed Integration/Security/RLS; Browser Smoke therefore did not run.
2. **Supabase Security Advisor still reports SECURITY DEFINER exposure warnings.** These require a function-by-function audit; the warnings are not automatically treated as vulnerabilities, but no 100% security claim is allowed until exposures are classified and tested.
3. **Leaked Password Protection is disabled** in Supabase Auth and remains an explicit security hardening item.
4. **CURRENT_WORK_PLAN had become stale** relative to actual `main`, Verify and Deploy run numbers. It has now been rewritten to match the current baseline and closure order.
5. **`main` is not protected by GitHub branch protection** at the time of this audit. CI is green, but direct push remains a governance risk until required checks can be enforced.
6. **UI/runtime backlog must be re-verified on the current deployed build before editing.** Old screenshots/issues are not automatically considered active because multiple fixes landed after those observations.

## Locked execution order

1. Synchronize PR #18 with latest `main` and preserve the database identity lock.
2. Review the PR's commits against current main to avoid reintroducing superseded code.
3. Close Permission-First regressions until Fresh DB + Integration/Security/RLS + Browser Smoke are green.
4. Audit SECURITY DEFINER functions and external EXECUTE grants on `azzdesuowpdcoflmyezn`.
5. Harden or revoke unintended exposure, with regression tests.
6. Enable/resolve leaked password protection.
7. Run full Verify again.
8. Re-run runtime UI regression checks on the live/current build.
9. Fix only regressions reproduced on current main.
10. Protect main with required checks if GitHub permissions allow.
11. Finalize printing and remaining operational polish.
12. Run full operational E2E and produce final Zero-Drift report before any 100% declaration.

## Non-negotiable constraints

- Never point this repository at any Supabase project other than `azzdesuowpdcoflmyezn`.
- Super Admin is the only implicit full-access principal.
- All other roles are labels; authorization is permission-first.
- No weakening/deleting tests or RLS to make a gate green.
- No reopening closed work without a current regression signal.
- No production database mutation outside an explicitly approved task.

## Source of Truth

`docs/CURRENT_WORK_PLAN.md` on `main` is the authoritative execution plan after this audit.
