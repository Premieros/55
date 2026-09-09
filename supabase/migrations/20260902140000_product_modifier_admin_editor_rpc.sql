-- Secure administration read surface for product modifiers.
-- The POS catalog continues to use get_product_modifiers(), which never exposes
-- inventory effects. This RPC is intentionally restricted to privileged roles
-- and returns the editable configuration only for products in accessible branches.

CREATE OR REPLACE FUNCTION public.get_product_modifiers_admin(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_role text;
  v_groups jsonb;
BEGIN
  SELECT branch_id INTO v_branch_id
  FROM public.products
  WHERE id = p_product_id;

  IF v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR NOT public.user_may_access_branch(v_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT COALESCE(jsonb_agg(group_json ORDER BY sort_order, id), '[]'::jsonb)
  INTO v_groups
  FROM (
    SELECT
      g.id,
      g.sort_order,
      jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'name_en', g.name_en,
        'min_selections', g.min_selections,
        'max_selections', g.max_selections,
        'sort_order', g.sort_order,
        'options', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', o.id,
              'name', o.name,
              'name_en', o.name_en,
              'price_delta', o.price_delta,
              'is_default', o.is_default,
              'sort_order', o.sort_order,
              'inventory_effects', COALESCE((
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'target_type', e.target_type,
                    'target_id', CASE
                      WHEN e.target_type = 'raw_material' THEN e.raw_material_id
                      ELSE e.inventory_unit_id
                    END,
                    'quantity_delta', e.quantity_delta
                  ) ORDER BY e.id
                )
                FROM public.product_modifier_inventory_effects e
                WHERE e.option_id = o.id
              ), '[]'::jsonb)
            ) ORDER BY o.sort_order, o.id
          )
          FROM public.product_modifier_options o
          WHERE o.group_id = g.id AND o.is_active = true
        ), '[]'::jsonb)
      ) AS group_json
    FROM public.product_modifier_groups g
    WHERE g.product_id = p_product_id
      AND g.branch_id = v_branch_id
      AND g.is_active = true
  ) q;

  RETURN jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'branch_id', v_branch_id,
    'groups', v_groups
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_product_modifiers_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_modifiers_admin(uuid) TO authenticated, service_role;
