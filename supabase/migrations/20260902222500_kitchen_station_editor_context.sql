-- Kitchen station editor context
--
-- The existing assignment model is already branch-aware. This RPC exposes the
-- branch, users, and product categories needed by the editor in one guarded
-- read so the UI does not depend on the global header branch selector or direct
-- cross-table reads.

CREATE OR REPLACE FUNCTION public.get_kitchen_station_editor_context(p_branch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_branch jsonb;
  v_users jsonb;
  v_categories jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.users
  WHERE id = auth.uid() AND is_active = true;

  IF v_role NOT IN ('super_admin', 'owner', 'branch_manager')
     OR p_branch_id IS NULL
     OR NOT public.user_may_access_branch(p_branch_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  END IF;

  SELECT jsonb_build_object('id', b.id, 'name', b.name)
    INTO v_branch
  FROM public.branches b
  WHERE b.id = p_branch_id;

  IF v_branch IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRANCH_NOT_FOUND');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', u.id,
        'full_name', u.full_name,
        'email', u.email,
        'role', u.role
      ) ORDER BY COALESCE(NULLIF(u.full_name, ''), u.email), u.id
    ),
    '[]'::jsonb
  )
  INTO v_users
  FROM public.users u
  WHERE u.branch_id = p_branch_id
    AND u.is_active = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'name_en', c.name_en,
        'kitchen_station_id', c.kitchen_station_id
      ) ORDER BY c.name, c.id
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM public.categories c
  WHERE c.branch_id = p_branch_id;

  RETURN jsonb_build_object(
    'success', true,
    'branch', v_branch,
    'users', v_users,
    'categories', v_categories
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_kitchen_station_editor_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kitchen_station_editor_context(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_kitchen_station_editor_context(uuid) IS
  'Branch-scoped kitchen station editor context: branch, active users, and product categories. No write side effects.';
