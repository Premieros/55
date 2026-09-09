import { supabase } from '@/api';

export const PRODUCT_IMAGES_BUCKET = 'product-images';
export const PRODUCT_IMAGE_MAX_BYTES = 5 * 1024 * 1024;

export function validateProductImage(file: File) {
  if (!file.type.startsWith('image/')) throw new Error('INVALID_IMAGE_TYPE');
  if (file.size > PRODUCT_IMAGE_MAX_BYTES) throw new Error('IMAGE_TOO_LARGE');
}

function safeExtension(file: File) {
  const fromName = file.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '');
  if (fromName && fromName.length <= 5) return fromName;
  const subtype = file.type.split('/')[1]?.toLowerCase().replace(/[^a-z0-9]/g, '');
  return subtype || 'jpg';
}

export async function uploadProductImage(file: File, branchId: string, productId: string) {
  validateProductImage(file);
  if (!branchId || !productId) throw new Error('MISSING_PRODUCT_IMAGE_SCOPE');
  const token = typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const path = `${branchId}/${productId}/${token}.${safeExtension(file)}`;
  const { error } = await supabase.storage.from(PRODUCT_IMAGES_BUCKET).upload(path, file, {
    cacheControl: '31536000',
    upsert: false,
    contentType: file.type,
  });
  if (error) throw error;
  const { data } = supabase.storage.from(PRODUCT_IMAGES_BUCKET).getPublicUrl(path);
  return { path, publicUrl: data.publicUrl };
}
