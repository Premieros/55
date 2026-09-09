-- Restore the administrative execution contract for manufactured-unit production.
-- Integration/admin flows use service_role, while application users use authenticated.

REVOKE ALL ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.produce_inventory_unit(uuid, numeric, uuid, uuid, text) TO service_role;
