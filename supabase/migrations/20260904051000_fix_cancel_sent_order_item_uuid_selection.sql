-- PostgreSQL does not provide min(uuid). Resolve the single matching sent line
-- explicitly after counting candidates so the compatibility wrapper stays
-- deterministic without changing the exact-item void path.
CREATE OR REPLACE FUNCTION public.cancel_sent_order_item(
  p_order_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
DECLARE
  v_item_id uuid;
  v_count integer;
BEGIN
  SELECT count(*)
  INTO v_count
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    );

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'SENT_ITEM_NOT_FOUND');
  END IF;

  IF v_count > 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'AMBIGUOUS_SENT_ITEM',
      'detail', 'Use cancel_sent_order_item_exact with order_item_id',
      'matching_lines', v_count
    );
  END IF;

  SELECT oi.id
  INTO v_item_id
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.product_id = p_product_id
    AND EXISTS (
      SELECT 1
      FROM public.order_kitchen_sends s
      WHERE s.order_item_id = oi.id
    )
  ORDER BY oi.id
  LIMIT 1;

  RETURN public.cancel_sent_order_item_exact(
    p_order_id,
    v_item_id,
    p_quantity,
    p_reason
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_sent_order_item(uuid,uuid,numeric,text) TO authenticated, service_role;
