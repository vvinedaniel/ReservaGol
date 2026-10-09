// CLIENTES C2B — chamadas do frontend a /api/customers e à troca explícita de cliente da reserva
// (puro: URL + fetch injetável). Sempre no-store. Erro HTTP => CustomerRequestError com code estável da API
// (PHONE_IN_USE, STALE_UPDATE, ...) — nunca texto do banco. Falha de rede => CustomerNetworkError (a escrita
// PODE ter sido confirmada: a tela recarrega antes de tentar de novo; nada é aplicado de forma otimista).
import { CUSTOMERS_PREFIX } from './customers-api.js'

export class CustomerRequestError extends Error {
  constructor(status, body) {
    super(typeof body?.error === 'string' ? body.error : `clientes ${status}`)
    this.status = status
    this.code = typeof body?.code === 'string' ? body.code : null
    this.conflictCustomerId = typeof body?.conflict_customer_id === 'string' ? body.conflict_customer_id : null
  }
}
export class CustomerNetworkError extends Error {
  constructor() { super('Não foi possível confirmar a resposta do servidor. Recarregue para ver o estado atual.'); this.network = true }
}

const ID_RE = /^[A-Za-z0-9-]+$/

export function customersUrl(id = null, params = {}) {
  if (id !== null && (typeof id !== 'string' || !ID_RE.test(id))) throw new Error('rota inválida')
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== '') q.set(k, String(v))
  const s = q.toString()
  return `${CUSTOMERS_PREFIX}${id ? `/${id}` : ''}${s ? `?${s}` : ''}`
}

async function call(url, init, fetchImpl) {
  let r
  try { r = await fetchImpl(url, { cache: 'no-store', ...init }) } catch { throw new CustomerNetworkError() }
  let body = null
  try { body = await r.json() } catch { body = null }
  if (!r.ok) throw new CustomerRequestError(r.status, body)
  return { status: r.status, data: body }
}
const JSON_HEADERS = { 'Content-Type': 'application/json' }

export function createCustomersApi(fetchImpl = fetch) {
  return {
    /** -> { items, next_cursor } (fin_flag só para OWNER/MANAGER, decidido no banco) */
    list: async ({ orgId, q = null, filter = 'ALL', limit = 25, cursor = null }) => (await call(customersUrl(null, {
      organization_id: orgId, q, filter: filter === 'ALL' ? null : filter, limit,
      after_name: cursor ? cursor.after_name : null, after_id: cursor ? cursor.after_id : null,
    }), { method: 'GET' }, fetchImpl)).data,
    /** -> { customer, upcoming, history, history_next_before, series, finance (null p/ recepção) } */
    detail: async (id, { historyBefore = null, historyLimit = 20 } = {}) =>
      (await call(customersUrl(id, { history_before: historyBefore, history_limit: historyLimit }), { method: 'GET' }, fetchImpl)).data,
    /** -> { customer_id, created, name_differs, existing } */
    create: async ({ orgId, name, phone = null, email = null, arenaId = null, origin = 'CUSTOMERS' }) =>
      (await call(customersUrl(), { method: 'POST', headers: JSON_HEADERS,
        body: JSON.stringify({ organization_id: orgId, name, phone, email, arena_id: arenaId, origin }) }, fetchImpl)).data,
    /** -> { changed, customer } ; changes ⊆ {name, phone, email, arena_id} */
    update: async (id, { changes, expectedUpdatedAt }) =>
      (await call(customersUrl(id), { method: 'PATCH', headers: JSON_HEADERS,
        body: JSON.stringify({ changes, expected_updated_at: expectedUpdatedAt }) }, fetchImpl)).data,
    /** Troca explícita do cliente de uma reserva avulsa -> { reservation_id, customer_id, changed } */
    changeReservationCustomer: async (reservationId, { customerId, expectedCustomerId }) => {
      if (typeof reservationId !== 'string' || !ID_RE.test(reservationId)) throw new Error('rota inválida')
      return (await call(`/api/reservations/${reservationId}/customer`, { method: 'POST', headers: JSON_HEADERS,
        body: JSON.stringify({ customer_id: customerId, expected_customer_id: expectedCustomerId ?? null }) }, fetchImpl)).data
    },
  }
}

const FALLBACK = 'Não foi possível concluir. Tente novamente.'
/** Mensagem para o usuário: rede => recarregar; HTTP => mensagem já saneada pela API. */
export function customerErrorMessage(e, fallback = FALLBACK) {
  if (e instanceof CustomerNetworkError) return e.message
  if (e instanceof CustomerRequestError && e.message && !/^clientes \d+$/.test(e.message)) return e.message
  return fallback
}
