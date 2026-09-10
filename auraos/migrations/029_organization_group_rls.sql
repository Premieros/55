-- 029_organization_group_rls.sql
-- Close the remaining tenant-isolation gap in multi-outlet organization tables.
-- Organization management runs through the database-owner backend path; the
-- app_tenant role must never gain cross-tenant organization visibility.

-- Junction rows are restaurant-scoped, so protect them with the same tenant key.
ALTER TABLE organization_group_restaurants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation_organization_group_restaurants
  ON organization_group_restaurants;
CREATE POLICY tenant_isolation_organization_group_restaurants
  ON organization_group_restaurants
  USING (restaurant_id::text = current_setting('app.restaurant_id', true))
  WITH CHECK (restaurant_id::text = current_setting('app.restaurant_id', true));

-- Organization groups themselves are cross-restaurant administrative objects.
-- Enable RLS but intentionally define no app_tenant policy: tenant-role access
-- therefore fails closed, while the table-owner backend keeps its existing
-- administrative behavior.
ALTER TABLE organization_groups ENABLE ROW LEVEL SECURITY;

-- Defense in depth: organization administration is never a tenant-role concern.
REVOKE ALL ON TABLE organization_groups FROM app_tenant;
