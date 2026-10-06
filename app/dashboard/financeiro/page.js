'use client'

// FASE 03B.1 — Financeiro (leitura): Visão geral, A receber e Caixa.
// FASE 03B.2B-2A — + Despesas (leitura) e Caixa consolidado (entradas e saídas), em componentes próprios.
// Autoridade é o banco (RPCs via /api/finance): esta tela só exibe. Somente OWNER/MANAGER
// (canViewFinance); para os demais nada financeiro é buscado e a tela mostra acesso negado.
// Aba, período e arena vivem SÓ na URL (?tab, ?preset | ?from&to, ?arena); toda troca reconstrói a
// query canônica (lib/reserva/finance-nav) e só a aba ativa monta e busca.
// Toda carga usa createRequestSequence + runLatest: resposta antiga nunca sobrescreve estado novo.
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { usePathname, useRouter, useSearchParams } from 'next/navigation'
import { useMe } from '@/components/reserva/dashboard-shell'
import { EmptyState } from '@/components/reserva/empty-state'
import { FinancePanel, PaymentStatusBadge } from '@/components/reserva/finance-panel'
import { PeriodPicker } from '@/components/reserva/finance/period-picker'
import { canViewFinance } from '@/lib/auth/permissions'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { periodFromSearch, pctChange, fmtPeriodShort } from '@/lib/reserva/finance-period'
import { fetchFinance, periodParams } from '@/lib/reserva/finance-client'
import { isUuid } from '@/lib/reserva/finance-api'
import { FINANCE_TABS, tabFromSearch, urlArena, nextFinanceSearch } from '@/lib/reserva/finance-nav'
import { createExpensesApi } from '@/lib/reserva/expenses-client'
import { formatCents } from '@/lib/reserva/money'
import { todayStr, fmtTime, fmtDateTimeLong, ARENA_TZ } from '@/lib/reserva/time'
import { ExpensesTab } from '@/components/reserva/finance/expenses-tab'
import { CashTab } from '@/components/reserva/finance/cash-tab'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import {
  Wallet, CircleDollarSign, Receipt, CalendarCheck, Clock, AlertTriangle, ShieldAlert, ArrowUpRight, ArrowDownRight,
  Minus, Loader2, Inbox, RefreshCw, Info, Gift,
} from 'lucide-react'
import { cn } from '@/lib/utils'

const RECEIVABLE_FILTER_LABELS = { OPEN: 'Em aberto', OVERDUE: 'Vencidas', UPCOMING: 'A vencer', UNPRICED: 'Sem valor' }
const PAGE_SIZE = 50
const TAB_LABELS = { overview: 'Visão geral', receivables: 'A receber', cash: 'Caixa', expenses: 'Despesas' }
const FINANCE_SEQS = ['overview', 'rec', 'recMore', 'cashResult', 'cashMoves', 'cashMovesMore', 'expCats', 'expOverview', 'expList', 'expListMore', 'expDetail']

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
      <p className="mt-1 text-sm text-muted-foreground">Reservas, caixa e despesas{orgName ? ` da ${orgName}` : ''}.</p>
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
  // Aba: fonte única é a URL (?tab); ausente/inválida => Visão geral. Voltar/avançar do navegador troca a aba.
  const tab = tabFromSearch(searchParams)

  const [arenas, setArenas] = useState({ ready: false, list: [] })
  const [recFilter, setRecFilter] = useState('OPEN')
  const [forbidden, setForbidden] = useState(false)
  const api = useMemo(() => createExpensesApi(), [])

  // Uma sequência por carga; "mais" de cada lista tem sequência própria.
  const seqs = useRef(null)
  if (!seqs.current) {
    seqs.current = {
      arenas: createRequestSequence(), overview: createRequestSequence(), rec: createRequestSequence(), recMore: createRequestSequence(),
      cashResult: createRequestSequence(), cashMoves: createRequestSequence(), cashMovesMore: createRequestSequence(),
      expCats: createRequestSequence(), expOverview: createRequestSequence(), expList: createRequestSequence(), expListMore: createRequestSequence(),
      expDetail: createRequestSequence(),
    }
  }
  const invalidateFinance = useCallback(() => {
    const s = seqs.current
    for (const k of FINANCE_SEQS) s[k].invalidate()
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
  // A query é sempre reconstruída do estado validado (período + arena + aba): nenhuma troca descarta
  // as outras chaves e parâmetros inválidos antigos não são copiados. Aba entra no histórico (push).
  const navigate = (change, { push = false } = {}) => {
    const qs = nextFinanceSearch({ period, arenaId: urlArena(arenaParam, arenas), tab }, change)
    const url = qs ? `${pathname}?${qs}` : pathname
    if (push) router.push(url, { scroll: false })
    else router.replace(url, { scroll: false })
  }
  const changePeriod = (p) => { invalidateFinance(); navigate({ period: p }) }
  const changeArena = (a) => { invalidateFinance(); navigate({ arenaId: a }) }
  const changeTab = (t) => { if (!FINANCE_TABS.includes(t) || t === tab) return; invalidateFinance(); navigate({ tab: t }, { push: true }) }
  const changeFilter = (f) => { if (f === recFilter) return; seqs.current.rec.invalidate(); seqs.current.recMore.invalidate(); setRecFilter(f) }
  const openUnpriced = () => { invalidateFinance(); setRecFilter('UNPRICED'); navigate({ tab: 'receivables' }, { push: true }) }
  const scope = useMemo(() => (ready ? { orgId, arenaId, period } : null), [ready, orgId, arenaId, period])
  const onForbidden = useCallback(() => setForbidden(true), [])

  if (forbidden) return <FinanceAccessDenied />

  return (
    <div className="space-y-6">
      <PageHeader orgName={me?.activeOrg?.name} />
      <PeriodPicker period={period} today={today} onChange={changePeriod} arenas={arenas.list} arenaId={arenaId} onArenaChange={changeArena} />
      <Tabs value={tab} onValueChange={changeTab}>
        {/* Mobile: 4 abas com rolagem horizontal (sem esmagar o texto), alvo de toque de 44 px. */}
        <div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
          <TabsList className="inline-flex h-auto w-max">
            {FINANCE_TABS.map((t) => <TabsTrigger key={t} value={t} className="h-11 px-4 motion-reduce:transition-none sm:h-7 sm:px-3">{TAB_LABELS[t]}</TabsTrigger>)}
          </TabsList>
        </div>
      </Tabs>
      {!ready ? <FinanceSkeletonBody /> : (
        <>
          {tab === 'overview' && <OverviewTab seq={seqs.current.overview} base={base} baseKey={baseKey} period={period} onForbidden={onForbidden} onUnpriced={openUnpriced} />}
          {tab === 'receivables' && <ReceivablesTab seqMain={seqs.current.rec} seqMore={seqs.current.recMore} base={base} baseKey={baseKey} filter={recFilter} onFilterChange={changeFilter} role={me?.role} onForbidden={onForbidden} />}
          {tab === 'cash' && <CashTab api={api} seqs={{ result: seqs.current.cashResult, moves: seqs.current.cashMoves, more: seqs.current.cashMovesMore }} scope={scope} baseKey={baseKey} period={period} onForbidden={onForbidden} />}
          {tab === 'expenses' && <ExpensesTab api={api} seqs={{ cats: seqs.current.expCats, overview: seqs.current.expOverview, list: seqs.current.expList, more: seqs.current.expListMore, detail: seqs.current.expDetail }} scope={scope} baseKey={baseKey} onForbidden={onForbidden} arenas={arenas.list} />}
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
                  <p className="text-xs text-muted-foreground">{fmtDayShort(it.start_at)} · {fmtTime(it.start_at)}–{fmtTime(it.end_at)} · {it.court_name || 'Quadra'}</p>
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
        <SheetHeader><SheetTitle>Reserva</SheetTitle><SheetDescription className="sr-only">Dados e situação financeira da reserva selecionada.</SheetDescription></SheetHeader>
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
