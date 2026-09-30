// FASE 03A — constantes e helpers de APRESENTAÇÃO do financeiro. Nunca é autoridade:
// payment_status, saldos e permissões reais são decididos no banco (RPCs rg_*).
import { timeToMin } from './time.js'

export const PAYMENT_METHODS = ['PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER']
export const PAYMENT_METHOD_LABELS = {
  PIX: 'PIX', CASH: 'Dinheiro', CREDIT_CARD: 'Cartão de crédito', DEBIT_CARD: 'Cartão de débito', TRANSFER: 'Transferência', OTHER: 'Outro',
}

// Motivo de alteração de valor: CÓDIGO controlado (sem texto livre => sem PII no audit).
export const PRICE_REASONS = ['CORRECTION', 'DISCOUNT', 'COURTESY', 'RULE_RECALC', 'OTHER']
export const PRICE_REASON_LABELS = {
  CORRECTION: 'Correção de valor', DISCOUNT: 'Desconto', COURTESY: 'Cortesia', RULE_RECALC: 'Recalcular pela tabela', OTHER: 'Outro',
}

export const PAYMENT_STATUS_META = {
  NOT_APPLICABLE: { label: 'Sem cobrança', badge: 'border-border bg-muted/40 text-muted-foreground' },
  UNPRICED: { label: 'Sem valor', badge: 'border-zinc-500/30 bg-zinc-500/10 text-zinc-300' },
  PENDING: { label: 'A receber', badge: 'border-amber-500/30 bg-amber-500/10 text-amber-300' },
  PARTIAL: { label: 'Parcial', badge: 'border-sky-500/30 bg-sky-500/10 text-sky-300' },
  PAID: { label: 'Pago', badge: 'border-emerald-500/30 bg-emerald-500/15 text-emerald-300' },
  OVERPAID: { label: 'Pago a mais', badge: 'border-violet-500/30 bg-violet-500/10 text-violet-300' },
  CANCELLED: { label: 'Sem pagamento', badge: 'border-border bg-muted/40 text-muted-foreground' },
  REFUNDED: { label: 'Estornado', badge: 'border-orange-500/30 bg-orange-500/10 text-orange-300' },
  RETAINED: { label: 'Valor retido', badge: 'border-destructive/30 bg-destructive/10 text-red-300' },
}
export function paymentStatusMeta(s) { return PAYMENT_STATUS_META[s] || PAYMENT_STATUS_META.NOT_APPLICABLE }

// Observação de PAYMENT/REFUND: espelha private.rg_fin_notes() — btrim (só espaços, como o btrim de
// um argumento do Postgres), vazio => NULL, no máximo 500 caracteres contados por code point (como
// char_length). NUNCA trunca: acima do limite ou tipo diferente de string/null => inválido, para que
// duas intenções diferentes jamais sejam normalizadas para a mesma.
export const NOTES_MAX_CHARS = 500
export function normalizeFinanceNotes(v) {
  if (v === undefined || v === null) return { ok: true, value: null }
  if (typeof v !== 'string') return { ok: false, value: null }
  const t = v.replace(/^ +| +$/g, '')
  if (t === '') return { ok: true, value: null }
  if ([...t].length > NOTES_MAX_CHARS) return { ok: false, value: null }
  return { ok: true, value: t }
}

export const WEEKDAY_LABELS =['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/

// SOMENTE PRÉVIA VISUAL — nunca autoridade de persistência. Uma faixa é UMA intenção enviada em UM
// POST; quem divide (atomicamente, na mesma transação) é a RPC rg_pricing_rule_create:
//   18:00–23:00 -> 1 período; 18:00–00:00 -> 1 período até 24:00;
//   22:00–02:00 -> [dia 22:00–24:00] + [dia seguinte 00:00–02:00].
// Início = fim (exceto 00:00–00:00 = dia inteiro) => null (inválido).
export function previewRulePeriods({ weekday, start_time, end_time }) {
  if (!Number.isInteger(weekday) || weekday < 0 || weekday > 6 || !HHMM.test(start_time || '') || !HHMM.test(end_time || '')) return null
  const s = timeToMin(start_time)
  const e = timeToMin(end_time)
  if (e !== 0 && e === s) return null
  if (e === 0 || e > s) return [{ weekday, start_time, end_time }]
  return [{ weekday, start_time, end_time: '00:00' }, { weekday: (weekday + 1) % 7, start_time: '00:00', end_time }]
}

// "YYYY-MM-DDTHH:MM" (input datetime-local, horário da arena) <-> ISO com offset fixo -03:00.
export function localInputToISO(v) {
  return typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v) ? `${v}:00-03:00` : null
}
export function nowLocalInput(now = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(now)
  const g = (t) => parts.find((p) => p.type === t)?.value || '00'
  return `${g('year')}-${g('month')}-${g('day')}T${g('hour') === '24' ? '00' : g('hour')}:${g('minute')}`
}
