// FASE 03B.3B — chamadas do frontend a /api/recurring-month (puro: URL + fetch injetável). Sempre no-store.
// Erro HTTP => RecurringMonthRequestError (status + code/reason estáveis da API, nunca texto do banco).
// Falha de rede => RecurringMonthNetworkError: numa escrita o servidor PODE ter confirmado, então quem chama
// mantém o mesmo operation_id para o retry receber o replay idempotente.
import { RM_PREFIX } from './recurring-month.js'

export class RecurringMonthRequestError extends Error {
  constructor(status, body) {
    super(typeof body?.error === 'string' ? body.error : `mensalistas ${status}`)
    this.status = status
    this.code = typeof body?.code === 'string' ? body.code : null
    this.reason = typeof body?.reason === 'string' ? body.reason : null
  }
}
export class RecurringMonthNetworkError extends Error {
  constructor() { super('Não foi possível confirmar a resposta do servidor. Tente novamente — não há cobrança em dobro.'); this.network = true }
}

const SEGMENT_RE = /^[A-Za-z0-9-]+$/

/** /api/recurring-month[/seg[/seg]]?... — segmentos só [A-Za-z0-9-]; parâmetros vazios omitidos. */
export function recurringMonthUrl(segments = [], params = {}) {
  const segs = Array.isArray(segments) ? segments : [segments]
  if (segs.length > 2 || !segs.every((s) => typeof s === 'string' && SEGMENT_RE.test(s))) throw new Error('rota inválida')
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== '') q.set(k, String(v))
  const s = q.toString()
  return `${RM_PREFIX}${segs.length ? `/${segs.join('/')}` : ''}${s ? `?${s}` : ''}`
}

async function call(url, init, fetchImpl) {
  let r
  try { r = await fetchImpl(url, { cache: 'no-store', ...init }) } catch { throw new RecurringMonthNetworkError() }
  let body = null
  try { body = await r.json() } catch { body = null }
  if (!r.ok) throw new RecurringMonthRequestError(r.status, body)
  return { status: r.status, data: body }
}
const get = async (segs, params, f) => (await call(recurringMonthUrl(segs, params), { method: 'GET' }, f)).data
const post = (segs, body, f) => call(recurringMonthUrl(segs), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }, f)

// Um método por RPC da 03B.3A. `month` = "YYYY-MM".
export function createRecurringMonthApi(fetchImpl = fetch) {
  return {
    list: ({ orgId, month, arenaId = null, status = null, q = null, limit = 50, cursor = null }) =>
      get([], {
        organization_id: orgId, month, arena_id: arenaId, status: status === 'ALL' ? null : status, q, limit,
        cursor_nc: cursor ? String(cursor.nc) : null, cursor_name: cursor ? cursor.name : null, cursor_lineage: cursor ? cursor.lineage : null,
      }, fetchImpl),
    search: ({ orgId, month, q = null, limit = 20 }) => get(['search'], { organization_id: orgId, month, q, limit }, fetchImpl),
    detail: (lineageId, month) => get([lineageId], { month }, fetchImpl),
    // expected_open SEMPRE enviado: o saldo do mês que o usuário confirmou na tela
    recordPayment: (operationId, lineageId, { month, amount, method, receivedAt, notes = null, expectedOpen }) =>
      post([lineageId, 'payments'], { operation_id: operationId, month, amount, method, received_at: receivedAt, notes, expected_open: expectedOpen }, fetchImpl),
    linkCustomer: (lineageId, { customerId = null, customer = null }) =>
      post([lineageId, 'customer'], customerId ? { customer_id: customerId } : { customer }, fetchImpl),
    applySeriesPrice: (lineageId, month) => post([lineageId, 'apply-series-price'], { month }, fetchImpl),
  }
}
