'use client'

// FASE 03B.1 — Financeiro (leitura): Visão geral, A receber e Caixa (entradas de reservas).
// Autoridade é o banco (RPCs rg_fin_* via /api/finance): esta tela só exibe. Somente OWNER/MANAGER
// (canViewFinance); para os demais nada financeiro é buscado e a tela mostra acesso negado.
// Toda carga usa createRequestSequence + runLatest: resposta antiga nunca sobrescreve estado novo.
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { usePathname, useRouter, useSearchParams } from 'next/navigation'
import { useMe } from '@/components/reserva/dashboard-shell'
import { EmptyState } from '@/components/reserva/empty-state'
import { FinancePanel, PaymentStatusBadge } from '@/components/reserva/finance-panel'
import { PeriodPicker } from '@/components/reserva/finance/period-picker'
import { canViewFinance } from '@/lib/auth/permissions'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { periodFromSearch, periodToSearch, pctChange, fmtPeriodShort } from '@/lib/reserva/finance-period'
import { fetchFinance, periodParams, cashflowGranularity } from '@/lib/reserva/finance-client'
import { isUuid } from '@/lib/reserva/finance-api'
import { formatCents } from '@/lib/reserva/money'
import { PAYMENT_METHOD_LABELS } from '@/lib/reserva/finance'
import { todayStr, fmtTime, fmtDateTimeLong, ARENA_TZ } from '@/lib/reserva/time'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import {
  Wallet, CircleDollarSign, Receipt, CalendarCheck, Clock, AlertTriangle, ShieldAlert, ArrowUpRight, ArrowDownRight,
  Minus, Loader2, Inbox, RefreshCw, BarChart3, Info, Gift,
} from 'lucide-react'
import { cn } from '@/lib/utils'

const RECEIVABLE_FILTER_LABELS = { OPEN: 'Em aberto', OVERDUE: 'Vencidas', UPCOMING: 'A vencer', UNPRICED: 'Sem valor' }
const PAGE_SIZE = 50
const TABS = ['overview', 'receivables', 'cash']

export default function FinanceiroPage() {
  const me = useMe()
  // Sem permissão: nenhum componente com carga financeira é montado (zero chamadas a /api/finance).
  if (!canViewFinance(me?.role)) return <FinanceAccessDenied />
  return (
    <Suspense fallback={<FinanceSkeleton />}>
      <FinanceView me={me} />
    </Suspense>
  )
}

function FinanceAccessDenied() {
  return (
    <div className="space-y-6">
      <PageHeader />
      <EmptyState icon={ShieldAlert} title="Acesso restrito" description="O Financeiro está disponível apenas para proprietários e gerentes da organização." />
    </div>
  )
}

function PageHeader({ orgName }) {
  return (
    <div>
      <h1 className="font-display text-2xl font-bold text-foreground">Financeiro</h1>
      <p className="mt-1 text-sm text-muted-foreground">Valores e entradas das reservas{orgName ? ` da ${orgName}` : ''}.</p>
    </div>
  )
}

function FinanceSkeleton() {
  return (
    <div className="space-y-6">
      <PageHeader />
      <Skeleton className="h-24 w-full" />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-32" />)}</div>
    </div>
  )
}

function FinanceView({ me }) {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()
  const orgId = me?.activeOrg?.id
  const [today] = useState(todayStr)
  const period = useMemo(() => periodFromSearch(searchParams, today), [searchParams, today])
  const arenaParam = searchParams.get('arena')

  const [arenas, setArenas] = useState({ ready: false, list: [] })
  const [tab, setTab] = useState('overview')
  const [recFilter, setRecFilter] = useState('OPEN')
  const [forbidden, setForbidden] = useState(false)

  // Uma sequência por carga; "mais" de cada lista tem sequência própria.
  const seqs = useRef(null)
  if (!seqs.current) {
    seqs.current = {
      arenas: createRequestSequence(), overview: createRequestSequence(), rec: createRequestSequence(), recMore: createRequestSequence(),
      flow: createRequestSequence(), entries: createRequestSequence(), entriesMore: createRequestSequence(),
    }
  }
  const invalidateFinance = useCallback(() => {
    const s = seqs.current
    for (const k of ['overview', 'rec', 'recMore', 'flow', 'entries', 'entriesMore']) s[k].invalidate()
  }, [])
  useEffect(() => () => { for (const s of Object.values(seqs.current)) s.invalidate() }, [])

  useEffect(() => {
    if (!orgId) return
    runLatest(seqs.current.arenas, () => fetch(`/api/arenas?organization_id=${orgId}`).then((r) => (r.ok ? r.json() : [])), {
      onResult: (d) => setArenas({ ready: true, list: Array.isArray(d) ? d.map((a) => ({ id: a.id, name: a.name })) : [] }),
      onError: () => setArenas({ ready: true, list: [] }),
    })
  }, [orgId])

  // Arena da URL só vale se for desta organização (lista carregada); senão, todas as arenas.
  const arenaId = arenas.ready && isUuid(arenaParam) && arenas.list.some((a) => a.id === arenaParam) ? arenaParam : null
  const ready = !!orgId && arenas.ready && !!period
  const base = useMemo(() => (ready ? periodParams(orgId, arenaId, period) : null), [ready, orgId, arenaId, period])
  const baseKey = base ? `${base.organization_id}|${base.arena_id || ''}|${base.from}|${base.to}` : ''

  // Mudança de intenção: invalida SINCRONAMENTE tudo o que está em andamento antes de trocar a URL.
  const replaceQuery = (qs) => router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false })
  const changePeriod = (p) => { invalidateFinance(); replaceQuery(periodToSearch(p, arenaId)) }
  const changeArena = (a) => { invalidateFinance(); replaceQuery(periodToSearch(period, a)) }
  const changeTab = (t) => { if (!TABS.includes(t) || t === tab) return; invalidateFinance(); setTab(t) }
  const changeFilter = (f) => { if (f === recFilter) return; seqs.current.rec.invalidate(); seqs.current.recMore.invalidate(); setRecFilter(f) }
  const openUnpriced = () => { invalidateFinance(); setRecFilter('UNPRICED'); setTab('receivables') }
  const onForbidden = useCallback(() => setForbidden(true), [])

  if (forbidden) return <FinanceAccessDenied />

  return (
    <div className="space-y-6">
      <PageHeader orgName={me?.activeOrg?.name} />
      <PeriodPicker period={period} today={today} onChange={changePeriod} arenas={arenas.list} arenaId={arenaId} onArenaChange={changeArena} />
      <Tabs value={tab} onValueChange={changeTab}>
        <TabsList className="grid w-full grid-cols-3 sm:inline-flex sm:w-auto">
          <TabsTrigger value="overview">Visão geral</TabsTrigger>
          <TabsTrigger value="receivables">A receber</TabsTrigger>
          <TabsTrigger value="cash">Caixa</TabsTrigger>
        </TabsList>
      </Tabs>
      {!ready ? <FinanceSkeletonBody /> : (
        <>
          {tab === 'overview' && <OverviewTab seq={seqs.current.overview} base={base} baseKey={baseKey} period={period} onForbidden={onForbidden} onUnpriced={openUnpriced} />}
          {tab === 'receivables' && <ReceivablesTab seqMain={seqs.current.rec} seqMore={seqs.current.recMore} base={base} baseKey={baseKey} filter={recFilter} onFilterChange={changeFilter} role={me?.role} onForbidden={onForbidden} />}
          {tab === 'cash' && <CashTab seqFlow={seqs.current.flow} seqEntries={seqs.current.entries} seqMore={seqs.current.entriesMore} base={base} baseKey={baseKey} period={period} onForbidden={onForbidden} />}
        </>
      )}
    </div>
  )
}

function FinanceSkeletonBody() {
  return <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-32" />)}</div>
}

function LoadError({ onRetry }) {
  return (
    <EmptyState icon={AlertTriangle} title="Não foi possível carregar" description="Verifique sua conexão e tente novamente."
      action={<Button variant="outline" size="sm" onClick={onRetry}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>} />
  )
}

// ------------------------------------------------------------------ Visão geral
function OverviewTab({ seq, base, baseKey, period, onForbidden, onUnpriced }) {
  const [st, setSt] = useState({ loading: true, data: null, error: false })
  const [reload, setReload] = useState(0)
  useEffect(() => {
    runLatest(seq, () => fetchFinance('overview', { ...base, compare_from: period.compare.from, compare_to: period.compare.to }), {
      onStart: () => setSt({ loading: true, data: null, error: false }),
      onResult: (d) => setSt({ loading: false, data: d, error: false }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setSt({ loading: false, data: null, error: true }) },
    })
    return () => seq.invalidate()
  }, [baseKey, period.compare.from, period.compare.to, reload])

  if (st.error) return <LoadError onRetry={() => setReload((n) => n + 1)} />
  if (st.loading || !st.data) return <FinanceSkeletonBody />
  const d = st.data
  const unpriced = d.reservations?.unpriced || 0
  const cmpLabel = d.compare ? fmtPeriodShort(d.compare.from, d.compare.to) : null
  return (
    <div className="space-y-5">
      {unpriced > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-amber-500/30 bg-amber-500/[0.06] px-4 py-3">
          <p className="flex items-start gap-2 text-sm text-amber-500">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            {unpriced === 1
              ? '1 reserva sem valor no período não entra na receita prevista.'
              : `${unpriced} reservas sem valor no período não entram na receita prevista.`}
          </p>
          <Button size="sm" variant="outline" onClick={onUnpriced}>Ver reservas sem valor</Button>
        </div>
      )}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <MetricCard label="Valor das reservas" icon={CircleDollarSign} value={formatCents(d.expected_revenue?.current)}
          hint="Reservas com valor no período" current={d.expected_revenue?.current} compare={d.expected_revenue?.compare} cmpLabel={cmpLabel} />
        <MetricCard label="Recebido no período" icon={Wallet} value={formatCents(d.cash_in?.net)}
          hint={d.cash_in?.refunds > 0 ? `${formatCents(d.cash_in.gross)} em pagamentos, -${formatCents(d.cash_in.refunds)} em estornos` : 'Pagamentos menos estornos'}
          current={d.cash_in?.net} compare={d.cash_in?.compare_net} cmpLabel={cmpLabel} />
        <MetricCard label="Ticket médio" icon={Receipt} value={d.average_ticket?.current == null ? '—' : formatCents(d.average_ticket.current)}
          hint={d.average_ticket?.current == null ? 'Nenhuma reserva com valor' : 'Valor médio por reserva com valor'}
          current={d.average_ticket?.current} compare={d.average_ticket?.compare} cmpLabel={cmpLabel} />
        <MetricCard label="Reservas com valor" icon={CalendarCheck} value={String(d.priced_count?.current ?? 0)}
          hint={`${d.reservations?.billable ?? 0} reservas no período · ${d.reservations?.cancelled ?? 0} canceladas`}
          current={d.priced_count?.current} compare={d.priced_count?.compare} cmpLabel={cmpLabel} />
        <MetricCard label="A receber" icon={Clock} value={formatCents(d.receivables?.open)} current_situation
          hint={`${(d.receivables?.overdue_count ?? 0) + (d.receivables?.upcoming_count ?? 0)} reservas do período com valor em aberto`} />
        <MetricCard label="Inadimplência" icon={AlertTriangle} value={formatCents(d.receivables?.overdue)} current_situation tone={d.receivables?.overdue > 0 ? 'warn' : undefined}
          hint={d.receivables?.overdue_count ? `${d.receivables.overdue_count} ${d.receivables.overdue_count === 1 ? 'reserva já realizada' : 'reservas já realizadas'} sem pagamento total` : 'Nenhuma reserva vencida em aberto'} />
      </div>
      {d.credits?.count > 0 && (
        <div className="flex items-start gap-3 rounded-xl border border-violet-500/30 bg-violet-500/[0.06] px-4 py-3 text-sm">
          <Gift className="mt-0.5 h-4 w-4 shrink-0 text-violet-400" />
          <p className="text-muted-foreground">
            <span className="font-medium text-foreground">Créditos de clientes: {formatCents(d.credits.total)}</span>{' '}
            — {d.credits.count} {d.credits.count === 1 ? 'reserva recebeu' : 'reservas receberam'} mais que o valor devido.
          </p>
        </div>
      )}
      <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <Info className="h-3.5 w-3.5" /> &quot;Situação atual&quot; considera os pagamentos registrados até agora para as reservas do período.
      </p>
    </div>
  )
}

function MetricCard({ label, icon: Icon, value, hint, current, compare, cmpLabel, current_situation, tone }) {
  const pct = current_situation ? null : pctChange(current, compare)
  const hasCompare = !current_situation && cmpLabel
  return (
    <Card className="overflow-hidden">
      <CardContent className="p-5">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
              {current_situation && <Badge variant="outline" className="h-5 px-1.5 text-[10px] font-normal">Situação atual</Badge>}
            </div>
            <p className={cn('mt-2 font-display text-2xl font-bold', tone === 'warn' ? 'text-amber-500' : 'text-foreground')}>{value ?? '—'}</p>
            {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
          </div>
          {Icon && <div className={cn('flex h-10 w-10 shrink-0 items-center justify-center rounded-lg', tone === 'warn' ? 'bg-amber-500/10 text-amber-500' : 'bg-primary/10 text-primary')}><Icon className="h-5 w-5" /></div>}
        </div>
        {hasCompare && (
          <p className="mt-3 flex items-center gap-1 border-t border-border pt-3 text-xs text-muted-foreground">
            {pct === null ? <Minus className="h-3.5 w-3.5" /> : pct > 0 ? <ArrowUpRight className="h-3.5 w-3.5 text-primary" /> : pct < 0 ? <ArrowDownRight className="h-3.5 w-3.5 text-red-400" /> : <Minus className="h-3.5 w-3.5" />}
            {pct === null ? 'Sem base de comparação' : <span className={cn('font-medium', pct > 0 ? 'text-primary' : pct < 0 ? 'text-red-400' : 'text-foreground')}>{pct > 0 ? '+' : ''}{pct}%</span>}
            <span>vs. {cmpLabel}</span>
          </p>
        )}
      </CardContent>
    </Card>
  )
}

// ------------------------------------------------------------------ A receber
const fmtDayShort = (iso) => (iso ? new Intl.DateTimeFormat('pt-BR', { timeZone: ARENA_TZ, weekday: 'short', day: '2-digit', month: '2-digit' }).format(new Date(iso)) : '')

function ReceivablesTab({ seqMain, seqMore, base, baseKey, filter, onFilterChange, role, onForbidden }) {
  const [list, setList] = useState({ loading: true, error: false, items: [], cursor: null })
  const [more, setMore] = useState({ loading: false, error: false })
  const [reload, setReload] = useState(0)
  const [open, setOpen] = useState(null)

  useEffect(() => {
    // Nova carga principal (período/arena/filtro/recarga): paginação anterior não vale mais.
    seqMore.invalidate()
    setMore({ loading: false, error: false })
    runLatest(seqMain, () => fetchFinance('receivables', { ...base, filter, limit: PAGE_SIZE }), {
      onStart: () => setList({ loading: true, error: false, items: [], cursor: null }),
      onResult: (d) => setList({ loading: false, error: false, items: Array.isArray(d?.items) ? d.items : [], cursor: d?.next_cursor || null }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setList({ loading: false, error: true, items: [], cursor: null }) },
    })
    return () => { seqMain.invalidate(); seqMore.invalidate() }
  }, [baseKey, filter, reload])

  function loadMore() {
    const cursor = list.cursor
    if (!cursor || more.loading) return
    runLatest(seqMore, () => fetchFinance('receivables', { ...base, filter, limit: PAGE_SIZE, after_start: cursor.start_at, after_id: cursor.id }), {
      onStart: () => setMore({ loading: true, error: false }),
      onResult: (d) => setList((l) => ({ ...l, items: [...l.items, ...(Array.isArray(d?.items) ? d.items : [])], cursor: d?.next_cursor || null })),
      onError: (e) => { if (e?.status === 403) onForbidden(); setMore({ loading: false, error: true }) },
      onSettled: () => setMore((m) => ({ ...m, loading: false })),
    })
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-1.5" role="group" aria-label="Filtro">
        {Object.entries(RECEIVABLE_FILTER_LABELS).map(([k, label]) => (
          <Button key={k} type="button" size="sm" className="h-8" variant={filter === k ? 'default' : 'outline'} aria-pressed={filter === k} onClick={() => onFilterChange(k)}>{label}</Button>
        ))}
      </div>
      {filter === 'UNPRICED' && (
        <p className="text-xs text-muted-foreground">Reservas do período sem valor definido. Abra a reserva para definir o valor.</p>
      )}
      {list.error ? <LoadError onRetry={() => setReload((n) => n + 1)} /> : list.loading ? (
        <div className="space-y-2">{Array.from({ length: 5 }).map((_, i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
      ) : list.items.length === 0 ? (
        <EmptyState icon={Inbox} title={filter === 'UNPRICED' ? 'Nenhuma reserva sem valor' : 'Nada a receber neste filtro'}
          description={filter === 'UNPRICED' ? 'Todas as reservas do período têm valor definido.' : 'Não há reservas do período com valor em aberto neste filtro.'} />
      ) : (
        <Card>
          <CardContent className="divide-y divide-border p-0">
            {list.items.map((it) => (
              <button key={it.reservation_id} type="button" onClick={() => setOpen(it)}
                className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left transition-colors hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium">{it.customer_name || 'Sem cliente'}</p>
                  <p className="truncate text-xs text-muted-foreground">{fmtDayShort(it.start_at)} · {fmtTime(it.start_at)}–{fmtTime(it.end_at)} · {it.court_name || 'Quadra'}</p>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  <span className="text-sm font-semibold">{it.balance == null ? 'Sem valor' : formatCents(it.balance)}</span>
                  <span className="flex items-center gap-1.5">
                    {it.overdue && <Badge className="border border-amber-500/30 bg-amber-500/10 text-[10px] font-normal text-amber-400">Vencida</Badge>}
                    <PaymentStatusBadge status={it.payment_status} className="text-[10px]" />
                  </span>
                </div>
              </button>
            ))}
          </CardContent>
        </Card>
      )}
      {!list.loading && !list.error && list.cursor && (
        <div className="flex flex-col items-center gap-2">
          <Button variant="outline" onClick={loadMore} disabled={more.loading}>{more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />} Carregar mais</Button>
          {more.error && <p className="text-xs text-amber-500">Não foi possível carregar mais. Tente novamente.</p>}
        </div>
      )}
      {open && <ReservationFinanceSheet item={open} role={role} onClose={() => setOpen(null)} onChanged={() => setReload((n) => n + 1)} />}
    </div>
  )
}

// Abre o painel financeiro JÁ EXISTENTE da reserva (03A): nenhum fluxo de pagamento novo aqui.
function ReservationFinanceSheet({ item, role, onClose, onChanged }) {
  const Row = ({ label, value }) => (<div className="py-2"><p className="text-xs text-muted-foreground">{label}</p><p className="text-sm">{value || '—'}</p></div>)
  return (
    <Sheet open onOpenChange={(o) => { if (!o) onClose() }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader><SheetTitle>Reserva</SheetTitle></SheetHeader>
        <div className="mt-4 divide-y divide-border">
          <Row label="Cliente" value={item.customer_name} />
          <Row label="Telefone" value={item.customer_phone} />
          <Row label="Quadra" value={item.court_name} />
          <Row label="Data" value={fmtDateTimeLong(item.start_at)} />
          <Row label="Horário" value={`${fmtTime(item.start_at)} — ${fmtTime(item.end_at)}`} />
        </div>
        <FinancePanel reservationId={item.reservation_id} role={role} onChanged={onChanged} />
      </SheetContent>
    </Sheet>
  )
}

// ------------------------------------------------------------------ Caixa (entradas de reservas)
const MONTHS = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez']
function bucketLabel(bucket, granularity) {
  if (typeof bucket !== 'string' || bucket.length < 10) return ''
  return granularity === 'month' ? `${MONTHS[Number(bucket.slice(5, 7)) - 1]}/${bucket.slice(2, 4)}` : `${bucket.slice(8, 10)}/${bucket.slice(5, 7)}`
}

function CashTab({ seqFlow, seqEntries, seqMore, base, baseKey, period, onForbidden }) {
  const granularity = cashflowGranularity(period)
  const [flow, setFlow] = useState({ loading: true, error: false, data: null })
  const [list, setList] = useState({ loading: true, error: false, items: [], cursor: null })
  const [more, setMore] = useState({ loading: false, error: false })
  const [reload, setReload] = useState(0)

  useEffect(() => {
    seqMore.invalidate()
    setMore({ loading: false, error: false })
    runLatest(seqFlow, () => fetchFinance('cashflow', { ...base, granularity }), {
      onStart: () => setFlow({ loading: true, error: false, data: null }),
      onResult: (d) => setFlow({ loading: false, error: false, data: d }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setFlow({ loading: false, error: true, data: null }) },
    })
    runLatest(seqEntries, () => fetchFinance('cash-entries', { ...base, limit: PAGE_SIZE }), {
      onStart: () => setList({ loading: true, error: false, items: [], cursor: null }),
      onResult: (d) => setList({ loading: false, error: false, items: Array.isArray(d?.items) ? d.items : [], cursor: d?.next_cursor || null }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setList({ loading: false, error: true, items: [], cursor: null }) },
    })
    return () => { seqFlow.invalidate(); seqEntries.invalidate(); seqMore.invalidate() }
  }, [baseKey, granularity, reload])

  function loadMore() {
    const cursor = list.cursor
    if (!cursor || more.loading) return
    runLatest(seqMore, () => fetchFinance('cash-entries', { ...base, limit: PAGE_SIZE, after_at: cursor.received_at, after_id: cursor.id }), {
      onStart: () => setMore({ loading: true, error: false }),
      onResult: (d) => setList((l) => ({ ...l, items: [...l.items, ...(Array.isArray(d?.items) ? d.items : [])], cursor: d?.next_cursor || null })),
      onError: (e) => { if (e?.status === 403) onForbidden(); setMore({ loading: false, error: true }) },
      onSettled: () => setMore((m) => ({ ...m, loading: false })),
    })
  }

  if (flow.error || list.error) return <LoadError onRetry={() => setReload((n) => n + 1)} />
  const t = flow.data?.totals
  return (
    <div className="space-y-5">
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="flex items-center gap-2 text-base"><BarChart3 className="h-4 w-4 text-primary" /> Entradas de reservas no período</CardTitle>
          <p className="text-xs text-muted-foreground">Pagamentos e estornos de reservas registrados no período, pela data do recebimento.</p>
        </CardHeader>
        <CardContent className="space-y-5">
          {flow.loading || !flow.data ? <Skeleton className="h-48 w-full" /> : (
            <>
              <div className="grid grid-cols-3 gap-2 sm:gap-4">
                <Total label="Pagamentos" value={formatCents(t?.in_gross)} />
                <Total label="Estornos" value={t?.refunds > 0 ? `-${formatCents(t.refunds)}` : formatCents(0)} negative={t?.refunds > 0} />
                <Total label="Líquido" value={formatCents(t?.in_net)} strong />
              </div>
              <CashChart buckets={flow.data.buckets || []} granularity={flow.data.granularity || granularity} />
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-2"><CardTitle className="text-base">Lançamentos</CardTitle></CardHeader>
        <CardContent className="p-0">
          {list.loading ? <div className="space-y-2 p-4">{Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
            : list.items.length === 0 ? <div className="p-4"><EmptyState icon={Wallet} title="Nenhuma entrada no período" description="Pagamentos e estornos de reservas registrados no período aparecem aqui." /></div>
              : (
                <div className="divide-y divide-border">
                  {list.items.map((e) => {
                    const refund = e.kind === 'REFUND'
                    return (
                      <div key={e.payment_id} className="flex items-center justify-between gap-3 px-4 py-3">
                        <div className="min-w-0">
                          <p className="truncate text-sm font-medium">{refund ? 'Estorno' : 'Pagamento'} · {PAYMENT_METHOD_LABELS[e.method] || e.method}</p>
                          <p className="truncate text-xs text-muted-foreground">{fmtDateTimeLong(e.received_at)} · {e.customer_name || 'Sem cliente'}{e.court_name ? ` · ${e.court_name}` : ''}</p>
                        </div>
                        <span className={cn('shrink-0 text-sm font-semibold', refund ? 'text-red-400' : 'text-primary')}>{refund ? '-' : '+'}{formatCents(e.amount)}</span>
                      </div>
                    )
                  })}
                </div>
              )}
        </CardContent>
      </Card>
      {!list.loading && list.cursor && (
        <div className="flex flex-col items-center gap-2">
          <Button variant="outline" onClick={loadMore} disabled={more.loading}>{more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />} Carregar mais</Button>
          {more.error && <p className="text-xs text-amber-500">Não foi possível carregar mais. Tente novamente.</p>}
        </div>
      )}
    </div>
  )
}

function Total({ label, value, negative, strong }) {
  return (
    <div className="rounded-lg border border-border bg-muted/20 px-3 py-2">
      <p className="text-[11px] text-muted-foreground sm:text-xs">{label}</p>
      <p className={cn('truncate text-sm sm:text-base', strong ? 'font-bold' : 'font-semibold', negative && 'text-red-400')}>{value}</p>
    </div>
  )
}

// Barras para cima = pagamentos; para baixo (vermelho) = estornos. Só CSS (leve e responsivo).
function CashChart({ buckets, granularity }) {
  const max = buckets.reduce((m, b) => Math.max(m, b.in_gross || 0, b.refunds || 0), 0)
  const hasRefunds = buckets.some((b) => (b.refunds || 0) > 0)
  if (max === 0) return <p className="rounded-lg border border-dashed border-border px-3 py-8 text-center text-sm text-muted-foreground">Nenhuma entrada registrada no período.</p>
  const pct = (v) => `${Math.max(v > 0 ? 2 : 0, Math.floor(((v || 0) * 100) / max))}%`
  const step = Math.max(1, Math.ceil(buckets.length / 8))
  return (
    <div>
      <div className="flex h-48 items-stretch gap-[2px] overflow-hidden sm:gap-1" role="img" aria-label="Gráfico de entradas de reservas">
        {buckets.map((b) => (
          <div key={b.bucket} className="flex min-w-0 flex-1 flex-col" title={`${bucketLabel(b.bucket, granularity)}: ${formatCents(b.in_gross)} em pagamentos${b.refunds ? `, -${formatCents(b.refunds)} em estornos` : ''}`}>
            <div className={cn('flex items-end', hasRefunds ? 'h-2/3' : 'h-full')}><div className="mx-auto w-full max-w-12 rounded-t-sm bg-primary/80" style={{ height: pct(b.in_gross) }} /></div>
            {hasRefunds && <div className="flex h-1/3 items-start border-t border-border"><div className="mx-auto w-full max-w-12 rounded-b-sm bg-red-400/80" style={{ height: pct(b.refunds) }} /></div>}
          </div>
        ))}
      </div>
      <div className="mt-1 flex gap-[2px] sm:gap-1">
        {buckets.map((b, i) => <span key={b.bucket} className="min-w-0 flex-1 truncate text-center text-[10px] text-muted-foreground">{i % step === 0 ? bucketLabel(b.bucket, granularity) : ''}</span>)}
      </div>
      <div className="mt-2 flex flex-wrap gap-4 text-xs text-muted-foreground">
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm bg-primary/80" /> Pagamentos</span>
        {hasRefunds && <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm bg-red-400/80" /> Estornos</span>}
      </div>
    </div>
  )
}
