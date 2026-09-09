import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useAuth } from '@/context/AuthContext';
import { useBranches } from '@/hooks/useBranches';
import { getActiveBranchId, setActiveBranchId } from '@/lib/activeBranch';
import type { Branch } from '@/lib/types';

type V2BranchContextValue = {
  branches: Branch[];
  selectedBranchId: string | null;
  selectedBranch: Branch | null;
  setSelectedBranchId: (branchId: string) => void;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
};

const V2BranchContext = createContext<V2BranchContextValue | null>(null);

function storageKey(userId: string): string {
  return `premier:v2:selected-branch:${userId}`;
}

export function V2BranchProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const { branches, loading, error, refresh } = useBranches();
  const [selectedBranchId, setSelectedBranchIdState] = useState<string | null>(null);

  useEffect(() => {
    if (!user?.id) {
      setSelectedBranchIdState(null);
      return;
    }
    if (branches.length === 0) {
      setSelectedBranchIdState(null);
      return;
    }

    const allowedIds = new Set(branches.map((branch) => branch.id));
    const active = getActiveBranchId();
    const saved = typeof window !== 'undefined' ? window.localStorage.getItem(storageKey(user.id)) : null;
    const fallback = user.branch_id && allowedIds.has(user.branch_id) ? user.branch_id : branches[0].id;
    const next = active && allowedIds.has(active)
      ? active
      : saved && allowedIds.has(saved)
        ? saved
        : fallback;

    setSelectedBranchIdState(next);
    setActiveBranchId(next);
    if (typeof window !== 'undefined') window.localStorage.setItem(storageKey(user.id), next);
  }, [branches, user?.id, user?.branch_id]);

  const setSelectedBranchId = useCallback((branchId: string) => {
    if (!user?.id) return;
    if (!branches.some((branch) => branch.id === branchId)) return;
    setSelectedBranchIdState(branchId);
    setActiveBranchId(branchId);
    if (typeof window !== 'undefined') window.localStorage.setItem(storageKey(user.id), branchId);
  }, [branches, user?.id]);

  const selectedBranch = useMemo(
    () => branches.find((branch) => branch.id === selectedBranchId) ?? null,
    [branches, selectedBranchId],
  );

  const value = useMemo<V2BranchContextValue>(() => ({
    branches,
    selectedBranchId,
    selectedBranch,
    setSelectedBranchId,
    loading,
    error,
    refresh,
  }), [branches, selectedBranchId, selectedBranch, setSelectedBranchId, loading, error, refresh]);

  return <V2BranchContext.Provider value={value}>{children}</V2BranchContext.Provider>;
}

export function useV2Branch(): V2BranchContextValue {
  const value = useContext(V2BranchContext);
  if (!value) throw new Error('useV2Branch must be used inside V2BranchProvider');
  return value;
}
