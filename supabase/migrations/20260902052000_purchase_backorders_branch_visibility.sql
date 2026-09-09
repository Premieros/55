-- P3 branch visibility: expose the purchase branch on backorder rows so the UI
-- can make branch scope explicit. Preserve server-side branch isolation and
-- harden SECURITY DEFINER search_path while replacing the table return type.

DROP FUNCTION IF EXISTS public.get_purchase_backorders(uuid);

CREATE FUNCTION public.get_purchase_backorders(
  p_branch_id uuid DEFAULT NULL
) RETURNS TABLE(
  purchase_id uuid,
  branch_id uuid,
  invoice_number text,
  supplier_id uuid,
  supplier_name text,
  purchase_item_id uuid,
  product_id uuid,
  raw_material_id uuid,
  item_name text,
  item_type text,
  unit_name text,
  ordered_quantity numeric,
  received_quantity numeric,
  remaining numeric,
  unit_cost numeric,
  status text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $function$
BEGIN
  IF p_branch_id IS NOT NULL
     AND NOT is_pos_admin()
     AND get_branch_id() IS NOT NULL
     AND get_branch_id() <> p_branch_id THEN
    RAISE EXCEPTION 'BRANCH_MISMATCH';
  END IF;

  RETURN QUERY
    SELECT
      pc.id,
      pc.branch_id,
      pc.invoice_number,
      pc.supplier_id,
      s.name,
      pi.id,
      pi.product_id,
      pi.raw_material_id,
      COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(rm.name), ''), '?'),
      CASE WHEN pi.product_id IS NOT NULL THEN 'product' ELSE 'raw_material' END,
      pi.unit_name,
      pi.quantity,
      COALESCE(pi.received_quantity, 0),
      pi.quantity - COALESCE(pi.received_quantity, 0),
      pi.unit_cost,
      pc.status
    FROM public.purchase_items pi
    JOIN public.purchases pc ON pc.id = pi.purchase_id
    JOIN public.suppliers s ON s.id = pc.supplier_id
    LEFT JOIN public.products p ON p.id = pi.product_id
    LEFT JOIN public.raw_materials rm ON rm.id = pi.raw_material_id
    WHERE pc.status IN ('approved', 'submitted', 'partial')
      AND pi.quantity - COALESCE(pi.received_quantity, 0) > 0
      AND (p_branch_id IS NULL OR pc.branch_id = p_branch_id)
      AND (is_pos_admin() OR pc.branch_id = get_branch_id())
    ORDER BY pc.created_at ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_purchase_backorders(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_backorders(uuid) TO authenticated, service_role;
