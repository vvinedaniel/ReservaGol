// Timezone-aware helpers for the arena operational timezone.
// São Paulo has no DST since 2019 -> fixed offset. Centralized for future multi-tz.
export const ARENA_TZ = 'America/Sao_Paulo'
export const ARENA_OFFSET = '-03:00'

function toMin(t) { const [h, m] = (t || '0:0').split(':').map(Number); return h * 60 + (m || 0) }
function toHHMM(min) { const h = Math.floor(min / 60), m = min % 60; return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}` }

export function todayStr() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
}
export function addDaysStr(dateStr, n) {
  const d = new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`)
  d.setUTCDate(d.getUTCDate() + n)
  return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d)
}
export function weekdayOf(dateStr) { return new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`).getUTCDay() }

export function fmtTime(iso) {
  if (!iso) return ''
  return new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(iso))
}
export function fmtDateTimeLong(iso) {
  if (!iso) return ''
  return new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(iso))
}
export function fmtDateLong(dateStr) {
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
  const end = toMin(close)
  while (cur + step <= end) { out.push({ start: toHHMM(cur), end: toHHMM(cur + step), startMin: cur, endMin: cur + step }); cur += step }
  return out
}

export function overlaps(res, startMin, endMin) {
  const s = minsOfDay(res.start_at), e = minsOfDay(res.end_at)
  return s < endMin && e > startMin
}
