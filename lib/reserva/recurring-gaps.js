// FASE 03C — rótulos e formatação das LACUNAS de recorrência (ocorrência esperada e não materializada).
// Puro (sem rede). O estado vem do banco (public.rg_recurring_gaps via GET /recurring-reservations/:id/gaps);
// nada aqui decide se uma data é ou não ocorrência — só apresenta o que o servidor persistiu.

/** Motivos persistidos (CHECK em public.recurring_occurrence_gaps.reason). */
export const GAP_REASONS = ['CONFLICT', 'OUTSIDE_BUSINESS_HOURS', 'COURT_INACTIVE']

export const GAP_REASON_LABELS = {
  CONFLICT: 'Horário ocupado por outra reserva',
  OUTSIDE_BUSINESS_HOURS: 'Fora do horário de funcionamento',
  COURT_INACTIVE: 'Quadra inativa',
}

/** O que o gestor pode fazer para resolver cada motivo (texto curto, sem dados de terceiros). */
export const GAP_REASON_HINTS = {
  CONFLICT: 'Cancele ou mova a reserva que ocupa o horário; a data é gerada na próxima execução.',
  OUTSIDE_BUSINESS_HOURS: 'Ajuste o horário de funcionamento ou o horário da série.',
  COURT_INACTIVE: 'Reative a quadra ou mude a série de quadra ("esta e as próximas").',
}

export function gapReasonLabel(reason) { return GAP_REASON_LABELS[reason] || 'Data não gerada' }
export function gapReasonHint(reason) { return GAP_REASON_HINTS[reason] || null }

const TZ = 'America/Sao_Paulo'
const hm = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false })

/** "2026-10-16" -> "16/10". */
export function gapDateLabel(dateStr) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dateStr || ''))
  return m ? `${m[3]}/${m[2]}` : '—'
}

/** Resumo da reserva que ocupa (só horário e estado; o servidor não envia dados do cliente). */
export function gapConflictLabel(conflict) {
  if (!conflict || !conflict.start_at || !conflict.end_at) return null
  const kind = conflict.recurring ? 'outro mensalista' : conflict.status === 'BLOCKED' ? 'bloqueio' : 'reserva avulsa'
  return `${kind} ${hm.format(new Date(conflict.start_at))}–${hm.format(new Date(conflict.end_at))}`
}

/** Normaliza a resposta da API (defensivo): só itens com data e motivo conhecidos, ordenados por data. */
export function normalizeGaps(payload) {
  const items = Array.isArray(payload?.items) ? payload.items : []
  return items
    .filter((g) => g && /^\d{4}-\d{2}-\d{2}$/.test(String(g.occurrence_date || '')) && GAP_REASONS.includes(g.reason))
    .map((g) => ({ id: g.id, series_id: g.series_id, date: g.occurrence_date, reason: g.reason, conflict: g.conflict || null }))
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0))
}
