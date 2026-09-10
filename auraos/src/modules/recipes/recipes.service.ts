import { withTenant } from '@/config/database';
import { BadRequestError, NotFoundError } from '@/shared/errors/AppError';

export interface RecipeLineInput {
  ingredient_id: string;
  quantity: number;
}

class RecipesService {
  async listIngredients(restaurantId: string) {
    return withTenant(restaurantId, async (q) => {
      const r = await q(
        `SELECT id, restaurant_id, name, unit, current_stock, reorder_level,
                cost_per_unit, is_active, created_at, updated_at
         FROM ingredients
         ORDER BY name ASC`,
      );
      return r.rows;
    });
  }

  async createIngredient(restaurantId: string, input: any) {
    const name = String(input.name ?? '').trim();
    const unit = String(input.unit ?? 'unit').trim() || 'unit';
    const currentStock = Number(input.current_stock ?? 0);
    const reorderLevel = Number(input.reorder_level ?? 0);
    const costPerUnit = Number(input.cost_per_unit ?? 0);
    if (!name) throw new BadRequestError('Ingredient name is required');
    if (![currentStock, reorderLevel, costPerUnit].every(Number.isFinite) || currentStock < 0 || reorderLevel < 0 || costPerUnit < 0) {
      throw new BadRequestError('Stock, reorder level and cost must be non-negative numbers');
    }
    return withTenant(restaurantId, async (q) => {
      const r = await q(
        `INSERT INTO ingredients (restaurant_id, name, unit, current_stock, reorder_level, cost_per_unit)
         VALUES ($1,$2,$3,$4,$5,$6)
         RETURNING *`,
        [restaurantId, name, unit, currentStock, reorderLevel, costPerUnit],
      );
      return r.rows[0];
    });
  }

  async updateIngredient(restaurantId: string, id: string, input: any, changedBy?: string | null) {
    return withTenant(restaurantId, async (q) => {
      const existing = await q('SELECT * FROM ingredients WHERE id=$1', [id]);
      if (!existing.rows[0]) throw new NotFoundError('Ingredient not found');
      const old = existing.rows[0];
      const name = input.name === undefined ? old.name : String(input.name).trim();
      const unit = input.unit === undefined ? old.unit : String(input.unit).trim();
      const currentStock = input.current_stock === undefined ? Number(old.current_stock) : Number(input.current_stock);
      const reorderLevel = input.reorder_level === undefined ? Number(old.reorder_level) : Number(input.reorder_level);
      const costPerUnit = input.cost_per_unit === undefined ? Number(old.cost_per_unit) : Number(input.cost_per_unit);
      const active = input.is_active === undefined ? old.is_active : Boolean(input.is_active);
      if (!name || !unit || ![currentStock, reorderLevel, costPerUnit].every(Number.isFinite) || currentStock < 0 || reorderLevel < 0 || costPerUnit < 0) {
        throw new BadRequestError('Invalid ingredient values');
      }
      const r = await q(
        `UPDATE ingredients SET name=$2, unit=$3, current_stock=$4, reorder_level=$5,
          cost_per_unit=$6, is_active=$7, updated_at=CURRENT_TIMESTAMP
         WHERE id=$1 RETURNING *`,
        [id, name, unit, currentStock, reorderLevel, costPerUnit, active],
      );
      if (currentStock !== Number(old.current_stock)) {
        await q(
          `INSERT INTO ingredient_transactions
           (restaurant_id, ingredient_id, quantity_before, quantity_after, quantity_change,
            transaction_type, notes, changed_by)
           VALUES ($1,$2,$3,$4,$5,'ADJUSTMENT','Manual stock adjustment',$6)`,
          [restaurantId, id, Number(old.current_stock), currentStock, currentStock - Number(old.current_stock), changedBy ?? null],
        );
      }
      return r.rows[0];
    });
  }

  async deleteIngredient(restaurantId: string, id: string) {
    return withTenant(restaurantId, async (q) => {
      const inUse = await q('SELECT 1 FROM menu_item_ingredients WHERE ingredient_id=$1 LIMIT 1', [id]);
      if (inUse.rowCount) throw new BadRequestError('Ingredient is used in a recipe');
      const r = await q('DELETE FROM ingredients WHERE id=$1 RETURNING id', [id]);
      if (!r.rowCount) throw new NotFoundError('Ingredient not found');
    });
  }

  async listRecipes(restaurantId: string) {
    return withTenant(restaurantId, async (q) => {
      const r = await q(
        `SELECT mi.id AS menu_item_id, mi.name AS menu_item_name,
                COALESCE(SUM(mii.quantity * i.cost_per_unit),0)::numeric AS recipe_cost,
                COUNT(mii.id)::int AS ingredient_count
         FROM menu_items mi
         LEFT JOIN menu_item_ingredients mii ON mii.menu_item_id=mi.id
         LEFT JOIN ingredients i ON i.id=mii.ingredient_id
         WHERE mi.restaurant_id=$1
         GROUP BY mi.id, mi.name
         ORDER BY mi.name`,
        [restaurantId],
      );
      return r.rows;
    });
  }

  async getRecipe(restaurantId: string, menuItemId: string) {
    return withTenant(restaurantId, async (q) => {
      const item = await q('SELECT id, name, price FROM menu_items WHERE id=$1 AND restaurant_id=$2', [menuItemId, restaurantId]);
      if (!item.rows[0]) throw new NotFoundError('Menu item not found');
      const lines = await q(
        `SELECT mii.id, mii.ingredient_id, i.name, i.unit, mii.quantity,
                i.current_stock, i.cost_per_unit,
                (mii.quantity * i.cost_per_unit)::numeric AS line_cost
         FROM menu_item_ingredients mii
         JOIN ingredients i ON i.id=mii.ingredient_id
         WHERE mii.menu_item_id=$1
         ORDER BY i.name`,
        [menuItemId],
      );
      const cost = lines.rows.reduce((sum, x) => sum + Number(x.line_cost || 0), 0);
      return { menu_item: item.rows[0], ingredients: lines.rows, recipe_cost: cost };
    });
  }

  async replaceRecipe(restaurantId: string, menuItemId: string, lines: RecipeLineInput[]) {
    if (!Array.isArray(lines)) throw new BadRequestError('ingredients must be an array');
    const seen = new Set<string>();
    for (const line of lines) {
      const qty = Number(line.quantity);
      if (!line.ingredient_id || !Number.isFinite(qty) || qty <= 0) throw new BadRequestError('Each ingredient needs a positive quantity');
      if (seen.has(line.ingredient_id)) throw new BadRequestError('Duplicate ingredient in recipe');
      seen.add(line.ingredient_id);
    }
    await withTenant(restaurantId, async (q) => {
      const item = await q('SELECT 1 FROM menu_items WHERE id=$1 AND restaurant_id=$2', [menuItemId, restaurantId]);
      if (!item.rowCount) throw new NotFoundError('Menu item not found');
      if (lines.length) {
        const ids = lines.map((x) => x.ingredient_id);
        const valid = await q('SELECT id FROM ingredients WHERE restaurant_id=$1 AND id=ANY($2::uuid[]) AND is_active=TRUE', [restaurantId, ids]);
        if (valid.rowCount !== ids.length) throw new BadRequestError('One or more ingredients are invalid');
      }
      await q('DELETE FROM menu_item_ingredients WHERE menu_item_id=$1', [menuItemId]);
      for (const line of lines) {
        await q(
          `INSERT INTO menu_item_ingredients (restaurant_id, menu_item_id, ingredient_id, quantity)
           VALUES ($1,$2,$3,$4)`,
          [restaurantId, menuItemId, line.ingredient_id, Number(line.quantity)],
        );
      }
    });
    return this.getRecipe(restaurantId, menuItemId);
  }

  /** Consume a recipe exactly once for one order item. Returns false when no BOM exists. */
  async consumeForOrderItem(restaurantId: string, orderId: string, orderItemId: string, menuItemId: string, orderQty: number, changedBy?: string | null): Promise<boolean> {
    return withTenant(restaurantId, async (q) => {
      const already = await q('SELECT 1 FROM order_ingredient_consumptions WHERE order_item_id=$1 LIMIT 1', [orderItemId]);
      if (already.rowCount) return true;
      const recipe = await q(
        `SELECT mii.ingredient_id, mii.quantity, i.current_stock, i.name
         FROM menu_item_ingredients mii
         JOIN ingredients i ON i.id=mii.ingredient_id
         WHERE mii.menu_item_id=$1 AND mii.restaurant_id=$2
         FOR UPDATE OF i`,
        [menuItemId, restaurantId],
      );
      if (!recipe.rowCount) return false;
      for (const line of recipe.rows) {
        const before = Number(line.current_stock);
        const required = Number(line.quantity) * Number(orderQty);
        const after = Math.max(0, before - required);
        await q('UPDATE ingredients SET current_stock=$2, updated_at=CURRENT_TIMESTAMP WHERE id=$1', [line.ingredient_id, after]);
        await q(
          `INSERT INTO order_ingredient_consumptions
           (restaurant_id, order_id, order_item_id, ingredient_id, quantity_consumed)
           VALUES ($1,$2,$3,$4,$5) ON CONFLICT (order_item_id, ingredient_id) DO NOTHING`,
          [restaurantId, orderId, orderItemId, line.ingredient_id, Math.min(before, required)],
        );
        await q(
          `INSERT INTO ingredient_transactions
           (restaurant_id, ingredient_id, order_id, order_item_id, quantity_before, quantity_after,
            quantity_change, transaction_type, notes, changed_by)
           VALUES ($1,$2,$3,$4,$5,$6,$7,'USAGE','Recipe consumption',$8)`,
          [restaurantId, line.ingredient_id, orderId, orderItemId, before, after, after - before, changedBy ?? null],
        );
      }
      return true;
    });
  }
}

export const recipesService = new RecipesService();
