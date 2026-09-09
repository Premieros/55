-- Remove the legacy one-argument overload after the authoritative two-argument
-- kitchen inventory function has been reconciled. The authoritative function
-- keeps p_sent_by DEFAULT NULL, so existing one-argument callers continue to
-- resolve normally without an ambiguous overload and cannot bypass inventory.

DROP FUNCTION IF EXISTS public.send_to_kitchen(uuid);

-- The remaining signature is public.send_to_kitchen(uuid, uuid DEFAULT NULL).
-- Keep its final least-privilege execution surface explicit.
REVOKE ALL ON FUNCTION public.send_to_kitchen(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_to_kitchen(uuid, uuid) TO authenticated, service_role;
