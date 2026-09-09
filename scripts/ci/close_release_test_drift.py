from pathlib import Path

p = Path('tests/integration/rls_branch_isolation.test.ts')
s = p.read_text(encoding='utf-8')

old_recipe = """        name: 'recipe_items', key: 'recipe_items', parent: 'recipes', fk: 'recipe_id', mode: 'parentWrite', noDel: 'all',
        ins: () => ({ sql: `INSERT INTO public.recipe_items (recipe_id, raw_material_id, quantity) VALUES ($1, $2, 1)`, paramsA: [ids.rows.recipes.own, ids.rm], paramsB: [ids.rows.recipes.other, ids.rmB] }),"""
new_recipe = """        name: 'recipe_items', key: 'recipe_items', parent: 'recipes', fk: 'recipe_id', mode: 'permRecipes', noDel: 'all',
        ins: () => ({
          sql: `WITH fresh_rm AS (
            INSERT INTO public.raw_materials (code, name, branch_id)
            SELECT 'RI-' || gen_random_uuid()::text || '-' || left($2::text, 8), 'Recipe probe', r.branch_id
            FROM public.recipes r WHERE r.id = $1
            RETURNING id
          )
          INSERT INTO public.recipe_items (recipe_id, raw_material_id, quantity)
          SELECT $1, id, 1 FROM fresh_rm`,
          paramsA: [ids.rows.recipes.own, ids.rm], paramsB: [ids.rows.recipes.other, ids.rmB],
        }),"""
if old_recipe not in s:
    raise SystemExit('recipe_items child spec not found; refusing blind patch')
s = s.replace(old_recipe, new_recipe, 1)

old_role = """    t('guard_role_permissions: branch managers cannot mint admin-only roles (044)', async () => {
      const ins = (perms: string) =>
        `INSERT INTO public.roles (role, name_ar, name_en, permissions) VALUES ('${uniq('RG')}', 'X', 'Y', '${perms}'::jsonb)`;
      await runProbe(client, 'roles INSERT bm with owned settings.manage', bmId(), ins('[\"settings.manage\"]'), 'ok');
      await runProbe(client, 'roles INSERT bm with unowned audit.view', bmId(), ins('[\"audit.view\"]'), 'denied');
      await runProbe(client, 'roles INSERT admin plain', adminId(), ins('[\"pos.sell\"]'), 'ok');
    });"""
new_role = """    t('guard_role_permissions: role creation requires roles.permissions.manage and forbids escalation', async () => {
      const ins = (perms: string) =>
        `INSERT INTO public.roles (role, name_ar, name_en, permissions) VALUES ('${uniq('RG')}', 'X', 'Y', '${perms}'::jsonb)`;

      // Permission-first contract: managing settings does not imply permission
      // to mint roles. The dedicated role-permission capability is required.
      await runProbe(client, 'roles INSERT bm without roles.permissions.manage', bmId(), ins('[\"settings.manage\"]'), 'denied');

      // Grant only the dedicated role-management capability in the fixture.
      // This runs as the outer postgres test session and rolls back afterwards.
      await client.query(
        `UPDATE public.roles SET permissions = permissions || '[\"roles.permissions.manage\"]'::jsonb WHERE role = 'branch_manager'`,
      );
      await runProbe(client, 'roles INSERT bm with owned settings.manage', bmId(), ins('[\"settings.manage\"]'), 'ok');
      await runProbe(client, 'roles INSERT bm with unowned audit.view', bmId(), ins('[\"audit.view\"]'), 'denied');
      await runProbe(client, 'roles INSERT super admin canonical permission', adminId(), ins('[\"pos.view\"]'), 'ok');
    });"""
if old_role not in s:
    raise SystemExit('role guard test block not found; refusing blind patch')
s = s.replace(old_role, new_role, 1)

p.write_text(s, encoding='utf-8')
print('Updated stale RLS integration expectations.')
