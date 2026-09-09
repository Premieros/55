# Database Identity Lock — Premieros/55

## Canonical project identity

This repository is permanently bound to the following Supabase project unless the user explicitly approves a coordinated database migration:

- Repository: `Premieros/55`
- Supabase project ref: `scpovyrqmsbiduanykod`
- Supabase project URL: `https://scpovyrqmsbiduanykod.supabase.co`

## Non-negotiable rule

No application code, CI workflow, deployment workflow, migration command, production-parity check, environment file, database connection string, or operational script may point this repository to another remote Supabase project.

Any remote project ref other than `scpovyrqmsbiduanykod` is a hard failure. Localhost/127.0.0.1 is allowed only for isolated test databases.

## Enforcement

`scripts/db/verify-database-identity.js` enforces the canonical identity and must run before release verification and deployment.

It rejects:

1. `SUPABASE_PROJECT_REF` values other than `scpovyrqmsbiduanykod`.
2. `VITE_SUPABASE_URL` values other than `https://scpovyrqmsbiduanykod.supabase.co`.
3. Remote `SUPABASE_DB_URL` values that do not belong to the locked project.

## Change control

Changing documentation alone does not authorize a database move. Any future database migration requires explicit user instruction, a reviewed migration plan, verification, rollback plan, and coordinated updates to CI/deployment configuration.
