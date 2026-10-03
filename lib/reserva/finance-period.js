// FASE 03B.1 — períodos do Financeiro (puro, sem I/O). Só APRESENTAÇÃO/intenção: quem valida e
// decide é a RPC (private.rg_fin_scope). Datas são sempre strings "YYYY-MM-DD" no timezone da arena;
// nenhuma conta passa por new Date('YYYY-MM-DD') (que seria lido em UTC).
import { isValidDateStr, addDaysStr } from './time.js'

export const PRESETS = ['today', 'last7', 'this_month', 'last_month', 'custom']
export const PRESET_LABELS = {
  today: 'Hoje', last7: 'Últimos 7 dias', this_month: 'Este mês', last_month: 'Mês passado', custom: 'Personalizado',
}
export const DEFAULT_PRESET = 'this_month'
// Mesmo teto de private.rg_fin_scope (p_max_days = 366).
export const MAX_PERIOD_DAYS = 366

const pad2 = (n) => String(n).padStart(2, '0')
const parts = (s) => ({ y: Number(s.slice(0, 4)), m: Number(s.slice(5, 7)), d: Number(s.slice(8, 10)) })
const ymd = (y, m, d) => `${y}-${pad2(m)}-${pad2(d)}`
// Dia do calendário como inteiro (UTC puro, sem fuso): só para contar dias entre duas datas.
const dayNumber = (s) => { const { y, m, d } = parts(s); return Date.UTC(y, m - 1, d) / 86400000 }

export function daysInMonth(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate() } // m 1-based
function prevMonth(y, m) { return m === 1 ? { y: y - 1, m: 12 } : { y, m: m - 1 } }

// Quantidade de dias de [from, to], inclusiva. Datas inválidas => null.
export function periodDays(from, to) {
  if (!isValidDateStr(from) || !isValidDateStr(to)) return null
  return dayNumber(to) - dayNumber(from) + 1
}

// Período personalizado aceito? (datas válidas, from <= to, no máximo 366 dias)
export function isValidCustomPeriod(from, to) {
  const n = periodDays(from, to)
  return n !== null && n >= 1 && n <= MAX_PERIOD_DAYS
}

function build(preset, from, to, cFrom, cTo) {
  if (![from, to, cFrom, cTo].every(isValidDateStr)) return null
  return {
    preset, from, to, days: periodDays(from, to),
    compare: { from: cFrom, to: cTo, days: periodDays(cFrom, cTo) },
  }
}

// Resolve um atalho em { preset, from, to, days, compare: { from, to, days } }. Inválido => null.
//   today      : hoje                     | ontem
//   last7      : hoje-6 .. hoje           | hoje-13 .. hoje-7
//   this_month : dia 1 .. hoje            | dia 1 do mês anterior .. mesmo dia (limitado ao último dia dele)
//   last_month : mês anterior inteiro     | mês imediatamente anterior a ele, inteiro
//   custom     : from .. to (<= 366 dias) | mesma duração imediatamente antes
export function resolvePeriod(preset, todayStr, custom) {
  if (!isValidDateStr(todayStr)) return null
  const t = parts(todayStr)
  switch (preset) {
    case 'today': {
      const y = addDaysStr(todayStr, -1)
      return build('today', todayStr, todayStr, y, y)
    }
    case 'last7':
      return build('last7', addDaysStr(todayStr, -6), todayStr, addDaysStr(todayStr, -13), addDaysStr(todayStr, -7))
    case 'this_month': {
      const p = prevMonth(t.y, t.m)
      return build('this_month', ymd(t.y, t.m, 1), todayStr, ymd(p.y, p.m, 1), ymd(p.y, p.m, Math.min(t.d, daysInMonth(p.y, p.m))))
    }
    case 'last_month': {
      const p = prevMonth(t.y, t.m)
      const pp = prevMonth(p.y, p.m)
      return build('last_month', ymd(p.y, p.m, 1), ymd(p.y, p.m, daysInMonth(p.y, p.m)), ymd(pp.y, pp.m, 1), ymd(pp.y, pp.m, daysInMonth(pp.y, pp.m)))
    }
    case 'custom': {
      const from = custom?.from, to = custom?.to
      if (!isValidCustomPeriod(from, to)) return null
      const n = periodDays(from, to)
      return build('custom', from, to, addDaysStr(from, -n), addDaysStr(from, -1))
    }
    default:
      return null
  }
}

// Estado do período na URL: ?preset=<atalho> ou ?from=YYYY-MM-DD&to=YYYY-MM-DD (personalizado).
// Qualquer coisa inválida cai no atalho padrão (nunca lança, nunca devolve período inválido).
export function periodFromSearch(params, todayStr) {
  const get = (k) => (params && typeof params.get === 'function' ? params.get(k) : null)
  const from = get('from'), to = get('to')
  if (from !== null || to !== null) {
    const p = resolvePeriod('custom', todayStr, { from, to })
    if (p) return p
  }
  const preset = get('preset')
  if (preset && preset !== 'custom' && PRESETS.includes(preset)) {
    const p = resolvePeriod(preset, todayStr)
    if (p) return p
  }
  return resolvePeriod(DEFAULT_PRESET, todayStr)
}

// Inverso de periodFromSearch: só as chaves do período (+ arena, se houver).
export function periodToSearch(period, arenaId) {
  const q = new URLSearchParams()
  if (period?.preset === 'custom') { q.set('from', period.from); q.set('to', period.to) }
  else if (period?.preset) q.set('preset', period.preset)
  if (arenaId) q.set('arena', arenaId)
  return q.toString()
}

// "01/09/2026 – 30/09/2026" (ou só uma data quando from = to). Sem Date: só fatiar a string.
export function fmtPeriodShort(from, to) {
  const f = (s) => (isValidDateStr(s) ? `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}` : '')
  return from === to ? f(from) : `${f(from)} – ${f(to)}`
}

// Variação percentual inteira para exibição (meio arredonda para longe de zero). Sem base positiva
// (null, 0 ou negativa) => null: a UI não mostra percentual.
export function pctChange(current, compare) {
  if (!Number.isSafeInteger(current) || !Number.isSafeInteger(compare) || compare <= 0) return null
  const diff = current - compare
  const v = Math.floor((Math.abs(diff) * 200 + compare) / (2 * compare))
  return diff < 0 ? -v : v
}
