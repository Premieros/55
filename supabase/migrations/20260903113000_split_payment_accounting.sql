-- True split tender support for POS sales.
-- Inventory remains owned by _process_sale_core and is therefore deducted once.
-- Split tender rows are private accounting metadata used to reconcile shift and refund postings.

CREATE TABLE IF NOT EXISTS public.sale_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  payment_method text NOT NULL CHECK (payment_method IN ('cash', 'card', 'transfer')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  refunded_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0 AND refunded_amount <= amount),
  created_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sale_payments_sale_id ON public.sale_payments(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_payments_branch_id ON public.sale_payments(branch_id);

ALTER TABLE public.sale_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sale_payments FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.sale_payments TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.process_sale_split(
  p_invoice_number text,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_customer_id uuid,
  p_salesperson_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_discount_type text,
  p_tax_amount numeric,
  p_bonus_amount numeric,
  p_total numeric,
  p_payments jsonb,
  p_status text,
  p_items jsonb,
  p_shift_id uuid DEFAULT NULL,
  p_order_type text DEFAULT 'takeaway',
  p_table_id uuid DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_guest_count integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_payment jsonb;
  v_method text;
  v_amount numeric(14,2);
  v_requested_total numeric(14,2) := 0;
  v_method_count integer := 0;
  v_core jsonb;
  v_sale_id uuid;
  v_sale_total numeric(14,2);
  v_sale_entry uuid;
  v_cash_account uuid;
  v_bank_account uuid;
BEGIN
  BEGIN
    IF auth.uid() IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
    END IF;

    IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) < 2 THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_REQUIRES_MULTIPLE_PAYMENTS');
    END IF;

    FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
    LOOP
      v_method := lower(trim(COALESCE(v_payment->>'payment_method', '')));
      v_amount := round(COALESCE((v_payment->>'amount')::numeric, 0), 2);
      IF v_method NOT IN ('cash', 'card', 'transfer') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYMENT_METHOD', 'payment_method', v_method);
      END IF;
      IF v_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_SPLIT_PAYMENT_AMOUNT', 'payment_method', v_method);
      END IF;
      v_requested_total := v_requested_total + v_amount;
    END LOOP;

    SELECT count(DISTINCT lower(trim(value->>'payment_method')))
      INTO v_method_count
    FROM jsonb_array_elements(p_payments);
    IF v_method_count < 2 THEN
      RETURN jsonb_build_object('success', false, 'error', 'SPLIT_REQUIRES_MULTIPLE_METHODS');
    END IF;

    -- The existing sale core remains the single stock/write boundary.
    -- Use a temporary cash collection, then replace only the collection-side accounting below.
    v_core := public._process_sale_core(
      p_invoice_number,
      p_branch_id,
      p_warehouse_id,
      p_customer_id,
      p_salesperson_id,
      p_subtotal,
      p_discount_amount,
      p_discount_type,
      p_tax_amount,
      p_bonus_amount,
      p_total,
      v_requested_total,
      'cash',
      p_status,
      p_items,
      p_shift_id,
      p_order_type,
      p_table_id,
      p_order_id,
      p_guest_count
    );

    IF COALESCE((v_core->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_core;
    END IF;

    v_sale_id := (v_core->>'sale_id')::uuid;
    SELECT total INTO v_sale_total FROM public.sales WHERE id = v_sale_id FOR UPDATE;

    IF round(COALESCE(v_sale_total, 0), 2) <> round(v_requested_total, 2) THEN
      RAISE EXCEPTION 'SPLIT_PAYMENT_TOTAL_MISMATCH: expected %, got %', v_sale_total, v_requested_total;
    END IF;

    INSERT INTO public.sale_payments(sale_id, branch_id, payment_method, amount, created_by)
    SELECT
      v_sale_id,
      p_branch_id,
      lower(trim(value->>'payment_method')),
      round((value->>'amount')::numeric, 2),
      auth.uid()
    FROM jsonb_array_elements(p_payments);

    UPDATE public.sales
    SET payment_method = 'split', paid_amount = v_sale_total
    WHERE id = v_sale_id;

    -- Replace the one temporary shift collection with one row per tender.
    IF p_shift_id IS NOT NULL THEN
      DELETE FROM public.shift_operations
      WHERE shift_id = p_shift_id
        AND operation_type = 'sale'
        AND reference_type = 'sale'
        AND reference_id = v_sale_id;

      INSERT INTO public.shift_operations(
        shift_id, operation_type, amount, payment_method, reference_type, reference_id, created_by
      )
      SELECT
        p_shift_id,
        'sale',
        round((value->>'amount')::numeric, 2),
        lower(trim(value->>'payment_method')),
        'sale',
        v_sale_id,
        auth.uid()
      FROM jsonb_array_elements(p_payments);
    END IF;

    -- Rewrite only collection debit lines. Revenue/VAT/discount/COGS remain exactly as core posted them.
    SELECT id INTO v_sale_entry
    FROM public.journal_entries
    WHERE branch_id = p_branch_id
      AND reference_type = 'sale'
      AND reference_id = v_sale_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_sale_entry IS NULL THEN
      RAISE EXCEPTION 'SPLIT_SALE_JOURNAL_NOT_FOUND';
    END IF;

    v_cash_account := public.resolve_account_key(p_branch_id, 'cash');
    v_bank_account := public.resolve_account_key(p_branch_id, 'bank');

    DELETE FROM public.journal_entry_lines
    WHERE journal_entry_id = v_sale_entry
      AND account_id IN (v_cash_account, v_bank_account)
      AND debit > 0;

    INSERT INTO public.journal_entry_lines(journal_entry_id, account_id, debit, credit, note)
    SELECT
      v_sale_entry,
      CASE WHEN lower(trim(value->>'payment_method')) = 'cash' THEN v_cash_account ELSE v_bank_account END,
      round((value->>'amount')::numeric, 2),
      0,
      p_invoice_number || ' · ' || lower(trim(value->>'payment_method'))
    FROM jsonb_array_elements(p_payments);

    RETURN v_core || jsonb_build_object(
      'split', true,
      'payment_count', jsonb_array_length(p_payments),
      'paid_amount', v_sale_total
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_split(text,uuid,uuid,uuid,uuid,numeric,numeric,text,numeric,numeric,numeric,jsonb,text,jsonb,uuid,text,uuid,uuid,integer) TO authenticated, service_role;

-- Preserve the exact, already-hardened refund/stock-restoration implementation as an internal core.
ALTER FUNCTION public.process_refund(uuid, jsonb, text) RENAME TO _process_refund_single_core;
REVOKE ALL ON FUNCTION public._process_refund_single_core(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._process_refund_single_core(uuid, jsonb, text) TO service_role, postgres;

CREATE OR REPLACE FUNCTION public.process_refund(
  p_sale_id uuid,
  p_items jsonb DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_has_split boolean := false;
  v_result jsonb;
  v_refund_total numeric(14,2);
  v_sale record;
  v_refund_entry uuid;
  v_cash_account uuid;
  v_bank_account uuid;
  v_remaining_total numeric(14,2);
  v_allocated numeric(14,2) := 0;
  v_left numeric(14,2);
  v_row record;
  v_part numeric(14,2);
  v_last_payment uuid;
  v_shift_id uuid;
BEGIN
  BEGIN
    IF p_sale_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_SALE');
    END IF;

    SELECT EXISTS(SELECT 1 FROM public.sale_payments WHERE sale_id = p_sale_id)
      INTO v_has_split;

    IF NOT v_has_split THEN
      RETURN public._process_refund_single_core(p_sale_id, p_items, p_reason);
    END IF;

    SELECT id, branch_id, invoice_number
      INTO v_sale
    FROM public.sales
    WHERE id = p_sale_id
    FOR UPDATE;
    IF v_sale.id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'SALE_NOT_FOUND');
    END IF;

    -- Run the exact existing refund core first. It owns approval, exact inventory restoration,
    -- sale-item refund state, and the non-collection reversal lines.
    v_result := public._process_refund_single_core(p_sale_id, p_items, p_reason);
    IF COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
      RETURN v_result;
    END IF;

    v_refund_total := round(COALESCE((v_result->>'refunded_amount')::numeric, 0), 2);
    IF v_refund_total <= 0 THEN
      RETURN v_result;
    END IF;

    -- Lock the tender rows before computing their remaining refundable balance.
    PERFORM 1
    FROM public.sale_payments
    WHERE sale_id = p_sale_id
    FOR UPDATE;

    SELECT round(COALESCE(sum(amount - refunded_amount), 0), 2)
      INTO v_remaining_total
    FROM public.sale_payments
    WHERE sale_id = p_sale_id;

    IF v_refund_total > v_remaining_total THEN
      RAISE EXCEPTION 'SPLIT_REFUND_EXCEEDS_REMAINING_TENDERS: refund %, remaining %', v_refund_total, v_remaining_total;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.split_refund_alloc(
      payment_id uuid PRIMARY KEY,
      payment_method text NOT NULL,
      amount numeric(14,2) NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE pg_temp.split_refund_alloc;

    -- Pro-rate the refund across remaining tenders; the final tender absorbs rounding cents.
    SELECT id INTO v_last_payment
    FROM public.sale_payments
    WHERE sale_id = p_sale_id AND amount > refunded_amount
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    FOR v_row IN
      SELECT id, payment_method, amount - refunded_amount AS remaining
      FROM public.sale_payments
      WHERE sale_id = p_sale_id AND amount > refunded_amount
      ORDER BY created_at, id
    LOOP
      IF v_row.id = v_last_payment THEN CONTINUE; END IF;
      v_part := LEAST(
        round(v_refund_total * v_row.remaining / NULLIF(v_remaining_total, 0), 2),
        v_row.remaining,
        v_refund_total - v_allocated
      );
      IF v_part > 0 THEN
        INSERT INTO pg_temp.split_refund_alloc(payment_id, payment_method, amount)
        VALUES (v_row.id, v_row.payment_method, v_part);
        v_allocated := v_allocated + v_part;
      END IF;
    END LOOP;

    v_left := round(v_refund_total - v_allocated, 2);
    IF v_left > 0 THEN
      SELECT id, payment_method, amount - refunded_amount AS remaining
        INTO v_row
      FROM public.sale_payments
      WHERE id = v_last_payment;
      IF v_row.id IS NULL OR v_left > v_row.remaining THEN
        RAISE EXCEPTION 'SPLIT_REFUND_ALLOCATION_FAILED';
      END IF;
      INSERT INTO pg_temp.split_refund_alloc(payment_id, payment_method, amount)
      VALUES (v_row.id, v_row.payment_method, v_left)
      ON CONFLICT (payment_id) DO UPDATE SET amount = pg_temp.split_refund_alloc.amount + EXCLUDED.amount;
    END IF;

    UPDATE public.sale_payments sp
    SET refunded_amount = sp.refunded_amount + a.amount
    FROM pg_temp.split_refund_alloc a
    WHERE sp.id = a.payment_id;

    -- Replace the core's single refund drawer row with exact tender rows.
    SELECT id INTO v_shift_id
    FROM public.shifts
    WHERE cashier_id = auth.uid() AND branch_id = v_sale.branch_id AND status = 'open'
    ORDER BY opened_at DESC LIMIT 1;

    IF v_shift_id IS NOT NULL THEN
      DELETE FROM public.shift_operations
      WHERE shift_id = v_shift_id
        AND operation_type = 'refund'
        AND reference_type = 'refund'
        AND reference_id = p_sale_id;

      INSERT INTO public.shift_operations(
        shift_id, operation_type, amount, payment_method, reference_type, reference_id, created_by
      )
      SELECT v_shift_id, 'refund', amount, payment_method, 'refund', p_sale_id, auth.uid()
      FROM pg_temp.split_refund_alloc;
    END IF;

    -- The core created a balanced reversal with a single collection credit.
    -- Replace only cash/bank collection credits with the split tender allocation.
    SELECT id INTO v_refund_entry
    FROM public.journal_entries
    WHERE branch_id = v_sale.branch_id
      AND reference_type = 'refund'
      AND reference_number = v_sale.invoice_number
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    IF v_refund_entry IS NULL THEN
      RAISE EXCEPTION 'SPLIT_REFUND_JOURNAL_NOT_FOUND';
    END IF;

    v_cash_account := public.resolve_account_key(v_sale.branch_id, 'cash');
    v_bank_account := public.resolve_account_key(v_sale.branch_id, 'bank');

    DELETE FROM public.journal_entry_lines
    WHERE journal_entry_id = v_refund_entry
      AND account_id IN (v_cash_account, v_bank_account)
      AND credit > 0;

    INSERT INTO public.journal_entry_lines(journal_entry_id, account_id, debit, credit, note)
    SELECT
      v_refund_entry,
      CASE WHEN payment_method = 'cash' THEN v_cash_account ELSE v_bank_account END,
      0,
      amount,
      'مرتجع ' || v_sale.invoice_number || ' · ' || payment_method
    FROM pg_temp.split_refund_alloc;

    RETURN v_result || jsonb_build_object('split_refund', true);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_FAILED', 'detail', SQLERRM);
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.process_refund(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_refund(uuid, jsonb, text) TO authenticated, service_role;
