'use client'

// FASE 03B.3B — busca operacional (RECEPTIONIST; qualquer membro ativo): localizar UM mensalista com
// jogos no mês. Fonte: rg_recurring_month_search (SEM valores financeiros: só identidade, horário, jogos e
// elegibilidade). Nenhum agregado da organização é buscado ou exibido. Valores só no detalhe de UM mensalista.
import { useEffect, useState } from 'react'
import { runLatest } from '@/lib/reserva/latest-request'
import { monthLabel, slotLabel } from '@/lib/reserva/recurring-month'
import { NoCustomerBadge } from '@/components/reserva/mensalistas/month-ui'
import { EmptyState } from '@/components/reserva/empty-state'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { AlertTriangle, ChevronRight, RefreshCw, Repeat, Search } from 'lucide-react'
import { cn } from '@/lib/utils'

export function MonthSearch({ api, seq, orgId, month, reloadKey, onOpen }) {
  const [q, setQ] = useState('')
  const [debouncedQ, setDebouncedQ] = useState('')
  const [retryKey, setRetryKey] = useState(0)
  const [st, setSt] = useState({ loading: true, error: false, items: [] })

  useEffect(() => { const t = setTimeout(() => setDebouncedQ(q.trim()), 250); return () => clearTimeout(t) }, [q])
  useEffect(() => {
    if (!orgId) return
    runLatest(seq, () => api.search({ orgId, month, q: debouncedQ || null }), {
      onStart: () => setSt((s) => ({ ...s, loading: true, error: false })),
      onResult: (d) => setSt({ loading: false, error: false, items: Array.isArray(d?.items) ? d.items : [] }),
      onError: () => setSt({ loading: false, error: true, items: [] }),
    })
    return () => seq.invalidate()
  }, [orgId, month, debouncedQ, reloadKey, retryKey])

  return (
    <div className="space-y-4">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} maxLength={100} autoFocus placeholder="Nome ou telefone do cliente"
          aria-label="Buscar mensalista por nome ou telefone" className="h-12 pl-9 text-base" />
      </div>
      <p className="text-xs text-muted-foreground" aria-live="polite">
        {st.loading ? 'Buscando…' : st.error ? '' : `${st.items.length} mensalista${st.items.length === 1 ? '' : 's'} com jogos em ${monthLabel(month)}${st.items.length === 20 ? ' (refine a busca)' : ''}.`}
      </p>
      {st.error ? (
        <EmptyState icon={AlertTriangle} title="Não foi possível buscar" description="Verifique sua conexão e tente novamente."
          action={<Button variant="outline" className="h-11 sm:h-9" onClick={() => setRetryKey((n) => n + 1)}><RefreshCw className="mr-2 h-4 w-4" /> Tentar novamente</Button>} />
      ) : st.loading && st.items.length === 0 ? (
        <div className="space-y-2" role="status" aria-label="Buscando mensalistas">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
      ) : st.items.length === 0 ? (
        <EmptyState icon={Repeat} title="Nenhum mensalista encontrado"
          description={debouncedQ ? `Nada encontrado para "${debouncedQ}" em ${monthLabel(month)}.` : `Nenhum mensalista com jogos em ${monthLabel(month)}.`} />
      ) : (
        <Card className={cn(st.loading && 'opacity-60')} aria-busy={st.loading}>
          <CardContent className="p-0">
            <ul className="divide-y divide-border">
              {st.items.map((it) => (
                <li key={it.lineage_id}>
                  <button type="button" onClick={(e) => onOpen(it.lineage_id, e.currentTarget)}
                    className="flex min-h-14 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none motion-reduce:transition-none">
                    <span className="min-w-0 flex-1">
                      <span className={cn('block truncate font-medium', !it.has_customer && 'italic text-muted-foreground')}>{it.customer_name || 'Sem cliente cadastrado'}</span>
                      <span className="block truncate text-sm text-muted-foreground">{slotLabel(it)} · {it.court_name} · {it.games} jogo{it.games === 1 ? '' : 's'}</span>
                    </span>
                    {!it.has_customer && <NoCustomerBadge className="shrink-0" />}
                    <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                  </button>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
