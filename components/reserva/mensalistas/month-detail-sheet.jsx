'use client'

// FASE 03B.3B — detalhe de UM mensalista (linhagem) no mês. Fonte: rg_recurring_month_detail (aceita o id de
// qualquer série da linhagem). Tudo o que é financeiro (resumo, status, saldo por jogo, elegibilidade, motivo
// de bloqueio, permissões de W1/W2) vem do servidor. Ações:
//   - "Receber <mês>" (qualquer membro ativo; só quando eligible);
//   - W1 vincular cliente / definir valor + W2 aplicar valor (OWNER/MANAGER: canViewFinance);
//   - estorno/anulação por jogo pelo FinancePanel da 03A (OWNER/MANAGER);
//   - "Gerar próximas datas" (ação explícita existente; leitura nunca gera ocorrência).
// Depois de qualquer mutação: refetch do detalhe e aviso à lista (onChanged) — nada otimista.
import { useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import { runLatest } from '@/lib/reserva/latest-request'
import {
  slotLabel, monthLabel, monthName, dayMonth, moneyOrDash, FREQUENCY_LABELS, OCCURRENCE_STATUS_LABELS, MONTH_REASON_MSG,
} from '@/lib/reserva/recurring-month'
import { WEEKDAY_LABELS } from '@/lib/reserva/finance'
import { fmtTime } from '@/lib/reserva/time'
import { FinancePanel, PaymentStatusBadge } from '@/components/reserva/finance-panel'
import { MonthStatusBadge, MonthNav, Money, NoCustomerBadge } from '@/components/reserva/mensalistas/month-ui'
import { ReceiveMonthDialog } from '@/components/reserva/mensalistas/receive-month-dialog'
import { LinkCustomerDialog } from '@/components/reserva/mensalistas/link-customer-dialog'
import { ApplySeriesPriceDialog } from '@/components/reserva/mensalistas/apply-series-price-dialog'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { AlertTriangle, CalendarPlus, CheckCircle2, Info, Loader2, RefreshCw, Tag, UserPlus, Wallet } from 'lucide-react'
import { cn } from '@/lib/utils'

export function MonthDetailSheet({ api, seq, lineageId, month, currentMonth, manager, role, orgId, onChangeMonth, onClose, onChanged, returnFocusTo }) {
  const [st, setSt] = useState({ loading: true, error: false, notFound: false, data: null, key: null })
  const [reload, setReload] = useState(0)
  const [dlg, setDlg] = useState(null) // 'receive' | 'link' | 'price' | { finance: occurrence }
  const [result, setResult] = useState(null) // split REAL do último recebimento
  const [generating, setGenerating] = useState(false)
  const dlgTrigger = useRef(null)
  const pending = useRef(null)

  useEffect(() => {
    const key = `${lineageId}|${month}`
    runLatest(seq, () => api.detail(lineageId, month), {
      // mesma linhagem e mesmo mês: mantém o conteúdo visível enquanto atualiza; outro mensalista/mês nunca herda o anterior
      onStart: () => setSt((s) => ({ loading: true, error: false, notFound: false, data: s.key === key ? s.data : null, key: s.key === key ? key : null })),
      onResult: (d) => { setSt({ loading: false, error: false, notFound: false, data: d, key }); if (pending.current) { pending.current(); pending.current = null } },
      onError: (e) => { setSt({ loading: false, error: true, notFound: e?.status === 404 || e?.status === 403, data: null, key: null }); if (pending.current) { pending.current(); pending.current = null } },
    })
    return () => seq.invalidate()
  }, [lineageId, month, reload])

  useEffect(() => { setResult(null) }, [lineageId, month])

  // Recarrega o detalhe e espera a resposta (usado pelos diálogos antes de seguir para o próximo passo).
  const reloadDetail = () => new Promise((resolve) => { pending.current = resolve; setReload((n) => n + 1) })
  const afterMutation = async () => { await reloadDetail(); onChanged?.() }
  const openDlg = (next, ev) => { dlgTrigger.current = ev?.currentTarget || null; setDlg(next) }

  async function generate() {
    const id = st.data?.current?.series_id
    if (!id || generating) return
    setGenerating(true)
    try {
      const r = await fetch(`/api/recurring-reservations/${encodeURIComponent(id)}/generate`, { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      const d = await r.json().catch(() => null)
      if (!r.ok) toast.error(typeof d?.error === 'string' ? d.error : 'Não foi possível gerar as próximas datas.')
      else toast.success(d?.created > 0 ? `${d.created} data(s) gerada(s)` : 'Nenhuma data nova para gerar (conflito ou fora do horário de funcionamento)')
    } catch { toast.error('Não foi possível confirmar a resposta do servidor. Atualize e confira.') }
    finally { setGenerating(false); await afterMutation() }
  }

  const d = st.data
  return (
    <Sheet open onOpenChange={(o) => { if (!o) onClose() }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-xl motion-reduce:animate-none motion-reduce:transition-none"
        onCloseAutoFocus={(e) => { const el = returnFocusTo?.current; if (el && el.isConnected) { e.preventDefault(); el.focus() } }}>
        <SheetHeader>
          <SheetTitle className={cn(!d?.customer && d && 'italic')}>{d ? (d.customer?.name || 'Sem cliente cadastrado') : 'Mensalista'}</SheetTitle>
          <SheetDescription>
            {d?.current ? `${slotLabel(d.current)} · ${d.current.court_name} · ${FREQUENCY_LABELS[d.current.frequency] || ''}` : 'Jogos, valores e recebimento do mês.'}
          </SheetDescription>
        </SheetHeader>

        <MonthNav month={month} currentMonth={currentMonth} onChange={onChangeMonth} compact className="mt-4" />

        {st.error ? (
          <div className="mt-6 space-y-3 rounded-lg border border-border px-4 py-5 text-center">
            <AlertTriangle className="mx-auto h-5 w-5 text-amber-500" aria-hidden="true" />
            <p className="text-sm text-muted-foreground">{st.notFound ? 'Mensalista não encontrado.' : 'Não foi possível carregar o mensalista.'}</p>
            {!st.notFound && <Button variant="outline" className="h-11 sm:h-9" onClick={() => setReload((n) => n + 1)}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>}
          </div>
        ) : !d ? (
          <div className="mt-6 space-y-3" role="status" aria-label="Carregando mensalista"><Skeleton className="h-20 w-full" /><Skeleton className="h-40 w-full" /></div>
        ) : (
          <div className="mt-4 space-y-5" aria-busy={st.loading}>
            {st.loading && (
              <p className="flex items-center gap-2 text-xs text-muted-foreground" role="status" aria-live="polite">
                <Loader2 className="h-3.5 w-3.5 animate-spin motion-reduce:animate-none" /> Atualizando…
              </p>
            )}
            {d.series.length > 1 && (
              <p className="flex items-start gap-2 text-xs text-muted-foreground"><Info className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
                Horário alterado em {dayMonth(d.series[d.series.length - 1].start_date)}: o mês inclui os jogos das {d.series.length} séries deste mensalista.</p>
            )}

            <Summary d={d} manager={manager} />

            <Blocked d={d} manager={manager} onLink={(e) => openDlg('link', e)} onPrice={(e) => openDlg('price', e)} />

            {d.eligible && (
              <Button className="h-12 w-full text-base" onClick={(e) => openDlg('receive', e)}>
                <Wallet className="mr-2 h-4 w-4" /> Receber {monthName(month)} · {moneyOrDash(d.summary.open)}
              </Button>
            )}

            {result && <PaymentResult result={result} onDismiss={() => setResult(null)} />}

            <Occurrences d={d} manager={manager} onFinance={(o, e) => openDlg({ finance: o }, e)} />

            {d.missing_future_dates.length > 0 && (
              <div className="rounded-lg border border-dashed border-border px-3 py-3 text-sm">
                <p className="text-muted-foreground">{d.missing_future_dates.length} data(s) prevista(s) deste mês ainda não gerada(s): {d.missing_future_dates.map(dayMonth).join(', ')}.</p>
                {manager && (
                  <Button variant="outline" className="mt-2 h-11 sm:h-9" onClick={generate} disabled={generating}>
                    {generating ? <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" /> : <CalendarPlus className="mr-2 h-4 w-4" />}Gerar próximas datas
                  </Button>
                )}
              </div>
            )}
          </div>
        )}

        {d && dlg === 'receive' && (
          <ReceiveMonthDialog api={api} detail={d} month={month} returnFocusTo={dlgTrigger} onClose={() => setDlg(null)} onReload={reloadDetail}
            onDone={async (r) => { setDlg(null); setResult(r); await afterMutation() }} />
        )}
        {d && dlg === 'link' && manager && (
          <LinkCustomerDialog api={api} orgId={orgId} lineageId={d.lineage_id} returnFocusTo={dlgTrigger} onClose={() => setDlg(null)}
            onDone={async () => { setDlg(null); await afterMutation() }} />
        )}
        {d && dlg === 'price' && manager && (
          <ApplySeriesPriceDialog api={api} detail={d} month={month} returnFocusTo={dlgTrigger} onClose={() => setDlg(null)} onReload={afterMutation}
            onDone={async () => { setDlg(null); await afterMutation() }} />
        )}
        {d && dlg?.finance && manager && (
          <Sheet open onOpenChange={(o) => { if (!o) setDlg(null) }}>
            <SheetContent className="w-full overflow-y-auto sm:max-w-lg"
              onCloseAutoFocus={(e) => { const el = dlgTrigger.current; if (el && el.isConnected) { e.preventDefault(); el.focus() } }}>
              <SheetHeader>
                <SheetTitle>Jogo de {dayMonth(dlg.finance.occurrence_date)}</SheetTitle>
                <SheetDescription>Lançamentos deste jogo. Estorno e anulação são individuais.</SheetDescription>
              </SheetHeader>
              <FinancePanel reservationId={dlg.finance.reservation_id} role={role} onChanged={afterMutation} />
            </SheetContent>
          </Sheet>
        )}
      </SheetContent>
    </Sheet>
  )
}

function Summary({ d, manager }) {
  const s = d.summary
  return (
    <div className="rounded-lg border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-medium">{s.games} jogo{s.games === 1 ? '' : 's'}{s.cancelled > 0 ? ` · ${s.cancelled} cancelado${s.cancelled === 1 ? '' : 's'}` : ''}</p>
        <span className="flex flex-wrap gap-1"><MonthStatusBadge status={s.status} />{!d.customer && <NoCustomerBadge />}</span>
      </div>
      <dl className="mt-3 grid grid-cols-3 gap-2 text-sm">
        <div><dt className="text-xs text-muted-foreground">Previsto</dt><dd><Money value={s.expected} /></dd></div>
        <div><dt className="text-xs text-muted-foreground">Recebido</dt><dd><Money value={s.net} /></dd></div>
        <div><dt className="text-xs text-muted-foreground">A receber</dt><dd><Money value={s.open} strong /></dd></div>
      </dl>
      {s.overdue > 0 && <p className="mt-2 text-xs text-red-300">{moneyOrDash(s.overdue)} vencido (jogos que já aconteceram).</p>}
      {s.unpriced > 0 && <p className="mt-1 text-xs text-amber-300">{s.unpriced} jogo{s.unpriced === 1 ? '' : 's'} sem valor.</p>}
      {manager && s.retained > 0 && <p className="mt-1 text-xs text-muted-foreground">Retido em jogos cancelados: {moneyOrDash(s.retained)} (estorno individual pelo jogo).</p>}
    </div>
  )
}

function Blocked({ d, manager, onLink, onPrice }) {
  if (d.blocked_reason === 'CUSTOMER_REQUIRED') {
    return (
      <Notice text={MONTH_REASON_MSG.CUSTOMER_REQUIRED}>
        {manager
          ? <Button variant="outline" className="h-11 sm:h-9" onClick={onLink}><UserPlus className="mr-2 h-4 w-4" /> Vincular cliente</Button>
          : <p className="text-xs text-muted-foreground">Peça ao gestor para vincular o cliente.</p>}
      </Notice>
    )
  }
  if (d.blocked_reason === 'UNPRICED') {
    return (
      <Notice text={MONTH_REASON_MSG.UNPRICED}>
        {manager
          ? <Button variant="outline" className="h-11 sm:h-9" onClick={onPrice}><Tag className="mr-2 h-4 w-4" /> {d.can_apply_series_price ? 'Aplicar valor da série' : 'Definir valor da série'}</Button>
          : <p className="text-xs text-muted-foreground">Peça ao gestor para definir o valor dos jogos.</p>}
      </Notice>
    )
  }
  if (d.blocked_reason === 'NOTHING_DUE' && d.summary.games > 0) {
    return <p className="flex items-center gap-2 rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-2 text-sm text-emerald-200"><CheckCircle2 className="h-4 w-4" aria-hidden="true" /> {MONTH_REASON_MSG.NOTHING_DUE}</p>
  }
  return null
}

function Notice({ text, children }) {
  return (
    <div className="space-y-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-3">
      <p className="flex items-start gap-2 text-sm text-amber-200"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />{text}</p>
      {children}
    </div>
  )
}

function PaymentResult({ result, onDismiss }) {
  return (
    <div className="rounded-lg border border-emerald-500/30 bg-emerald-500/10 p-3 text-sm" role="status" aria-live="polite">
      <p className="font-medium text-emerald-200">{result.idempotent ? 'Recebimento já registrado anteriormente' : 'Recebimento registrado'} · {moneyOrDash(result.applied)}</p>
      <p className="text-xs text-muted-foreground">Distribuição confirmada pelo sistema:</p>
      <ul className="mt-1 space-y-0.5">
        {(result.items || []).map((i) => <li key={i.payment_id} className="flex justify-between"><span>Jogo de {dayMonth(i.occurrence_date)}</span><span className="tabular-nums">{moneyOrDash(i.amount)}</span></li>)}
      </ul>
      <Button variant="ghost" className="mt-2 h-11 sm:h-8" onClick={onDismiss}>Ok</Button>
    </div>
  )
}

function Occurrences({ d, manager, onFinance }) {
  if (d.occurrences.length === 0) return <p className="text-sm text-muted-foreground">Nenhum jogo neste mês.</p>
  return (
    <div className="space-y-2">
      <p className="text-sm font-semibold">Jogos do mês</p>
      <ul className="divide-y divide-border rounded-lg border border-border">
        {d.occurrences.map((o) => {
          const weekday = WEEKDAY_LABELS[new Date(`${o.occurrence_date}T12:00:00-03:00`).getUTCDay()]?.slice(0, 3).toLowerCase()
          return (
            <li key={o.reservation_id} className={cn('px-3 py-2 text-sm', o.status === 'CANCELLED' && 'opacity-60')}>
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className={cn('font-medium', o.status === 'CANCELLED' && 'line-through')}>{dayMonth(o.occurrence_date)} {weekday} · {fmtTime(o.start_at)} · {o.court_name}</p>
                  <p className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
                    <span>{OCCURRENCE_STATUS_LABELS[o.status] || o.status}</span>
                    {o.moved && <Badge variant="outline" className="h-5 px-1.5 text-[10px] font-normal">Remarcado</Badge>}
                    {o.overdue && <Badge className="h-5 border border-red-500/40 bg-red-500/10 px-1.5 text-[10px] font-normal text-red-300">Vencido</Badge>}
                  </p>
                </div>
                <div className="shrink-0 text-right">
                  <p className="tabular-nums">{o.price === null ? <span className="text-amber-300">Sem valor</span> : moneyOrDash(o.price)}</p>
                  {o.collectible && o.open > 0 && <p className="text-xs text-muted-foreground">falta {moneyOrDash(o.open)}</p>}
                </div>
              </div>
              <div className="mt-1 flex items-center justify-between gap-2">
                <PaymentStatusBadge status={o.payment_status} />
                {manager && (
                  <Button variant="ghost" size="sm" className="h-11 sm:h-8" onClick={(e) => onFinance(o, e)} aria-label={`Financeiro do jogo de ${dayMonth(o.occurrence_date)}`}>Financeiro</Button>
                )}
              </div>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
