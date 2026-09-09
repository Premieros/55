import type { ApiResult } from '../types';
import type { RpcResult } from '@/lib/types';
import { rpc } from '../rpc';
import { supabase } from '../client';

/**
 * Shift mutations are intentionally server-authoritative.
 * Do not add direct table-write fallbacks here: open/close/force-close actions
 * must always pass the database permission, branch and approval checks.
 */
export const shifts = {
  open(p: { p_branch_id: string; p_opening_amount: number; p_notes: string | null }): ApiResult<RpcResult & { shift_id?: string }> {
    return rpc<RpcResult & { shift_id?: string }>('open_shift', p);
  },

  async close(p: { p_shift_id: string; p_actual_amount: number; p_notes: string | null }): ApiResult<RpcResult> {
    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (user?.id) {
        const { data: shift } = await supabase
          .from('shifts')
          .select('id, cashier_id, status')
          .eq('id', p.p_shift_id)
          .maybeSingle();

        if (shift && shift.cashier_id && shift.cashier_id !== user.id) {
          const { data: userProfile } = await supabase
            .from('users')
            .select('role')
            .eq('id', user.id)
            .maybeSingle();

          const isElevated = userProfile?.role === 'super_admin' || userProfile?.role === 'owner';
          if (!isElevated) {
            return {
              data: {
                success: false,
                error: 'OPENER_ONLY',
                detail: 'عذراً، فقط المستخدم الذي قام بفتح الوردية هو المخول بإغلاقها.',
              },
              error: null,
            };
          }
        }
      }
    } catch {
      // Fallback directly to server rpc
    }

    return rpc<RpcResult>('close_shift', p);
  },

  forceClose(p: { p_shift_id: string; p_actual_amount: number | null; p_reason: string | null }): ApiResult<RpcResult> {
    return rpc<RpcResult>('force_close_shift', p);
  },

  authorizeOpenDrawer(p: { p_shift_id: string; p_reason: string | null }): ApiResult<RpcResult & { authorized?: boolean; hardware_action_required?: boolean }> {
    return rpc<RpcResult & { authorized?: boolean; hardware_action_required?: boolean }>('authorize_open_drawer', p);
  },
};

