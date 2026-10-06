// FASE 03B.2B — Despesas & Caixa: constantes e helpers de APRESENTAÇÃO (puro, sem I/O). Nunca é
// autoridade: status, saldos, travas (amount_locked/arena_locked), can_cancel e direção do dinheiro
// vêm do banco (RPCs da 03B.2). Aqui só se traduz o que o banco devolveu em rótulos/ações/formulários.
import { parseMoneyToCents, toCents, formatCents } from './money.js'
import { isValidDateStr } from './time.js'
import { PAYMENT_METHODS, normalizeFinanceNotes, localInputToISO } from './finance.js'
import { newOperationId } from './operation-id.js'
import { EXPENSE_MAX_CENTS, DESCRIPTION_MAX_CHARS, CATEGORY_NAME_MAX_CHARS, REASON_MAX_CHARS, normalizeExpenseText } from './expenses-api.js'

export { EXPENSE_MAX_CENTS, normalizeExpenseText }

// ------------------------------------------------------------------ filtros e status
export const EXPENSE_STATUS_FILTERS = ['ACTIVE', 'OPEN', 'OVERDUE', 'PAID', 'CANCELLED']
export const DEFAULT_EXPENSE_FILTER = 'ACTIVE'
export const EXPENSE_FILTER_LABELS = { ACTIVE: 'Ativas', OPEN: 'Em aberto', OVERDUE: 'Vencidas', PAID: 'Pagas', CANCELLED: 'Canceladas' }

// Status derivado pelo banco (private.rg_exp_rows). OVERDUE é FLAG (overdue=true) sobre OPEN/PARTIAL.
export const EXPENSE_STATUS_META = {
  OPEN: { label: 'Em aberto', badge: 'border-amber-500/30 bg-amber-500/10 text-amber-300' },
  PARTIAL: { label: 'Parcial', badge: 'border-sky-500/30 bg-sky-500/10 text-sky-300' },
  PAID: { label: 'Paga', badge: 'border-emerald-500/30 bg-emerald-500/15 text-emerald-300' },
  CANCELLED: { label: 'Cancelada', badge: 'border-border bg-muted/40 text-muted-foreground' },
}
export const OVERDUE_META = { label: 'Vencida', badge: 'border-amber-500/40 bg-amber-500/15 text-amber-400' }

// Badges de uma despesa (linha da lista ou detalhe): status + "Vencida" quando o banco marcar overdue.
export function expenseBadges(row) {
  const meta = EXPENSE_STATUS_META[row?.status]
  if (!meta) return []
  const out = [{ key: row.status, label: meta.label, badge: meta.badge }]
  if (row.overdue === true && (row.status === 'OPEN' || row.status === 'PARTIAL')) out.push({ key: 'OVERDUE', label: OVERDUE_META.label, badge: OVERDUE_META.badge })
  return out
}

// "YYYY-MM-DD" -> "dd/mm/aaaa" (sem Date: nada de leitura em UTC).
export function fmtDueDate(s) { return isValidDateStr(s) ? `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}` : '' }

// ------------------------------------------------------------------ ações do detalhe
// Valor ainda devolvível de um PAYMENT (detalhe traz `reversed` = soma das devoluções não anuladas).
export function reversibleOf(entry) {
  if (!entry || entry.kind !== 'PAYMENT' || entry.voided_at) return 0
  const amount = toCents(entry.amount), reversed = toCents(entry.reversed ?? 0)
  return amount === null || reversed === null ? 0 : Math.max(0, amount - reversed)
}

// Ações disponíveis segundo o ESTADO REAL devolvido por rg_expense_detail. O banco continua decidindo
// (AMOUNT_LOCKED, HAS_REVERSALS, NET_PAID...): isto só evita oferecer o que certamente seria recusado.
export function deriveExpenseActions(d) {
  if (!d || typeof d !== 'object') return null
  const cancelled = d.cancelled_at != null
  const due = toCents(d.amount_due)
  const entries = (Array.isArray(d.entries) ? d.entries : []).map((e) => {
    const active = !e.voided_at
    const reversible = reversibleOf(e)
    const hasReversals = e.kind === 'PAYMENT' && (toCents(e.reversed ?? 0) || 0) > 0
    return {
      ...e,
      active,
      reversible,
      canReverse: !cancelled && active && e.kind === 'PAYMENT' && reversible > 0,
      canVoid: !cancelled && active && !(e.kind === 'PAYMENT' && hasReversals),
      voidBlocked: !cancelled && active && e.kind === 'PAYMENT' && hasReversals ? 'HAS_REVERSALS' : null,
    }
  })
  return {
    cancelled,
    canEdit: !cancelled,
    canPay: !cancelled && due !== null && due > 0,
    canCancel: d.can_cancel === true,
    amountLocked: d.amount_locked === true,
    arenaLocked: d.arena_locked === true,
    entries,
  }
}

// ------------------------------------------------------------------ formulários
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const chars = (s) => [...s].length
const moneyOpts = { max: EXPENSE_MAX_CENTS }

// Rascunho da despesa (strings do formulário) -> valores da API. errors: { campo: mensagem }.
export function validateExpenseDraft(f) {
  const errors = {}
  const description = normalizeExpenseText(f?.description ?? '')
  if (!description) errors.description = 'Informe a descrição.'
  else if (chars(description) > DESCRIPTION_MAX_CHARS) errors.description = `Máximo de ${DESCRIPTION_MAX_CHARS} caracteres.`
  const category_id = f?.category_id || ''
  if (!UUID_RE.test(category_id)) errors.category_id = 'Escolha a categoria.'
  const arena_id = f?.arena_id ? f.arena_id : null
  if (arena_id !== null && !UUID_RE.test(arena_id)) errors.arena_id = 'Arena inválida.'
  const amount = parseMoneyToCents(f?.amount ?? '', moneyOpts)
  if (amount === null || amount < 1) errors.amount = 'Valor inválido. Use o formato 150,00 (até R$ 1.000.000,00).'
  const due_date = f?.due_date || ''
  if (!isValidDateStr(due_date)) errors.due_date = 'Informe o vencimento.'
  const notes = normalizeFinanceNotes(f?.notes ?? null)
  if (!notes.ok) errors.notes = 'Máximo de 500 caracteres.'
  if (Object.keys(errors).length) return { ok: false, errors }
  return { ok: true, value: { description, category_id, arena_id, amount, due_date, notes: notes.value } }
}

// Diferença entre o detalhe carregado e o rascunho válido: só os campos realmente alterados. Campos
// travados pelo banco (amount_locked / arena_locked) nunca entram. {} => nada a alterar.
export function buildExpenseChanges(d, v) {
  const changes = {}
  if (!d || !v) return changes
  if (v.description !== d.description) changes.description = v.description
  if (v.category_id !== d.category_id) changes.category_id = v.category_id
  if (d.arena_locked !== true && (v.arena_id ?? null) !== (d.arena_id ?? null)) changes.arena_id = v.arena_id ?? null
  if (d.amount_locked !== true && v.amount !== toCents(d.amount)) changes.amount = v.amount
  if (v.due_date !== d.due_date) changes.due_date = v.due_date
  if ((v.notes ?? null) !== (d.notes ?? null)) changes.notes = v.notes ?? null
  return changes
}

// Pagamento/devolução: valor (até maxCents), meio, data local "YYYY-MM-DDTHH:MM" (não futura), observação.
export function validateEntryDraft(f, { maxCents = EXPENSE_MAX_CENTS, nowMs = Date.now() } = {}) {
  const errors = {}
  const cap = Math.min(EXPENSE_MAX_CENTS, Number.isSafeInteger(maxCents) ? maxCents : 0)
  const amount = parseMoneyToCents(f?.amount ?? '', moneyOpts)
  if (amount === null || amount < 1) errors.amount = 'Valor inválido. Use o formato 150,00.'
  else if (amount > cap) errors.amount = `O valor máximo é ${formatCents(cap)}.`
  if (!PAYMENT_METHODS.includes(f?.method)) errors.method = 'Escolha o meio.'
  const at = localInputToISO(f?.at)
  if (!at) errors.at = 'Informe a data e a hora.'
  else if (Date.parse(at) > nowMs) errors.at = 'A data não pode estar no futuro.'
  const notes = normalizeFinanceNotes(f?.notes ?? null)
  if (!notes.ok) errors.notes = 'Máximo de 500 caracteres.'
  if (Object.keys(errors).length) return { ok: false, errors }
  return { ok: true, value: { amount, method: f.method, at, notes: notes.value } }
}

export function validateReason(s) {
  const t = typeof s === 'string' ? s.trim() : ''
  if (!t) return { ok: false, error: 'Informe o motivo.' }
  if (chars(t) > REASON_MAX_CHARS) return { ok: false, error: `Máximo de ${REASON_MAX_CHARS} caracteres.` }
  return { ok: true, value: t }
}

export function validateCategoryName(s) {
  const t = normalizeExpenseText(s ?? '')
  if (!t) return { ok: false, error: 'Informe o nome.' }
  if (chars(t) > CATEGORY_NAME_MAX_CHARS) return { ok: false, error: `Máximo de ${CATEGORY_NAME_MAX_CHARS} caracteres.` }
  return { ok: true, value: t }
}

// Opções do select de categoria: ativas (ordem do banco) + a atual da despesa, mesmo inativa.
export function categoryOptions(categories, currentId = null) {
  const list = Array.isArray(categories) ? categories : []
  return list.filter((c) => c.is_active === true || (currentId && c.id === currentId))
}

// ------------------------------------------------------------------ idempotência por intenção
// operation_id gerado UMA vez por intenção (no 1º envio) e reutilizado em todo retry; reset() ao mudar
// qualquer campo, ao fechar o formulário ou depois do sucesso (próxima ação = nova intenção).
export function createOperationIntent(gen = newOperationId) {
  let key = null
  return {
    get() { if (key === null) key = gen(); return key },
    peek() { return key },
    reset() { key = null },
  }
}

// ------------------------------------------------------------------ Caixa: movimentos
// Rótulo pela ORIGEM + TIPO; direção/sinal SEMPRE pelos campos do banco (direction / signed_amount),
// nunca inferidos da origem.
export const MOVEMENT_LABELS = {
  'RESERVATION:PAYMENT': 'Recebimento de reserva',
  'RESERVATION:REFUND': 'Estorno de reserva',
  'EXPENSE:PAYMENT': 'Pagamento de despesa',
  'EXPENSE:REVERSAL': 'Devolução de despesa',
}
export function movementView(m) {
  const signed = toCents(m?.signed_amount)
  const direction = m?.direction === 'IN' || m?.direction === 'OUT' ? m.direction : null
  return {
    label: MOVEMENT_LABELS[`${m?.source}:${m?.kind}`] || 'Movimento',
    direction,
    tone: direction === 'IN' ? 'in' : direction === 'OUT' ? 'out' : 'neutral',
    value: signed === null ? '—' : `${signed > 0 ? '+' : ''}${formatCents(signed)}`,
    // invariante do contrato: IN sse signed_amount > 0 (banco garante; aqui só sinaliza dado inesperado)
    consistent: direction !== null && signed !== null && (direction === 'IN') === (signed > 0),
  }
}
