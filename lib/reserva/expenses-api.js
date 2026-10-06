// FASE 03B.2B — camada fina da API de Despesas & Caixa sobre as 14 RPCs da 03B.2 (puro: sem Next, sem
// Supabase). O route só injeta a chamada RPC da SESSÃO do usuário; nunca service-role. Aqui: rotear,
// validar formato (allowlist de query/body), montar argumentos e mapear erro. Autorização (vínculo
// ATIVO OWNER/MANAGER), tenant, saldos e regras financeiras continuam sendo decididos no banco.
import { isValidDateStr } from './time.js'
import { periodDays, MAX_PERIOD_DAYS } from './finance-period.js'
import { isUuid, isInstant, FINANCE_ERRORS, PAGE_LIMIT_DEFAULT, PAGE_LIMIT_MAX, CASHFLOW_GRANULARITIES, CASHFLOW_MAX_MONTHS, CASHFLOW_MAX_YEARS } from './finance-api.js'
import { PAYMENT_METHODS, normalizeFinanceNotes } from './finance.js'

// Primeiro segmento depois de /api/finance/ que pertence à 03B.2B (os da 03B.1 seguem em finance-api.js).
export const EXPENSE_ENDPOINTS = ['expense-categories', 'expense-overview', 'expenses', 'expense-payments', 'cash-result', 'cash-movements']
export function isExpenseEndpoint(endpoint) { return EXPENSE_ENDPOINTS.includes(endpoint) }

export const EXPENSE_STATUSES = ['ACTIVE', 'OPEN', 'OVERDUE', 'PAID', 'CANCELLED']
export const EXPENSE_MAX_CENTS = 100000000 // R$ 1.000.000,00 — mesmo teto das constraints da 03B.2
export const DESCRIPTION_MAX_CHARS = 200
export const CATEGORY_NAME_MAX_CHARS = 60
export const REASON_MAX_CHARS = 500
export const BODY_MAX_CHARS = 16384

export const EXPENSE_ERRORS = {
  ...FINANCE_ERRORS,
  forbidden: 'Sem permissão para Despesas & Caixa desta organização.',
  body: 'Corpo da requisição inválido.',
  expenseNotFound: 'Despesa não encontrada.',
  entryNotFound: 'Lançamento não encontrado.',
  categoryNotFound: 'Categoria não encontrada.',
  state: 'A situação atual não permite esta operação. Atualize e tente novamente.',
  limit: 'Valor acima do permitido para esta operação.',
  idempotency: 'Esta operação já foi utilizada com dados diferentes. Atualize e tente novamente.',
  tenant: 'Os dados informados não pertencem à mesma organização.',
  busy: 'Operação concorrente em andamento. Tente novamente em instantes.',
}

// Mensagens por HINT estável das exceções RGP01/RGP03 da 03B.2 (nunca o texto interno da exceção).
export const EXPENSE_HINT_MSG = {
  EXPENSE_CANCELLED: 'Esta despesa está cancelada e não pode ser alterada.',
  AMOUNT_LOCKED: 'O valor não pode mudar depois de um pagamento registrado.',
  ARENA_LOCKED: 'A arena não pode mudar depois de um pagamento registrado.',
  NET_PAID: 'A despesa tem valor pago. Registre a devolução ou anule os pagamentos antes de cancelar.',
  CATEGORY_INACTIVE: 'Esta categoria está inativa. Escolha outra ou reative-a em Categorias.',
  CATEGORY_INACTIVE_EXISTS: 'Já existe uma categoria inativa com esse nome. Reative-a em Categorias.',
  CATEGORY_NAME_EXISTS: 'Já existe uma categoria com esse nome.',
  NOT_A_PAYMENT: 'Somente pagamentos podem ter devolução.',
  PAYMENT_VOIDED: 'Este pagamento foi anulado e não pode ter devolução.',
  HAS_REVERSALS: 'Anule primeiro as devoluções deste pagamento.',
  OVER_BALANCE: 'O valor é maior que o valor a pagar da despesa.',
  OVER_REVERSIBLE: 'A devolução é maior que o valor disponível deste pagamento.',
}

const LIMIT_RE = /^[1-9]\d{0,2}$/
const NOT_FOUND = { status: 404, body: { error: FINANCE_ERRORS.notFound } }
const fail = (error = EXPENSE_ERRORS.invalid) => ({ ok: false, status: 400, error })
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k)
const chars = (s) => [...s].length

// Mesma normalização das RPCs: btrim(regexp_replace(x, '\s+', ' ', 'g')).
export function normalizeExpenseText(v) {
  return typeof v === 'string' ? v.replace(/[ \t\n\v\f\r]+/g, ' ').replace(/^ +| +$/g, '') : null
}
function validText(v, max) { const t = normalizeExpenseText(v); return t !== null && t !== '' && chars(t) <= max }
export function isExpenseAmount(v) { return Number.isSafeInteger(v) && v >= 1 && v <= EXPENSE_MAX_CENTS }
// Instante do movimento: ISO com fuso explícito, entre 2000-01-01 e 2101-01-01 (constraint do banco).
export function isMovementInstant(v) {
  if (!isInstant(v)) return false
  const t = Date.parse(v)
  return t >= Date.UTC(2000, 0, 1) && t < Date.UTC(2101, 0, 1)
}
function cleanReason(v) {
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t && chars(t) <= REASON_MAX_CHARS ? t : null
}

// ------------------------------------------------------------------ query (GET)
// Parâmetro: ausente/vazio => null. Repetido (?a=1&a=2) => inválido.
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
function limitOf(v) {
  if (v === null) return PAGE_LIMIT_DEFAULT
  if (!LIMIT_RE.test(v)) return null
  const n = Number(v)
  return n >= 1 && n <= PAGE_LIMIT_MAX ? n : null
}
// org + arena + período [from, to] (1..366 dias). Devolve erro ou os argumentos base.
function scopeArgs(p, { maxDays = MAX_PERIOD_DAYS, period = true } = {}) {
  if (!isUuid(p.organization_id)) return fail('Organização inválida.')
  if (p.arena_id !== null && p.arena_id !== undefined && !isUuid(p.arena_id)) return fail('Arena inválida.')
  const args = { p_org: p.organization_id }
  if (period) {
    if (!isValidDateStr(p.from) || !isValidDateStr(p.to)) return fail('Período inválido.')
    const days = periodDays(p.from, p.to)
    if (days < 1) return fail('Período inválido.')
    if (days > maxDays) return fail(`Período acima do limite de ${maxDays} dias.`)
    Object.assign(args, { p_arena: p.arena_id ?? null, p_from: p.from, p_to: p.to })
  }
  return { ok: true, args }
}

const QUERY_KEYS = {
  'expense-categories': ['organization_id', 'include_inactive'],
  'expense-overview': ['organization_id', 'arena_id', 'category_id', 'from', 'to', 'compare_from', 'compare_to'],
  expenses: ['organization_id', 'arena_id', 'category_id', 'from', 'to', 'status', 'limit', 'after_due', 'after_id'],
  'cash-result': ['organization_id', 'arena_id', 'from', 'to', 'granularity'],
  'cash-movements': ['organization_id', 'arena_id', 'from', 'to', 'limit', 'after_at', 'after_source', 'after_id'],
}

// Leitura de lista/agregado: { ok, rpc, args } ou { ok: false, status, error }.
export function parseExpenseQuery(endpoint, sp) {
  if (!has(QUERY_KEYS, endpoint)) return { ok: false, status: 404, error: FINANCE_ERRORS.notFound }
  const p = readQuery(sp, QUERY_KEYS[endpoint])
  if (!p) return fail()

  if (endpoint === 'expense-categories') {
    const s = scopeArgs(p, { period: false })
    if (!s.ok) return s
    if (p.include_inactive !== null && !['0', '1'].includes(p.include_inactive)) return fail()
    return { ok: true, rpc: 'rg_expense_categories', args: { p_org: s.args.p_org, p_include_inactive: p.include_inactive === '1' } }
  }

  if (endpoint === 'cash-result') {
    const g = p.granularity === null ? 'day' : p.granularity
    if (!CASHFLOW_GRANULARITIES.includes(g)) return fail('Granularidade inválida.')
    // Mesmo teto de public.rg_fin_cash_result: day 366 dias; month 60 meses-calendário; year 10 anos.
    const s = scopeArgs(p, { maxDays: g === 'day' ? MAX_PERIOD_DAYS : 3660 })
    if (!s.ok) return s
    const fy = Number(p.from.slice(0, 4)), fm = Number(p.from.slice(5, 7))
    const ty = Number(p.to.slice(0, 4)), tm = Number(p.to.slice(5, 7))
    if (g === 'month' && (ty * 12 + tm) - (fy * 12 + fm) + 1 > CASHFLOW_MAX_MONTHS) return fail(`Período acima do limite de ${CASHFLOW_MAX_MONTHS} meses.`)
    if (g === 'year' && ty - fy + 1 > CASHFLOW_MAX_YEARS) return fail(`Período acima do limite de ${CASHFLOW_MAX_YEARS} anos.`)
    return { ok: true, rpc: 'rg_fin_cash_result', args: { ...s.args, p_granularity: g } }
  }

  const s = scopeArgs(p)
  if (!s.ok) return s
  const args = s.args

  if (endpoint === 'cash-movements') {
    const limit = limitOf(p.limit)
    if (limit === null) return fail('Limite inválido.')
    const parts = [p.after_at, p.after_source, p.after_id]
    if (parts.some((x) => x === null) && !parts.every((x) => x === null)) return fail('Cursor inválido.')
    let source = null
    if (p.after_at !== null) {
      if (!isInstant(p.after_at) || !isUuid(p.after_id) || !['1', '2'].includes(p.after_source)) return fail('Cursor inválido.')
      source = Number(p.after_source)
    }
    return { ok: true, rpc: 'rg_fin_cash_movements', args: { ...args, p_limit: limit, p_after_at: p.after_at, p_after_source: source, p_after_id: p.after_id } }
  }

  if (p.category_id !== null && !isUuid(p.category_id)) return fail('Categoria inválida.')

  if (endpoint === 'expense-overview') {
    if ((p.compare_from === null) !== (p.compare_to === null)) return fail('Período de comparação inválido.')
    if (p.compare_from !== null) {
      if (!isValidDateStr(p.compare_from) || !isValidDateStr(p.compare_to)) return fail('Período de comparação inválido.')
      const cd = periodDays(p.compare_from, p.compare_to)
      if (cd < 1 || cd > MAX_PERIOD_DAYS || periodDays(p.compare_to, p.from) < 2) return fail('Período de comparação inválido.')
    }
    return {
      ok: true, rpc: 'rg_expense_overview',
      args: { p_org: args.p_org, p_arena: args.p_arena, p_category: p.category_id, p_from: args.p_from, p_to: args.p_to, p_compare_from: p.compare_from, p_compare_to: p.compare_to },
    }
  }

  // expenses
  const status = p.status === null ? 'ACTIVE' : p.status
  if (!EXPENSE_STATUSES.includes(status)) return fail('Filtro inválido.')
  const limit = limitOf(p.limit)
  if (limit === null) return fail('Limite inválido.')
  if ((p.after_due === null) !== (p.after_id === null)) return fail('Cursor inválido.')
  if (p.after_due !== null && (!isValidDateStr(p.after_due) || !isUuid(p.after_id))) return fail('Cursor inválido.')
  return {
    ok: true, rpc: 'rg_expenses',
    args: { p_org: args.p_org, p_arena: args.p_arena, p_category: p.category_id, p_from: args.p_from, p_to: args.p_to, p_status: status, p_limit: limit, p_after_due: p.after_due, p_after_id: p.after_id },
  }
}

// ------------------------------------------------------------------ body (POST/PATCH)
// Corpo JSON obrigatoriamente objeto, até BODY_MAX_CHARS. Qualquer outra coisa => null.
export function parseJsonBody(raw) {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > BODY_MAX_CHARS) return null
  let v
  try { v = JSON.parse(raw) } catch { return null }
  return v !== null && typeof v === 'object' && !Array.isArray(v) ? v : null
}
function onlyKeys(b, allowed, required = []) {
  for (const k of Object.keys(b)) if (!allowed.includes(k)) return false
  return required.every((k) => has(b, k))
}
function notesOf(b) {
  if (!has(b, 'notes')) return { ok: true, value: null }
  return normalizeFinanceNotes(b.notes)
}

export function parseCategoryCreate(b) {
  if (!onlyKeys(b, ['organization_id', 'name'], ['organization_id', 'name'])) return fail()
  if (!isUuid(b.organization_id)) return fail('Organização inválida.')
  if (!validText(b.name, CATEGORY_NAME_MAX_CHARS)) return fail(`Nome da categoria inválido (1 a ${CATEGORY_NAME_MAX_CHARS} caracteres).`)
  return { ok: true, args: { p_org: b.organization_id, p_name: b.name } }
}

export function parseCategoryUpdate(id, b) {
  if (!onlyKeys(b, ['name', 'is_active']) || Object.keys(b).length === 0) return fail()
  const changes = {}
  if (has(b, 'name')) {
    if (!validText(b.name, CATEGORY_NAME_MAX_CHARS)) return fail(`Nome da categoria inválido (1 a ${CATEGORY_NAME_MAX_CHARS} caracteres).`)
    changes.name = b.name
  }
  if (has(b, 'is_active')) {
    if (typeof b.is_active !== 'boolean') return fail()
    changes.is_active = b.is_active
  }
  return { ok: true, args: { p_category_id: id, p_changes: changes } }
}

export function parseExpenseCreate(b) {
  const keys = ['operation_id', 'organization_id', 'arena_id', 'category_id', 'description', 'amount', 'due_date', 'notes']
  if (!onlyKeys(b, keys, ['operation_id', 'organization_id', 'category_id', 'description', 'amount', 'due_date'])) return fail()
  if (!isUuid(b.operation_id)) return fail('Operação inválida. Atualize a página e tente novamente.')
  if (!isUuid(b.organization_id)) return fail('Organização inválida.')
  const arena = has(b, 'arena_id') ? b.arena_id : null
  if (arena !== null && !isUuid(arena)) return fail('Arena inválida.')
  if (!isUuid(b.category_id)) return fail('Categoria inválida.')
  if (!validText(b.description, DESCRIPTION_MAX_CHARS)) return fail(`Descrição inválida (1 a ${DESCRIPTION_MAX_CHARS} caracteres).`)
  if (!isExpenseAmount(b.amount)) return fail('Valor inválido (de R$ 0,01 a R$ 1.000.000,00).')
  if (!isValidDateStr(b.due_date)) return fail('Vencimento inválido.')
  const notes = notesOf(b)
  if (!notes.ok) return fail('Observação inválida (máximo de 500 caracteres).')
  return {
    ok: true,
    args: { p_operation_id: b.operation_id, p_org: b.organization_id, p_arena: arena, p_category: b.category_id, p_description: b.description, p_amount: b.amount, p_due_date: b.due_date, p_notes: notes.value },
  }
}

export function parseExpenseUpdate(id, b) {
  const keys = ['description', 'category_id', 'arena_id', 'amount', 'due_date', 'notes']
  if (!onlyKeys(b, keys) || Object.keys(b).length === 0) return fail()
  const changes = {}
  if (has(b, 'description')) {
    if (!validText(b.description, DESCRIPTION_MAX_CHARS)) return fail(`Descrição inválida (1 a ${DESCRIPTION_MAX_CHARS} caracteres).`)
    changes.description = b.description
  }
  if (has(b, 'category_id')) {
    if (!isUuid(b.category_id)) return fail('Categoria inválida.')
    changes.category_id = b.category_id
  }
  if (has(b, 'arena_id')) {
    if (b.arena_id !== null && !isUuid(b.arena_id)) return fail('Arena inválida.')
    changes.arena_id = b.arena_id
  }
  if (has(b, 'amount')) {
    if (!isExpenseAmount(b.amount)) return fail('Valor inválido (de R$ 0,01 a R$ 1.000.000,00).')
    changes.amount = b.amount
  }
  if (has(b, 'due_date')) {
    if (!isValidDateStr(b.due_date)) return fail('Vencimento inválido.')
    changes.due_date = b.due_date
  }
  if (has(b, 'notes')) {
    const n = normalizeFinanceNotes(b.notes)
    if (!n.ok) return fail('Observação inválida (máximo de 500 caracteres).')
    changes.notes = n.value
  }
  return { ok: true, args: { p_expense_id: id, p_changes: changes } }
}

function parseEntry(b, atKey) {
  if (!onlyKeys(b, ['operation_id', 'method', 'amount', atKey, 'notes'], ['operation_id', 'method', 'amount', atKey])) return fail()
  if (!isUuid(b.operation_id)) return fail('Operação inválida. Atualize a página e tente novamente.')
  if (!PAYMENT_METHODS.includes(b.method)) return fail('Meio de pagamento inválido.')
  if (!isExpenseAmount(b.amount)) return fail('Valor inválido (de R$ 0,01 a R$ 1.000.000,00).')
  if (!isMovementInstant(b[atKey])) return fail('Data do movimento inválida.')
  const notes = notesOf(b)
  if (!notes.ok) return fail('Observação inválida (máximo de 500 caracteres).')
  return { ok: true, value: { op: b.operation_id, method: b.method, amount: b.amount, at: b[atKey], notes: notes.value } }
}
export function parsePaymentRegister(id, b) {
  const e = parseEntry(b, 'paid_at')
  if (!e.ok) return e
  const v = e.value
  return { ok: true, args: { p_operation_id: v.op, p_expense_id: id, p_method: v.method, p_amount: v.amount, p_paid_at: v.at, p_notes: v.notes } }
}
export function parsePaymentReverse(id, b) {
  const e = parseEntry(b, 'reversed_at')
  if (!e.ok) return e
  const v = e.value
  return { ok: true, args: { p_operation_id: v.op, p_payment_id: id, p_method: v.method, p_amount: v.amount, p_reversed_at: v.at, p_notes: v.notes } }
}
function parseReason(b, label) {
  if (!onlyKeys(b, ['reason'], ['reason'])) return fail()
  const reason = cleanReason(b.reason)
  if (!reason) return fail(`Informe o motivo ${label} (até ${REASON_MAX_CHARS} caracteres).`)
  return { ok: true, reason }
}
export function parseExpenseCancel(id, b) {
  const r = parseReason(b, 'do cancelamento')
  return r.ok ? { ok: true, args: { p_expense_id: id, p_reason: r.reason } } : r
}
export function parsePaymentVoid(id, b) {
  const r = parseReason(b, 'da anulação')
  return r.ok ? { ok: true, args: { p_payment_id: id, p_reason: r.reason } } : r
}

// ------------------------------------------------------------------ roteamento
// Segmentos depois de /api/finance/ ("/api/finance/expenses/<id>/payments" => ['expenses', '<id>', 'payments']).
// Segmento vazio (barra dupla/final) ou fora do prefixo => null (404).
export function financePathSegments(pathname) {
  const prefix = '/api/finance/'
  if (typeof pathname !== 'string' || !pathname.startsWith(prefix)) return null
  const segs = pathname.slice(prefix.length).split('/')
  return segs.length >= 1 && segs.length <= 3 && segs.every((s) => s.length > 0) ? segs : null
}

// Resolve método + segmentos em uma operação. null => 404.
export function resolveExpenseRoute(method, segs) {
  if (!Array.isArray(segs) || segs.length < 1 || segs.length > 3) return null
  const [ep, id, sub] = segs
  const key = `${method} ${ep}${id === undefined ? '' : '/:id'}${sub === undefined ? '' : `/${sub}`}`
  const table = {
    'GET expense-categories': { kind: 'read' },
    'POST expense-categories': { kind: 'write', rpc: 'rg_expense_category_create', parse: (b) => parseCategoryCreate(b), created: (d) => d?.created === true },
    'PATCH expense-categories/:id': { kind: 'write', rpc: 'rg_expense_category_update', parse: (b, i) => parseCategoryUpdate(i, b), notFound: EXPENSE_ERRORS.categoryNotFound },
    'GET expense-overview': { kind: 'read' },
    'GET expenses': { kind: 'read' },
    'POST expenses': { kind: 'write', rpc: 'rg_expense_create', parse: (b) => parseExpenseCreate(b), created: (d) => d?.idempotent === false },
    'GET expenses/:id': { kind: 'detail', rpc: 'rg_expense_detail', notFound: EXPENSE_ERRORS.expenseNotFound },
    'PATCH expenses/:id': { kind: 'write', rpc: 'rg_expense_update', parse: (b, i) => parseExpenseUpdate(i, b), notFound: EXPENSE_ERRORS.expenseNotFound },
    'POST expenses/:id/cancel': { kind: 'write', rpc: 'rg_expense_cancel', parse: (b, i) => parseExpenseCancel(i, b), notFound: EXPENSE_ERRORS.expenseNotFound },
    'POST expenses/:id/payments': { kind: 'write', rpc: 'rg_expense_payment_register', parse: (b, i) => parsePaymentRegister(i, b), created: (d) => d?.idempotent === false, notFound: EXPENSE_ERRORS.expenseNotFound },
    'POST expense-payments/:id/reverse': { kind: 'write', rpc: 'rg_expense_payment_reverse', parse: (b, i) => parsePaymentReverse(i, b), created: (d) => d?.idempotent === false, notFound: EXPENSE_ERRORS.entryNotFound },
    'POST expense-payments/:id/void': { kind: 'write', rpc: 'rg_expense_payment_void', parse: (b, i) => parsePaymentVoid(i, b), notFound: EXPENSE_ERRORS.entryNotFound },
    'GET cash-result': { kind: 'read' },
    'GET cash-movements': { kind: 'read' },
  }
  const r = has(table, key) ? table[key] : null
  return r ? { ...r, endpoint: ep, id } : null
}

// ------------------------------------------------------------------ erros
// Erro da RPC -> HTTP. Nunca devolve mensagem/detalhe/SQL/stack do banco ao cliente.
export function mapExpenseError(error, { notFound = EXPENSE_ERRORS.notFound } = {}) {
  const code = error?.code
  const hint = typeof error?.hint === 'string' && has(EXPENSE_HINT_MSG, error.hint) ? error.hint : null
  if (code === '42501') return { status: 403, body: { error: EXPENSE_ERRORS.forbidden } }
  if (code === 'P0002') return { status: 404, body: { error: notFound } }
  if (code === 'RGP02') return { status: 409, body: { error: EXPENSE_ERRORS.idempotency, code: 'IDEMPOTENCY_MISMATCH' } }
  if (code === 'RGP01') return { status: 409, body: { error: hint ? EXPENSE_HINT_MSG[hint] : EXPENSE_ERRORS.state, code: 'FINANCE_STATE', ...(hint && { reason: hint }) } }
  if (code === 'RGP03') return { status: 409, body: { error: hint ? EXPENSE_HINT_MSG[hint] : EXPENSE_ERRORS.limit, code: 'FINANCE_LIMIT', ...(hint && { reason: hint }) } }
  if (code === 'RGT01' || code === 'RGT02') return { status: 400, body: { error: EXPENSE_ERRORS.tenant } }
  if (['22023', '23514', '23502', '23503', '22P02', '22007', '22008', 'P0001'].includes(code)) return { status: 400, body: { error: EXPENSE_ERRORS.invalid } }
  if (['40001', '40P01', '55P03'].includes(code)) return { status: 503, body: { error: EXPENSE_ERRORS.busy } }
  return { status: 500, body: { error: EXPENSE_ERRORS.internal } }
}

// ------------------------------------------------------------------ execução
// `callRpc(name, args)` => Promise<{ data, error }> do client da SESSÃO. `rawBody` = texto do corpo
// (só POST/PATCH). Sempre resolve com { status, body }: quem chama devolve com Cache-Control: no-store.
export async function runExpenseRoute({ method, segments, searchParams, rawBody, user, callRpc, log = console.error }) {
  if (!user) return { status: 401, body: { error: FINANCE_ERRORS.unauthenticated } }
  const route = resolveExpenseRoute(method, segments)
  if (!route) return NOT_FOUND
  if (route.id !== undefined && !isUuid(route.id)) return { status: 404, body: { error: route.notFound || FINANCE_ERRORS.notFound } }

  let rpc, args
  if (route.kind === 'read') {
    const q = parseExpenseQuery(route.endpoint, searchParams)
    if (!q.ok) return { status: q.status, body: { error: q.error } }
    rpc = q.rpc; args = q.args
  } else {
    // detalhe e escritas: nenhum parâmetro de query aceito
    if ([...searchParams.keys()].length > 0) return { status: 400, body: { error: EXPENSE_ERRORS.invalid } }
    if (route.kind === 'detail') {
      rpc = route.rpc; args = { p_expense_id: route.id }
    } else {
      const b = parseJsonBody(rawBody)
      if (!b) return { status: 400, body: { error: EXPENSE_ERRORS.body } }
      const parsed = route.parse(b, route.id)
      if (!parsed.ok) return { status: parsed.status, body: { error: parsed.error } }
      rpc = route.rpc; args = parsed.args
    }
  }

  try {
    const { data, error } = await callRpc(rpc, args)
    if (error) {
      const mapped = mapExpenseError(error, { notFound: route.notFound })
      if (mapped.status === 500) log('rpc despesas 03B.2B', rpc, error?.code || 'sem código')
      return mapped
    }
    if (data === null || data === undefined || typeof data !== 'object' || Array.isArray(data)) {
      log('rpc despesas 03B.2B', rpc, 'resposta vazia')
      return { status: 500, body: { error: EXPENSE_ERRORS.internal } }
    }
    return { status: route.created && route.created(data) ? 201 : 200, body: data }
  } catch {
    log('rpc despesas 03B.2B', rpc, 'exceção')
    return { status: 500, body: { error: EXPENSE_ERRORS.internal } }
  }
}
