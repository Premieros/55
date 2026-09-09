import { openOfflineDb } from './offlineStorage';

const LOCAL_PRODUCT_PREFIX = 'pos_offline_products_cache_v1_';
const LOCAL_CATEGORY_PREFIX = 'pos_offline_categories_cache_v1_';

/**
 * Invalidate both POS catalog cache layers after catalog mutations.
 * IndexedDB catalog stores are global in the current offline schema, while
 * the legacy localStorage cache is branch-keyed.
 */
export async function invalidatePosCatalogCache(branchId?: string | null): Promise<void> {
  try {
    if (typeof localStorage !== 'undefined') {
      if (branchId) {
        localStorage.removeItem(`${LOCAL_PRODUCT_PREFIX}${branchId}`);
        localStorage.removeItem(`${LOCAL_CATEGORY_PREFIX}${branchId}`);
      } else {
        const keys: string[] = [];
        for (let i = 0; i < localStorage.length; i += 1) {
          const key = localStorage.key(i);
          if (key && (key.startsWith(LOCAL_PRODUCT_PREFIX) || key.startsWith(LOCAL_CATEGORY_PREFIX))) {
            keys.push(key);
          }
        }
        keys.forEach((key) => localStorage.removeItem(key));
      }
    }
  } catch (err) {
    console.warn('[POS cache] Failed to clear localStorage catalog cache', err);
  }

  try {
    const db = await openOfflineDb();
    const stores = ['products', 'categories'].filter((name) => db.objectStoreNames.contains(name));
    if (stores.length === 0) return;
    const tx = db.transaction(stores, 'readwrite');
    stores.forEach((name) => tx.objectStore(name).clear());
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } catch (err) {
    console.warn('[POS cache] Failed to clear IndexedDB catalog cache', err);
  }
}
