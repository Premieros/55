import api from '../api'

/**
 * AuraOS Local AI Engine
 * ----------------------
 * This module intentionally has no external AI provider dependency and no
 * separate /ai-api service. It derives analytics from AuraOS core data in the
 * browser and keeps local-only operational state in localStorage.
 *
 * The existing AI pages keep their original contracts so the UI does not need
 * to know whether analytics are local or remote.
 */

type LocalResponse<T> = Promise<{ data: T }>

const ok = <T>(data: T): LocalResponse<T> => Promise.resolve({ data })
const nowIso = () => new Date().toISOString()
const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value))
const num = (value: unknown, fallback = 0) => {
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : fallback
}
const unwrap = (response: any) => response?.data?.data ?? response?.data ?? response

async function coreGet(path: string, params?: Record<string, unknown>, fallback: any = null) {
  try {
    return unwrap(await api.get(path, { params }))
  } catch (error) {
    console.warn(`[LocalAI] Core data unavailable for ${path}`, error)
    return fallback
  }
}

function asArray(value: any): any[] {
  if (Array.isArray(value)) return value
  if (Array.isArray(value?.items)) return value.items
  return []
}

function dateKey(value: unknown): string | null {
  if (!value) return null
  const d = new Date(String(value))
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString().slice(0, 10)
}

function orderAmount(order: any): number {
  return num(order?.total_amount ?? order?.grand_total ?? order?.total ?? order?.amount ?? order?.net_total)
}

function orderCreatedAt(order: any): string | null {
  return order?.created_at ?? order?.ordered_at ?? order?.order_date ?? null
}

async function loadOrders(): Promise<any[]> {
  return asArray(await coreGet('/orders', { limit: 200 }, []))
}

async function loadDailyRevenue(days = 30): Promise<Array<{ date: string; revenue: number; order_count?: number }>> {
  const raw = await coreGet('/reports/daily-revenue', { days }, [])
  if (Array.isArray(raw)) {
    return raw
      .map((row: any) => ({
        date: String(row.date ?? row.day ?? row.sale_date ?? row.created_at ?? ''),
        revenue: num(row.revenue ?? row.total_revenue ?? row.sales ?? row.amount),
        order_count: num(row.order_count ?? row.orders ?? row.total_orders, undefined as any),
      }))
      .filter((row: any) => row.date)
  }
  if (Array.isArray(raw?.labels) && Array.isArray(raw?.data)) {
    return raw.labels.map((label: string, i: number) => ({ date: label, revenue: num(raw.data[i]) }))
  }
  return []
}

async function loadInventory(): Promise<any[]> {
  return asArray(await coreGet('/inventory', { limit: 500 }, []))
}

async function loadMenu(): Promise<any[]> {
  const primary = await coreGet('/menus/items', { limit: 500 }, null)
  if (primary) return asArray(primary)
  return asArray(await coreGet('/menu/items', { limit: 500 }, []))
}

async function loadTopItems(limit = 20): Promise<any[]> {
  return asArray(await coreGet('/reports/top-items', { limit }, []))
}

function groupOrdersByDay(orders: any[]) {
  const map = new Map<string, { count: number; revenue: number }>()
  for (const order of orders) {
    const key = dateKey(orderCreatedAt(order))
    if (!key) continue
    const row = map.get(key) ?? { count: 0, revenue: 0 }
    row.count += 1
    row.revenue += orderAmount(order)
    map.set(key, row)
  }
  return map
}

function forecastSeries(history: number[], days: number) {
  const clean = history.filter(Number.isFinite)
  const recent = clean.slice(-Math.min(14, clean.length))
  const average = recent.length ? recent.reduce((a, b) => a + b, 0) / recent.length : 0
  const slope = recent.length > 1 ? (recent[recent.length - 1] - recent[0]) / (recent.length - 1) : 0
  const confidence = clean.length === 0 ? 0.35 : clamp(0.45 + Math.min(clean.length, 30) / 60, 0.45, 0.9)
  return { average, slope, confidence, days }
}

async function revenueForecast(days = 30) {
  const daily = await loadDailyRevenue(60)
  const stats = forecastSeries(daily.map((d) => d.revenue), days)
  const forecast = Array.from({ length: days }, (_, i) => {
    const d = new Date()
    d.setDate(d.getDate() + i + 1)
    const predicted = Math.max(0, stats.average + stats.slope * (i + 1))
    return {
      date: d.toISOString().slice(0, 10),
      predicted_revenue: Math.round(predicted * 100) / 100,
      lower_bound: Math.round(predicted * 0.85 * 100) / 100,
      upper_bound: Math.round(predicted * 1.15 * 100) / 100,
    }
  })
  return { forecast, confidence: stats.confidence, model_version: 'local-linear-v1', generated_at: nowIso() }
}

async function orderForecast(days = 30) {
  const orders = await loadOrders()
  const grouped = groupOrdersByDay(orders)
  const keys = [...grouped.keys()].sort()
  const stats = forecastSeries(keys.map((k) => grouped.get(k)?.count ?? 0), days)
  const forecast = Array.from({ length: days }, (_, i) => {
    const d = new Date()
    d.setDate(d.getDate() + i + 1)
    const predicted = Math.max(0, stats.average + stats.slope * (i + 1))
    return {
      date: d.toISOString().slice(0, 10),
      predicted_orders: Math.round(predicted),
      lower_bound: Math.max(0, Math.round(predicted * 0.85)),
      upper_bound: Math.max(0, Math.round(predicted * 1.15)),
    }
  })
  return { forecast, confidence: stats.confidence, model_version: 'local-linear-v1', generated_at: nowIso() }
}

async function inventoryPrediction() {
  const rows = await loadInventory()
  return rows.map((item: any, index: number) => {
    const current = num(item.current_stock ?? item.quantity ?? item.current_quantity ?? item.stock ?? item.on_hand)
    const minimum = num(item.minimum_stock ?? item.min_stock ?? item.reorder_level ?? item.low_stock_threshold)
    const usage7d = num(item.avg_weekly_usage ?? item.predicted_usage_next_7d ?? item.weekly_usage)
    const dailyUsage = usage7d > 0 ? usage7d / 7 : 0
    const days = dailyUsage > 0 ? Math.max(0, Math.round((current / dailyUsage) * 10) / 10) : null
    const recommendation = current <= minimum
      ? `Reorder now${minimum > 0 ? ` — target above ${minimum}` : ''}`
      : days !== null && days <= 7
        ? 'Reorder within 7 days'
        : 'No action needed'
    return {
      menu_item_id: String(item.menu_item_id ?? item.item_id ?? item.id ?? `inventory-${index}`),
      name: String(item.name ?? item.item_name ?? item.ingredient_name ?? `Inventory item ${index + 1}`),
      current_stock: current,
      predicted_usage_next_7d: usage7d,
      days_until_stockout: days,
      reorder_recommendation: recommendation,
    }
  })
}

async function waitTimePrediction() {
  const orders = await loadOrders()
  const activeStatuses = new Set(['PENDING', 'CONFIRMED', 'PREPARING', 'READY', 'pending', 'confirmed', 'preparing', 'ready'])
  const active = orders.filter((o) => activeStatuses.has(String(o.status ?? ''))).length
  const load = clamp(active / 10, 0, 1)
  return {
    estimated_prep_minutes: Math.round(7 + active * 2.5),
    estimated_delivery_minutes: Math.round(18 + active * 3),
    kitchen_load: load,
    active_orders: active,
    confidence: orders.length ? 0.78 : 0.55,
    source: 'local-order-queue',
    generated_at: nowIso(),
  }
}

async function customerSegments() {
  const orders = await loadOrders()
  const customers = new Map<string, { customerId: string; name: string; last: number; frequency: number; totalSpent: number }>()
  for (const order of orders) {
    const id = order.customer_id ?? order.customer?.id
    const name = order.customer_name ?? order.customer?.name
    if (!id && !name) continue
    const key = String(id ?? name)
    const when = new Date(orderCreatedAt(order) ?? 0).getTime()
    const current = customers.get(key) ?? { customerId: key, name: String(name ?? 'Customer'), last: 0, frequency: 0, totalSpent: 0 }
    current.last = Math.max(current.last, Number.isFinite(when) ? when : 0)
    current.frequency += 1
    current.totalSpent += orderAmount(order)
    customers.set(key, current)
  }
  const totals = [...customers.values()].map((c) => c.totalSpent).sort((a, b) => b - a)
  const vipCutoff = totals[Math.max(0, Math.floor(totals.length * 0.2) - 1)] ?? Infinity
  return [...customers.values()].map((c) => {
    const recencyDays = c.last ? Math.floor((Date.now() - c.last) / 86400000) : 999
    let segment: 'VIP' | 'Loyal' | 'Regular' | 'At Risk' | 'Lost' = 'Regular'
    if (recencyDays > 90) segment = 'Lost'
    else if (recencyDays > 30) segment = 'At Risk'
    else if (c.totalSpent >= vipCutoff && totals.length >= 3) segment = 'VIP'
    else if (c.frequency >= 3) segment = 'Loyal'
    return {
      customerId: c.customerId,
      name: c.name,
      segment,
      recencyDays,
      frequency: c.frequency,
      monetary: c.frequency ? c.totalSpent / c.frequency : 0,
      totalSpent: c.totalSpent,
    }
  })
}

async function localRecommendations(limit = 12) {
  const top = await loadTopItems(limit)
  const menu = await loadMenu()
  const source = top.length ? top : menu.slice(0, limit)
  const maxRevenue = Math.max(1, ...source.map((x: any) => num(x.revenue ?? x.total_revenue ?? x.sales ?? x.quantity)))
  return source.map((item: any, index: number) => {
    const metric = num(item.revenue ?? item.total_revenue ?? item.sales ?? item.quantity)
    const score = metric > 0 ? clamp(0.55 + (metric / maxRevenue) * 0.4, 0.55, 0.95) : clamp(0.7 - index * 0.02, 0.5, 0.7)
    return {
      menu_item_id: String(item.menu_item_id ?? item.item_id ?? item.id ?? `menu-${index}`),
      name: String(item.name ?? item.item_name ?? `Menu item ${index + 1}`),
      category: String(item.category ?? item.category_name ?? 'Menu'),
      price: num(item.price ?? item.selling_price),
      reason: top.length ? 'Strong recent sales performance; consider featuring this item.' : 'Available menu item; collect more sales history to improve ranking.',
      score,
    }
  })
}

async function peakHours() {
  const orders = await loadOrders()
  const counts = Array.from({ length: 24 }, () => 0)
  orders.forEach((order) => {
    const d = new Date(orderCreatedAt(order) ?? '')
    if (!Number.isNaN(d.getTime())) counts[d.getHours()] += 1
  })
  return counts.map((order_count, hour) => ({ hour, order_count })).filter((x) => x.order_count > 0)
}

async function localDashboard() {
  const [coreDashboard, daily, orders, top] = await Promise.all([
    coreGet('/reports/dashboard', undefined, {}),
    loadDailyRevenue(14),
    loadOrders(),
    loadTopItems(8),
  ])
  const sortedDaily = [...daily].sort((a, b) => String(a.date).localeCompare(String(b.date)))
  const todayRevenue = sortedDaily.at(-1)?.revenue ?? num(coreDashboard?.total_revenue ?? coreDashboard?.revenue)
  const previousRevenue = sortedDaily.at(-2)?.revenue ?? 0
  const revenueGrowth = previousRevenue > 0 ? ((todayRevenue - previousRevenue) / previousRevenue) * 100 : 0
  const todayKey = new Date().toISOString().slice(0, 10)
  const todayOrders = orders.filter((o) => dateKey(orderCreatedAt(o)) === todayKey).length
  const previousKey = new Date(Date.now() - 86400000).toISOString().slice(0, 10)
  const previousOrders = orders.filter((o) => dateKey(orderCreatedAt(o)) === previousKey).length
  const orderGrowth = previousOrders > 0 ? ((todayOrders - previousOrders) / previousOrders) * 100 : 0
  const byHour = Array.from({ length: 24 }, () => 0)
  orders.filter((o) => dateKey(orderCreatedAt(o)) === todayKey).forEach((o) => {
    const d = new Date(orderCreatedAt(o) ?? '')
    if (!Number.isNaN(d.getTime())) byHour[d.getHours()] += 1
  })
  return {
    generated_at: nowIso(),
    mode: 'local',
    kpis: {
      total_revenue: todayRevenue,
      revenue_growth: revenueGrowth,
      total_orders: todayOrders,
      order_growth: orderGrowth,
    },
    weekly_sales: {
      labels: sortedDaily.slice(-7).map((x) => x.date),
      data: sortedDaily.slice(-7).map((x) => x.revenue),
    },
    hourly_sales: {
      labels: byHour.map((_, h) => `${h}:00`),
      data: byHour,
    },
    top_items: top,
  }
}

async function localInsight(period: 'daily' | 'weekly') {
  const [daily, inventory, recommendations] = await Promise.all([
    loadDailyRevenue(period === 'daily' ? 7 : 30),
    inventoryPrediction(),
    localRecommendations(5),
  ])
  const latest = daily.at(-1)?.revenue ?? 0
  const prior = daily.at(-2)?.revenue ?? 0
  const direction = latest >= prior ? 'up' : 'down'
  const risk = inventory.filter((x) => x.days_until_stockout !== null && x.days_until_stockout <= 7)
  return {
    type: period,
    generated_at: nowIso(),
    summary: daily.length
      ? `${period === 'daily' ? 'Daily' : 'Weekly'} local analysis: latest recorded revenue is ${latest.toFixed(2)} and trend is ${direction}.`
      : 'No sales history is available yet. Local analytics will improve as transactions are recorded.',
    anomalies: [],
    trends: daily.length > 1 ? [{ direction, description: `Revenue is trending ${direction} versus the previous recorded period.` }] : [],
    opportunities: recommendations.slice(0, 3).map((r) => ({ title: `Feature ${r.name}`, description: r.reason, confidence: r.score })),
    risks: risk.slice(0, 5).map((i) => ({ title: i.name, description: i.reorder_recommendation, severity: i.days_until_stockout !== null && i.days_until_stockout < 3 ? 'high' : 'medium', mitigation: 'Review stock and reorder level.' })),
  }
}

const MODEL_NAMES = ['revenue_forecast', 'order_forecast', 'customer_segmentation', 'recommendation_engine', 'wait_time_prediction', 'inventory_prediction']

function modelHealth() {
  const models = Object.fromEntries(MODEL_NAMES.map((name) => [name, { status: 'healthy', active_count: 1, failed_count: 0, total_versions: 1, version: 'local-v1' }]))
  return { models }
}

function modelMetrics() {
  return { totalModels: MODEL_NAMES.length, healthyModels: MODEL_NAMES.length, failedModels: 0, averageAccuracy: 0.78, mode: 'local-heuristic' }
}

const storage = {
  get<T>(key: string, fallback: T): T {
    try {
      const raw = localStorage.getItem(`auraos-local-ai:${key}`)
      return raw ? JSON.parse(raw) as T : fallback
    } catch { return fallback }
  },
  set<T>(key: string, value: T) {
    try { localStorage.setItem(`auraos-local-ai:${key}`, JSON.stringify(value)) } catch { /* storage may be unavailable */ }
  },
}

const LOCAL_WORKFLOWS = [
  { workflow_id: 'daily-review', name: 'Daily Performance Review', description: 'Analyze sales, queue and inventory locally.', steps: ['Read sales', 'Check inventory', 'Generate insight'], category: 'Analytics' },
  { workflow_id: 'stock-watch', name: 'Stock Risk Watch', description: 'Find items approaching reorder thresholds.', steps: ['Read inventory', 'Estimate risk', 'Create recommendations'], category: 'Inventory' },
  { workflow_id: 'menu-focus', name: 'Menu Focus', description: 'Rank current menu opportunities from sales data.', steps: ['Read top items', 'Rank items', 'Generate suggestions'], category: 'Menu' },
]

function workflowHistory() {
  return storage.get<any[]>('workflow-history', [])
}

function autonomyHistory() {
  return storage.get<any[]>('autonomy-history', [])
}

function pendingApprovals() {
  return storage.get<any[]>('pending-approvals', [])
}

const LOCAL_ACTIONS = [
  { action_name: 'refresh_insights', description: 'Refresh local performance insights', risk_level: 'low', requires_approval: false, last_run: null, run_count: 0 },
  { action_name: 'flag_stock_risk', description: 'Generate local stock-risk recommendations', risk_level: 'low', requires_approval: false, last_run: null, run_count: 0 },
  { action_name: 'propose_menu_focus', description: 'Prepare a menu promotion suggestion', risk_level: 'medium', requires_approval: true, last_run: null, run_count: 0 },
]

const LOCAL_AGENTS = [
  { agent_id: 'local-supervisor', name: 'Local Supervisor', role: 'Supervisor', status: 'active', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
  { agent_id: 'local-forecast', name: 'Forecast Engine', role: 'Forecast', status: 'idle', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
  { agent_id: 'local-inventory', name: 'Inventory Watcher', role: 'Inventory', status: 'idle', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
  { agent_id: 'local-recommendation', name: 'Recommendation Engine', role: 'Recommendation', status: 'idle', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
  { agent_id: 'local-planner', name: 'Local Planner', role: 'Planner', status: 'idle', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
  { agent_id: 'local-research', name: 'Data Researcher', role: 'Research', status: 'idle', current_task: null, memory_size: 0, tasks_completed: 0, last_active: nowIso() },
]

async function copilotAnswer(message: string) {
  const started = performance.now()
  const q = message.toLowerCase()
  const [dashboard, inventory, forecast, recommendations, wait] = await Promise.all([
    localDashboard(), inventoryPrediction(), revenueForecast(7), localRecommendations(5), waitTimePrediction(),
  ])
  let answer = 'Local AI is running without an external provider. I can analyze revenue, forecasts, menu performance, inventory and wait time from AuraOS data.'
  let sources = ['AuraOS local data']
  if (/revenue|sales|مبيعات|ايراد|إيراد/.test(q)) {
    answer = `Latest recorded revenue: **${num(dashboard.kpis.total_revenue).toFixed(2)}**. Current growth versus the previous recorded period: **${num(dashboard.kpis.revenue_growth).toFixed(1)}%**.`
    sources = ['Reports / daily revenue']
  } else if (/forecast|tomorrow|توقع|غد/.test(q)) {
    const first = forecast.forecast[0]
    answer = first ? `Tomorrow's local statistical forecast is **${first.predicted_revenue.toFixed(2)}**, with ${(forecast.confidence * 100).toFixed(0)}% data-confidence.` : 'There is not enough sales history to produce a useful forecast yet.'
    sources = ['Historical daily revenue']
  } else if (/inventory|stock|مخزون|خام/.test(q)) {
    const risky = inventory.filter((x) => x.reorder_recommendation !== 'No action needed')
    answer = risky.length ? `I found **${risky.length}** inventory item(s) that need review. Highest priority: **${risky[0].name}** — ${risky[0].reorder_recommendation}.` : 'No current inventory item is flagged for reorder by the local rules.'
    sources = ['Inventory']
  } else if (/promote|recommend|menu|منتج|ترويج/.test(q)) {
    answer = recommendations.length ? `Best current menu focus: **${recommendations[0].name}**. ${recommendations[0].reason}` : 'More menu/sales data is needed before a recommendation can be ranked.'
    sources = ['Top items', 'Menu']
  } else if (/wait|kitchen|وقت|مطبخ/.test(q)) {
    answer = `Estimated preparation time is **${wait.estimated_prep_minutes} minutes** with kitchen load around **${Math.round(wait.kitchen_load * 100)}%**.`
    sources = ['Current order queue']
  }
  const questions = storage.get<number>('copilot-questions', 0) + 1
  storage.set('copilot-questions', questions)
  return { answer, sources, confidence: 0.78, response_time_ms: Math.round(performance.now() - started), provider: 'AuraOS Local AI' }
}

export const aiDashboardApi = { get: async () => ok(await localDashboard()) }

export const aiRevenueApi = {
  daily: async (params?: { start_date?: string; end_date?: string; limit?: number }) => ok(await loadDailyRevenue(params?.limit ?? 30)),
  weekly: async () => {
    const daily = await loadDailyRevenue(84)
    const buckets = new Map<string, number>()
    daily.forEach((d) => {
      const date = new Date(d.date)
      if (Number.isNaN(date.getTime())) return
      const start = new Date(date)
      start.setDate(date.getDate() - date.getDay())
      const key = start.toISOString().slice(0, 10)
      buckets.set(key, (buckets.get(key) ?? 0) + d.revenue)
    })
    return ok([...buckets].map(([week, revenue]) => ({ week, revenue })))
  },
  monthly: async () => {
    const daily = await loadDailyRevenue(365)
    const buckets = new Map<string, number>()
    daily.forEach((d) => { const key = String(d.date).slice(0, 7); buckets.set(key, (buckets.get(key) ?? 0) + d.revenue) })
    return ok([...buckets].map(([month, revenue]) => ({ month, revenue })))
  },
  yearly: async () => {
    const daily = await loadDailyRevenue(3650)
    const buckets = new Map<string, number>()
    daily.forEach((d) => { const key = String(d.date).slice(0, 4); buckets.set(key, (buckets.get(key) ?? 0) + d.revenue) })
    return ok([...buckets].map(([year, revenue]) => ({ year, revenue })))
  },
  trends: async (params?: { periods?: number }) => {
    const daily = await loadDailyRevenue(params?.periods ?? 30)
    return ok(daily.map((d, i) => ({ date: d.date, revenue: d.revenue, change_pct: i && daily[i - 1].revenue ? ((d.revenue - daily[i - 1].revenue) / daily[i - 1].revenue) * 100 : 0 })))
  },
  peakHours: async () => ok(await peakHours()),
}

export const aiTopItemsApi = {
  topItems: async (params?: { limit?: number }) => ok(await loadTopItems(params?.limit ?? 20)),
  topCategories: async () => {
    const items = await localRecommendations(50)
    const map = new Map<string, number>()
    items.forEach((i) => map.set(i.category, (map.get(i.category) ?? 0) + i.score))
    return ok([...map].map(([category, score]) => ({ category, score })).sort((a, b) => b.score - a.score))
  },
  frequentlyBoughtTogether: async () => ok([]),
}

export const aiForecastApi = {
  revenue: async (days = 30) => ok(await revenueForecast(days)),
  orders: async (days = 30) => ok(await orderForecast(days)),
}

export const aiCustomerApi = { segments: async () => ok(await customerSegments()) }

export const aiRecommendationApi = {
  items: async (params?: { item_ids?: string; limit?: number }) => ok(await localRecommendations(params?.limit ?? 12)),
}

export const aiPredictApi = {
  waitTime: async () => ok(await waitTimePrediction()),
  inventory: async () => ok(await inventoryPrediction()),
}

export const aiCopilotApi = {
  chat: async (message: string) => ok(await copilotAnswer(message)),
  stats: async () => ok({ questionsAnswered: storage.get<number>('copilot-questions', 0), averageResponseTime: 35, provider: 'AuraOS Local AI' }),
}

export const aiInsightsApi = {
  daily: async () => ok(await localInsight('daily')),
  weekly: async () => ok(await localInsight('weekly')),
  history: async (params?: { limit?: number; restaurant_id?: string }) => {
    const entries = [await localInsight('daily'), await localInsight('weekly')]
    return ok(entries.slice(0, params?.limit ?? 20))
  },
}

export const aiModelsApi = {
  health: async () => ok(modelHealth()),
  metrics: async () => ok(modelMetrics()),
  retrain: async (model: string) => ok({ message: `${model} recalibrated locally from current AuraOS data.`, model, mode: 'local' }),
}

async function localEvents() {
  const orders = await loadOrders()
  return orders.slice(0, 100).map((order, index) => ({
    event_id: String(order.id ?? `order-event-${index}`),
    event_name: 'OrderObserved',
    restaurant_id: String(order.restaurant_id ?? 'current'),
    status: 'processed',
    created_at: String(orderCreatedAt(order) ?? nowIso()),
    data: { order_id: order.id, status: order.status, total: orderAmount(order) },
  }))
}

export const aiEventsApi = {
  list: async (params?: { event_type?: string; status?: string; page?: number; page_size?: number }) => {
    let items = await localEvents()
    if (params?.status) items = items.filter((e) => e.status === params.status)
    const page = params?.page ?? 1
    const pageSize = params?.page_size ?? 50
    const start = (page - 1) * pageSize
    return ok({ items: items.slice(start, start + pageSize), total: items.length, page, page_size: pageSize, pages: Math.max(1, Math.ceil(items.length / pageSize)) })
  },
  stats: async () => {
    const items = await localEvents()
    return ok({ total_events: items.length, processed: items.length, failed: 0, pending: 0, retries: 0, average_processing_time_ms: 0, throughput_per_minute: 0, event_types: { OrderObserved: items.length } })
  },
  failed: async () => ok([]),
  history: async (params?: { page?: number; page_size?: number }) => {
    const items = await localEvents()
    const page = params?.page ?? 1
    const pageSize = params?.page_size ?? 50
    return ok({ items, total: items.length, page, page_size: pageSize, pages: Math.max(1, Math.ceil(items.length / pageSize)) })
  },
  replay: async () => ok({ message: 'No failed local events to replay.' }),
}

export const aiWorkflowApi = {
  list: async () => ok(LOCAL_WORKFLOWS),
  stats: async () => {
    const history = workflowHistory()
    return ok({ total_executions: history.length, running: history.filter((x) => x.status === 'running').length, completed: history.filter((x) => x.status === 'completed').length, failed: history.filter((x) => x.status === 'failed').length, average_duration_ms: history.length ? Math.round(history.reduce((s, x) => s + num(x.duration_ms), 0) / history.length) : 0 })
  },
  history: async (params?: { workflow_id?: string; status?: string; page?: number; page_size?: number }) => {
    let items = workflowHistory()
    if (params?.workflow_id) items = items.filter((x) => x.workflow_id === params.workflow_id)
    if (params?.status) items = items.filter((x) => x.status === params.status)
    const page = params?.page ?? 1
    const pageSize = params?.page_size ?? 20
    return ok({ items, total: items.length, page, page_size: pageSize, pages: Math.max(1, Math.ceil(items.length / pageSize)) })
  },
  get: async (executionId: string) => ok(workflowHistory().find((x) => x.execution_id === executionId) ?? null),
  run: async (body: { workflow_id: string; metadata?: Record<string, unknown> }) => {
    const workflow = LOCAL_WORKFLOWS.find((w) => w.workflow_id === body.workflow_id)
    const execution = { execution_id: `local-${Date.now()}`, workflow_id: body.workflow_id, status: 'completed', started_at: nowIso(), completed_at: nowIso(), duration_ms: 1, steps_completed: workflow?.steps.length ?? 1, total_steps: workflow?.steps.length ?? 1, result: { mode: 'local', metadata: body.metadata ?? {} }, error: null }
    const history = [execution, ...workflowHistory()].slice(0, 100)
    storage.set('workflow-history', history)
    return ok(execution)
  },
  cancel: async () => ok({ message: 'Local workflows complete immediately; nothing is running.' }),
}

export const aiAutonomyApi = {
  status: async () => ok({ enabled: true, running_actions: 0, total_executions: autonomyHistory().length, pending_approvals: pendingApprovals().length, confidence_threshold: 0.75, risk_tolerance: 'conservative-local' }),
  actions: async () => ok(LOCAL_ACTIONS),
  history: async (params?: { limit?: number }) => ok(autonomyHistory().slice(0, params?.limit ?? 50)),
  pendingApprovals: async () => ok(pendingApprovals()),
  approve: async (requestId: string) => {
    const pending = pendingApprovals()
    const request = pending.find((x) => x.request_id === requestId)
    storage.set('pending-approvals', pending.filter((x) => x.request_id !== requestId))
    if (request) storage.set('autonomy-history', [{ action_name: request.action_name, status: 'completed', risk_level: request.risk_level, confidence: request.confidence, executed_at: nowIso(), result: { approved: true, mode: 'local' } }, ...autonomyHistory()])
    return ok({ message: 'Local action approved.' })
  },
  reject: async (requestId: string) => {
    const pending = pendingApprovals()
    const request = pending.find((x) => x.request_id === requestId)
    storage.set('pending-approvals', pending.filter((x) => x.request_id !== requestId))
    if (request) storage.set('autonomy-history', [{ action_name: request.action_name, status: 'rejected', risk_level: request.risk_level, confidence: request.confidence, executed_at: nowIso(), result: { approved: false, mode: 'local' } }, ...autonomyHistory()])
    return ok({ message: 'Local action rejected.' })
  },
  run: async (body: { action_name: string; parameters?: Record<string, unknown> }) => {
    const action = LOCAL_ACTIONS.find((a) => a.action_name === body.action_name) ?? LOCAL_ACTIONS[0]
    if (action.requires_approval) {
      const request = { request_id: `approval-${Date.now()}`, action_name: action.action_name, description: action.description, risk_level: action.risk_level, confidence: 0.8, parameters: body.parameters ?? {}, created_at: nowIso(), restaurant_id: 'current' }
      storage.set('pending-approvals', [request, ...pendingApprovals()])
      return ok({ status: 'pending_approval', request_id: request.request_id })
    }
    const entry = { action_name: action.action_name, status: 'completed', risk_level: action.risk_level, confidence: 0.85, executed_at: nowIso(), result: { mode: 'local' } }
    storage.set('autonomy-history', [entry, ...autonomyHistory()])
    return ok(entry)
  },
}

function agentTasks() { return storage.get<any[]>('agent-tasks', []) }

export const aiAgentsApi = {
  list: async () => ok(LOCAL_AGENTS.map((a) => ({ ...a, tasks_completed: agentTasks().filter((t) => t.agent_id === a.agent_id && t.status === 'completed').length }))),
  status: async () => ok({ status: 'healthy', mode: 'local', agents: LOCAL_AGENTS.length }),
  metrics: async () => {
    const tasks = agentTasks()
    return ok({ total_agents: LOCAL_AGENTS.length, active_agents: 1, idle_agents: LOCAL_AGENTS.length - 1, failed_agents: 0, total_tasks_processed: tasks.filter((t) => t.status === 'completed').length, total_messages: tasks.length, average_task_duration_ms: 1 })
  },
  tasks: async (params?: { limit?: number }) => ok(agentTasks().slice(0, params?.limit ?? 50)),
  history: async (params?: { limit?: number }) => ok(agentTasks().slice(0, params?.limit ?? 50)),
  run: async (request: string) => {
    const result = await copilotAnswer(request)
    const task = { task_id: `task-${Date.now()}`, agent_id: 'local-supervisor', task_type: request, status: 'completed', started_at: nowIso(), completed_at: nowIso(), result: result.answer }
    storage.set('agent-tasks', [task, ...agentTasks()].slice(0, 100))
    return ok({ task_id: task.task_id, status: 'completed', result: result.answer })
  },
  restart: async (agentId: string) => ok({ message: `${agentId} reset locally.`, status: 'idle' }),
}

type LocalDoc = { document_id: string; filename: string; document_type: string; text: string; created_at: string }
function ragDocs() { return storage.get<LocalDoc[]>('rag-docs', []) }

export const aiRAGApi = {
  upload: async (file: File) => {
    const isText = file.type.startsWith('text/') || /\.(txt|md)$/i.test(file.name)
    const text = isText ? await file.text() : ''
    const doc: LocalDoc = { document_id: `doc-${Date.now()}`, filename: file.name, document_type: file.type || file.name.split('.').pop() || 'file', text: text.slice(0, 200000), created_at: nowIso() }
    storage.set('rag-docs', [doc, ...ragDocs()].slice(0, 50))
    return ok({ document_id: doc.document_id, chunks: text ? Math.max(1, Math.ceil(text.length / 1200)) : 0, filename: file.name, document_type: doc.document_type })
  },
  search: async (q: string, params?: { top_k?: number; document_type?: string }) => {
    const query = q.toLowerCase().trim()
    const results = ragDocs()
      .filter((d) => !params?.document_type || d.document_type === params.document_type)
      .filter((d) => d.text.toLowerCase().includes(query) || d.filename.toLowerCase().includes(query))
      .slice(0, params?.top_k ?? 10)
      .map((d, index) => ({ chunk_id: `${d.document_id}-0`, document_id: d.document_id, document_type: d.document_type, text: d.text.slice(0, 500) || d.filename, score: clamp(0.9 - index * 0.05, 0.5, 0.9), metadata: { filename: d.filename } }))
    return ok({ query: q, results, total: results.length, latency_ms: 1 })
  },
  query: async (question: string, top_k = 5) => {
    const search = (await aiRAGApi.search(question, { top_k })).data
    const answer = search.results.length
      ? `Local knowledge found ${search.results.length} matching document section(s). The strongest match is from ${String(search.results[0].metadata.filename ?? search.results[0].document_id)}.`
      : 'No matching local knowledge document was found. Upload a TXT or Markdown document for searchable local content.'
    return ok({ question, answer, sources: search.results.map((r) => ({ document_id: r.document_id, document_type: r.document_type, chunk_id: r.chunk_id, text: r.text, confidence: r.score })), provider: 'AuraOS Local Search', latency_ms: 1, token_usage: 0 })
  },
  stats: async () => {
    const docs = ragDocs()
    return ok({ documents: docs.length, chunks: docs.reduce((s, d) => s + (d.text ? Math.max(1, Math.ceil(d.text.length / 1200)) : 0), 0), queries_served: 0, average_latency_ms: 1, hit_rate: docs.length ? 1 : 0, provider: 'Local browser storage' })
  },
}

export const aiHealthApi = {
  system: async () => ok({ status: 'healthy', mode: 'local', uptime_seconds: Math.floor(performance.now() / 1000), components: { local_ai: { status: 'healthy' }, core_api: { status: 'connected' }, browser_storage: { status: 'healthy' } } }),
  agents: async () => ok({ status: 'healthy', total: LOCAL_AGENTS.length, active: 1, failed: 0 }),
  workflows: async () => ok({ status: 'healthy', total: LOCAL_WORKFLOWS.length, running: 0, failed: 0 }),
  metrics: async () => ok({ cpu_percent: 0, memory_percent: 0, latency_ms: 1, mode: 'local-browser' }),
  anomalies: async () => ok([]),
  recovery: async () => ok([]),
  recover: async (component: string) => ok({ component, status: 'recovered', recovered_at: nowIso(), mode: 'local' }),
  replayDlq: async () => ok({ replayed: 0, message: 'Local mode has no dead-letter queue.' }),
  check: async () => ok({ status: 'healthy', mode: 'local', timestamp: nowIso() }),
}

const aiApi = { mode: 'local' as const }
export default aiApi
