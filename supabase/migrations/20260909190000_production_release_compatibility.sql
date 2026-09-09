-- Production compatibility closure for the 2026-09-09 release candidate.
-- Safe on the fresh canonical schema and on the current scpovyrqmsbiduanykod production schema.
-- Keeps Super Admin as the only implicit bypass; all other authorization is permission-first + branch access.

-- 1) Cloud print queue may be absent on the current Production schema.
CREATE TABLE IF NOT EXISTS public.print_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  job_type text NOT NULL CHECK (job_type IN ('kitchen_ticket', 'receipt', 'drawer_kick', 'custom')),
  station_code text NOT NULL DEFAULT 'main',
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  sale_id uuid REFERENCES public.sales(id) ON DELETE SET NULL,
  title text,
  ticket_text text,
  ticket_html text,
  metadata jsonb DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  target_printer text,
  terminal_id text,
  printed_at timestamptz,
  error_message text,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_print_jobs_branch_status
  ON public.print_jobs(branch_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_print_jobs_order_id
  ON public.print_jobs(order_id);

ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view print jobs in their branch" ON public.print_jobs;
DROP POLICY IF EXISTS "Users can insert print jobs in their branch" ON public.print_jobs;
DROP POLICY IF EXISTS "Users can update print jobs in their branch" ON public.print_jobs;

CREATE POLICY "Users can view print jobs in their branch"
ON public.print_jobs FOR SELECT TO authenticated
USING (public.user_may_access_branch(branch_id));

CREATE POLICY "Users can insert print jobs in their branch"
ON public.print_jobs FOR INSERT TO authenticated
WITH CHECK (public.user_may_access_branch(branch_id));

CREATE POLICY "Users can update print jobs in their branch"
ON public.print_jobs FOR UPDATE TO authenticated
USING (public.user_may_access_branch(branch_id))
WITH CHECK (public.user_may_access_branch(branch_id));

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'print_jobs'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.print_jobs;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.enqueue_print_job(
  p_branch_id uuid,
  p_job_type text,
  p_station_code text,
  p_ticket_text text,
  p_ticket_html text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_sale_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_job_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_ACCESS_DENIED');
  END IF;

  INSERT INTO public.print_jobs (
    branch_id, job_type, station_code, ticket_text, ticket_html, title,
    order_id, sale_id, metadata, status, created_by
  ) VALUES (
    p_branch_id, p_job_type, COALESCE(p_station_code, 'main'), p_ticket_text,
    p_ticket_html, p_title, p_order_id, p_sale_id,
    COALESCE(p_metadata, '{}'::jsonb), 'pending', auth.uid()
  ) RETURNING id INTO v_job_id;

  RETURN jsonb_build_object('success', true, 'job_id', v_job_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.enqueue_print_job(uuid,text,text,text,text,text,uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enqueue_print_job(uuid,text,text,text,text,text,uuid,uuid,jsonb)
  TO authenticated, service_role;

-- 2) Production process_purchase still contains legacy role-name authorization.
-- Patch only the known stale blocks; if the function is already canonical this is a no-op.
DO $rewrite$
DECLARE
  v_sig regprocedure := 'public.process_purchase(text,uuid,uuid,uuid,numeric,numeric,numeric,numeric,numeric,text,text,text,jsonb)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  IF position('get_user_role()' in v_def) > 0 OR position('is_platform_admin()' in v_def) > 0 THEN
    v_old := $old$IF NOT (
       public.is_pos_admin()
       OR public.is_platform_admin()
       OR public.can_permission('purchases.manage')
       OR public.get_user_role() IN ('super_admin', 'owner', 'admin', 'branch_manager', 'warehouse_manager', 'accountant', 'production_manager')
     ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED', 'detail', 'صلاحية إدارة المشتريات مطلوبة لتسجيل فواتير الشراء');
  END IF;$old$;
    v_new := $new$IF NOT public.is_pos_admin() AND NOT public.can_permission('purchases.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED', 'detail', 'صلاحية إدارة المشتريات مطلوبة لتسجيل فواتير الشراء');
  END IF;$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_purchase production permission gate drifted; refusing unsafe rewrite';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();' in v_def) > 0 THEN
    v_old := $old$IF NOT public.is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND p_branch_id IS NOT NULL AND v_user_branch <> p_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH', 'detail', 'المستخدم غير مخصص لهذا الفرع');
    END IF;
  END IF;$old$;
    v_new := $new$IF NOT public.is_pos_admin() AND NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH', 'detail', 'المستخدم غير مخول لهذا الفرع');
  END IF;$new$;

    IF position(v_old in v_def) = 0 THEN
      RAISE EXCEPTION 'process_purchase production branch gate drifted; refusing unsafe rewrite';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  EXECUTE v_def;
END
$rewrite$;
