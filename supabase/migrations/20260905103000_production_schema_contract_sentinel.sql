-- Narrow, data-free Production schema sentinel used by the deploy parity gate.
-- It exposes only whether the required kitchen inventory contract exists; no
-- tenant or business rows are read or returned.

CREATE OR REPLACE FUNCTION public._production_schema_contract_kitchen_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, public
AS $function$
  SELECT
    EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'orders'
        AND a.attname = 'inventory_warehouse_id'
        AND a.attnum > 0
        AND NOT a.attisdropped
    )
    AND pg_catalog.to_regclass('public.order_kitchen_inventory_events') IS NOT NULL
    AND pg_catalog.to_regclass('public.order_kitchen_inventory_effects') IS NOT NULL
    AND pg_catalog.to_regprocedure('public._prepare_kitchen_sale_settlement(uuid,uuid,uuid,jsonb)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public._restore_kitchen_inventory_for_void(uuid,uuid,numeric)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public.send_to_kitchen(uuid,uuid)') IS NOT NULL
    AND pg_catalog.to_regprocedure('public.send_to_kitchen(uuid)') IS NULL;
$function$;

REVOKE ALL ON FUNCTION public._production_schema_contract_kitchen_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._production_schema_contract_kitchen_v1() TO anon, authenticated, service_role;
