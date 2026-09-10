export const AURAOS_SUPABASE_PROJECT_REF = 'limpprtlwtlvfwezkulq' as const;
export const AURAOS_SUPABASE_URL = 'https://limpprtlwtlvfwezkulq.supabase.co' as const;

/**
 * Fail closed if AuraOS is pointed at a database other than its dedicated
 * Supabase project. The project ref appears in either the direct hostname
 * (db.<ref>.supabase.co) or the Supavisor username (postgres.<ref>).
 *
 * The returned URL also enforces sslmode=require without ever logging or
 * persisting the password.
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

  if (!url.searchParams.has('sslmode')) {
    url.searchParams.set('sslmode', 'require');
  }

  return url.toString();
}
