'use client'

// FASE 03B.3B — visão mensal OWNER/MANAGER: cards (mês + arena), filtros, busca e lista por mensalista
// (linhagem). Fonte única: rg_recurring_month_list via /api/recurring-month (status, saldos e contagens
// vêm do banco; nada é calculado aqui). Toda carga usa runLatest: mês/filtro antigo nunca sobrescreve o novo.
import { useEffect, useState } from 'react'
import { runLatest } from '@/lib/reserva/latest-request'
import { MONTH_FILTERS, MONTH_FILTER_LABELS, monthLabel, slotLabel } from '@/lib/reserva/recurring-month'
import { MonthStatusBadge, NoCustomerBadge, OverdueBadge, Money } from '@/components/reserva/mensalistas/month-ui'
import { EmptyState } from '@/components/reserva/empty-state'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { AlertTriangle, Loader2, RefreshCw, Repeat, Search, Users, CalendarCheck, Wallet, Clock } from 'lucide-react'
import { cn } from '@/lib/utils'

const PAGE_SIZE = 50
const ALL_ARENAS = 'all'

export function MonthList({ api, seqs, orgId, month, arenaId, arenas = [], status, reloadKey, onChangeArena, onChangeStatus, onOpen, onForbidden }) {
  const [q, setQ] = useState('')
  const [debouncedQ, setDebouncedQ] = useState('')
  const [st, setSt] = useState({ loading: true, refreshing: false, error: false, summary: null, items: [], cursor: null })
  const [more, setMore] = useState({ loading: false, error: false })
  const [retryKey, setRetryKey] = useState(0)

  useEffect(() => { const t = setTimeout(() => setDebouncedQ(q.trim()), 250); return () => clearTimeout(t) }, [q])

  useEffect(() => {
    if (!orgId) return
    seqs.more.invalidate()
    setMore({ loading: false, error: false })
    runLatest(seqs.list, () => api.list({ orgId, month, arenaId, status, q: debouncedQ || null, limit: PAGE_SIZE }), {
      onStart: () => setSt((s) => ({ ...s, loading: s.items.length === 0 && !s.summary, refreshing: s.items.length > 0 || !!s.summary, error: false })),
      onResult: (d) => setSt({ loading: false, refreshing: false, error: false, summary: d?.summary || null, items: Array.isArray(d?.items) ? d.items : [], cursor: d?.next_cursor || null }),
      onError: (e) => { if (e?.status === 403) onForbidden?.(); setSt({ loading: false, refreshing: false, error: true, summary: null, items: [], cursor: null }) },
    })
    return () => { seqs.list.invalidate(); seqs.more.invalidate() }
  }, [orgId, month, arenaId, status, debouncedQ, reloadKey, retryKey])

  function loadMore() {
    const cursor = st.cursor
    if (!cursor || more.loading || st.refreshing) return
    runLatest(seqs.more, () => api.list({ orgId, month, arenaId, status, q: debouncedQ || null, limit: PAGE_SIZE, cursor }), {
      onStart: () => setMore({ loading: true, error: false }),
      onResult: (d) => setSt((s) => ({ ...s, items: [...s.items, ...(Array.isArray(d?.items) ? d.items : [])], cursor: d?.next_cursor || null })),
      onError: () => setMore({ loading: false, error: true }),
      onSettled: () => setMore((m) => ({ ...m, loading: false })),
    })
  }
  const retry = () => setRetryKey((n) => n + 1)

  return (
    <div className="space-y-5">
      <SummaryCards summary={st.summary} loading={st.loading} refreshing={st.refreshing} />

      <div className="space-y-3">
        <div className="-mx-4 flex gap-1.5 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0" role="group" aria-label="Situação do mês">
          {MONTH_FILTERS.map((f) => (
            <Button key={f} type="button" size="sm" variant={status === f ? 'default' : 'outline'} aria-pressed={status === f}
              className="h-11 shrink-0 px-4 sm:h-8 sm:px-3" onClick={() => onChangeStatus(f)}>{MONTH_FILTER_LABELS[f]}</Button>
          ))}
        </div>
        <div className="flex flex-col gap-2 sm:flex-row">
          <div className="relative flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
            <Input value={q} onChange={(e) => setQ(e.target.value)} maxLength={100} placeholder="Buscar cliente ou telefone" aria-label="Buscar mensalista por cliente ou telefone"
              className="h-11 pl-9 sm:h-9" />
          </div>
          {arenas.length > 1 && (
            <Select value={arenaId || ALL_ARENAS} onValueChange={(v) => onChangeArena(v === ALL_ARENAS ? null : v)}>
              <SelectTrigger className="h-11 w-full sm:h-9 sm:w-56" aria-label="Arena"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL_ARENAS}>Todas as arenas</SelectItem>
                {arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}
              </SelectContent>
            </Select>
          )}
        </div>
      </div>

      <LineageList st={st} month={month} status={status} onOpen={onOpen} onRetry={retry} />

      {!st.loading && !st.error && st.cursor && (
        <div className="flex flex-col items-center gap-2">
          <Button variant="outline" className="h-11 sm:h-9" onClick={loadMore} disabled={more.loading || st.refreshing}>
            {more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Carregar mais
          </Button>
          {more.error && <p className="text-xs text-amber-500" role="alert">Não foi possível carregar mais. Tente novamente.</p>}
        </div>
      )}
    </div>
  )
}

function SummaryCards({ summary, loading, refreshing }) {
  if (loading || !summary) {
    return <div className="grid grid-cols-2 gap-3 lg:grid-cols-4" role="status" aria-label="Carregando resumo do mês">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-24" />)}</div>
  }
  return (
    <div className={cn('grid grid-cols-2 gap-3 lg:grid-cols-4', refreshing && 'opacity-60')} aria-busy={refreshing}>
      <Metric label="Mensalistas no mês" icon={Users} value={String(summary.lineages ?? 0)} hint={`${summary.games ?? 0} jogos`} />
      <Metric label="Previsto" icon={CalendarCheck} value={<Money value={summary.expected} />} hint="Jogos com valor no mês" />
      <Metric label="Recebido" icon={Wallet} value={<Money value={summary.net} />}
        hint={summary.retained > 0 ? <>+ <Money value={summary.retained} /> retido</> : 'Líquido dos jogos do mês'} />
      <Metric label="A receber" icon={Clock} value={<Money value={summary.open} />}
        hint={summary.overdue > 0 ? <span className="text-red-300"><Money value={summary.overdue} /> vencido</span> : 'Nada vencido'} tone={summary.overdue > 0 ? 'warn' : null} />
    </div>
  )
}

function Metric({ label, icon: Icon, value, hint, tone }) {
  return (
    <Card>
      <CardContent className="p-4">
        <div className="flex items-start justify-between gap-2">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
          <Icon className={cn('h-4 w-4 shrink-0', tone === 'warn' ? 'text-red-300' : 'text-muted-foreground')} aria-hidden="true" />
        </div>
        <p className="mt-2 font-display text-xl font-bold sm:text-2xl">{value}</p>
        {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
      </CardContent>
    </Card>
  )
}

function LineageList({ st, month, status, onOpen, onRetry }) {
  if (st.error) {
    return (
      <EmptyState icon={AlertTriangle} title="Não foi possível carregar" description="Verifique sua conexão e tente novamente."
        action={<Button variant="outline" className="h-11 sm:h-9" onClick={onRetry}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>} />
    )
  }
  if (st.loading) return <div className="space-y-2" role="status" aria-label="Carregando mensalistas">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
  if (st.items.length === 0 && !st.refreshing) {
    return <EmptyState icon={Repeat} title="Nenhum mensalista neste filtro"
      description={status === 'ALL' ? `Nenhum mensalista com jogos em ${monthLabel(month)}.` : `Nenhum mensalista "${MONTH_FILTER_LABELS[status]}" em ${monthLabel(month)}.`} />
  }
  return (
    <Card className={cn(st.refreshing && 'opacity-60')} aria-busy={st.refreshing}>
      <CardContent className="p-0">
        <div className="hidden grid-cols-[minmax(0,2fr)_minmax(0,2fr)_4rem_7rem_7rem_7rem_8.5rem] gap-3 border-b border-border px-4 py-2 text-xs font-medium text-muted-foreground md:grid">
          <span>Cliente</span><span>Horário</span><span className="text-right">Jogos</span>
          <span className="text-right">Previsto</span><span className="text-right">Recebido</span><span className="text-right">A receber</span><span>Situação</span>
        </div>
        <ul className="divide-y divide-border">
          {st.items.map((it) => (
            <li key={it.lineage_id}>
              <button type="button" onClick={(e) => onOpen(it.lineage_id, e.currentTarget)}
                className="flex min-h-11 w-full flex-col gap-1.5 px-4 py-3 text-left transition-colors hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none motion-reduce:transition-none md:grid md:grid-cols-[minmax(0,2fr)_minmax(0,2fr)_4rem_7rem_7rem_7rem_8.5rem] md:items-center md:gap-3">
                <span className="flex min-w-0 items-start justify-between gap-2 md:block">
                  <span className={cn('block truncate text-sm font-medium', !it.customer_name && 'italic text-muted-foreground')}>{it.customer_name || 'Sem cliente cadastrado'}</span>
                  <span className="shrink-0 md:hidden"><MonthStatusBadge status={it.status} /></span>
                </span>
                <span className="truncate text-xs text-muted-foreground md:text-sm md:text-foreground">{slotLabel(it)} · {it.court_name}</span>
                <span className="text-xs text-muted-foreground md:text-right md:text-sm md:text-foreground">
                  <span className="md:hidden">{it.games} jogos · A receber </span><span className="hidden md:inline">{it.games}</span>
                  <span className="md:hidden"><Money value={it.open} strong /></span>
                </span>
                <span className="hidden text-right text-sm md:block"><Money value={it.expected} /></span>
                <span className="hidden text-right text-sm md:block"><Money value={it.net} /></span>
                <span className="hidden text-right text-sm md:block"><Money value={it.open} strong /></span>
                <span className="flex flex-wrap gap-1">
                  <span className="hidden md:inline-flex"><MonthStatusBadge status={it.status} /></span>
                  {!it.customer_id && <NoCustomerBadge />}
                  {it.has_overdue && it.status !== 'OVERDUE' && <OverdueBadge amount={it.overdue} />}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  )
}
