import { createClient } from '@supabase/supabase-js';

const rawUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
const rawKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();

function resolveSupabaseUrl(url?: string): string {
  if (!url) return 'https://scpovyrqmsbiduanykod.supabase.co';
  if (url.startsWith('postgres://') || url.startsWith('postgresql://')) {
    const match = url.match(/@db\.([a-z0-9]+)\.supabase\.co/i);
    if (match?.[1]) return `https://${match[1]}.supabase.co`;
    return 'https://scpovyrqmsbiduanykod.supabase.co';
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return `https://${url}`;
  }
  return url;
}

function resolveSupabaseAnonKey(key?: string): string {
  const DEFAULT_KEY = 'sb_publishable_r1Qbehu-uzsQo-8vOr77OQ_Tzj6K_Jm';
  if (!key) return DEFAULT_KEY;
  // If the user accidentally set the database connection string instead of the API key
  if (key.startsWith('postgres://') || key.startsWith('postgresql://')) {
    return DEFAULT_KEY;
  }
  return key;
}

const supabaseUrl = resolveSupabaseUrl(rawUrl);
const supabaseAnonKey = resolveSupabaseAnonKey(rawKey);

if (!supabaseUrl) {
  throw new Error('Supabase URL is missing. Please set VITE_SUPABASE_URL.');
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey || 'placeholder-anon-key-for-build', {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});

