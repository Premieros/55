export const AURAOS_SUPABASE_PROJECT_REF = 'limpprtlwtlvfwezkulq' as const;
export const AURAOS_SUPABASE_URL = 'https://limpprtlwtlvfwezkulq.supabase.co' as const;

/**
 * Fail closed if AuraOS is pointed at a database other than its dedicated
 * Supabase project. The project ref appears in either the direct hostname
 * (db.<ref>.supabase.co) or the Supavisor username (postgres.<ref>).
 *
 * The returned URL enforces SSL. For Supavisor shared pooler hosts we also set
 * uselibpqcompat=true because current node-postgres/pg-connection-string treats
 * sslmode=require as verify-full unless libpq compatibility is explicitly
 * requested; Supabase's standard Session Pooler URI expects libpq semantics.
 */
export function normalizeAndAssertAuraDatabaseUrl(rawDatabaseUrl: string): string {
  let url: URL;
  try {
    url = new URL(rawDatabaseUrl);
  } catch {
    throw new Error('AuraOS DATABASE_URL is not a valid PostgreSQL URL');
  }

  if (url.protocol !== 'postgresql:' && url.protocol !== 'postgres:') {
    throw new Error('AuraOS DATABASE_URL must use postgresql:// or postgres://');
  }

  const identity = `${url.hostname} ${decodeURIComponent(url.username)}`;
  if (!identity.includes(AURAOS_SUPABASE_PROJECT_REF)) {
    throw new Error(
      `DATABASE IDENTITY MISMATCH: AuraOS is locked to Supabase project ${AURAOS_SUPABASE_PROJECT_REF}`,
    );
  }

  url.searchParams.set('sslmode', 'require');
  if (url.hostname.endsWith('.pooler.supabase.com')) {
    url.searchParams.set('uselibpqcompat', 'true');
  }

  return url.toString();
}
