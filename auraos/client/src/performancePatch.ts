import api from './api'

/**
 * Small client-side request de-duplication/cache layer.
 *
 * Local AI pages derive several widgets from the same core datasets (orders,
 * inventory, reports). Without de-duplication the browser can fire the same GET
 * request multiple times in parallel when a page mounts, which makes navigation
 * feel frozen on slower/mobile connections.
 *
 * Cache lifetime is intentionally short so operational data remains fresh.
 */
const CACHE_TTL_MS = 5000

type CachedEntry = {
  expiresAt: number
  promise: ReturnType<typeof api.get>
}

const cache = new Map<string, CachedEntry>()
const originalGet = api.get.bind(api)

function stableParams(params: unknown): string {
  if (!params || typeof params !== 'object') return ''
  try {
    const entries = Object.entries(params as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
    return JSON.stringify(Object.fromEntries(entries))
  } catch {
    return String(params)
  }
}

api.get = ((url: string, config?: any) => {
  const key = `${url}|${stableParams(config?.params)}`
  const now = Date.now()
  const cached = cache.get(key)

  if (cached && cached.expiresAt > now) {
    return cached.promise
  }

  const promise = originalGet(url, config)
  cache.set(key, { expiresAt: now + CACHE_TTL_MS, promise })

  promise.catch(() => {
    if (cache.get(key)?.promise === promise) cache.delete(key)
  })

  return promise
}) as typeof api.get

// Any write may change data returned by GET endpoints, so invalidate immediately.
api.interceptors.request.use((config) => {
  const method = String(config.method ?? 'get').toLowerCase()
  if (method !== 'get' && method !== 'head' && method !== 'options') {
    cache.clear()
  }
  return config
})
