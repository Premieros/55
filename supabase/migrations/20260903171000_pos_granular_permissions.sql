-- Granular POS permissions and server-side enforcement.
-- UI visibility is not a security boundary; these triggers protect the
-- authoritative mutation tables even when SECURITY DEFINER RPCs are called
-- directly.

CREATE OR REPLACE FUNCTION public._append_role_permission(p_permissions jsonb, p_permission text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN COALESCE(p_permissions, '[]'::jsonb) ? p_permission THEN COALESCE(p_permissions, '[]'::jsonb)
    ELSE COALESCE(p_permissions, '[]'::jsonb) || jsonb_build_array(p_permission)
  END;
$$;

UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(
                public._append_role_permission(
                  public._append_role_permission(
                    public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
                    'pos.send_kitchen'),
                  'pos.kds_view'),
                'pos.print_kitchen'),
              'pos.pay'),
            'pos.void'),
          'pos.cancel_order'),
        'pos.refund'),
      'pos.transfer_order'),
    'pos.split_order'),
  'pos.change_branch')
WHERE role IN ('super_admin', 'owner');

UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(
                public._append_role_permission(
                  public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
                  'pos.send_kitchen'),
                'pos.kds_view'),
              'pos.print_kitchen'),
            'pos.pay'),
          'pos.void'),
        'pos.cancel_order'),
      'pos.refund'),
    'pos.transfer_order'),
  'pos.split_order')
WHERE role = 'branch_manager';

-- Cashier baseline preserves the existing manager-approval workflows:
-- split/transfer/sent-item void may be initiated, but their authoritative RPCs
-- still require manager approval. Direct manager authority stays absent.
UPDATE public.roles
SET permissions = public._append_role_permission(
  public._append_role_permission(
    public._append_role_permission(
      public._append_role_permission(
        public._append_role_permission(
          public._append_role_permission(
            public._append_role_permission(
              public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.hold'),
              'pos.send_kitchen'),
            'pos.kds_view'),
          'pos.print_kitchen'),
        'pos.pay'),
      'pos.void'),
    'pos.transfer_order'),
  'pos.split_order')
WHERE role = 'cashier';

-- Remove legacy direct-authority permissions from cashier so discount, price
-- override and receipt reprint use their manager-approval paths by default.
UPDATE public.roles
SET permissions = COALESCE(permissions, '[]'::jsonb)
  - 'pos.discount'
  - 'pos.change_price'
  - 'pos.reprint'
  - 'pos.cancel_order'
  - 'pos.refund'
  - 'pos.change_branch'
WHERE role = 'cashier';

-- Kitchen staff need KDS visibility without POS selling rights.
UPDATE public.roles
SET permissions = public._append_role_permission(COALESCE(permissions, '[]'::jsonb), 'pos.kds_view')
WHERE role = 'kitchen';

DROP FUNCTION public._append_role_permission(jsonb, text);

CREATE OR REPLACE FUNCTION public.enforce_pos_permission_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'sales' THEN
    IF TG_OP = 'INSERT' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_kitchen_sends' THEN
    IF NOT public.can_permission('pos.send_kitchen') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.send_kitchen';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      END IF;
      RETURN OLD;
    END IF;

    -- Kitchen workers may update ONLY kitchen workflow fields. Comparing the
    -- remaining row as jsonb prevents smuggling sale/order changes through the
    -- KDS exception.
    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'cancelled' AND NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      ELSIF NEW.status = 'completed' AND (NOT public.can_permission('pos.sell') OR NOT public.can_permission('pos.pay')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.pay';
      ELSIF NEW.status IN ('open', 'held') AND NOT public.can_permission('pos.hold') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.hold';
      END IF;
    END IF;

    IF NEW.table_id IS DISTINCT FROM OLD.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT public.can_permission('pos.transfer_order') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.transfer_order';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.table_id IS NOT DISTINCT FROM OLD.table_id
       AND NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.sell') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.void') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.void';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      IF NOT public.can_permission('pos.split_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.split_order';
      END IF;
    ELSIF NOT public.can_permission('pos.sell') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.sell';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pos_permission_orders ON public.orders;
CREATE TRIGGER trg_pos_permission_orders
BEFORE INSERT OR UPDATE OR DELETE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_order_items ON public.order_items;
CREATE TRIGGER trg_pos_permission_order_items
BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_kitchen_sends ON public.order_kitchen_sends;
CREATE TRIGGER trg_pos_permission_kitchen_sends
BEFORE INSERT OR UPDATE OR DELETE ON public.order_kitchen_sends
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

DROP TRIGGER IF EXISTS trg_pos_permission_sales ON public.sales;
CREATE TRIGGER trg_pos_permission_sales
BEFORE INSERT ON public.sales
FOR EACH ROW EXECUTE FUNCTION public.enforce_pos_permission_mutation();

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;
