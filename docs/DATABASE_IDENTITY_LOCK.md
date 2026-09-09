# Database Identity Lock — johna-s

## Canonical project identity

This repository is permanently bound to the following Supabase project unless an explicit migration plan is approved and this lock is intentionally changed in the same reviewed change:

- Repository: `Premieros/johna-s`
- Supabase project ref: `azzdesuowpdcoflmyezn`
- Supabase project URL: `https://azzdesuowpdcoflmyezn.supabase.co`
- Supabase project name: `john's`

## Non-negotiable rule

No application code, CI workflow, deployment workflow, migration command, production-parity check, environment file, database connection string, or operational script may point this repository to another Supabase project.

A different project ref or Supabase URL is a hard failure, not a fallback.

## Enforcement

`scripts/db/verify-database-identity.js` enforces the canonical identity.

The verification must run before production build/deploy and as part of repository verification. It rejects:

1. `SUPABASE_PROJECT_REF` values other than `azzdesuowpdcoflmyezn`.
2. `VITE_SUPABASE_URL` values other than `https://azzdesuowpdcoflmyezn.supabase.co`.
3. Remote `SUPABASE_DB_URL` values that do not belong to the locked project. Localhost/127.0.0.1 database URLs remain allowed for isolated CI tests only.

## Secrets rule

GitHub/hosting secrets may provide credentials such as the publishable/anon key, but they must never override the project identity with another Supabase URL or project ref.

## Change control

Changing this file alone does not authorize a database move. Any future database migration requires an explicit user instruction, a migration plan, data verification, rollback plan, and coordinated updates to this lock, CI and deployment configuration.
