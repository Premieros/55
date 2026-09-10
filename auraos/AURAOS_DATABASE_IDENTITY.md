# AuraOS Database Identity Lock

AuraOS on branch `development/auraos-preview` is dedicated to exactly one Supabase project:

- Project ref: `limpprtlwtlvfwezkulq`
- API URL: `https://limpprtlwtlvfwezkulq.supabase.co`

## Hard rules

1. Never use the `55` production database or any other Supabase project for AuraOS.
2. Never commit a database password, JWT secret, service-role key, or real `.env` file.
3. `src/config/databaseIdentity.ts` rejects any `DATABASE_URL` whose hostname/username does not identify `limpprtlwtlvfwezkulq`.
4. `npm run migrate` goes through `scripts/migrate-locked.ts`, so migrations fail closed before touching a mismatched database.
5. Use `sslmode=require` for PostgreSQL connections.
6. For GitHub Actions or other IPv4-only hosts, use Supavisor **Session Pooler** (port 5432), not the direct `db.<project-ref>.supabase.co` endpoint unless an IPv4 add-on is enabled.

## Migration set

AuraOS currently carries migrations `001` through `028`. Apply them only to the dedicated AuraOS database after connection verification.

## Current deployment state

The GitHub Pages route `/55/auraos-preview/` is the static frontend preview. AuraOS also requires its Node/Express backend for API, authentication, Socket.io, and live database operations; GitHub Pages cannot host that backend.
