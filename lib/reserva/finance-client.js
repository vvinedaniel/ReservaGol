// FASE 03B.1 — chamadas do frontend ao /api/finance (puro: URL + fetch injetável).
// Erros viram FinanceRequestError com o status HTTP (403 => tela de acesso negado, sem dados).
export class FinanceRequestError extends Error {
  constructor(status) { super(`finance ${status}`); this.status = status }
}

// Monta /api/finance/<endpoint>?... omitindo valores vazios (null/undefined/'').
export function financeUrl(endpoint, params = {}) {
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== '') q.set(k, String(v))
  const s = q.toString()
  return `/api/finance/${endpoint}${s ? `?${s}` : ''}`
}

export async function fetchFinance(endpoint, params, fetchImpl = fetch) {
  const r = await fetchImpl(financeUrl(endpoint, params), { cache: 'no-store' })
  if (!r.ok) throw new FinanceRequestError(r.status)
  return r.json()
}

// Parâmetros comuns (organização + arena opcional + período) de todas as rotas.
export function periodParams(orgId, arenaId, period) {
  return { organization_id: orgId, arena_id: arenaId || null, from: period.from, to: period.to }
}

// Granularidade do gráfico de caixa: por dia até ~2 meses, por mês acima disso.
export function cashflowGranularity(period) { return period.days <= 62 ? 'day' : 'month' }
