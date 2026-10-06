// FASE 03B.3B — camada fina da API de Mensalistas (visão mensal) sobre as 6 RPCs da 03B.3A (puro: sem
// Next, sem Supabase). O route só injeta a chamada RPC da SESSÃO do usuário; nunca service-role. Aqui:
// rotear, validar formato (allowlist de query/body), montar argumentos e mapear erro. Autorização
// (vínculo ATIVO real), tenant, saldos, status e regras financeiras continuam sendo decididos no banco.
// Diferença deliberada em relação à RPC: expected_open é OBRIGATÓRIO no "Receber mês" (regra do freeze).
import { isUuid } from './finance-api.js'
import { normalizeFinanceNotes, PAYMENT_METHODS } from './finance.js'
import { isMovementInstant, parseJsonBody } from './expenses-api.js'
import { RM_PREFIX, isMonthParam, monthToDate, MONTH_FILTERS, MONTH_REASON_MSG, MONTH_PAYMENT_MAX_CENTS, normalizePhoneDigits } from './recurring-month.js'

export { RM_PREFIX }

export const RM_LIST_LIMIT_MAX = 100
export const RM_SEARCH_LIMIT_MAX = 20
export const RM_Q_MAX_CHARS = 100
export const RM_CUSTOMER_NAME_MAX = 120

export const RM_ERRORS = {
  unauthenticated: 'Sessão expirada. Entre novamente.',
  notFound: 'Rota não encontrada',
  lineageNotFound: 'Mensalista não encontrado.',
  lineageOrCustomerNotFound: 'Mensalista ou cliente não encontrado.',
  orgNotFound: 'Organização não encontrada.',
  forbidden: 'Sem permissão para esta ação nos mensalistas desta organização.',
  invalid: 'Parâmetros inválidos.',
  body: 'Corpo da requisição inválido.',
  state: 'A situação atual não permite esta operação. Atualize e tente novamente.',
  limit: 'Valor acima do permitido para esta operação.',
  idempotency: 'Esta operação já foi utilizada com dados diferentes. Atualize e tente novamente.',
  tenant: 'Os dados informados não pertencem à mesma organização.',
  busy: 'Operação concorrente em andamento. Tente novamente em instantes.',
  internal: 'Erro interno. Tente novamente.',
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k)
const chars = (s) => [...s].length
const fail = (error = RM_ERRORS.invalid) => ({ ok: false, status: 400, error })
const LIMIT_RE = /^[1-9]\d{0,2}$/

// Parâmetro de query: ausente/vazio => null; repetido ou fora da allowlist => inválido.
function readQuery(sp, allowed) {
  const out = {}
  for (const k of new Set(sp.keys())) if (!allowed.includes(k)) return null
  for (const k of allowed) {
    const all = sp.getAll(k)
    if (all.length > 1) return null
    out[k] = all.length === 0 || all[0] === '' ? null : all[0]
  }
  return out
}
function limitOf(v, max, dflt) {
  if (v === null) return dflt
  if (!LIMIT_RE.test(v)) return null
  const n = Number(v)
  return n >= 1 && n <= max ? n : null
}
function qOf(v) {
  if (v === null) return { ok: true, value: null }
  const t = v.trim()
  if (chars(t) > RM_Q_MAX_CHARS) return { ok: false }
  return { ok: true, value: t || null }
}

/** /api/recurring-month[/a[/b]] -> [] | [a] | [a, b]; qualquer outra forma => null. */
export function recurringMonthPathSegments(pathname) {
  if (typeof pathname !== 'string') return null
  if (pathname === RM_PREFIX) return []
  if (!pathname.startsWith(`${RM_PREFIX}/`)) return null
  const segs = pathname.slice(RM_PREFIX.length + 1).split('/')
  return segs.length >= 1 && segs.length <= 2 && segs.every((s) => s.length > 0) ? segs : null
}

// ------------------------------------------------------------------ leituras
function parseList(sp) {
  const p = readQuery(sp, ['organization_id', 'month', 'arena_id', 'status', 'q', 'limit', 'cursor_nc', 'cursor_name', 'cursor_lineage'])
  if (!p) return fail()
  if (!isUuid(p.organization_id)) return fail('Organização inválida.')
  if (!isMonthParam(p.month)) return fail('Mês inválido.')
  if (p.arena_id !== null && !isUuid(p.arena_id)) return fail('Arena inválida.')
  if (p.status !== null && !MONTH_FILTERS.includes(p.status)) return fail('Situação inválida.')
  const q = qOf(p.q)
  if (!q.ok) return fail('Busca muito longa.')
  const limit = limitOf(p.limit, RM_LIST_LIMIT_MAX, 50)
  if (limit === null) return fail('Limite inválido.')
  const cur = [p.cursor_nc, p.cursor_name, p.cursor_lineage]
  let cursor = null
  if (cur.some((v) => v !== null)) {
    // nome do cursor pode ser vazio (linhagem sem cliente): só nc e lineage são obrigatórios
    if (!['true', 'false'].includes(p.cursor_nc) || !isUuid(p.cursor_lineage)) return fail('Cursor inválido.')
    const name = p.cursor_name ?? ''
    if (chars(name) > 200) return fail('Cursor inválido.')
    cursor = { nc: p.cursor_nc === 'true', name, lineage: p.cursor_lineage }
  }
  return {
    ok: true, rpc: 'rg_recurring_month_list',
    args: { p_org: p.organization_id, p_arena: p.arena_id, p_month: monthToDate(p.month), p_status: p.status, p_q: q.value, p_limit: limit, p_cursor: cursor },
  }
}
function parseSearch(sp) {
  const p = readQuery(sp, ['organization_id', 'month', 'q', 'limit'])
  if (!p) return fail()
  if (!isUuid(p.organization_id)) return fail('Organização inválida.')
  if (!isMonthParam(p.month)) return fail('Mês inválido.')
  const q = qOf(p.q)
  if (!q.ok) return fail('Busca muito longa.')
  const limit = limitOf(p.limit, RM_SEARCH_LIMIT_MAX, RM_SEARCH_LIMIT_MAX)
  if (limit === null) return fail('Limite inválido.')
  return { ok: true, rpc: 'rg_recurring_month_search', args: { p_org: p.organization_id, p_month: monthToDate(p.month), p_q: q.value, p_limit: limit } }
}
function parseDetail(id, sp) {
  const p = readQuery(sp, ['month'])
  if (!p) return fail()
  if (!isMonthParam(p.month)) return fail('Mês inválido.')
  return { ok: true, rpc: 'rg_recurring_month_detail', args: { p_lineage_id: id, p_month: monthToDate(p.month) } }
}

// ------------------------------------------------------------------ escritas
function onlyKeys(b, allowed, required = []) {
  for (const k of Object.keys(b)) if (!allowed.includes(k)) return false
  return required.every((k) => has(b, k))
}
const isCents = (v, min, max) => Number.isSafeInteger(v) && v >= min && v <= max

export function parseMonthPayment(id, b) {
  if (!onlyKeys(b, ['operation_id', 'month', 'amount', 'method', 'received_at', 'notes', 'expected_open'],
    ['operation_id', 'month', 'amount', 'method', 'received_at', 'expected_open'])) return fail(RM_ERRORS.body)
  if (!isUuid(b.operation_id)) return fail('operation_id inválido.')
  if (!isMonthParam(b.month)) return fail('Mês inválido.')
  if (!isCents(b.amount, 1, MONTH_PAYMENT_MAX_CENTS)) return fail('Valor inválido.')
  if (!PAYMENT_METHODS.includes(b.method)) return fail('Meio de pagamento inválido.')
  if (!isMovementInstant(b.received_at)) return fail('Data do recebimento inválida.')
  // obrigatório na API: o saldo que o usuário confirmou na tela (STATE_CHANGED se divergir no banco)
  if (!Number.isSafeInteger(b.expected_open) || b.expected_open < 0) return fail('Saldo confirmado (expected_open) obrigatório.')
  const n = normalizeFinanceNotes(has(b, 'notes') ? b.notes : null)
  if (!n.ok) return fail('Observação inválida.')
  return {
    ok: true, rpc: 'rg_recurring_month_payment_record',
    args: { p_operation_id: b.operation_id, p_lineage_id: id, p_month: monthToDate(b.month), p_amount: b.amount, p_method: b.method,
      p_received_at: b.received_at, p_notes: n.value, p_expected_open: b.expected_open },
  }
}
export function parseLinkCustomer(id, b) {
  const byId = has(b, 'customer_id')
  const byData = has(b, 'customer')
  if (byId === byData) return fail(RM_ERRORS.body)
  if (byId) {
    if (!onlyKeys(b, ['customer_id']) || !isUuid(b.customer_id)) return fail('Cliente inválido.')
    return { ok: true, rpc: 'rg_recurring_link_customer', args: { p_lineage_id: id, p_customer_id: b.customer_id, p_customer: null } }
  }
  const c = b.customer
  if (!onlyKeys(b, ['customer']) || c === null || typeof c !== 'object' || Array.isArray(c) || !onlyKeys(c, ['name', 'phone'], ['name'])) return fail(RM_ERRORS.body)
  const name = typeof c.name === 'string' ? c.name.replace(/\s+/g, ' ').trim() : ''
  if (!name || chars(name) > RM_CUSTOMER_NAME_MAX) return fail('Nome do cliente inválido.')
  if (has(c, 'phone') && c.phone !== null && typeof c.phone !== 'string') return fail('Telefone inválido.')
  const phone = normalizePhoneDigits(c.phone ?? '')
  if (phone && (phone.length < 8 || phone.length > 15)) return fail('Telefone inválido.')
  return { ok: true, rpc: 'rg_recurring_link_customer', args: { p_lineage_id: id, p_customer_id: null, p_customer: { name, phone: phone || null } } }
}
export function parseApplySeriesPrice(id, b) {
  if (!onlyKeys(b, ['month'], ['month']) || !isMonthParam(b.month)) return fail(RM_ERRORS.body)
  return { ok: true, rpc: 'rg_recurring_month_apply_series_price', args: { p_lineage_id: id, p_month: monthToDate(b.month) } }
}

// ------------------------------------------------------------------ roteamento
/** Método + segmentos -> operação; null => 404. */
export function resolveRecurringMonthRoute(method, segs) {
  if (!Array.isArray(segs) || segs.length > 2) return null
  if (segs.length === 0) return method === 'GET' ? { kind: 'list' } : null
  const [a, b] = segs
  if (a === 'search') return method === 'GET' && b === undefined ? { kind: 'search' } : null
  if (b === undefined) return method === 'GET' ? { kind: 'detail', id: a } : null
  if (method !== 'POST') return null
  if (b === 'payments') return { kind: 'write', id: a, parse: parseMonthPayment, created: (d) => d?.idempotent === false }
  if (b === 'customer') return { kind: 'write', id: a, parse: parseLinkCustomer }
  if (b === 'apply-series-price') return { kind: 'write', id: a, parse: parseApplySeriesPrice }
  return null
}

// ------------------------------------------------------------------ erros
// Erro da RPC -> HTTP. Nunca devolve mensagem/detalhe/SQL/stack do banco ao cliente.
export function mapRecurringMonthError(error, { notFound = RM_ERRORS.lineageNotFound } = {}) {
  const code = error?.code
  const hint = typeof error?.hint === 'string' && has(MONTH_REASON_MSG, error.hint) ? error.hint : null
  if (code === '42501') return { status: 403, body: { error: RM_ERRORS.forbidden } }
  if (code === 'P0002') return { status: 404, body: { error: notFound } }
  if (code === 'RGP02') return { status: 409, body: { error: RM_ERRORS.idempotency, code: 'IDEMPOTENCY_MISMATCH' } }
  if (code === 'RGP01') return { status: 409, body: { error: hint ? MONTH_REASON_MSG[hint] : RM_ERRORS.state, code: 'FINANCE_STATE', ...(hint && { reason: hint }) } }
  if (code === 'RGP03') return { status: 409, body: { error: hint ? MONTH_REASON_MSG[hint] : RM_ERRORS.limit, code: 'FINANCE_LIMIT', ...(hint && { reason: hint }) } }
  if (code === 'RGR01') return { status: 409, body: { error: hint ? MONTH_REASON_MSG[hint] : RM_ERRORS.state, code: 'RECURRING_STATE', ...(hint && { reason: hint }) } }
  if (code === 'RGT01' || code === 'RGT02') return { status: 400, body: { error: RM_ERRORS.tenant } }
  if (['22023', '23514', '23502', '23503', '22P02', '22007', '22008', 'P0001'].includes(code)) return { status: 400, body: { error: RM_ERRORS.invalid } }
  if (['40001', '40P01', '55P03'].includes(code)) return { status: 503, body: { error: RM_ERRORS.busy } }
  return { status: 500, body: { error: RM_ERRORS.internal } }
}

// ------------------------------------------------------------------ execução
// `callRpc(name, args)` => Promise<{ data, error }> do client da SESSÃO. Sempre resolve { status, body };
// quem chama devolve com Cache-Control: no-store.
export async function runRecurringMonthRoute({ method, segments, searchParams, rawBody, user, callRpc, log = console.error }) {
  if (!user) return { status: 401, body: { error: RM_ERRORS.unauthenticated } }
  const route = resolveRecurringMonthRoute(method, segments)
  if (!route) return { status: 404, body: { error: RM_ERRORS.notFound } }
  if (route.id !== undefined && !isUuid(route.id)) return { status: 404, body: { error: RM_ERRORS.lineageNotFound } }

  let parsed
  if (route.kind === 'list') parsed = parseList(searchParams)
  else if (route.kind === 'search') parsed = parseSearch(searchParams)
  else if (route.kind === 'detail') parsed = parseDetail(route.id, searchParams)
  else {
    if ([...searchParams.keys()].length > 0) return { status: 400, body: { error: RM_ERRORS.invalid } }
    const b = parseJsonBody(rawBody)
    if (!b) return { status: 400, body: { error: RM_ERRORS.body } }
    parsed = route.parse(route.id, b)
  }
  if (!parsed.ok) return { status: parsed.status, body: { error: parsed.error } }

  const notFound = route.kind === 'search' || route.kind === 'list' ? RM_ERRORS.orgNotFound
    : parsed.rpc === 'rg_recurring_link_customer' ? RM_ERRORS.lineageOrCustomerNotFound : RM_ERRORS.lineageNotFound
  try {
    const { data, error } = await callRpc(parsed.rpc, parsed.args)
    if (error) {
      const mapped = mapRecurringMonthError(error, { notFound })
      if (mapped.status === 500) log('rpc mensalistas 03B.3B', parsed.rpc, error?.code || 'sem código')
      return mapped
    }
    if (data === null || data === undefined || typeof data !== 'object' || Array.isArray(data)) {
      log('rpc mensalistas 03B.3B', parsed.rpc, 'resposta vazia')
      return { status: 500, body: { error: RM_ERRORS.internal } }
    }
    return { status: route.created && route.created(data) ? 201 : 200, body: data }
  } catch {
    log('rpc mensalistas 03B.3B', parsed.rpc, 'exceção')
    return { status: 500, body: { error: RM_ERRORS.internal } }
  }
}
