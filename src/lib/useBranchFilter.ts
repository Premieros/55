import { useEffect } from 'react';
import { useAuth } from '../context/AuthContext';
import { isAdminRole } from './permissions';
import { useActiveBranchId } from './activeBranch';
import { useBranches } from '@/hooks/useBranches';

/**
 * Uses the shared selected branch when it is one of the branches visible
 * through RLS/user_branch_access. Other users fall back to their primary
 * branch; Super Admin may keep the all-branches (null) context.
 */
export function useBranchFilter(): string | null {
  const { user } = useAuth();
  const [activeBranchId, setActiveBranchId] = useActiveBranchId();
  const { branches, loading } = useBranches();
  const activeIsAccessible = !!activeBranchId && branches.some((branch) => branch.id === activeBranchId);

  useEffect(() => {
    if (!loading && activeBranchId && !activeIsAccessible) setActiveBranchId(null);
  }, [activeBranchId, activeIsAccessible, loading, setActiveBranchId]);

  if (!user) return null;
  if (activeIsAccessible) return activeBranchId;
  if (isAdminRole(user.role)) return null;
  return user.branch_id || null;
}
