-- Modifier option ids are persisted on open/held order items and are resolved
-- again at sale completion. Prevent catalogue edits from deleting or moving an
-- option that is still referenced by an editable order, otherwise a valid
-- open order could become unsellable or resolve to a different configuration.

CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_reference()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.status IN ('open', 'held')
      AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
  ) THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_modifier_option_open_order_delete ON public.product_modifier_options;
CREATE TRIGGER trg_protect_modifier_option_open_order_delete
BEFORE DELETE ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._protect_modifier_option_open_order_reference();

-- Moving an option to another group or branch changes its meaning just as much
-- as deleting it, so protect identity-changing updates as well.
CREATE OR REPLACE FUNCTION public._protect_modifier_option_open_order_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (NEW.group_id, NEW.branch_id) IS DISTINCT FROM (OLD.group_id, OLD.branch_id)
     AND EXISTS (
       SELECT 1
       FROM public.order_items oi
       JOIN public.orders o ON o.id = oi.order_id
       WHERE o.status IN ('open', 'held')
         AND OLD.id = ANY(COALESCE(oi.modifier_option_ids, ARRAY[]::uuid[]))
     )
  THEN
    RAISE EXCEPTION 'MODIFIER_OPTION_IN_OPEN_ORDER';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_modifier_option_open_order_update ON public.product_modifier_options;
CREATE TRIGGER trg_protect_modifier_option_open_order_update
BEFORE UPDATE OF group_id, branch_id ON public.product_modifier_options
FOR EACH ROW EXECUTE FUNCTION public._protect_modifier_option_open_order_update();

REVOKE ALL ON FUNCTION public._protect_modifier_option_open_order_reference() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._protect_modifier_option_open_order_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._protect_modifier_option_open_order_reference() TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public._protect_modifier_option_open_order_update() TO service_role, postgres;
