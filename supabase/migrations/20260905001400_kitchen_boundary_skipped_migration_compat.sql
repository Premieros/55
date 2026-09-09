-- Production skipped 20260904050000_kitchen_send_inventory_boundary.sql while
-- later migrations rewrote cancel_sent_order_item_exact in a compact format.
-- The skipped boundary migration patches that function by exact source pattern.
-- This compatibility migration is a semantic no-op: on a fresh database it
-- runs after the boundary and does nothing; during the production repair it can
-- be applied immediately before the skipped boundary so the authoritative patch
-- can match the current function without replacing newer approval behavior.

DO $compat$
DECLARE
  v_oid regprocedure := to_regprocedure('public.cancel_sent_order_item_exact(uuid,uuid,numeric,text)');
  v_def text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'EXACT_SENT_VOID_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  v_new := v_def;

  -- Current production compact declaration -> canonical boundary patch shape.
  v_new := replace(
    v_new,
    'v_note text; v_privileged boolean:=false;',
    E'v_note text;\n  v_privileged boolean := false;'
  );

  -- Current production compact guard -> canonical boundary patch shape.
  v_new := replace(
    v_new,
    'PERFORM set_config(''app.approved_sent_item_void'',''1'',true);',
    E'  PERFORM set_config(''app.approved_sent_item_void'', ''1'', true);'
  );

  IF v_new IS DISTINCT FROM v_def THEN
    EXECUTE v_new;
  END IF;
END;
$compat$;
