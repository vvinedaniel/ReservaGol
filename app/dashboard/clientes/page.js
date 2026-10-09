'use client'

// CLIENTES C2B — lista de clientes da organização ativa (rg_customer_list): busca e paginação NO SERVIDOR
// (cursor por nome), filtro Mensalistas / Sem reservas há 60 dias, ficha (rg_customer_detail) e cadastro/
// edição (rg_customer_resolve / rg_customer_update). A coluna "Situação" (fin_flag) só existe para
// OWNER/MANAGER — para a recepção o banco devolve null e a coluna nem aparece.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { EmptyState } from '@/components/reserva/empty-state'
import { CustomerFormDialog } from '@/components/reserva/customers/customer-form-dialog'
import { CustomerDetailSheet } from '@/components/reserva/customers/customer-detail-sheet'
import { createCustomersApi, customerErrorMessage } from '@/lib/reserva/customers-client'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { canViewFinance } from '@/lib/auth/permissions'
import { formatBrPhone } from '@/lib/reserva/phone'
import { fmtDateTimeLong } from '@/lib/reserva/time'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Card, CardContent } from '@/components/ui/card'
import { Loader2, Plus, Search, Users } from 'lucide-react'

const FILTERS = [{ k: 'ALL', l: 'Todos' }, { k: 'MENSALISTA', l: 'Mensalistas' }, { k: 'INACTIVE_60D', l: 'Sem reservas há 60 dias' }]
const FIN_FLAG = {
  OVERDUE: { label: 'Vencido', cls: 'border-amber-500/40 bg-amber-500/10 text-amber-300' },
  OPEN: { label: 'Em aberto', cls: 'border-border bg-muted/40 text-muted-foreground' },
}
const PAGE = 25

function FinFlag({ flag }) {
  const m = FIN_FLAG[flag]
  if (!m) return <span className="text-muted-foreground" aria-label="Sem pendências">—</span>
  return <Badge variant="outline" className={m.cls}>{m.label}</Badge>
}
const when = (iso) => (iso ? fmtDateTimeLong(iso) : '—')

export default function ClientesPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const manager = canViewFinance(me?.role)
  const api = useMemo(() => createCustomersApi(), [])
  const [qInput, setQInput] = useState('')
  const [q, setQ] = useState('')
  const [filter, setFilter] = useState('ALL')
  const [st, setSt] = useState({ loading: true, items: [], next: null, error: null })
  const [more, setMore] = useState({ loading: false, error: null })
  const [reload, setReload] = useState(0)
  const [arenas, setArenas] = useState([])
  const [form, setForm] = useState(null) // { customer: null | {...} }
  const [openId, setOpenId] = useState(null)
  const [detailReload, setDetailReload] = useState(0)
  const seqs = useRef(null)
  if (!seqs.current) seqs.current = { list: createRequestSequence(), more: createRequestSequence(), arenas: createRequestSequence() }
  useEffect(() => () => { for (const s of Object.values(seqs.current)) s.invalidate() }, [])

  useEffect(() => { const t = setTimeout(() => setQ(qInput.trim()), 300); return () => clearTimeout(t) }, [qInput])

  useEffect(() => {
    if (!orgId) return
    runLatest(seqs.current.arenas, () => fetch(`/api/arenas?organization_id=${encodeURIComponent(orgId)}`, { cache: 'no-store' }).then((r) => (r.ok ? r.json() : [])), {
      onResult: (d) => setArenas(Array.isArray(d) ? d.map((a) => ({ id: a.id, name: a.name })) : []),
      onError: () => setArenas([]),
    })
  }, [orgId])

  const load = useCallback(() => {
    if (!orgId) return
    seqs.current.more.invalidate()
    setMore({ loading: false, error: null })
    runLatest(seqs.current.list, () => api.list({ orgId, q: q || null, filter, limit: PAGE }), {
      onStart: () => setSt((s) => ({ ...s, loading: true, error: null })),
      onResult: (d) => setSt({ loading: false, items: Array.isArray(d?.items) ? d.items : [], next: d?.next_cursor ?? null, error: null }),
      onError: (e) => setSt({ loading: false, items: [], next: null, error: customerErrorMessage(e, 'Não foi possível carregar os clientes.') }),
    })
  }, [api, orgId, q, filter])
  useEffect(() => { load() }, [load, reload])

  function loadMore() {
    if (!st.next || more.loading) return
    const cursor = st.next
    runLatest(seqs.current.more, () => api.list({ orgId, q: q || null, filter, limit: PAGE, cursor }), {
      onStart: () => setMore({ loading: true, error: null }),
      onResult: (d) => {
        setMore({ loading: false, error: null })
        setSt((s) => {
          const seen = new Set(s.items.map((c) => c.id))
          return { ...s, items: [...s.items, ...(Array.isArray(d?.items) ? d.items.filter((c) => !seen.has(c.id)) : [])], next: d?.next_cursor ?? null }
        })
      },
      onError: (e) => setMore({ loading: false, error: customerErrorMessage(e, 'Não foi possível carregar mais clientes.') }),
    })
  }

  // Depois de salvar: recarrega lista e ficha (sem atualização otimista).
  async function onSaved(customerId) {
    setForm(null)
    setReload((n) => n + 1)
    setDetailReload((n) => n + 1)
    setOpenId(customerId)
  }

  const filtered = q || filter !== 'ALL'
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-display text-2xl font-bold">Clientes</h1>
          <p className="mt-1 text-sm text-muted-foreground">Cadastro, histórico de reservas e mensalistas de cada cliente.</p>
        </div>
        <Button className="h-11 sm:h-9" onClick={() => setForm({ customer: null })}><Plus className="mr-2 h-4 w-4" aria-hidden="true" />Novo cliente</Button>
      </div>

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="relative flex-1">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input className="h-11 pl-9 sm:h-9" placeholder="Buscar por nome ou telefone" value={qInput} onChange={(e) => setQInput(e.target.value)}
            aria-label="Buscar cliente por nome ou telefone" />
        </div>
        <div className="inline-flex flex-wrap rounded-lg border border-border bg-card p-1" role="group" aria-label="Filtro">
          {FILTERS.map((f) => (
            <button key={f.k} type="button" aria-pressed={filter === f.k} onClick={() => setFilter(f.k)}
              className={`h-11 rounded-md px-3 text-sm font-medium transition-colors sm:h-8 ${filter === f.k ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'}`}>{f.l}</button>
          ))}
        </div>
      </div>

      {st.loading && st.items.length === 0 ? (
        <div className="space-y-2" aria-busy="true" aria-label="Carregando clientes">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-14 w-full" />)}</div>
      ) : st.error ? (
        <Card><CardContent className="space-y-3 py-8 text-center text-sm" role="alert">
          <p className="text-amber-500">{st.error}</p>
          <Button variant="outline" className="h-11 sm:h-9" onClick={() => setReload((n) => n + 1)}>Tentar novamente</Button>
        </CardContent></Card>
      ) : st.items.length === 0 ? (
        <EmptyState icon={Users}
          title={filtered ? 'Nenhum cliente encontrado' : 'Nenhum cliente cadastrado'}
          description={filtered ? 'Tente outro nome, telefone ou filtro.' : 'Clientes aparecem aqui ao criar reservas ou ao cadastrá-los.'}
          action={filtered ? null : <Button className="h-11 sm:h-9" onClick={() => setForm({ customer: null })}>Cadastrar cliente</Button>} />
      ) : (
        <>
          <div className="hidden overflow-x-auto rounded-lg border border-border md:block" aria-busy={st.loading}>
            <table className="w-full text-sm">
              <thead className="bg-muted/30 text-left text-xs text-muted-foreground">
                <tr>
                  <th scope="col" className="px-3 py-2 font-medium">Nome</th>
                  <th scope="col" className="px-3 py-2 font-medium">Telefone</th>
                  <th scope="col" className="px-3 py-2 font-medium">Última reserva</th>
                  <th scope="col" className="px-3 py-2 font-medium">Próxima reserva</th>
                  {manager && <th scope="col" className="px-3 py-2 font-medium">Situação</th>}
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {st.items.map((c) => (
                  <tr key={c.id} className="hover:bg-accent/30">
                    <td className="px-3 py-2">
                      <button type="button" className="flex items-center gap-2 text-left font-medium hover:underline focus-visible:underline focus-visible:outline-none" onClick={() => setOpenId(c.id)}>
                        {c.name}{c.is_mensalista && <Badge variant="outline" className="text-xs">Mensalista</Badge>}
                      </button>
                    </td>
                    <td className="px-3 py-2 tabular-nums">{c.phone ? formatBrPhone(c.phone) : <span className="text-muted-foreground">—</span>}</td>
                    <td className="px-3 py-2 tabular-nums text-muted-foreground">{when(c.last_at)}</td>
                    <td className="px-3 py-2 tabular-nums">{when(c.next_at)}</td>
                    {manager && <td className="px-3 py-2"><FinFlag flag={c.fin_flag} /></td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <ul className="space-y-2 md:hidden">
            {st.items.map((c) => (
              <li key={c.id}>
                <button type="button" onClick={() => setOpenId(c.id)} className="w-full rounded-lg border border-border bg-card p-3 text-left text-sm hover:bg-accent/30 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
                  <span className="flex items-center justify-between gap-2">
                    <span className="truncate font-medium">{c.name}</span>
                    <span className="flex shrink-0 gap-1">{c.is_mensalista && <Badge variant="outline" className="text-xs">Mensalista</Badge>}{manager && c.fin_flag && <FinFlag flag={c.fin_flag} />}</span>
                  </span>
                  <span className="mt-1 block text-xs text-muted-foreground">{c.phone ? formatBrPhone(c.phone) : 'Sem telefone'}</span>
                  <span className="mt-1 block text-xs text-muted-foreground">Próxima: {when(c.next_at)} · Última: {when(c.last_at)}</span>
                </button>
              </li>
            ))}
          </ul>
          {more.error && <p className="text-sm text-amber-500" role="alert">{more.error}</p>}
          {st.next && (
            <Button variant="outline" className="h-11 w-full sm:h-9" onClick={loadMore} disabled={more.loading}>
              {more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Carregar mais
            </Button>
          )}
        </>
      )}

      {openId && (
        <CustomerDetailSheet api={api} customerId={openId} reloadKey={detailReload} onClose={() => setOpenId(null)}
          onEdit={(c) => setForm({ customer: c })} />
      )}
      {form && (
        <CustomerFormDialog key={form.customer?.id ?? 'new'} api={api} orgId={orgId} arenas={arenas} customer={form.customer}
          onClose={() => setForm(null)} onSaved={onSaved}
          onOpenCustomer={(id) => { setForm(null); setOpenId(id); setDetailReload((n) => n + 1) }}
          onStale={() => { setForm(null); setDetailReload((n) => n + 1); setReload((n) => n + 1) }} />
      )}
    </div>
  )
}
