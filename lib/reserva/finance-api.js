// FASE 03B.1 — camada fina da API do Financeiro sobre as RPCs rg_fin_* (puro: sem Next, sem Supabase).
// O route só injeta a chamada RPC da SESSÃO do usuário; nunca service-role. Aqui: validar formato,
// montar argumentos e mapear erro. Autorização (OWNER/MANAGER da organização), tenant da arena e
// limites finais continuam sendo decididos no banco (private.rg_fin_scope).
import { isValidDateStr } from './time.js'
import { periodDays, MAX_PERIOD_DAYS } from './finance-period.js'

export const FINANCE_ENDPOINTS = {
  overview: 'rg_fin_overview',
  receivables: 'rg_fin_receivables',
  cashflow: 'rg_fin_cashflow',
  'cash-entries': 'rg_fin_cash_entries',
}
export const RECEIVABLE_FILTERS = ['OPEN', 'OVERDUE', 'UPCOMING', 'UNPRICED']
export const CASHFLOW_GRANULARITIES = ['day', 'month', 'year']
export const PAGE_LIMIT_DEFAULT = 50
export const PAGE_LIMIT_MAX = 200 // mesmo teto das RPCs

export const FINANCE_ERRORS = {
  unauthenticated: 'Não autenticado',
  forbidden: 'Sem permissão para ver o financeiro desta organização.',
  invalid: 'Parâmetros inválidos.',
  notFound: 'Rota não encontrada',
  internal: 'Erro interno do servidor',
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// Instante ISO 8601 com fuso explícito (como o banco devolve no next_cursor).
const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/
const LIMIT_RE = /^[1-9]\d{0,2}$/

export function isUuid(v) { return typeof v === 'string' && UUID_RE.test(v) }
export function isInstant(v) { return typeof v === 'string' && v.length <= 40 && INSTANT_RE.test(v) && !Number.isNaN(Date.parse(v)) }

// Parâmetro de query: ausente/vazio => null. Repetido (?a=1&a=2) => inválido.
function param(sp, key) {
  const all = sp.getAll(key)
  if (all.length > 1) return { bad: true }
  const v = all[0]
  return { value: v === undefined || v === '' ? null : v }
}

const fail = (error = FINANCE_ERRORS.invalid) => ({ ok: false, status: 400, error })

// Valida a query de um endpoint e devolve { ok, rpc, args } ou { ok: false, status, error }.
export function parseFinanceQuery(endpoint, sp) {
  const rpc = FINANCE_ENDPOINTS[endpoint]
  if (!Object.prototype.hasOwnProperty.call(FINANCE_ENDPOINTS, endpoint)) return { ok: false, status: 404, error: FINANCE_ERRORS.notFound }
  const p = {}
  for (const k of ['organization_id', 'arena_id', 'from', 'to', 'compare_from', 'compare_to', 'filter', 'limit', 'after_start', 'after_at', 'after_id', 'granularity']) {
    const r = param(sp, k)
    if (r.bad) return fail()
    p[k] = r.value
  }
  if (!isUuid(p.organization_id)) return fail('Organização inválida.')
  if (p.arena_id !== null && !isUuid(p.arena_id)) return fail('Arena inválida.')
  if (!isValidDateStr(p.from) || !isValidDateStr(p.to)) return fail('Período inválido.')
  const days = periodDays(p.from, p.to)
  if (days < 1) return fail('Período inválido.')
  if (days > MAX_PERIOD_DAYS) return fail(`Período acima do limite de ${MAX_PERIOD_DAYS} dias.`)
  const args = { p_org: p.organization_id, p_arena: p.arena_id, p_from: p.from, p_to: p.to }

  const allowed = { overview: ['compare_from', 'compare_to'], receivables: ['filter', 'limit', 'after_start', 'after_id'], cashflow: ['granularity'], 'cash-entries': ['limit', 'after_at', 'after_id'] }[endpoint]
  for (const k of ['compare_from', 'compare_to', 'filter', 'limit', 'after_start', 'after_at', 'after_id', 'granularity']) {
    if (p[k] !== null && !allowed.includes(k)) return fail()
  }

  const limitOf = () => {
    if (p.limit === null) return PAGE_LIMIT_DEFAULT
    if (!LIMIT_RE.test(p.limit)) return null
    const n = Number(p.limit)
    return n >= 1 && n <= PAGE_LIMIT_MAX ? n : null
  }

  if (endpoint === 'overview') {
    if ((p.compare_from === null) !== (p.compare_to === null)) return fail('Período de comparação inválido.')
    if (p.compare_from !== null) {
      if (!isValidDateStr(p.compare_from) || !isValidDateStr(p.compare_to)) return fail('Período de comparação inválido.')
      const cd = periodDays(p.compare_from, p.compare_to)
      // comparação sempre termina ANTES do período atual
      if (cd < 1 || cd > MAX_PERIOD_DAYS || periodDays(p.compare_to, p.from) < 2) return fail('Período de comparação inválido.')
      args.p_compare_from = p.compare_from
      args.p_compare_to = p.compare_to
    }
  } else if (endpoint === 'receivables') {
    const filter = p.filter === null ? 'OPEN' : p.filter
    if (!RECEIVABLE_FILTERS.includes(filter)) return fail('Filtro inválido.')
    const limit = limitOf()
    if (limit === null) return fail('Limite inválido.')
    if ((p.after_start === null) !== (p.after_id === null)) return fail('Cursor inválido.')
    if (p.after_start !== null && (!isInstant(p.after_start) || !isUuid(p.after_id))) return fail('Cursor inválido.')
    Object.assign(args, { p_filter: filter, p_limit: limit, p_after_start: p.after_start, p_after_id: p.after_id })
  } else if (endpoint === 'cashflow') {
    const g = p.granularity === null ? 'day' : p.granularity
    if (!CASHFLOW_GRANULARITIES.includes(g)) return fail('Granularidade inválida.')
    args.p_granularity = g
  } else {
    const limit = limitOf()
    if (limit === null) return fail('Limite inválido.')
    if ((p.after_at === null) !== (p.after_id === null)) return fail('Cursor inválido.')
    if (p.after_at !== null && (!isInstant(p.after_at) || !isUuid(p.after_id))) return fail('Cursor inválido.')
    Object.assign(args, { p_limit: limit, p_after_at: p.after_at, p_after_id: p.after_id })
  }
  return { ok: true, rpc, args }
}

// Erro da RPC -> HTTP. Nunca devolve mensagem/código/SQL/stack do banco ao cliente.
export function mapFinanceError(error) {
  const code = error?.code
  if (code === '42501') return { status: 403, body: { error: FINANCE_ERRORS.forbidden } }
  if (code === '22023') return { status: 400, body: { error: FINANCE_ERRORS.invalid } }
  return { status: 500, body: { error: FINANCE_ERRORS.internal } }
}

// Executa um endpoint. `callRpc(name, args)` => Promise<{ data, error }> do client da sessão.
// Sempre resolve com { status, body }: quem chama devolve com Cache-Control: no-store.
export async function runFinanceEndpoint({ endpoint, searchParams, user, callRpc, log = console.error }) {
  if (!user) return { status: 401, body: { error: FINANCE_ERRORS.unauthenticated } }
  const q = parseFinanceQuery(endpoint, searchParams)
  if (!q.ok) return { status: q.status, body: { error: q.error } }
  try {
    const { data, error } = await callRpc(q.rpc, q.args)
    if (error) {
      const mapped = mapFinanceError(error)
      if (mapped.status === 500) log('rpc financeiro 03B.1', q.rpc, error?.code || 'sem código')
      return mapped
    }
    if (data === null || data === undefined || typeof data !== 'object') {
      log('rpc financeiro 03B.1', q.rpc, 'resposta vazia')
      return { status: 500, body: { error: FINANCE_ERRORS.internal } }
    }
    return { status: 200, body: data }
  } catch (err) {
    log('rpc financeiro 03B.1', q.rpc, 'exceção')
    return { status: 500, body: { error: FINANCE_ERRORS.internal } }
  }
}
