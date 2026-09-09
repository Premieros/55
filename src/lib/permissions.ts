import { useCallback } from 'react';
import { useAuth } from '../context/AuthContext';
import { useRoles } from '../context/RolesContext';
import { type Permission } from './permissionDefs';

export * from './permissionDefs';

/**
 * Memoized permission checker for the current user.
 * Super Admin is the only implicit platform-wide bypass. Every other role,
 * including owner, resolves permissions from the DB-backed role matrix.
 */
export function useCan(): (permission: Permission) => boolean {
  const { user } = useAuth();
  const { rolePermissionsMap } = useRoles();
  return useCallback(
    (permission: Permission) => {
      const role = user?.role;
      if (!role) return false;
      if (role === 'super_admin') return true;
      return (rolePermissionsMap[role] ?? []).includes(permission);
    },
    [user?.role, rolePermissionsMap]
  );
}
