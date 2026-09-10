import { useState, useEffect, useCallback, useRef } from 'react'

interface UseAIQueryResult<T> {
  data: T | null
  loading: boolean
  error: string | null
  refetch: () => void
}

export function useAIQuery<T>(
  fetcher: () => Promise<{ data: T }>,
  deps: unknown[] = [],
): UseAIQueryResult<T> {
  const [data, setData] = useState<T | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const mountedRef = useRef(true)
  const inFlightRef = useRef(false)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const fetch = useCallback(async () => {
    // Ignore repeated clicks/poll ticks while the same query is already running.
    if (inFlightRef.current) return
    inFlightRef.current = true

    // Only block the UI on the first load. Background refreshes keep current
    // data visible so buttons/navigation remain responsive.
    setData((current) => {
      if (current === null) setLoading(true)
      return current
    })
    setError(null)

    try {
      const res = await fetcher()
      if (mountedRef.current) setData(res.data)
    } catch (err: any) {
      const msg = err?.response?.data?.detail || err?.message || 'Failed to fetch data'
      if (mountedRef.current) setError(msg)
    } finally {
      inFlightRef.current = false
      if (mountedRef.current) setLoading(false)
    }
  }, deps)

  useEffect(() => {
    void fetch()
  }, [fetch])

  return { data, loading, error, refetch: () => void fetch() }
}

export function useAIPolling<T>(
  fetcher: () => Promise<{ data: T }>,
  intervalMs: number,
  deps: unknown[] = [],
): UseAIQueryResult<T> {
  const result = useAIQuery(fetcher, deps)

  useEffect(() => {
    const tick = () => {
      // Background tabs should not spend CPU/network recalculating Local AI.
      if (document.visibilityState === 'visible') result.refetch()
    }

    const id = window.setInterval(tick, intervalMs)
    return () => window.clearInterval(id)
  }, [result.refetch, intervalMs])

  return result
}
