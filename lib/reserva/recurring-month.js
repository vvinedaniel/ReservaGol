// FASE 03B.3B — Mensalistas (visão mensal): contratos (JSDoc) e helpers PUROS de apresentação.
// Nunca é autoridade financeira: status do mês, saldo, elegibilidade e valores vêm das RPCs da 03B.3A
// (rg_recurring_month_*). Aqui só: formato de mês, rótulos, validação de formulário e a PRÉVIA VISUAL
// da distribuição do recebimento (nunca enviada ao servidor; o split real vem da resposta da RPC).
import { parseMoneyToCents, formatCents, toCents } from './money.js'
import { PAYMENT_METHODS, normalizeFinanceNotes, localInputToISO, WEEKDAY_LABELS } from './finance.js'

/**
 * @typedef {'UNPRICED'|'OVERDUE'|'PARTIAL'|'OPEN'|'PAID'|'NO_CHARGE'} MonthStatus
 * @typedef {{ lineages: number, games: number, expected: number, net: number, retained: number, open: number, overdue: number }} MonthSummaryCards
 * @typedef {{ lineage_id: string, series_id: string, customer_id: string|null, customer_name: string|null, arena_id: string,
 *   arena_name: string, court_id: string, court_name: string, frequency: 'WEEKLY'|'BIWEEKLY'|'MONTHLY', weekday: number|null,
 *   day_of_month: number|null, start_time: string, end_time: string, series_status: string, games: number, cancelled: number,
 *   unpriced: number, expected: number, net: number, retained: number, open: number, overdue: number, has_overdue: boolean,
 *   status: MonthStatus }} MonthListItem
 * @typedef {{ nc: boolean, name: string, lineage: string }} MonthCursor
 * @typedef {{ month: string, summary: MonthSummaryCards, items: MonthListItem[], next_cursor: MonthCursor|null }} MonthListResult
 * @typedef {{ lineage_id: string, customer_name: string|null, has_customer: boolean, arena_name: string, court_name: string,
 *   frequency: string, weekday: number|null, day_of_month: number|null, start_time: string, end_time: string, games: number,
 *   eligible: boolean }} MonthSearchItem
 * @typedef {{ reservation_id: string, series_id: string, occurrence_date: string, start_at: string, end_at: string,
 *   court_name: string, status: string, is_exception: boolean, moved: boolean, price: number|null, net_received: number,
 *   open: number, payment_status: string, collectible: boolean, overdue: boolean }} MonthOccurrence
 * @typedef {{ lineage_id: string, month: string, is_manager: boolean, customer: {id: string, name: string}|null,
 *   current: object, series: object[], summary: { games: number, cancelled: number, unpriced: number, expected: number,
 *   net: number, retained: number|null, open: number, overdue: number, has_overdue: boolean, status: MonthStatus },
 *   occurrences: MonthOccurrence[], missing_future_dates: string[], eligible: boolean,
 *   blocked_reason: 'CUSTOMER_REQUIRED'|'UNPRICED'|'NOTHING_DUE'|null, can_link_customer: boolean,
 *   can_apply_series_price: boolean }} MonthDetail
 * @typedef {{ position: number, reservation_id: string, occurrence_date: string, amount: number, payment_id: string }} MonthPaymentItem
 * @typedef {{ batch_id: string, lineage_id: string, month: string, amount: number, applied: number, idempotent: boolean,
 *   items: MonthPaymentItem[], open_after: number }} MonthPaymentResult
 */

export const RM_PREFIX = '/api/recurring-month'

export const MONTH_STATUSES = ['UNPRICED', 'OVERDUE', 'PARTIAL', 'OPEN', 'PAID', 'NO_CHARGE']
export const MONTH_FILTERS = ['ALL', 'OPEN', 'OVERDUE', 'PARTIAL', 'PAID', 'UNPRICED', 'NO_CUSTOMER', 'NO_CHARGE']
export const MONTH_FILTER_LABELS = {
  ALL: 'Todos', OPEN: 'Em aberto', OVERDUE: 'Vencidos', PARTIAL: 'Parciais', PAID: 'Pagos', UNPRICED: 'Sem valor',
  NO_CUSTOMER: 'Sem cliente', NO_CHARGE: 'Sem cobrança',
}
// Status do mês: texto + ícone (nunca só cor). Ícone é o nome do componente lucide usado na UI.
export const MONTH_STATUS_META = {
  UNPRICED: { label: 'Sem valor', icon: 'AlertTriangle', badge: 'border-amber-500/40 bg-amber-500/15 text-amber-300' },
  OVERDUE: { label: 'Vencido', icon: 'AlertCircle', badge: 'border-red-500/40 bg-red-500/15 text-red-300' },
  PARTIAL: { label: 'Parcial', icon: 'CircleDashed', badge: 'border-sky-500/40 bg-sky-500/15 text-sky-300' },
  OPEN: { label: 'Em aberto', icon: 'Circle', badge: 'border-border bg-muted/40 text-foreground' },
  PAID: { label: 'Pago', icon: 'CheckCircle2', badge: 'border-emerald-500/40 bg-emerald-500/15 text-emerald-300' },
  NO_CHARGE: { label: 'Sem cobrança', icon: 'MinusCircle', badge: 'border-border bg-muted/30 text-muted-foreground' },
}
export function monthStatusMeta(s) { return MONTH_STATUS_META[s] || MONTH_STATUS_META.NO_CHARGE }

// Status operacional da reserva (rótulo curto para a linha do jogo).
export const OCCURRENCE_STATUS_LABELS = {
  CONFIRMED: 'Confirmada', PENDING: 'Pendente', NO_SHOW: 'Não compareceu', CANCELLED: 'Cancelada', PAID: 'Paga', BLOCKED: 'Bloqueada',
}

// Mensagens dos bloqueios/recusas contratuais (reason estável da API).
export const MONTH_REASON_MSG = {
  CUSTOMER_REQUIRED: 'Este mensalista não tem cliente cadastrado. Vincule um cliente para receber o mês.',
  UNPRICED: 'Há jogos sem valor neste mês. Defina o valor antes de receber.',
  NOTHING_DUE: 'Não há valor a receber neste mês.',
  STATE_CHANGED: 'Os valores mudaram desde que a tela foi aberta. Confira e confirme novamente.',
  OVER_BALANCE: 'O valor informado é maior que o saldo do mês.',
  CUSTOMER_ALREADY_SET: 'Este mensalista já tem cliente cadastrado.',
}

// ------------------------------------------------------------------ mês (competência YYYY-MM)
const MONTH_RE = /^(\d{4})-(0[1-9]|1[0-2])$/
const MONTH_NAMES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']

/** "2026-10" válido (2000-01..2100-12). */
export function isMonthParam(v) {
  const m = typeof v === 'string' ? MONTH_RE.exec(v) : null
  if (!m) return false
  const y = Number(m[1])
  return y >= 2000 && y <= 2100
}
/** "2026-10" -> "2026-10-01" (formato das RPCs) ou null. */
export function monthToDate(v) { return isMonthParam(v) ? `${v}-01` : null }
/** "2026-10-01" -> "2026-10" ou null. */
export function dateToMonth(v) {
  return typeof v === 'string' && /^\d{4}-\d{2}-01$/.test(v) && isMonthParam(v.slice(0, 7)) ? v.slice(0, 7) : null
}
/** Mês civil de "hoje" (YYYY-MM-DD da arena) -> "YYYY-MM". */
export function monthOf(todayStr) { return typeof todayStr === 'string' && isMonthParam(todayStr.slice(0, 7)) ? todayStr.slice(0, 7) : null }
export function shiftMonth(month, delta) {
  if (!isMonthParam(month) || !Number.isInteger(delta)) return null
  const y = Number(month.slice(0, 4))
  const m = Number(month.slice(5, 7)) - 1 + delta
  const ny = y + Math.floor(m / 12)
  const nm = ((m % 12) + 12) % 12
  const out = `${ny}-${String(nm + 1).padStart(2, '0')}`
  return isMonthParam(out) ? out : null
}
export const prevMonth = (m) => shiftMonth(m, -1)
export const nextMonth = (m) => shiftMonth(m, 1)
/** "2026-10" -> "outubro de 2026". */
export function monthLabel(month) {
  if (!isMonthParam(month)) return ''
  return `${MONTH_NAMES[Number(month.slice(5, 7)) - 1]} de ${month.slice(0, 4)}`
}
/** "2026-10" -> "outubro" (para o botão "Receber outubro"). */
export function monthName(month) { return isMonthParam(month) ? MONTH_NAMES[Number(month.slice(5, 7)) - 1] : '' }

// ------------------------------------------------------------------ rótulos
export const FREQUENCY_LABELS = { WEEKLY: 'Semanal', BIWEEKLY: 'Quinzenal', MONTHLY: 'Mensal' }
/** "Terça · 20:00–21:00" ou "Dia 10 · 20:00–21:00". */
export function slotLabel(s) {
  if (!s) return ''
  const time = `${String(s.start_time || '').slice(0, 5)}–${String(s.end_time || '').slice(0, 5)}`
  const day = s.frequency === 'MONTHLY'
    ? (s.day_of_month != null ? `Dia ${s.day_of_month}` : '')
    : (WEEKDAY_LABELS[s.weekday] ?? '')
  // series[] do detalhe não traz weekday/day_of_month: sem o dia, mostra só o horário (nunca "· 07:00").
  return day ? `${day} · ${time}` : time
}
/** "outubro de 2026" -> "Outubro de 2026" (só a primeira letra; CSS capitalize viraria "De"). */
export function capitalizeFirst(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : '' }
/** "2026-10-03" -> "03/10". */
export function dayMonth(dateStr) {
  return typeof dateStr === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(dateStr) ? `${dateStr.slice(8, 10)}/${dateStr.slice(5, 7)}` : ''
}
/** Valor para exibição; null/indefinido => "—". */
export function moneyOrDash(v) { return toCents(v) === null ? '—' : formatCents(v) }

// ------------------------------------------------------------------ formulário "Receber mês"
export const MONTH_PAYMENT_MAX_CENTS = 100000000 // R$ 1.000.000,00 — teto do batch (constraint 03B.3A)
const FUTURE_TOLERANCE_MS = 5 * 60 * 1000 // o banco recusa received_at > now() + 5 min

/**
 * Valida o rascunho do recebimento. `openCents` = summary.open do detalhe confirmado (vem do servidor).
 * Devolve { ok, value: { amount, method, at, notes } } ou { ok:false, errors }.
 */
export function validateMonthPaymentDraft(f, { openCents, nowMs = Date.now() } = {}) {
  const errors = {}
  const open = toCents(openCents)
  const cap = open === null ? 0 : Math.min(open, MONTH_PAYMENT_MAX_CENTS)
  const amount = parseMoneyToCents(f?.amount ?? '', { max: MONTH_PAYMENT_MAX_CENTS })
  if (amount === null || amount < 1) errors.amount = 'Valor inválido. Use o formato 150,00.'
  else if (amount > cap) errors.amount = `O valor máximo é ${formatCents(cap)} (saldo do mês).`
  if (!PAYMENT_METHODS.includes(f?.method)) errors.method = 'Escolha o meio.'
  const at = localInputToISO(f?.at)
  if (!at) errors.at = 'Informe a data e a hora.'
  else if (Date.parse(at) > nowMs + FUTURE_TOLERANCE_MS) errors.at = 'A data não pode estar no futuro.'
  const notes = normalizeFinanceNotes(f?.notes ?? null)
  if (!notes.ok) errors.notes = 'Máximo de 500 caracteres.'
  if (Object.keys(errors).length) return { ok: false, errors }
  return { ok: true, value: { amount, method: f.method, at, notes: notes.value } }
}

/**
 * PRÉVIA VISUAL da distribuição (mais antigo primeiro), a partir das ocorrências e saldos retornados pelo
 * servidor. NÃO é autoridade e NUNCA é enviada: o servidor distribui e devolve o split real.
 * @param {MonthOccurrence[]} occurrences
 * @param {number} amount centavos
 * @returns {{ reservation_id: string, occurrence_date: string, amount: number }[]}
 */
export function previewMonthSplit(occurrences, amount) {
  const list = Array.isArray(occurrences) ? occurrences : []
  let left = Number.isSafeInteger(amount) && amount > 0 ? amount : 0
  const out = []
  const ordered = list
    .filter((o) => o && o.collectible === true && toCents(o.price) !== null && (toCents(o.open) ?? 0) > 0)
    .slice()
    .sort((a, b) => (a.occurrence_date < b.occurrence_date ? -1 : a.occurrence_date > b.occurrence_date ? 1
      : a.start_at < b.start_at ? -1 : a.start_at > b.start_at ? 1 : a.reservation_id < b.reservation_id ? -1 : 1))
  for (const o of ordered) {
    if (left === 0) break
    const take = Math.min(left, toCents(o.open))
    out.push({ reservation_id: o.reservation_id, occurrence_date: o.occurrence_date, amount: take })
    left -= take
  }
  return out
}

// ------------------------------------------------------------------ W1 / definir valor da série
const PHONE_MIN_DIGITS = 8
export function normalizePhoneDigits(v) { return typeof v === 'string' ? v.replace(/\D/g, '') : '' }
/** Novo cliente para o W1 (o banco reaproveita pelo telefone na organização). */
export function validateNewCustomer(f) {
  const errors = {}
  const name = typeof f?.name === 'string' ? f.name.replace(/\s+/g, ' ').trim() : ''
  const phone = normalizePhoneDigits(f?.phone)
  if (!name) errors.name = 'Informe o nome.'
  else if ([...name].length > 120) errors.name = 'Máximo de 120 caracteres.'
  if (phone && phone.length < PHONE_MIN_DIGITS) errors.phone = 'Telefone incompleto.'
  if (Object.keys(errors).length) return { ok: false, errors }
  return { ok: true, value: { name, phone: phone || null } }
}
/** Valor da série (default_price) em centavos: 0..R$100.000 (teto 03A por jogo). */
export function validateSeriesPrice(raw) {
  const cents = parseMoneyToCents(raw ?? '')
  if (cents === null) return { ok: false, error: 'Valor inválido. Use o formato 150,00.' }
  return { ok: true, value: cents }
}

// ------------------------------------------------------------------ erros das mutações (client)
// Erro de RecurringMonthRequestError/NetworkError (duck typing: sem importar o client aqui).
const FALLBACK = 'Não foi possível concluir. Tente novamente.'
/** Mensagem segura para o usuário: rede => confirmar resposta; HTTP => mensagem já saneada pela API. */
export function monthErrorMessage(e, fallback = FALLBACK) {
  if (e && e.network === true && typeof e.message === 'string') return e.message
  if (e && Number.isInteger(e.status) && typeof e.message === 'string' && e.message && !/^mensalistas \d+$/.test(e.message)) return e.message
  return fallback
}
/** reason estável da API (STATE_CHANGED, NOTHING_DUE, ...) ou null. */
export function monthErrorReason(e) { return e && typeof e.reason === 'string' ? e.reason : null }
/** Falhas em que o operation_id DEVE ser mantido (o servidor pode ter confirmado / tentar de novo). */
export function keepsIntent(e) { return !!e && (e.network === true || e.status === 503) }

// ------------------------------------------------------------------ W2: séries que ainda precisam de valor
/**
 * Séries da linhagem com jogos cobráveis SEM valor neste mês, separadas por terem ou não default_price.
 * Só agrupa o que o servidor devolveu (não calcula valores).
 * @param {MonthDetail} d
 */
export function unpricedSeries(d) {
  const ids = new Set((Array.isArray(d?.occurrences) ? d.occurrences : [])
    .filter((o) => o && o.collectible === true && o.price === null).map((o) => o.series_id))
  const list = (Array.isArray(d?.series) ? d.series : []).filter((s) => ids.has(s.series_id))
  return { withoutPrice: list.filter((s) => s.default_price === null), withPrice: list.filter((s) => s.default_price !== null) }
}
