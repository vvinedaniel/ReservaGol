// FASE 03B.2B — navegação do Financeiro na URL (puro, sem I/O). A URL é a ÚNICA fonte da aba ativa,
// do período e da arena: toda troca reconstrói a query canônica a partir do estado já validado, então
// parâmetros antigos/inválidos nunca são copiados adiante e nenhuma troca descarta as outras chaves.
import { periodToSearch } from './finance-period.js'

export const FINANCE_TABS = ['overview', 'receivables', 'cash', 'expenses']
export const DEFAULT_FINANCE_TAB = 'overview'
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// ?tab=... ausente, repetido ou desconhecido => overview.
export function tabFromSearch(params) {
  const all = params && typeof params.getAll === 'function' ? params.getAll('tab') : []
  return all.length === 1 && FINANCE_TABS.includes(all[0]) ? all[0] : DEFAULT_FINANCE_TAB
}

// Arena que a URL deve carregar: depois de carregada a lista da organização, só a arena validada
// (ou nenhuma); antes disso, preserva um uuid bem formado da URL para não perdê-lo numa troca precoce.
export function urlArena(arenaParam, arenas) {
  if (arenas?.ready) return Array.isArray(arenas.list) && arenas.list.some((a) => a.id === arenaParam) ? arenaParam : null
  return typeof arenaParam === 'string' && UUID_RE.test(arenaParam) ? arenaParam : null
}

// Query canônica: período (?preset | ?from&to) + arena + aba (omitida quando overview).
export function financeSearch({ period, arenaId = null, tab = DEFAULT_FINANCE_TAB }) {
  const q = new URLSearchParams(periodToSearch(period, arenaId || null))
  if (FINANCE_TABS.includes(tab) && tab !== DEFAULT_FINANCE_TAB) q.set('tab', tab)
  return q.toString()
}

// Próxima query a partir do estado atual + mudança ({ period } | { arenaId } | { tab }).
export function nextFinanceSearch(current, change) {
  const next = { ...current, ...change }
  return financeSearch({ period: next.period, arenaId: next.arenaId, tab: FINANCE_TABS.includes(next.tab) ? next.tab : DEFAULT_FINANCE_TAB })
}
