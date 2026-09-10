-- 031_recipes_and_ingredients.sql
-- Raw ingredients + BOM recipes + idempotent order consumption.
-- Existing inventory_items (finished-goods stock) remains unchanged for products
-- that do not have a recipe.

CREATE TABLE IF NOT EXISTS ingredients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    unit VARCHAR(32) NOT NULL DEFAULT 'unit',
    current_stock NUMERIC(14,4) NOT NULL DEFAULT 0 CHECK (current_stock >= 0),
    reorder_level NUMERIC(14,4) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
    cost_per_unit NUMERIC(14,4) NOT NULL DEFAULT 0 CHECK (cost_per_unit >= 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (restaurant_id, name)
);

CREATE TABLE IF NOT EXISTS menu_item_ingredients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    menu_item_id UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
    ingredient_id UUID NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    quantity NUMERIC(14,4) NOT NULL CHECK (quantity > 0),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (menu_item_id, ingredient_id)
);

CREATE TABLE IF NOT EXISTS ingredient_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    ingredient_id UUID NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
    order_id UUID REFERENCES orders(id) ON DELETE SET NULL,
    order_item_id UUID REFERENCES order_items(id) ON DELETE SET NULL,
    quantity_before NUMERIC(14,4) NOT NULL,
    quantity_after NUMERIC(14,4) NOT NULL,
    quantity_change NUMERIC(14,4) NOT NULL,
    transaction_type VARCHAR(32) NOT NULL,
    notes TEXT,
    changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS order_ingredient_consumptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    order_id UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    order_item_id UUID NOT NULL REFERENCES order_items(id) ON DELETE CASCADE,
    ingredient_id UUID NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    quantity_consumed NUMERIC(14,4) NOT NULL CHECK (quantity_consumed >= 0),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (order_item_id, ingredient_id)
);

CREATE INDEX IF NOT EXISTS idx_ingredients_restaurant ON ingredients(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_recipe_menu_item ON menu_item_ingredients(menu_item_id);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredient ON menu_item_ingredients(ingredient_id);
CREATE INDEX IF NOT EXISTS idx_ingredient_tx_restaurant ON ingredient_transactions(restaurant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_consumption_order_item ON order_ingredient_consumptions(order_item_id);

-- New tables are tenant-scoped exactly like the existing RLS model in 021_rls.sql.
GRANT SELECT, INSERT, UPDATE, DELETE ON ingredients, menu_item_ingredients, ingredient_transactions, order_ingredient_consumptions TO app_tenant;

ALTER TABLE ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_item_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingredient_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_ingredient_consumptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON ingredients;
CREATE POLICY tenant_isolation ON ingredients
  USING (restaurant_id = current_setting('app.restaurant_id', true)::uuid)
  WITH CHECK (restaurant_id = current_setting('app.restaurant_id', true)::uuid);

DROP POLICY IF EXISTS tenant_isolation ON menu_item_ingredients;
CREATE POLICY tenant_isolation ON menu_item_ingredients
  USING (restaurant_id = current_setting('app.restaurant_id', true)::uuid)
  WITH CHECK (restaurant_id = current_setting('app.restaurant_id', true)::uuid);

DROP POLICY IF EXISTS tenant_isolation ON ingredient_transactions;
CREATE POLICY tenant_isolation ON ingredient_transactions
  USING (restaurant_id = current_setting('app.restaurant_id', true)::uuid)
  WITH CHECK (restaurant_id = current_setting('app.restaurant_id', true)::uuid);

DROP POLICY IF EXISTS tenant_isolation ON order_ingredient_consumptions;
CREATE POLICY tenant_isolation ON order_ingredient_consumptions
  USING (restaurant_id = current_setting('app.restaurant_id', true)::uuid)
  WITH CHECK (restaurant_id = current_setting('app.restaurant_id', true)::uuid);
