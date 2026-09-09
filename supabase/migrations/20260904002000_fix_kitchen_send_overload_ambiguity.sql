-- Resolve ambiguous one-argument calls to send_to_kitchen.
--
-- The canonical RPC is public.send_to_kitchen(uuid, uuid default null), which
-- already supports both one-argument and two-argument callers. Keeping the
-- legacy public.send_to_kitchen(uuid) overload makes PostgreSQL unable to
-- choose a best candidate for calls such as send_to_kitchen($1).
--
-- Remove only the redundant legacy overload. Do not change the canonical
-- function body, permissions, RLS behavior, or kitchen send semantics.

drop function if exists public.send_to_kitchen(uuid);
