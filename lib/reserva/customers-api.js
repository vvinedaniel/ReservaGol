// CLIENTES C2B — camada fina da API de Clientes sobre as RPCs do C2A (puro: sem Next, sem Supabase).
// O route só injeta a chamada RPC da SESSÃO do usuário (nunca service-role). Aqui: rotear, validar FORMATO
// (allowlist de query/body), pré-validar telefone com o espelho da regra canônica (UX) e mapear erros estáveis.
// Identidade, autorização (vínculo ATIVO), tenant e financeiro continuam sendo decididos no banco:
//   rg_customer_list / rg_customer_detail / rg_customer_resolve / rg_customer_update / rg_reservation_change_customer
import { isUuid } from './finance-api.js'
import { parseJsonBody } from './expenses-api.js'
import { canonicalBrPhone, PHONE_INVALID_MSG } from './phone.js'

export const CUSTOMERS_PREFIX = '/api/customers'
export const CUSTOMER_LIST_LIMIT_MAX = 50
export const CUSTOMER_LIST_LIMIT_DEFAULT = 25
export const CUSTOMER_HISTORY_LIMIT_MAX = 50
export const CUSTOMER_Q_MAX_CHARS = 100
export const CUSTOMER_NAME_MAX = 120
export const CUSTOMER_EMAIL_MAX = 254
export const CUSTOMER_FILTERS = ['ALL', 'MENSALISTA', 'INACTIVE_60D']
const ORIGINS = ['CUSTOMERS', 'RESERVATION']

export const CUSTOMER_ERRORS = {
  unauthenticated: 'Sessão expirada. Entre novamente.',
  notFound: 'Rota não encontrada',
  customerNotFound: 'Cliente não encontrado.',
  reservationNotFound: 'Reserva não encontrada.',
  orgNotFound: 'Organização não encontrada.',
  forbidden: 'Sem permissão para esta ação nos clientes desta organização.',
  invalid: 'Parâmetros inválidos.',
  body: 'Corpo da requisição inválido.',
  tenant: 'Os dados informados não pertencem à mesma organização.',
  busy: 'Operação concorrente em andamento. Tente novamente em instantes.',
  internal: 'Erro interno. Tente novamente.',
}

// Motivos estáveis (hint/código do C2A) -> mensagem para o usuário. Nunca texto do banco.
export const CUSTOMER_REASON_MSG = {
  INVALID_PHONE: PHONE_INVALID_MSG,
  INVALID_NAME: 'Informe o nome do cliente (até 120 caracteres).',
  INVALID_EMAIL: 'E-mail inválido.',
  INVALID_ARENA: 'Arena inválida para esta organização.',
  INVALID_FIELD: 'Alteração inválida.',
  INVALID_LIMIT: 'Limite inválido.',
  INVALID_FILTER: 'Filtro inválido.',
  INVALID_CURSOR: 'Paginação inválida. Recarregue a lista.',
  INVALID_ORIGIN: 'Origem inválida.',
  CUSTOMER_REQUIRED: 'Escolha o novo cliente.',
  CUSTOMER_NOT_FOUND: 'Cliente não encontrado nesta organização.',
  PHONE_IN_USE: 'Este telefone já pertence a outro cliente. Não fazemos junção automática de cadastros.',
  STALE_UPDATE: 'Os dados foram alterados por outra pessoa. Recarregue e tente novamente.',
  RECURRING_OCCURRENCE: 'O cliente de um jogo de mensalista é o da série. Para vincular um cliente, use Mensalistas.',
  BLOCKED_SLOT: 'Bloqueio de horário não tem cliente.',
  CANCELLED_RESERVATION: 'Reserva cancelada não troca de cliente.',
}

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k)
const chars = (s) => [...s].length
const fail = (error = CUSTOMER_ERRORS.invalid, code = null) => ({ ok: false, status: 400, error, ...(code && { code }) })
const LIMIT_RE = /^[1-9]\d{0,2}$/

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
function onlyKeys(b, allowed, required = []) {
  for (const k of Object.keys(b)) if (!allowed.includes(k)) return false
  return required.every((k) => has(b, k))
}
const isInstant = (v) => typeof v === 'string' && v.length <= 40 && /^\d{4}-\d{2}-\d{2}T/.test(v) && !Number.isNaN(Date.parse(v))

/** Nome: espaços colapsados; 1..120 caracteres. */
export function normalizeCustomerName(v) {
  if (typeof v !== 'string') return null
  const t = v.replace(/\s+/g, ' ').trim()
  return t && chars(t) <= CUSTOMER_NAME_MAX ? t : null
}
/** E-mail: vazio => null; formato básico (o banco revalida). */
export function normalizeCustomerEmail(v) {
  if (v === null || v === undefined) return { ok: true, value: null }
  if (typeof v !== 'string') return { ok: false }
  const t = v.trim().toLowerCase()
  if (!t) return { ok: true, value: null }
  return t.length <= CUSTOMER_EMAIL_MAX && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(t) ? { ok: true, value: t } : { ok: false }
}

// ------------------------------------------------------------------ leituras
export function parseCustomerList(sp) {
  const p = readQuery(sp, ['organization_id', 'q', 'phone', 'filter', 'limit', 'after_name', 'after_id'])
  if (!p) return fail()
  if (!isUuid(p.organization_id)) return fail('Organização inválida.')
  if (p.q !== null && p.phone !== null) return fail()
  const rawQ = p.q ?? p.phone // `phone` = alias legado (busca por telefone)
  const q = rawQ === null ? null : rawQ.trim()
  if (q !== null && chars(q) > CUSTOMER_Q_MAX_CHARS) return fail('Busca muito longa.')
  const filter = p.filter ?? 'ALL'
  if (!CUSTOMER_FILTERS.includes(filter)) return fail('Filtro inválido.', 'INVALID_FILTER')
  const limit = limitOf(p.limit, CUSTOMER_LIST_LIMIT_MAX, CUSTOMER_LIST_LIMIT_DEFAULT)
  if (limit === null) return fail('Limite inválido.', 'INVALID_LIMIT')
  if ((p.after_name === null) !== (p.after_id === null)) return fail('Paginação inválida.', 'INVALID_CURSOR')
  if (p.after_id !== null && (!isUuid(p.after_id) || chars(p.after_name) > 200)) return fail('Paginação inválida.', 'INVALID_CURSOR')
  return {
    ok: true, rpc: 'rg_customer_list',
    args: { p_org: p.organization_id, p_q: q || null, p_filter: filter, p_limit: limit, p_after_name: p.after_name, p_after_id: p.after_id },
  }
}
export function parseCustomerDetail(id, sp) {
  const p = readQuery(sp, ['history_before', 'history_limit'])
  if (!p) return fail()
  if (p.history_before !== null && !isInstant(p.history_before)) return fail('Paginação inválida.', 'INVALID_CURSOR')
  const limit = limitOf(p.history_limit, CUSTOMER_HISTORY_LIMIT_MAX, 20)
  if (limit === null) return fail('Limite inválido.', 'INVALID_LIMIT')
  return { ok: true, rpc: 'rg_customer_detail', args: { p_customer_id: id, p_history_before: p.history_before, p_history_limit: limit } }
}

// ------------------------------------------------------------------ escritas
export function parseCustomerCreate(b) {
  if (!onlyKeys(b, ['organization_id', 'name', 'phone', 'email', 'arena_id', 'origin'], ['organization_id', 'name'])) return fail(CUSTOMER_ERRORS.body)
  if (!isUuid(b.organization_id)) return fail('Organização inválida.')
  const name = normalizeCustomerName(b.name)
  if (!name) return fail(CUSTOMER_REASON_MSG.INVALID_NAME, 'INVALID_NAME')
  const phone = canonicalBrPhone(has(b, 'phone') ? b.phone : null)
  if (!phone.ok) return fail(CUSTOMER_REASON_MSG.INVALID_PHONE, 'INVALID_PHONE')
  const email = normalizeCustomerEmail(has(b, 'email') ? b.email : null)
  if (!email.ok) return fail(CUSTOMER_REASON_MSG.INVALID_EMAIL, 'INVALID_EMAIL')
  const arena = has(b, 'arena_id') ? b.arena_id : null
  if (arena !== null && !isUuid(arena)) return fail(CUSTOMER_REASON_MSG.INVALID_ARENA, 'INVALID_ARENA')
  const origin = has(b, 'origin') ? b.origin : 'CUSTOMERS'
  if (!ORIGINS.includes(origin)) return fail(CUSTOMER_REASON_MSG.INVALID_ORIGIN, 'INVALID_ORIGIN')
  return {
    ok: true, rpc: 'rg_customer_resolve',
    args: { p_org: b.organization_id, p_name: name, p_phone: phone.value, p_email: email.value, p_arena: arena, p_origin: origin },
  }
}
export function parseCustomerUpdate(id, b) {
  if (!onlyKeys(b, ['changes', 'expected_updated_at'], ['changes', 'expected_updated_at'])) return fail(CUSTOMER_ERRORS.body)
  if (!isInstant(b.expected_updated_at)) return fail(CUSTOMER_REASON_MSG.STALE_UPDATE, 'STALE_UPDATE')
  const c = b.changes
  if (c === null || typeof c !== 'object' || Array.isArray(c) || Object.keys(c).length === 0
      || !onlyKeys(c, ['name', 'phone', 'email', 'arena_id'])) return fail(CUSTOMER_REASON_MSG.INVALID_FIELD, 'INVALID_FIELD')
  const changes = {}
  if (has(c, 'name')) {
    const name = normalizeCustomerName(c.name)
    if (!name) return fail(CUSTOMER_REASON_MSG.INVALID_NAME, 'INVALID_NAME')
    changes.name = name
  }
  if (has(c, 'phone')) {
    const phone = canonicalBrPhone(c.phone)
    if (!phone.ok) return fail(CUSTOMER_REASON_MSG.INVALID_PHONE, 'INVALID_PHONE')
    changes.phone = phone.value
  }
  if (has(c, 'email')) {
    const email = normalizeCustomerEmail(c.email)
    if (!email.ok) return fail(CUSTOMER_REASON_MSG.INVALID_EMAIL, 'INVALID_EMAIL')
    changes.email = email.value
  }
  if (has(c, 'arena_id')) {
    if (c.arena_id !== null && !isUuid(c.arena_id)) return fail(CUSTOMER_REASON_MSG.INVALID_ARENA, 'INVALID_ARENA')
    changes.arena_id = c.arena_id
  }
  return { ok: true, rpc: 'rg_customer_update', args: { p_customer_id: id, p_changes: changes, p_expected_updated_at: b.expected_updated_at } }
}
/** Troca EXPLÍCITA do cliente de uma reserva: customer_id obrigatório; expected_customer_id obrigatório (pode ser null). */
export function parseChangeCustomer(reservationId, b) {
  if (!onlyKeys(b, ['customer_id', 'expected_customer_id'], ['customer_id', 'expected_customer_id'])) return fail(CUSTOMER_ERRORS.body)
  if (!isUuid(b.customer_id)) return fail(CUSTOMER_REASON_MSG.CUSTOMER_REQUIRED, 'CUSTOMER_REQUIRED')
  if (b.expected_customer_id !== null && !isUuid(b.expected_customer_id)) return fail(CUSTOMER_ERRORS.body)
  return {
    ok: true, rpc: 'rg_reservation_change_customer',
    args: { p_reservation_id: reservationId, p_customer_id: b.customer_id, p_expected_customer_id: b.expected_customer_id },
  }
}

// ------------------------------------------------------------------ erros
// Erro da RPC -> HTTP com motivo estável. Nunca devolve mensagem/detalhe/SQL do banco (só o id do cliente
// conflitante no PHONE_IN_USE, que o próprio membro já pode ler).
export function mapCustomerError(error, { notFound = CUSTOMER_ERRORS.customerNotFound } = {}) {
  const code = error?.code
  const hint = typeof error?.hint === 'string' && has(CUSTOMER_REASON_MSG, error.hint) ? error.hint : null
  const reason = (r, status = 409, extra = {}) => ({ status, body: { error: CUSTOMER_REASON_MSG[r], code: r, ...extra } })
  if (code === '42501') return { status: 403, body: { error: CUSTOMER_ERRORS.forbidden } }
  if (code === 'P0002') return { status: 404, body: { error: hint === 'CUSTOMER_NOT_FOUND' ? CUSTOMER_REASON_MSG.CUSTOMER_NOT_FOUND : notFound, ...(hint && { code: hint }) } }
  if (code === 'RGC01') {
    const other = typeof error?.details === 'string' && isUuid(error.details) ? error.details : null
    return reason('PHONE_IN_USE', 409, other ? { conflict_customer_id: other } : {})
  }
  if (code === 'RGC02') return reason('STALE_UPDATE')
  if (code === 'RGC03') return reason('RECURRING_OCCURRENCE')
  if (code === 'RGC04') return reason('BLOCKED_SLOT')
  if (code === 'RGC05') return reason('CANCELLED_RESERVATION')
  if (code === '22023' && hint) return reason(hint, 400)
  if (code === 'RGT01' || code === 'RGT02') return { status: 400, body: { error: CUSTOMER_ERRORS.tenant } }
  if (['22023', '23514', '23502', '23503', '22P02', '22007', '22008', 'P0001'].includes(code)) return { status: 400, body: { error: CUSTOMER_ERRORS.invalid } }
  if (['40001', '40P01', '55P03'].includes(code)) return { status: 503, body: { error: CUSTOMER_ERRORS.busy } }
  return { status: 500, body: { error: CUSTOMER_ERRORS.internal } }
}

// ------------------------------------------------------------------ roteamento + execução
/** Método + segmentos depois de /api/customers -> operação; null => 404. */
export function resolveCustomersRoute(method, segs) {
  if (!Array.isArray(segs) || segs.length > 1) return null
  if (segs.length === 0) return method === 'GET' ? { kind: 'list' } : method === 'POST' ? { kind: 'create' } : null
  if (method === 'GET') return { kind: 'detail', id: segs[0] }
  if (method === 'PATCH') return { kind: 'update', id: segs[0] }
  return null
}

async function runRpc(parsed, callRpc, log, { notFound, created } = {}) {
  try {
    const { data, error } = await callRpc(parsed.rpc, parsed.args)
    if (error) {
      const mapped = mapCustomerError(error, { notFound })
      if (mapped.status === 500) log('rpc clientes C2B', parsed.rpc, error?.code || 'sem código')
      return mapped
    }
    if (data === null || data === undefined || typeof data !== 'object' || Array.isArray(data)) {
      log('rpc clientes C2B', parsed.rpc, 'resposta vazia')
      return { status: 500, body: { error: CUSTOMER_ERRORS.internal } }
    }
    return { status: created && created(data) ? 201 : 200, body: data }
  } catch {
    log('rpc clientes C2B', parsed.rpc, 'exceção')
    return { status: 500, body: { error: CUSTOMER_ERRORS.internal } }
  }
}

// `callRpc(name, args)` => Promise<{ data, error }> do client da SESSÃO. Sempre resolve { status, body }.
export async function runCustomersRoute({ method, segments, searchParams, rawBody, user, callRpc, log = console.error }) {
  if (!user) return { status: 401, body: { error: CUSTOMER_ERRORS.unauthenticated } }
  const route = resolveCustomersRoute(method, segments)
  if (!route) return { status: 404, body: { error: CUSTOMER_ERRORS.notFound } }
  if (route.id !== undefined && !isUuid(route.id)) return { status: 404, body: { error: CUSTOMER_ERRORS.customerNotFound } }
  let parsed
  if (route.kind === 'list') parsed = parseCustomerList(searchParams)
  else if (route.kind === 'detail') parsed = parseCustomerDetail(route.id, searchParams)
  else {
    if ([...searchParams.keys()].length > 0) return { status: 400, body: { error: CUSTOMER_ERRORS.invalid } }
    const b = parseJsonBody(rawBody)
    if (!b) return { status: 400, body: { error: CUSTOMER_ERRORS.body } }
    parsed = route.kind === 'create' ? parseCustomerCreate(b) : parseCustomerUpdate(route.id, b)
  }
  if (!parsed.ok) return { status: parsed.status, body: { error: parsed.error, ...(parsed.code && { code: parsed.code }) } }
  return runRpc(parsed, callRpc, log, {
    notFound: route.kind === 'list' || route.kind === 'create' ? CUSTOMER_ERRORS.orgNotFound : CUSTOMER_ERRORS.customerNotFound,
    created: route.kind === 'create' ? (d) => d?.created === true : null,
  })
}

/** POST /api/reservations/:id/customer — troca explícita (única autoridade: rg_reservation_change_customer). */
export async function runChangeReservationCustomer({ reservationId, searchParams, rawBody, user, callRpc, log = console.error }) {
  if (!user) return { status: 401, body: { error: CUSTOMER_ERRORS.unauthenticated } }
  if (!isUuid(reservationId)) return { status: 404, body: { error: CUSTOMER_ERRORS.reservationNotFound } }
  if ([...searchParams.keys()].length > 0) return { status: 400, body: { error: CUSTOMER_ERRORS.invalid } }
  const b = parseJsonBody(rawBody)
  if (!b) return { status: 400, body: { error: CUSTOMER_ERRORS.body } }
  const parsed = parseChangeCustomer(reservationId, b)
  if (!parsed.ok) return { status: parsed.status, body: { error: parsed.error, ...(parsed.code && { code: parsed.code }) } }
  return runRpc(parsed, callRpc, log, { notFound: CUSTOMER_ERRORS.reservationNotFound })
}

// ------------------------------------------------------------------ busca em Reservas/Séries (no banco)
// C2D: formato de telefone da consulta INTEIRA (espelho do teste em rg_customer_list).
export const PHONE_QUERY_RE = /^\+?[0-9 ().-]+$/
/**
 * Classificação nome × telefone — ESPELHO EXATO de public.rg_customer_list (C2D): v = btrim (só espaços);
 * telefone SOMENTE se a consulta inteira tem formato de telefone E >= 4 dígitos (digits2 = sem o 55 quando
 * 12/13 dígitos começando com 55); senão nome. Paridade JS × SQL provada em tests/customers_c2b.test.mjs.
 * -> { mode: 'none' } | { mode: 'phone', digits, digits2 } | { mode: 'name', text }
 */
export function customerSearchMode(q) {
  if (typeof q !== 'string') return { mode: 'none' }
  const v = q.replace(/^ +| +$/g, '')
  if (!v) return { mode: 'none' }
  const digits = v.replace(/[^0-9]/g, '')
  if (digits.length >= 4 && PHONE_QUERY_RE.test(v)) {
    const digits2 = (digits.length === 12 || digits.length === 13) && digits.startsWith('55') ? digits.slice(2) : digits
    return { mode: 'phone', digits, digits2 }
  }
  return { mode: 'name', text: v }
}
/**
 * Filtro PostgREST (aplicado na tabela embutida `customers`, ANTES do limit) para a busca `q` de Reservas e
 * Séries. Mesma classificação de rg_customer_list (customerSearchMode): telefone => telefone contém os dígitos
 * (e a forma sem 55); nome => nome contém o texto. O texto é reduzido a letras/dígitos/espaço/.'- (sem curingas
 * nem sintaxe PostgREST). Retorna { kind: 'none' } (sem busca) | { kind: 'empty' } (busca sem termo útil =>
 * sem resultados) | { kind: 'or', value }.
 */
export function customerSearchFilter(q) {
  if (q === null || q === undefined) return { kind: 'none' }
  if (typeof q !== 'string') return { kind: 'empty' }
  const t = q.trim().slice(0, CUSTOMER_Q_MAX_CHARS)
  if (!t) return { kind: 'none' }
  const m = customerSearchMode(t)
  if (m.mode === 'phone') {
    const parts = [`phone.like.*${m.digits}*`]
    if (m.digits2 !== m.digits) parts.push(`phone.like.*${m.digits2}*`)
    return { kind: 'or', value: parts.join(',') }
  }
  const name = t.normalize('NFC').replace(/[^\p{L}\p{N} .'-]/gu, ' ').replace(/\s+/g, ' ').trim()
  if (!name) return { kind: 'empty' }
  return { kind: 'or', value: `name.ilike.*${name}*` }
}
