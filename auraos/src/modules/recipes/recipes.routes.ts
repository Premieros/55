import { Router, Response, NextFunction } from 'express';
import { authenticate, AuthenticatedRequest } from '@/shared/middleware/authenticate';
import { authorize } from '@/shared/middleware/authorize';
import { checkSubscription } from '@/shared/middleware/checkSubscription';
import { successResponse } from '@/shared/utils/responseHandler';
import { recipesService } from './recipes.service';

const router = Router();
const admin = [authenticate, authorize('ADMIN')];

function restaurantId(req: AuthenticatedRequest): string {
  const id = req.user?.restaurantId;
  if (!id) throw new Error('User not associated with a restaurant');
  return id;
}

router.get('/ingredients', ...admin, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.json(successResponse(await recipesService.listIngredients(restaurantId(req)))); } catch (e) { next(e); }
});
router.post('/ingredients', ...admin, checkSubscription, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.status(201).json(successResponse(await recipesService.createIngredient(restaurantId(req), req.body))); } catch (e) { next(e); }
});
router.patch('/ingredients/:id', ...admin, checkSubscription, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.json(successResponse(await recipesService.updateIngredient(restaurantId(req), req.params.id, req.body, req.user?.userId))); } catch (e) { next(e); }
});
router.delete('/ingredients/:id', ...admin, checkSubscription, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { await recipesService.deleteIngredient(restaurantId(req), req.params.id); res.json(successResponse({ deleted: true })); } catch (e) { next(e); }
});
router.get('/', ...admin, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.json(successResponse(await recipesService.listRecipes(restaurantId(req)))); } catch (e) { next(e); }
});
router.get('/:menuItemId', ...admin, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.json(successResponse(await recipesService.getRecipe(restaurantId(req), req.params.menuItemId))); } catch (e) { next(e); }
});
router.put('/:menuItemId', ...admin, checkSubscription, async (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
  try { res.json(successResponse(await recipesService.replaceRecipe(restaurantId(req), req.params.menuItemId, req.body?.ingredients ?? []))); } catch (e) { next(e); }
});

export default router;
