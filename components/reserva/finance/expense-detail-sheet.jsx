'use client'

// FASE 03B.2B-2A — detalhe de UMA despesa. Tudo vem de rg_expense_detail via /api/finance/expenses/:id.
// Sequência própria (expDetail): abrir outra despesa ou fechar o Sheet invalida a requisição anterior —
// resposta antiga nunca substitui a despesa aberta agora.
// FASE 03B.2B-2B — ações pelo ESTADO REAL do banco (deriveExpenseActions): Editar, Registrar pagamento,
// Cancelar despesa e, por lançamento, Registrar devolução / Anular lançamento. Os formulários ficam em
// expense-forms.jsx. Depois de cada mutação (ou de recusa por estado), o detalhe é recarregado em
// segundo plano e a aba é avisada (onChanged) — nada otimista.
import { useEffect, useState } from 'react'
import { runLatest } from '@/lib/reserva/latest-request'
import { expenseBadges, fmtDueDate, deriveExpenseActions } from '@/lib/reserva/expenses'
import { formatCents } from '@/lib/reserva/money'
import { PAYMENT_METHOD_LABELS } from '@/lib/reserva/finance'
import { fmtDateTimeLong } from '@/lib/reserva/time'
import { ExpenseFormDialog, EntryDialog, ReasonDialog } from '@/components/reserva/finance/expense-forms'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { AlertTriangle, Ban, Loader2, Pencil, Plus, RefreshCw, Undo2, XCircle } from 'lucide-react'
import { cn } from '@/lib/utils'

export function ExpenseBadges({ row, className }) {
  return expenseBadges(row).map((b) => <Badge key={b.key} className={cn('border font-normal', b.badge, className)}>{b.label}</Badge>)
}

export function ExpenseDetailSheet({ expenseId, api, seq, onClose, onForbidden, returnFocusTo, orgId, arenas = [], categories = [], onChanged, onCategoriesChanged }) {
  const [st, setSt] = useState({ loading: true, error: false, data: null })
  const [reload, setReload] = useState(0)
  const [dlg, setDlg] = useState(null)

  useEffect(() => {
    runLatest(seq, () => api.detail(expenseId), {
      // recarga da MESMA despesa mantém o conteúdo visível; outra despesa nunca herda dados da anterior
      onStart: () => setSt((s) => ({ loading: true, error: false, data: s.data?.expense_id === expenseId ? s.data : null })),
      onResult: (d) => setSt({ loading: false, error: false, data: d }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setSt({ loading: false, error: true, data: null, notFound: e?.status === 404 }) },
    })
    return () => seq.invalidate()
  }, [expenseId, reload])

  // Depois de uma mutação (ou recusa por estado): recarrega o detalhe e avisa a aba (lista + resumo).
  const done = async (opts) => {
    if (!opts?.keepOpen) setDlg(null)
    setReload((n) => n + 1)
    onChanged?.()
  }

  const d = st.data
  const a = d ? deriveExpenseActions(d) : null
  return (
    <Sheet open onOpenChange={(o) => { if (!o) onClose() }}>
      <SheetContent
        className="w-full overflow-y-auto sm:max-w-lg motion-reduce:animate-none motion-reduce:transition-none"
        onCloseAutoFocus={(e) => { const el = returnFocusTo?.current; if (el && el.isConnected) { e.preventDefault(); el.focus() } }}>
        <SheetHeader>
          <SheetTitle>{d?.description || 'Despesa'}</SheetTitle>
          <SheetDescription>Dados, situação e histórico de lançamentos da despesa selecionada.</SheetDescription>
        </SheetHeader>
        {st.error ? (
          <div className="mt-6 space-y-3 rounded-lg border border-border px-4 py-5 text-center">
            <AlertTriangle className="mx-auto h-5 w-5 text-amber-500" />
            <p className="text-sm text-muted-foreground">{st.notFound ? 'Despesa não encontrada.' : 'Não foi possível carregar a despesa.'}</p>
            {!st.notFound && <Button variant="outline" className="h-11 sm:h-9" onClick={() => setReload((n) => n + 1)}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>}
          </div>
        ) : !d ? (
          <div className="mt-6 space-y-3" role="status" aria-label="Carregando despesa">
            <Skeleton className="h-6 w-40" /><Skeleton className="h-24 w-full" /><Skeleton className="h-32 w-full" />
          </div>
        ) : (
          <div aria-busy={st.loading}>
            {st.loading && (
              <p className="mt-3 flex items-center gap-2 text-xs text-muted-foreground" role="status" aria-live="polite">
                <Loader2 className="h-3.5 w-3.5 animate-spin motion-reduce:animate-none" /> Atualizando…
              </p>
            )}
            <ExpenseActions a={a} busy={st.loading} onEdit={() => setDlg({ type: 'edit' })} onPay={() => setDlg({ type: 'payment' })} onCancel={() => setDlg({ type: 'cancel' })} />
            <ExpenseDetailBody d={d} a={a} busy={st.loading} onReverse={(e) => setDlg({ type: 'reverse', entry: e })} onVoid={(e) => setDlg({ type: 'void', entry: e })} />
          </div>
        )}
        {d && dlg?.type === 'edit' && (
          <ExpenseFormDialog mode="edit" api={api} orgId={orgId} arenas={arenas} categories={categories} detail={d} onClose={() => setDlg(null)} onDone={done} onCategoriesChanged={onCategoriesChanged} />
        )}
        {d && dlg?.type === 'payment' && <EntryDialog kind="payment" api={api} expense={d} onClose={() => setDlg(null)} onDone={done} />}
        {d && dlg?.type === 'reverse' && <EntryDialog kind="reverse" api={api} expense={d} entry={dlg.entry} onClose={() => setDlg(null)} onDone={done} />}
        {d && dlg?.type === 'void' && <ReasonDialog kind="void" api={api} expense={d} entry={dlg.entry} onClose={() => setDlg(null)} onDone={done} />}
        {d && dlg?.type === 'cancel' && <ReasonDialog kind="cancel" api={api} expense={d} onClose={() => setDlg(null)} onDone={done} />}
      </SheetContent>
    </Sheet>
  )
}

// Ações da despesa: só as que o estado real permite (o banco continua decidindo).
function ExpenseActions({ a, busy, onEdit, onPay, onCancel }) {
  if (!a || (!a.canEdit && !a.canPay && !a.canCancel)) return null
  return (
    <div className="mt-4 flex flex-wrap gap-2">
      {a.canPay && <Button className="h-11 sm:h-9" disabled={busy} onClick={onPay}><Plus className="mr-1.5 h-4 w-4" /> Registrar pagamento</Button>}
      {a.canEdit && <Button variant="outline" className="h-11 sm:h-9" disabled={busy} onClick={onEdit}><Pencil className="mr-1.5 h-4 w-4" /> Editar</Button>}
      {a.canCancel && <Button variant="outline" className="h-11 hover:text-destructive sm:h-9" disabled={busy} onClick={onCancel}><XCircle className="mr-1.5 h-4 w-4" /> Cancelar despesa</Button>}
    </div>
  )
}

function Row({ label, value }) {
  return <div className="py-2"><p className="text-xs text-muted-foreground">{label}</p><p className="break-words text-sm">{value || '—'}</p></div>
}
function Amount({ label, value, strong }) {
  return (
    <div className="rounded-lg bg-muted/30 px-3 py-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={cn('whitespace-nowrap text-sm', strong && 'font-semibold')}>{value}</p>
    </div>
  )
}

function ExpenseDetailBody({ d, a, busy, onReverse, onVoid }) {
  const entries = a ? a.entries : (Array.isArray(d.entries) ? d.entries : [])
  const byId = Object.fromEntries(entries.map((e) => [e.payment_id, e]))
  return (
    <div className="mt-4 space-y-5">
      <div className="flex flex-wrap gap-1.5"><ExpenseBadges row={d} /></div>
      {d.cancelled_at && (
        <p className="rounded-lg border border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
          Cancelada em {fmtDateTimeLong(d.cancelled_at)}{d.cancel_reason ? ` · Motivo: ${d.cancel_reason}` : ''}
        </p>
      )}
      <div className="divide-y divide-border">
        <Row label="Categoria" value={d.category_name} />
        <Row label="Arena" value={d.arena_id ? d.arena_name : 'Geral'} />
        <Row label="Vencimento" value={fmtDueDate(d.due_date)} />
        <Row label="Observação" value={d.notes} />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <Amount label="Valor" value={formatCents(d.amount)} strong />
        <Amount label="A pagar" value={formatCents(d.amount_due)} strong />
        <Amount label="Pago bruto" value={formatCents(d.paid_gross)} />
        <Amount label="Devolvido" value={formatCents(d.reversed)} />
        <Amount label="Pago líquido" value={formatCents(d.net_paid)} />
      </div>
      <div className="space-y-2 border-t border-border pt-4">
        <p className="text-sm font-semibold">Lançamentos</p>
        {entries.length === 0 ? <p className="text-xs text-muted-foreground">Nenhum lançamento registrado.</p> : (
          <ul className="space-y-1.5">
            {entries.map((e) => {
              const reversal = e.kind === 'REVERSAL'
              const parent = reversal ? byId[e.reversal_of] : null
              return (
                <li key={e.payment_id} className={cn('rounded-lg border border-border px-3 py-2 text-xs', e.voided_at && 'opacity-60', reversal && 'ml-4 border-l-2 border-l-sky-500/40')}>
                  <div className="flex items-start justify-between gap-2">
                    <p className={cn('font-medium', e.voided_at && 'line-through')}>{reversal ? 'Devolução' : 'Pagamento'} · {PAYMENT_METHOD_LABELS[e.method] || e.method}</p>
                    <span className={cn('whitespace-nowrap font-semibold', e.voided_at && 'line-through')}>{formatCents(e.amount)}</span>
                  </div>
                  <p className="text-muted-foreground">{fmtDateTimeLong(e.paid_at)}{e.notes ? ` · ${e.notes}` : ''}</p>
                  {reversal && <p className="text-muted-foreground">Devolução do pagamento{parent ? ` de ${fmtDateTimeLong(parent.paid_at)} (${formatCents(parent.amount)})` : ''}</p>}
                  {!reversal && e.reversed > 0 && <p className="text-muted-foreground">Devolvido deste pagamento: {formatCents(e.reversed)}</p>}
                  {e.voided_at && <p className="text-muted-foreground">Anulado em {fmtDateTimeLong(e.voided_at)}{e.void_reason ? ` · Motivo: ${e.void_reason}` : ''}</p>}
                  {(e.canReverse || e.canVoid || e.voidBlocked) && (
                    <div className="mt-2 flex flex-wrap gap-1.5">
                      {e.canReverse && <Button size="sm" variant="outline" className="h-11 sm:h-8" disabled={busy} onClick={() => onReverse(e)}><Undo2 className="mr-1 h-3.5 w-3.5" /> Registrar devolução</Button>}
                      {(e.canVoid || e.voidBlocked) && (
                        <Button size="sm" variant="ghost" className="h-11 hover:text-destructive sm:h-8" disabled={busy || !e.canVoid} onClick={() => onVoid(e)}
                          aria-describedby={e.voidBlocked ? `void-blocked-${e.payment_id}` : undefined}><Ban className="mr-1 h-3.5 w-3.5" /> Anular lançamento</Button>
                      )}
                      {e.voidBlocked === 'HAS_REVERSALS' && <p id={`void-blocked-${e.payment_id}`} className="w-full text-muted-foreground">Anule primeiro as devoluções deste pagamento.</p>}
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </div>
  )
}
