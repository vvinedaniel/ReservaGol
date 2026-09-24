// Regras ÚNICAS de validação da reserva pública (A4). Funções puras, sem I/O: usadas pela
// API (/api/public/availability e /api/public/reserve) e pela tela /jogar/[slug].
// A tela só espelha estas regras por conveniência; a segurança está no servidor.
import { ARENA_OFFSET, addDaysStr, buildSlots } from './time'

// Janela pública inclusiva: hoje .. hoje + 90 dias (timezone operacional da arena).
export const PUBLIC_BOOKING_MAX_DAYS = 90

// default_reservation_minutes aceito para gerar slots públicos. Hoje todas as orgs usam 60.
// 15 min limita um dia inteiro a no máximo 96 slots; 240 min (4 h) cobre eventos longos.
// Fora disso a configuração é tratada como inválida: nenhum slot é gerado e a API responde
// "agenda indisponível" (sem loop, sem travar). Não altera dados nem a tela de configuração.
export const SLOT_MINUTES_MIN = 15
export const SLOT_MINUTES_MAX = 240

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/
const HHMM_RE = /^([01]\d|2[0-3]):([0-5]\d)$/
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// Mesmo formato que slugify() produz: [a-z0-9] separados por hífen único, até 60 chars.
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
// Compatível com crypto.randomUUID() e com o fallback String(Date.now()) + Math.random().
const IDEMPOTENCY_RE = /^[A-Za-z0-9._-]{8,100}$/

export const PUBLIC_ERRORS = {
  params: 'Parâmetros inválidos.',
  date: 'Data inválida.',
  datePast: 'Esta data já passou. Escolha outra data.',
  dateFar: `Reservas online podem ser feitas com até ${PUBLIC_BOOKING_MAX_DAYS} dias de antecedência.`,
  closed: 'A arena não abre nesta data.',
  slot: 'Horário indisponível para reserva online. Escolha um dos horários exibidos.',
  slotPast: 'Este horário já começou. Escolha outro horário.',
  config: 'Agenda indisponível para reservas online no momento.',
  name: 'Informe seu nome (2 a 80 caracteres).',
  phone: 'Informe um WhatsApp válido com DDD.',
  email: 'E-mail inválido.',
  terms: 'É necessário aceitar as regras da arena.',
  idempotency: 'Requisição inválida. Recarregue a página e tente novamente.',
}

export function isUuid(v) { return typeof v === 'string' && UUID_RE.test(v) }
export function isValidSlug(v) { return typeof v === 'string' && v.length <= 60 && SLUG_RE.test(v) }
export function isHHMM(v) { return typeof v === 'string' && HHMM_RE.test(v) }

// Data EXATA YYYY-MM-DD e existente no calendário (rejeita 2026-02-31, 2026-13-10, abc, 24/09/2026).
export function isRealDate(v) {
  if (typeof v !== 'string') return false
  const m = DATE_RE.exec(v)
  if (!m) return false
  const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3])
  const dt = new Date(Date.UTC(y, mo - 1, d))
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d
}

// Última data aceita pela janela pública (inclusiva).
export function publicMaxDate(today) { return addDaysStr(today, PUBLIC_BOOKING_MAX_DAYS) }

// Regra única de data pública. `today` = hoje no timezone operacional (YYYY-MM-DD).
// Retorna null se válida, ou a chave do erro em PUBLIC_ERRORS.
export function checkPublicDate(date, today) {
  if (!isRealDate(date)) return 'date'
  if (date < today) return 'datePast'
  if (date > publicMaxDate(today)) return 'dateFar'
  return null
}

// default_reservation_minutes defensivo: inteiro dentro de [MIN, MAX] ou null (inválido).
export function safeSlotMinutes(v) {
  const n = Number(v)
  if (!Number.isInteger(n) || n < SLOT_MINUTES_MIN || n > SLOT_MINUTES_MAX) return null
  return n
}

// Slots oficiais do dia (mesma geração da agenda: close 00:00 = meia-noite). [] se fechado.
export function publicSlots(bh, minutes) {
  if (!bh || bh.closed || !bh.open_time || !bh.close_time) return []
  return buildSlots(bh.open_time, bh.close_time, minutes)
}

// Match EXATO do par enviado com um slot gerado pelo servidor (nunca só pela duração).
export function findSlot(slots, start, end) {
  if (!isHHMM(start) || !isHHMM(end)) return null
  return slots.find((s) => s.start === start && s.end === end) || null
}

// Instante (ms) de início do slot no timezone operacional.
export function slotStartMs(date, start) { return new Date(`${date}T${start}:00${ARENA_OFFSET}`).getTime() }

// Slot já iniciado (início <= agora) nunca pode ser reservado online.
export function slotStarted(date, start, nowMs) { return slotStartMs(date, start) <= nowMs }

export function cleanName(v) {
  if (typeof v !== 'string') return null
  const s = v.trim().replace(/\s+/g, ' ')
  return s.length >= 2 && s.length <= 80 ? s : null
}

// Telefone brasileiro: só dígitos; aceita com ou sem +55. Resultado armazenado = DDD + número
// (10 ou 11 dígitos, DDD sem zero à esquerda). "abc" ou vazio -> null.
export function cleanBrPhone(v) {
  if (typeof v !== 'string' || v.length > 30) return null
  let d = v.replace(/\D/g, '')
  if ((d.length === 12 || d.length === 13) && d.startsWith('55')) d = d.slice(2)
  return /^[1-9]\d{9,10}$/.test(d) ? d : null
}

// E-mail opcional: ausente/vazio -> { ok: true, value: null }.
export function cleanEmail(v) {
  if (v === undefined || v === null) return { ok: true, value: null }
  if (typeof v !== 'string') return { ok: false }
  const s = v.trim()
  if (!s) return { ok: true, value: null }
  return s.length <= 254 && EMAIL_RE.test(s) ? { ok: true, value: s } : { ok: false }
}

// Idempotency key opcional: ausente -> { ok: true, value: null }.
export function cleanIdempotencyKey(v) {
  if (v === undefined || v === null || v === '') return { ok: true, value: null }
  return typeof v === 'string' && IDEMPOTENCY_RE.test(v) ? { ok: true, value: v } : { ok: false }
}
