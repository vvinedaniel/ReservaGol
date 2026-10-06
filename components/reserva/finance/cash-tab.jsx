'use client'

// FASE 03B.2B-2A — Caixa consolidado (substitui o Caixa só de entradas da 03B.1). Fontes:
// rg_fin_cash_result (Entradas / Saídas / Resultado de caixa + buckets) e rg_fin_cash_movements
// (movimentos das duas origens, cursor composto occurred_at + source_kind + id). Direção e sinal de
// cada movimento vêm SEMPRE do banco (direction / signed_amount, via movementView), nunca da origem.
// Resultado de caixa = Entradas − Saídas do período; não é lucro.
import { useEffect, useState } from 'react'
import { runLatest } from '@/lib/reserva/latest-request'
import { movementView } from '@/lib/reserva/expenses'
import { cashflowGranularity } from '@/lib/reserva/finance-client'
import { formatCents, toCents } from '@/lib/reserva/money'
import { PAYMENT_METHOD_LABELS } from '@/lib/reserva/finance'
import { fmtDateTimeLong } from '@/lib/reserva/time'
import { EmptyState } from '@/components/reserva/empty-state'
import { GeneralExcludedNotice } from '@/components/reserva/finance/expenses-tab'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { AlertTriangle, ArrowDownLeft, ArrowUpRight, BarChart3, Loader2, RefreshCw, Scale, Wallet } from 'lucide-react'
import { cn } from '@/lib/utils'

const PAGE_SIZE = 50
const MONTHS = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez']
function bucketLabel(bucket, granularity) {
  if (typeof bucket !== 'string' || bucket.length < 10) return ''
  if (granularity === 'year') return bucket.slice(0, 4)
  return granularity === 'month' ? `${MONTHS[Number(bucket.slice(5, 7)) - 1]}/${bucket.slice(2, 4)}` : `${bucket.slice(8, 10)}/${bucket.slice(5, 7)}`
}

export function CashTab({ api, seqs, scope, baseKey, period, onForbidden }) {
  const granularity = cashflowGranularity(period)
  const [res, setRes] = useState({ loading: true, error: false, data: null })
  const [list, setList] = useState({ loading: true, error: false, items: [], cursor: null })
  const [more, setMore] = useState({ loading: false, error: false })
  const [reload, setReload] = useState(0)

  useEffect(() => {
    seqs.more.invalidate()
    setMore({ loading: false, error: false })
    runLatest(seqs.result, () => api.cashResult(scope, granularity), {
      onStart: () => setRes({ loading: true, error: false, data: null }),
      onResult: (d) => setRes({ loading: false, error: false, data: d }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setRes({ loading: false, error: true, data: null }) },
    })
    runLatest(seqs.moves, () => api.cashMovements(scope, { limit: PAGE_SIZE }), {
      onStart: () => setList({ loading: true, error: false, items: [], cursor: null }),
      onResult: (d) => setList({ loading: false, error: false, items: Array.isArray(d?.items) ? d.items : [], cursor: d?.next_cursor || null }),
      onError: (e) => { if (e?.status === 403) onForbidden(); setList({ loading: false, error: true, items: [], cursor: null }) },
    })
    return () => { seqs.result.invalidate(); seqs.moves.invalidate(); seqs.more.invalidate() }
  }, [baseKey, granularity, reload])

  function loadMore() {
    const cursor = list.cursor
    if (!cursor || more.loading) return
    runLatest(seqs.more, () => api.cashMovements(scope, { limit: PAGE_SIZE, cursor }), {
      onStart: () => setMore({ loading: true, error: false }),
      onResult: (d) => setList((l) => ({ ...l, items: [...l.items, ...(Array.isArray(d?.items) ? d.items : [])], cursor: d?.next_cursor || null })),
      onError: (e) => { if (e?.status === 403) onForbidden(); setMore({ loading: false, error: true }) },
      onSettled: () => setMore((m) => ({ ...m, loading: false })),
    })
  }

  if (res.error || list.error) {
    return (
      <EmptyState icon={AlertTriangle} title="Não foi possível carregar" description="Verifique sua conexão e tente novamente."
        action={<Button variant="outline" className="h-11 sm:h-9" onClick={() => setReload((n) => n + 1)}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>} />
    )
  }
  const t = res.data?.totals
  const result = toCents(t?.result)
  return (
    <div className="space-y-5">
      {res.data?.excludes_general === true && <GeneralExcludedNotice />}
      {res.loading || !res.data ? (
        <div className="grid gap-4 sm:grid-cols-3" role="status" aria-label="Carregando caixa">{Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-28" />)}</div>
      ) : (
        <div className="grid gap-4 sm:grid-cols-3">
          <CashCard label="Entradas" icon={ArrowDownLeft} value={formatCents(t?.in_net)}
            hint={`${formatCents(t?.in_gross)} em recebimentos − ${formatCents(t?.in_refunds)} em estornos`} />
          <CashCard label="Saídas" icon={ArrowUpRight} value={formatCents(t?.out_net)}
            hint={`${formatCents(t?.out_gross)} em pagamentos de despesas − ${formatCents(t?.out_reversals)} em devoluções`} />
          <CashCard label="Resultado de caixa" icon={Scale} value={formatCents(t?.result)} tone={result !== null && result < 0 ? 'warn' : undefined}
            hint="Entradas − Saídas registradas no período" />
        </div>
      )}

      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="flex items-center gap-2 text-base"><BarChart3 className="h-4 w-4 text-primary" /> Caixa no período</CardTitle>
          <p className="text-xs text-muted-foreground">Movimentos pela data real do recebimento ou do pagamento.</p>
        </CardHeader>
        <CardContent>
          {res.loading || !res.data ? <Skeleton className="h-48 w-full" /> : <CashChart buckets={res.data.buckets || []} granularity={res.data.granularity || granularity} />}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-2"><CardTitle className="text-base">Movimentos</CardTitle></CardHeader>
        <CardContent className="p-0">
          {list.loading ? <div className="space-y-2 p-4" role="status" aria-label="Carregando movimentos">{Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-12 w-full" />)}</div>
            : list.items.length === 0 ? <div className="p-4"><EmptyState icon={Wallet} title="Nenhum movimento no período" description="Recebimentos, estornos, pagamentos de despesas e devoluções registrados no período aparecem aqui." /></div>
              : (
                <ul className="divide-y divide-border">
                  {list.items.map((m) => {
                    const v = movementView(m)
                    const who = m.source === 'EXPENSE'
                      ? [m.description, m.category_name].filter(Boolean).join(' · ')
                      : [m.customer_name || 'Sem cliente', m.court_name].filter(Boolean).join(' · ')
                    return (
                      <li key={`${m.source_kind}:${m.id}`} className="flex items-start justify-between gap-3 px-4 py-3">
                        <div className="min-w-0">
                          <p className="truncate text-sm font-medium">{v.label} · {PAYMENT_METHOD_LABELS[m.method] || m.method}</p>
                          <p className="text-xs text-muted-foreground">{fmtDateTimeLong(m.occurred_at)}{who ? ` · ${who}` : ''}</p>
                        </div>
                        <span className={cn('shrink-0 whitespace-nowrap text-sm font-semibold', v.tone === 'in' ? 'text-primary' : v.tone === 'out' ? 'text-red-400' : 'text-foreground')}>{v.value}</span>
                      </li>
                    )
                  })}
                </ul>
              )}
        </CardContent>
      </Card>
      {!list.loading && list.cursor && (
        <div className="flex flex-col items-center gap-2">
          <Button variant="outline" className="h-11 sm:h-9" onClick={loadMore} disabled={more.loading}>
            {more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />} Carregar mais
          </Button>
          {more.error && <p className="text-xs text-amber-500" role="alert">Não foi possível carregar mais. Tente novamente.</p>}
        </div>
      )}
    </div>
  )
}

function CashCard({ label, icon: Icon, value, hint, tone }) {
  return (
    <Card className="overflow-hidden">
      <CardContent className="p-5">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
            <p className={cn('mt-2 whitespace-nowrap font-display text-2xl font-bold', tone === 'warn' ? 'text-amber-500' : 'text-foreground')}>{value ?? '—'}</p>
            {hint && <p className="mt-1 text-xs text-muted-foreground">{hint}</p>}
          </div>
          {Icon && <div className={cn('flex h-10 w-10 shrink-0 items-center justify-center rounded-lg', tone === 'warn' ? 'bg-amber-500/10 text-amber-500' : 'bg-primary/10 text-primary')}><Icon className="h-5 w-5" /></div>}
        </div>
      </CardContent>
    </Card>
  )
}

// Barras a partir de uma linha base: para cima = entradas líquidas do bucket; para baixo = saídas
// líquidas; traço = resultado do bucket (acima da base se positivo, abaixo se negativo). Escala
// única pelo maior valor absoluto do período. Só CSS (leve e responsivo, sem biblioteca).
function CashChart({ buckets, granularity }) {
  const v = (x) => toCents(x) ?? 0
  const max = buckets.reduce((m, b) => Math.max(m, Math.abs(v(b.in_net)), Math.abs(v(b.out_net)), Math.abs(v(b.result))), 0)
  if (max === 0) return <p className="rounded-lg border border-dashed border-border px-3 py-8 text-center text-sm text-muted-foreground">Nenhum movimento registrado no período.</p>
  const pct = (x) => (x > 0 ? Math.max(1, Math.floor((x * 100) / max)) : 0)
  const step = Math.max(1, Math.ceil(buckets.length / 8))
  return (
    <div>
      <div className="relative flex h-48 items-stretch gap-[2px] overflow-hidden sm:gap-1" role="img" aria-label="Gráfico de entradas, saídas e resultado de caixa do período">
        <div className="pointer-events-none absolute inset-x-0 top-1/2 border-t border-border" aria-hidden="true" />
        {buckets.map((b) => {
          const inn = v(b.in_net), out = v(b.out_net), r = v(b.result)
          return (
            <div key={b.bucket} className="relative flex min-w-0 flex-1 flex-col"
              title={`${bucketLabel(b.bucket, granularity)}: entradas ${formatCents(inn)}, saídas ${formatCents(out)}, resultado ${formatCents(r)}`}>
              <div className="flex h-1/2 items-end"><div className="mx-auto w-full max-w-12 rounded-t-sm bg-primary/70" style={{ height: `${pct(inn)}%` }} /></div>
              <div className="flex h-1/2 items-start"><div className="mx-auto w-full max-w-12 rounded-b-sm bg-red-400/70" style={{ height: `${pct(out)}%` }} /></div>
              {r !== 0 && (
                <div className={cn('absolute inset-x-0 mx-auto h-0.5 w-full max-w-12', r > 0 ? 'bg-foreground' : 'bg-amber-400')}
                  style={r > 0 ? { bottom: `${50 + pct(r) / 2}%` } : { top: `${50 + pct(-r) / 2}%` }} />
              )}
            </div>
          )
        })}
      </div>
      <div className="relative mt-1 h-4 text-[10px] text-muted-foreground" aria-hidden="true">
        {buckets.map((b, i) => (i % step === 0 ? (
          <span key={b.bucket} className={cn('absolute top-0 whitespace-nowrap', i === 0 ? 'translate-x-0' : i === buckets.length - 1 ? '-translate-x-full' : '-translate-x-1/2')}
            style={{ left: i === 0 ? 0 : `${((i * 2 + 1) * 50) / buckets.length}%` }}>{bucketLabel(b.bucket, granularity)}</span>
        ) : null))}
      </div>
      <div className="mt-2 flex flex-wrap gap-4 text-xs text-muted-foreground">
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm bg-primary/70" /> Entradas</span>
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm bg-red-400/70" /> Saídas</span>
        <span className="flex items-center gap-1.5"><span className="h-0.5 w-3 bg-foreground" /> Resultado</span>
      </div>
    </div>
  )
}
