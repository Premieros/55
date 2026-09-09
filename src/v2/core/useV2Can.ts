import { useCallback } from 'react';
import { ALL_PERMISSIONS, type Permission, useCan } from '@/lib/permissions';

/**
 * Compatibility adapter for dynamic permission strings returned by RPCs.
 *
 * There is no second V2 authorization model: known strings are validated
 * against the canonical Permission registry, then delegated to useCan().
 * Unknown/deprecated permission names are denied rather than silently revived.
 */
export function useV2Can(): (permission: string) => boolean {
  const can = useCan();

  return useCallback((permission: string) => {
    if (!ALL_PERMISSIONS.includes(permission as Permission)) return false;
    return can(permission as Permission);
  }, [can]);
}
