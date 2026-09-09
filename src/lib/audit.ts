import { supabase } from './supabase';

export type AuditSystemModule =
  | 'pos'
  | 'inventory'
  | 'shifts'
  | 'products'
  | 'approvals'
  | 'users'
  | 'accounting'
  | 'settings'
  | 'general';

export interface LogAuditOptions {
  branchId?: string | null;
  module?: AuditSystemModule;
  userEmail?: string | null;
  userId?: string | null;
}

/**
 * Global audit logging helper that associates events with the active branch,
 * system module, and authenticated actor. Safe against throwing unhandled errors.
 */
export async function logAudit(
  action: string,
  entity: string,
  entityId?: string,
  details?: Record<string, unknown>,
  optionsOrBranchId?: string | LogAuditOptions
): Promise<void> {
  try {
    const { data: { user } } = await supabase.auth.getUser();
    let branchId: string | null = null;
    let moduleTag: AuditSystemModule | undefined;

    if (typeof optionsOrBranchId === 'string') {
      branchId = optionsOrBranchId;
    } else if (optionsOrBranchId && typeof optionsOrBranchId === 'object') {
      branchId = optionsOrBranchId.branchId || null;
      moduleTag = optionsOrBranchId.module;
    }

    // Auto-detect branch if not explicitly provided
    if (!branchId) {
      try {
        branchId =
          localStorage.getItem('pos_active_branch_id') ||
          localStorage.getItem('pos_branch_id') ||
          localStorage.getItem('active_branch_id') ||
          null;
      } catch {
        // storage fallback
      }
      if (!branchId && user?.id) {
        const { data: profile } = await supabase
          .from('users')
          .select('branch_id')
          .eq('id', user.id)
          .maybeSingle();
        branchId = profile?.branch_id || null;
      }
    }

    const payloadDetails: Record<string, unknown> = {
      ...(details || {}),
    };
    if (moduleTag) {
      payloadDetails._module = moduleTag;
    }

    await supabase.from('audit_log').insert({
      user_id: user?.id || null,
      user_email: user?.email || null,
      action,
      entity,
      entity_id: entityId || null,
      details: payloadDetails,
      branch_id: branchId || null,
    });
  } catch {
    // audit logging should never block the operation
  }
}

// Module-specific audit log helpers for explicit categorization
export const logPosAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'pos' });

export const logInventoryAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'inventory' });

export const logShiftAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'shifts' });

export const logProductAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'products' });

export const logApprovalAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'approvals' });

export const logUserAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'users' });

export const logAccountingAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'accounting' });

export const logSettingsAudit = (action: string, entity: string, entityId?: string, details?: Record<string, unknown>, branchId?: string) =>
  logAudit(action, entity, entityId, details, { branchId, module: 'settings' });

