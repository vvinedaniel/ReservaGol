// Timezone-aware helpers for the arena operational timezone.
// São Paulo has no DST since 2019 -> fixed offset. Centralized for future multi-tz.
export const ARENA_TZ = 'America/Sao_Paulo'
export const ARENA_OFFSET = '-03:00'

export const DAY_MIN = 1440

// "HH:MM[:SS]" -> minutos do dia (00:00 = 0).
export function timeToMin(t) { const [h, m] = (t || '0:0').split(':').map(Number); return h * 60 + (m || 0) }
const toMin = timeToMin
// Minutos -> "HH:MM". 1440 (meia-noite do dia seguinte) vira "00:00".
function toHHMM(min) { const x = ((min % DAY_MIN) + DAY_MIN) % DAY_MIN; const h = Math.floor(x / 60), m = x % 60; return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}` }

// REGRA ÚNICA de horário de FECHAMENTO: close_time = 00:00 significa meia-noite do
// dia seguinte (1440), nunca o início do mesmo dia.
export function closeTimeToMin(t) { const m = timeToMin(t); return m === 0 ? DAY_MIN : m }

// REGRA ÚNICA de intervalo: end = start é inválido; end < start termina no dia seguinte.
export function crossesMidnight(startT, endT) { return timeToMin(endT) <= timeToMin(startT) }
export function intervalEndMin(startT, endT) { return crossesMidnight(startT, endT) ? timeToMin(endT) + DAY_MIN : timeToMin(endT) }

// O minuto `min` (0..1439) está dentro do horário de funcionamento?
export function isWithinHours(bh, min) {
  if (!bh || bh.closed || !bh.open_time || !bh.close_time) return false
  return min >= timeToMin(bh.open_time) && min < closeTimeToMin(bh.close_time)
}

// Intervalo operacional de datas aceitas pela UI. Fora dele (ex.: o "0002" que o
// <input type="date"> emite enquanto o ano é digitado) a data é tratada como inválida.
export const MIN_OPERATIONAL_YEAR = 2000
export const MAX_OPERATIONAL_YEAR = 2100

// REGRA ÚNICA de data "YYYY-MM-DD": formato estrito, ano no intervalo operacional e dia
// existente no mês (bissexto incluso). Não usa o parser permissivo de Date.
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/
export function isValidDateStr(s) {
  if (typeof s !== 'string') return false
  const m = DATE_RE.exec(s)
  if (!m) return false
  const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3])
  if (y < MIN_OPERATIONAL_YEAR || y > MAX_OPERATIONAL_YEAR || mo < 1 || mo > 12 || d < 1) return false
  return d <= new Date(Date.UTC(y, mo, 0)).getUTCDate()
}

// <input type="date">: o que a pessoa digita (dateInput) é separado da última data
// válida (date). Valor parcial/inválido muda só o campo; a data aceita não muda.
export function applyDateInput(currentDate, raw) {
  return { dateInput: raw, date: isValidDateStr(raw) ? raw : currentDate }
}

export function todayStr() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
}
// Entrada inválida devolve '' (nunca lança): quem exige data válida deve checar com isValidDateStr.
export function addDaysStr(dateStr, n) {
  if (!isValidDateStr(dateStr)) return ''
  const d = new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`)
  d.setUTCDate(d.getUTCDate() + n)
  return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
}
export function weekdayOf(dateStr) { return new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`).getUTCDay() }

// Primeira data da série (>= início) para cotar o default_price pela tabela de preços.
// Sem data de início válida não há série: devolve null.
export function firstSeriesDate(f) {
  if (!isValidDateStr(f?.start_date)) return null
  const start = new Date(`${f.start_date}T12:00:00${ARENA_OFFSET}`)
  for (let i = 0; i < 62; i++) {
    const d = new Date(start.getTime() + i * 86400000)
    const ds = new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ }).format(d)
    const dow = new Date(`${ds}T12:00:00${ARENA_OFFSET}`).getUTCDay()
    if (f.frequency === 'MONTHLY' ? Number(ds.slice(8, 10)) === Number(f.day_of_month) : dow === Number(f.weekday)) return ds
  }
  return null
}

export function fmtTime(iso) {
  if (!iso) return ''
  return new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso))
}
export function fmtDateTimeLong(iso) {
  if (!iso) return ''
  return new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso))
}
// Data inválida/parcial vira '' em vez de lançar RangeError durante a renderização.
export function fmtDateLong(dateStr) {
  if (!isValidDateStr(dateStr)) return ''
  return new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, weekday: 'short', day: '2-digit', month: 'long' }).format(new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`))
}
export function minsOfDay(iso) {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: ARENA_TZ, hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date(iso))
  let h = 0, m = 0
  for (const p of parts) { if (p.type === 'hour') h = +p.value; if (p.type === 'minute') m = +p.value }
  return h * 60 + m
}

// Build time slots from arena business hours + default duration.
export function buildSlots(open, close, stepMin) {
  if (!open || !close) return []
  const step = stepMin || 60
  const out = []
  let cur = toMin(open)
  const end = closeTimeToMin(close)
  while (cur + step <= end) { out.push({ start: toHHMM(cur), end: toHHMM(cur + step), startMin: cur, endMin: cur + step }); cur += step }
  return out
}

export function overlaps(res, startMin, endMin) {
  const s = minsOfDay(res.start_at)
  let e = minsOfDay(res.end_at)
  if (e <= s) e += DAY_MIN // reserva que termina após a meia-noite (ex.: 23:00 -> 00:00)
  return s < endMin && e > startMin
}
