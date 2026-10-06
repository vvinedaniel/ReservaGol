'use client'

// FASE 03B.2B-2A — aba Despesas (somente leitura). Só monta quando a aba está ativa (zero chamadas
// fora dela). Fontes: rg_expense_overview (cards), rg_expenses (lista paginada por cursor),
// rg_expense_categories (filtro) e rg_expense_detail (Sheet). Toda carga usa runLatest com as
// sequências recebidas da página; trocar filtro invalida SINCRONAMENTE as cargas em andamento.
// Nenhuma escrita nesta etapa.
import { useEffect, useRef, useState } from 'react'
import { runLatest } from '@/lib/reserva/latest-request'
import { EXPENSE_STATUS_FILTERS, DEFAULT_EXPENSE_FILTER, EXPENSE_FILTER_LABELS, fmtDueDate } from '@/lib/reserva/expenses'
import { pctChange, fmtPeriodShort } from '@/lib/reserva/finance-period'
import { formatCents } from '@/lib/reserva/money'
import { EmptyState } from '@/components/reserva/empty-state'
import { ExpenseBadges, ExpenseDetailSheet } from '@/components/reserva/finance/expense-detail-sheet'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { AlertTriangle, ArrowDownRight, ArrowUpRight, CalendarClock, CheckCircle2, Clock, Info, Loader2, Minus, ReceiptText, RefreshCw } from 'lucide-react'
import { cn } from '@/lib/utils'

const PAGE_SIZE = 50
const ALL_CATEGORIES = 'all'
export const GENERAL_EXCLUDED_MSG = 'Despesas gerais da organização não estão incluídas neste filtro.'

export function ExpensesTab({ api, seqs, scope, baseKey, onForbidden }) {
  const [categoryId, setCategoryId] = useState(null)
  const [status, setStatus] = useState(DEFAULT_EXPENSE_FILTER)
  const [reload, setReload] = useState(0)
  const [cats, setCats] = useState({ ready: false, list: [] })
  const [ov, setOv] = useState({ loading: true, error: false, data: null })
  const [list, setList] = useState({ loading: true, refreshing: false, error: false, items: [], cursor: null, excludesGeneral: false })
  const [more, setMore] = useState({ loading: false, error: false })
  const [openId, setOpenId] = useState(null)
  const lastTrigger = useRef(null)

  // Categorias (inclusive inativas, marcadas) só para o filtro.
  useEffect(() => {
    runLatest(seqs.cats, () => api.categories(scope.orgId, true), {
      onResult: (d) => setCats({ ready: true, list: Array.isArray(d?.items) ? d.items : [] }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setCats({ ready: true, list: [] }) },
    })
    return () => seqs.cats.invalidate()
  }, [scope.orgId])

  // Cards: período/arena/categoria (status não se aplica ao resumo).
  useEffect(() => {
    runLatest(seqs.overview, () => api.overview(scope, { categoryId }), {
      onStart: () => setOv((s) => ({ loading: true, error: false, data: s.data })),
      onResult: (d) => setOv({ loading: false, error: false, data: d }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setOv({ loading: false, error: true, data: null }) },
    })
    return () => seqs.overview.invalidate()
  }, [baseKey, categoryId, reload])

  // Lista: nova carga principal invalida qualquer "carregar mais" pendente e zera a paginação.
  // Conteúdo anterior pode ficar visível (marcado como atualizando) até a resposta nova.
  useEffect(() => {
    seqs.more.invalidate()
    setMore({ loading: false, error: false })
    runLatest(seqs.list, () => api.list(scope, { categoryId, status, limit: PAGE_SIZE }), {
      onStart: () => setList((l) => ({ ...l, loading: l.items.length === 0, refreshing: l.items.length > 0, error: false, cursor: null })),
      onResult: (d) => setList({ loading: false, refreshing: false, error: false, items: Array.isArray(d?.items) ? d.items : [], cursor: d?.next_cursor || null, excludesGeneral: d?.excludes_general === true }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setList({ loading: false, refreshing: false, error: true, items: [], cursor: null, excludesGeneral: false }) },
    })
    return () => { seqs.list.invalidate(); seqs.more.invalidate() }
  }, [baseKey, categoryId, status, reload])

  function loadMore() {
    const cursor = list.cursor
    if (!cursor || more.loading || list.refreshing) return
    runLatest(seqs.more, () => api.list(scope, { categoryId, status, limit: PAGE_SIZE, cursor }), {
      onStart: () => setMore({ loading: true, error: false }),
      onResult: (d) => setList((l) => ({ ...l, items: [...l.items, ...(Array.isArray(d?.items) ? d.items : [])], cursor: d?.next_cursor || null })),
      onError: (e) => { if (e?.status === 403) onForbidden(); setMore({ loading: false, error: true }) },
      onSettled: () => setMore((m) => ({ ...m, loading: false })),
    })
  }

  // Mudança de filtro: invalida SINCRONAMENTE o que está em andamento antes de trocar o estado.
  const changeCategory = (v) => {
    const next = v === ALL_CATEGORIES ? null : v
    if (next === categoryId) return
    seqs.overview.invalidate(); seqs.list.invalidate(); seqs.more.invalidate()
    setCategoryId(next)
  }
  const changeStatus = (s) => {
    if (s === status || !EXPENSE_STATUS_FILTERS.includes(s)) return
    seqs.list.invalidate(); seqs.more.invalidate()
    setStatus(s)
  }
  const openDetail = (id, el) => { lastTrigger.current = el; setOpenId(id) }
  const closeDetail = () => { seqs.detail.invalidate(); setOpenId(null) }
  const retry = () => setReload((n) => n + 1)
  const excludesGeneral = ov.data?.excludes_general === true || list.excludesGeneral

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="font-display text-lg font-semibold">Despesas</h2>
          <p className="text-xs text-muted-foreground">Despesas com vencimento no período selecionado.</p>
        </div>
      </div>

      <ExpenseCards st={ov} onRetry={retry} />
      <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
        <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
        Os valores desta área consideram despesas com vencimento no período. As Saídas do Caixa consideram a data real dos pagamentos.
      </p>
      {excludesGeneral && <GeneralExcludedNotice />}

      <div className="space-y-3">
        <div className="-mx-4 flex gap-1.5 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0" role="group" aria-label="Situação das despesas">
          {EXPENSE_STATUS_FILTERS.map((s) => (
            <Button key={s} type="button" size="sm" variant={status === s ? 'default' : 'outline'} aria-pressed={status === s}
              className="h-11 shrink-0 px-4 sm:h-8 sm:px-3" onClick={() => changeStatus(s)}>{EXPENSE_FILTER_LABELS[s]}</Button>
          ))}
        </div>
        <Select value={categoryId || ALL_CATEGORIES} onValueChange={changeCategory} disabled={!cats.ready}>
          <SelectTrigger className="h-11 w-full sm:h-9 sm:w-64" aria-label="Categoria"><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL_CATEGORIES}>Todas as categorias</SelectItem>
            {cats.list.map((c) => <SelectItem key={c.id} value={c.id}>{c.is_active ? c.name : `${c.name} (inativa)`}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>

      <ExpenseList list={list} onRetry={retry} onOpen={openDetail} status={status} />

      {!list.loading && !list.error && list.cursor && (
        <div className="flex flex-col items-center gap-2">
          <Button variant="outline" className="h-11 sm:h-9" onClick={loadMore} disabled={more.loading || list.refreshing}>
            {more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />} Carregar mais
          </Button>
          {more.error && <p className="text-xs text-amber-500" role="alert">Não foi possível carregar mais. Tente novamente.</p>}
        </div>
      )}

      {openId && <ExpenseDetailSheet expenseId={openId} api={api} seq={seqs.detail} onClose={closeDetail} onForbidden={onForbidden} returnFocusTo={lastTrigger} />}
    </div>
  )
}

export function GeneralExcludedNotice() {
  return (
    <p className="flex items-start gap-2 rounded-xl border border-sky-500/30 bg-sky-500/[0.06] px-4 py-3 text-sm text-sky-300">
      <Info className="mt-0.5 h-4 w-4 shrink-0" /> {GENERAL_EXCLUDED_MSG}
    </p>
  )
}

function ExpenseCards({ st, onRetry }) {
  if (st.error) return <LoadError onRetry={onRetry} />
  if (!st.data) return <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" role="status" aria-label="Carregando resumo">{Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-32" />)}</div>
  const d = st.data
  const cmpLabel = d.compare ? fmtPeriodShort(d.compare.from, d.compare.to) : null
  const n = (c, one, many) => `${c ?? 0} ${(c ?? 0) === 1 ? one : many}`
  return (
    <div className={cn('grid gap-4 sm:grid-cols-2 lg:grid-cols-4', st.loading && 'opacity-60')} aria-busy={st.loading}>
      <ExpenseMetric label="Despesas previstas" icon={ReceiptText} value={formatCents(d.expected?.current)}
        hint={n(d.expected?.count, 'despesa com vencimento no período', 'despesas com vencimento no período')}
        current={d.expected?.current} compare={d.expected?.compare} cmpLabel={cmpLabel} />
      <ExpenseMetric label="Pago" icon={CheckCircle2} value={formatCents(d.paid_of_period?.current)} hint="Pago das despesas com vencimento no período" />
      <ExpenseMetric label="A pagar" icon={Clock} value={formatCents(d.payable?.total)} situation hint={n(d.payable?.count, 'despesa em aberto', 'despesas em aberto')} />
      <ExpenseMetric label="Vencidas" icon={CalendarClock} value={formatCents(d.overdue?.total)} situation tone={d.overdue?.total > 0 ? 'warn' : undefined}
        hint={d.overdue?.count ? n(d.overdue.count, 'despesa vencida em aberto', 'despesas vencidas em aberto') : 'Nenhuma despesa vencida em aberto'} />
    </div>
  )
}

// Comparação de despesa é sempre NEUTRA: aumento de despesa não é "bom" (sem verde/vermelho).
function ExpenseMetric({ label, icon: Icon, value, hint, current, compare, cmpLabel, situation, tone }) {
  const pct = situation ? null : pctChange(current, compare)
  const hasCompare = !situation && cmpLabel
  return (
    <Card className="overflow-hidden">
      <CardContent className="p-5">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
              {situation && <Badge variant="outline" className="h-5 px-1.5 text-[10px] font-normal">Situação atual</Badge>}
            </div>
            <p className={cn('mt-2 whitespace-nowrap font-display text-2xl font-bold', tone === 'warn' ? 'text-amber-500' : 'text-foreground')}>{value ?? '—'}</p>
            {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
          </div>
          {Icon && <div className={cn('flex h-10 w-10 shrink-0 items-center justify-center rounded-lg', tone === 'warn' ? 'bg-amber-500/10 text-amber-500' : 'bg-muted text-muted-foreground')}><Icon className="h-5 w-5" /></div>}
        </div>
        {hasCompare && (
          <p className="mt-3 flex items-center gap-1 border-t border-border pt-3 text-xs text-muted-foreground">
            {pct === null ? <Minus className="h-3.5 w-3.5" /> : pct > 0 ? <ArrowUpRight className="h-3.5 w-3.5" /> : pct < 0 ? <ArrowDownRight className="h-3.5 w-3.5" /> : <Minus className="h-3.5 w-3.5" />}
            {pct === null ? 'Sem base de comparação' : <span className="font-medium text-foreground">{pct > 0 ? '+' : ''}{pct}%</span>}
            <span>vs. {cmpLabel}</span>
          </p>
        )}
      </CardContent>
    </Card>
  )
}

function LoadError({ onRetry }) {
  return (
    <EmptyState icon={AlertTriangle} title="Não foi possível carregar" description="Verifique sua conexão e tente novamente."
      action={<Button variant="outline" className="h-11 sm:h-9" onClick={onRetry}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>} />
  )
}

const EMPTY_BY_STATUS = {
  ACTIVE: 'Nenhuma despesa com vencimento no período.',
  OPEN: 'Nenhuma despesa em aberto no período.',
  OVERDUE: 'Nenhuma despesa vencida no período.',
  PAID: 'Nenhuma despesa paga no período.',
  CANCELLED: 'Nenhuma despesa cancelada no período.',
}

function ExpenseList({ list, onRetry, onOpen, status }) {
  if (list.error) return <LoadError onRetry={onRetry} />
  if (list.loading) return <div className="space-y-2" role="status" aria-label="Carregando despesas">{Array.from({ length: 5 }).map((_, i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
  if (list.items.length === 0 && !list.refreshing) return <EmptyState icon={ReceiptText} title="Nenhuma despesa neste filtro" description={EMPTY_BY_STATUS[status] || EMPTY_BY_STATUS.ACTIVE} />
  return (
    <div className="space-y-2">
      {list.refreshing && (
        <p className="flex items-center gap-2 text-xs text-muted-foreground" role="status" aria-live="polite">
          <Loader2 className="h-3.5 w-3.5 animate-spin motion-reduce:animate-none" /> Atualizando…
        </p>
      )}
      <Card className={cn(list.refreshing && 'opacity-60')} aria-busy={list.refreshing}>
        <CardContent className="p-0">
          <div className="hidden grid-cols-[minmax(0,2.2fr)_minmax(0,1.2fr)_minmax(0,1fr)_6.5rem_7rem_7rem_7rem] gap-3 border-b border-border px-4 py-2 text-xs font-medium text-muted-foreground md:grid">
            <span>Descrição</span><span>Categoria</span><span>Arena</span><span>Vencimento</span>
            <span className="text-right">Valor</span><span className="text-right">Pago</span><span className="text-right">A pagar</span>
          </div>
          <ul className="divide-y divide-border">
            {list.items.map((it) => (
              <li key={it.expense_id}>
                <button type="button" onClick={(e) => onOpen(it.expense_id, e.currentTarget)}
                  className="flex min-h-11 w-full flex-col gap-1.5 px-4 py-3 text-left transition-colors hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none motion-reduce:transition-none md:grid md:grid-cols-[minmax(0,2.2fr)_minmax(0,1.2fr)_minmax(0,1fr)_6.5rem_7rem_7rem_7rem] md:items-center md:gap-3">
                  <span className="flex min-w-0 items-start justify-between gap-3 md:block">
                    <span className="min-w-0">
                      <span className="block truncate text-sm font-medium">{it.description}</span>
                      <span className="mt-1 flex flex-wrap gap-1"><ExpenseBadges row={it} className="text-[10px]" /></span>
                    </span>
                    <span className="whitespace-nowrap text-sm font-semibold md:hidden">{formatCents(it.amount)}</span>
                  </span>
                  <span className="truncate text-xs text-muted-foreground md:text-sm md:text-foreground">
                    <span className="md:hidden">{it.category_name} · {it.arena_id ? it.arena_name : 'Geral'} · vence {fmtDueDate(it.due_date)}</span>
                    <span className="hidden md:inline">{it.category_name}</span>
                  </span>
                  <span className="hidden truncate text-sm md:block">{it.arena_id ? it.arena_name : 'Geral'}</span>
                  <span className="hidden whitespace-nowrap text-sm md:block">{fmtDueDate(it.due_date)}</span>
                  <span className="hidden whitespace-nowrap text-right text-sm font-semibold md:block">{formatCents(it.amount)}</span>
                  <span className="flex justify-between gap-3 text-xs md:block md:text-right md:text-sm">
                    <span className="text-muted-foreground md:hidden">Pago</span><span className="whitespace-nowrap">{formatCents(it.net_paid)}</span>
                  </span>
                  <span className="flex justify-between gap-3 text-xs md:block md:text-right md:text-sm">
                    <span className="text-muted-foreground md:hidden">A pagar</span><span className="whitespace-nowrap font-medium">{formatCents(it.amount_due)}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>
    </div>
  )
}
