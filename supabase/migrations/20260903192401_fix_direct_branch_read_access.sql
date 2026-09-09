-- Ensure every authenticated user can read their directly assigned branch,
-- even when that branch belongs to an organization.
-- Cross-branch visibility remains limited to platform admins or organization membership.

drop policy if exists auth_select_branches on public.branches;

create policy auth_select_branches
on public.branches
for select
to authenticated
using (
  is_platform_admin()
  or id = get_branch_id()
  or organization_id in (select user_organization_ids())
);
