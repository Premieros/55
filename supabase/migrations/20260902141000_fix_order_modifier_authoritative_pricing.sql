-- Fix trigger ordering regression between the P2 base-price trigger and the
-- modifier-price trigger. PostgreSQL executes same-timing triggers by name, so
-- trg_order_items_authoritative_price could overwrite the modifier-aware price
-- back to the base product price. Consolidate pricing into one authoritative
-- trigger and remove the redundant modifier trigger.

CREATE OR REPLACE FUNCTION public._reprice_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_branch_id uuid;
  v_base_price numeric(14,2);
  v_mod jsonb;
BEGIN
  SELECT o.branch_id INTO v_branch_id
  FROM public.orders o
  WHERE o.id = NEW.order_id;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT p.sale_price INTO v_base_price
  FROM public.products p
  WHERE p.id = NEW.product_id
    AND p.branch_id = v_branch_id
    AND p.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_IN_BRANCH';
  END IF;
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  v_mod := public.resolve_product_modifiers(
    NEW.product_id,
    v_branch_id,
    to_jsonb(COALESCE(NEW.modifier_option_ids, '{}'::uuid[]))
  );
  IF COALESCE((v_mod->>'success')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'MODIFIER_VALIDATION_FAILED: %', COALESCE(v_mod->>'error', 'unknown');
  END IF;

  NEW.modifiers_snapshot := COALESCE(v_mod->'snapshot', '[]'::jsonb);
  NEW.unit_price := ROUND(
    GREATEST(COALESCE(v_base_price, 0) + COALESCE((v_mod->>'price_delta')::numeric, 0), 0),
    2
  );
  NEW.discount_amount := ROUND(
    LEAST(GREATEST(COALESCE(NEW.discount_amount, 0), 0), NEW.quantity * NEW.unit_price),
    2
  );
  NEW.bonus_quantity := GREATEST(COALESCE(NEW.bonus_quantity, 0), 0);
  NEW.total := ROUND(NEW.quantity * NEW.unit_price - NEW.discount_amount, 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_item_modifier_price ON public.order_items;
DROP TRIGGER IF EXISTS trg_order_items_authoritative_price ON public.order_items;
CREATE TRIGGER trg_order_items_authoritative_price
BEFORE INSERT OR UPDATE OF product_id, quantity, unit_price, discount_amount, bonus_quantity, total, modifier_option_ids
ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public._reprice_order_item();

REVOKE ALL ON FUNCTION public._reprice_order_item() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._reprice_order_item() TO service_role, postgres;

NOTIFY pgrst, 'reload schema';
