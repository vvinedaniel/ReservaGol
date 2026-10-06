// FASE 03B.2B — chamadas do frontend a /api/finance para Despesas & Caixa (puro: URL + fetch injetável).
// Leituras e escritas sempre no-store. Erro HTTP => ExpenseRequestError (status + code/reason estáveis
// da API, nunca texto do banco). Falha de rede => ExpenseNetworkError: numa escrita o servidor PODE ter
// confirmado, então quem chama mantém o mesmo operation_id para o retry receber o replay idempotente.
import { periodParams } from './finance-client.js'

export class ExpenseRequestError extends Error {
  constructor(status, body) {
    super(typeof body?.error === 'string' ? body.error : `finance ${status}`)
    this.status = status
    this.code = typeof body?.code === 'string' ? body.code : null
    this.reason = typeof body?.reason === 'string' ? body.reason : null
  }
}
export class ExpenseNetworkError extends Error {
  constructor() { super('Não foi possível confirmar a resposta do servidor. Tente novamente.'); this.network = true }
}

const SEGMENT_RE = /^[A-Za-z0-9-]+$/

// /api/finance/<seg>/<seg>?... — segmentos só [A-Za-z0-9-]; parâmetros vazios (null/undefined/'') omitidos.
export function expensesUrl(segments, params = {}) {
  const segs = Array.isArray(segments) ? segments : [segments]
  if (segs.length < 1 || segs.length > 3 || !segs.every((s) => typeof s === 'string' && SEGMENT_RE.test(s))) throw new Error('rota inválida')
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== '') q.set(k, String(v))
  const s = q.toString()
  return `/api/finance/${segs.join('/')}${s ? `?${s}` : ''}`
}

async function call(url, init, fetchImpl) {
  let r
  try { r = await fetchImpl(url, { cache: 'no-store', ...init }) } catch { throw new ExpenseNetworkError() }
  let body = null
  try { body = await r.json() } catch { body = null }
  if (!r.ok) throw new ExpenseRequestError(r.status, body)
  return { status: r.status, data: body }
}

export async function fetchExpenses(segments, params, fetchImpl = fetch) {
  return (await call(expensesUrl(segments, params), { method: 'GET' }, fetchImpl)).data
}

export async function sendExpense(method, segments, body, fetchImpl = fetch) {
  if (method !== 'POST' && method !== 'PATCH') throw new Error('método inválido')
  return call(expensesUrl(segments), { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }, fetchImpl)
}

// Contrato aprovado: um método por RPC da 03B.2. `scope` = { orgId, arenaId, period } (period da 03B.1).
export function createExpensesApi(fetchImpl = fetch) {
  const base = (s) => periodParams(s.orgId, s.arenaId, s.period)
  return {
    // leituras
    categories: (orgId, includeInactive = false) => fetchExpenses('expense-categories', { organization_id: orgId, include_inactive: includeInactive ? 1 : 0 }, fetchImpl),
    overview: (scope, { categoryId = null } = {}) =>
      fetchExpenses('expense-overview', { ...base(scope), category_id: categoryId, compare_from: scope.period.compare?.from, compare_to: scope.period.compare?.to }, fetchImpl),
    list: (scope, { categoryId = null, status = 'ACTIVE', limit = 50, cursor = null } = {}) =>
      fetchExpenses('expenses', { ...base(scope), category_id: categoryId, status, limit, after_due: cursor?.due_date, after_id: cursor?.id }, fetchImpl),
    detail: (expenseId) => fetchExpenses(['expenses', expenseId], {}, fetchImpl),
    cashResult: (scope, granularity) => fetchExpenses('cash-result', { ...base(scope), granularity }, fetchImpl),
    cashMovements: (scope, { limit = 50, cursor = null } = {}) =>
      fetchExpenses('cash-movements', { ...base(scope), limit, after_at: cursor?.occurred_at, after_source: cursor?.source_kind, after_id: cursor?.id }, fetchImpl),
    // escritas
    createCategory: (orgId, name) => sendExpense('POST', 'expense-categories', { organization_id: orgId, name }, fetchImpl),
    updateCategory: (categoryId, changes) => sendExpense('PATCH', ['expense-categories', categoryId], changes, fetchImpl),
    createExpense: (operationId, orgId, v) =>
      sendExpense('POST', 'expenses', { operation_id: operationId, organization_id: orgId, arena_id: v.arena_id ?? null, category_id: v.category_id, description: v.description, amount: v.amount, due_date: v.due_date, notes: v.notes ?? null }, fetchImpl),
    updateExpense: (expenseId, changes) => sendExpense('PATCH', ['expenses', expenseId], changes, fetchImpl),
    cancelExpense: (expenseId, reason) => sendExpense('POST', ['expenses', expenseId, 'cancel'], { reason }, fetchImpl),
    registerPayment: (operationId, expenseId, v) =>
      sendExpense('POST', ['expenses', expenseId, 'payments'], { operation_id: operationId, method: v.method, amount: v.amount, paid_at: v.at, notes: v.notes ?? null }, fetchImpl),
    reversePayment: (operationId, paymentId, v) =>
      sendExpense('POST', ['expense-payments', paymentId, 'reverse'], { operation_id: operationId, method: v.method, amount: v.amount, reversed_at: v.at, notes: v.notes ?? null }, fetchImpl),
    voidPayment: (paymentId, reason) => sendExpense('POST', ['expense-payments', paymentId, 'void'], { reason }, fetchImpl),
  }
}
