-- ==============================================================================
-- Cloud Realtime Print Queue for POS: Cross-Device Silent Printing
-- Allows mobile phones to send print jobs (kitchen tickets & cashier receipts)
-- which are picked up and printed silently by the Windows terminal in the branch.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.print_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  job_type text NOT NULL CHECK (job_type IN ('kitchen_ticket', 'receipt', 'drawer_kick', 'custom')),
  station_code text NOT NULL DEFAULT 'main', -- 'main', 'drinks', 'grill', 'dessert', 'cashier', etc.
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

CREATE INDEX IF NOT EXISTS idx_print_jobs_branch_status ON public.print_jobs(branch_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_print_jobs_order_id ON public.print_jobs(order_id);

-- Enable RLS
ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users of the same branch to select print jobs
DROP POLICY IF EXISTS "Users can view print jobs in their branch" ON public.print_jobs;
CREATE POLICY "Users can view print jobs in their branch"
ON public.print_jobs FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND (
        u.role IN ('super_admin', 'owner', 'admin')
        OR u.branch_id = print_jobs.branch_id
      )
  )
);

-- Allow authenticated users to insert print jobs for their branch
DROP POLICY IF EXISTS "Users can insert print jobs in their branch" ON public.print_jobs;
CREATE POLICY "Users can insert print jobs in their branch"
ON public.print_jobs FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND (
        u.role IN ('super_admin', 'owner', 'admin')
        OR u.branch_id = print_jobs.branch_id
      )
  )
);

-- Allow updating print jobs (status transition to completed/failed)
DROP POLICY IF EXISTS "Users can update print jobs in their branch" ON public.print_jobs;
CREATE POLICY "Users can update print jobs in their branch"
ON public.print_jobs FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND (
        u.role IN ('super_admin', 'owner', 'admin')
        OR u.branch_id = print_jobs.branch_id
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = auth.uid()
      AND u.is_active = true
      AND (
        u.role IN ('super_admin', 'owner', 'admin')
        OR u.branch_id = print_jobs.branch_id
      )
  )
);

-- Realtime publication registration
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables 
      WHERE pubname = 'supabase_realtime' 
        AND schemaname = 'public' 
        AND tablename = 'print_jobs'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.print_jobs;
    END IF;
  END IF;
END $$;

-- RPC helper function for atomic enqueueing
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
  INSERT INTO public.print_jobs (
    branch_id,
    job_type,
    station_code,
    ticket_text,
    ticket_html,
    title,
    order_id,
    sale_id,
    metadata,
    status,
    created_by
  ) VALUES (
    p_branch_id,
    p_job_type,
    COALESCE(p_station_code, 'main'),
    p_ticket_text,
    p_ticket_html,
    p_title,
    p_order_id,
    p_sale_id,
    COALESCE(p_metadata, '{}'::jsonb),
    'pending',
    auth.uid()
  )
  RETURNING id INTO v_job_id;

  RETURN jsonb_build_object(
    'success', true,
    'job_id', v_job_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.enqueue_print_job(uuid, text, text, text, text, text, uuid, uuid, jsonb) TO authenticated, service_role;
