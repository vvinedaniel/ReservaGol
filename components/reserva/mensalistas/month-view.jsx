'use client'

// FASE 03B.3B — view "Mês" de Mensalistas (padrão). Estado de navegação SÓ na URL:
//   ?month=YYYY-MM (ausente = mês atual) · ?status (filtro, só gestor) · ?arena · ?l=<linhagem aberta>
// Modo por papel (canViewFinance = OWNER/MANAGER; nunca isManagerOrAbove):
//   - gestor: cards + filtros + lista mensal (rg_recurring_month_list) + detalhe + W1/W2 + estorno/anulação;
//   - demais membros (RECEPTIONIST): busca operacional (rg_recurring_month_search, sem valores) + detalhe de
//     UM mensalista + "Receber mês". Nenhum agregado é buscado. Se a lista responder 403, cai no modo busca.
// Toda carga usa createRequestSequence + runLatest e toda troca invalida SINCRONAMENTE o que está em curso.
import { useEffect, useMemo, useRef, useState } from 'react'
import { usePathname, useRouter, useSearchParams } from 'next/navigation'
import { canViewFinance } from '@/lib/auth/permissions'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { createRecurringMonthApi } from '@/lib/reserva/recurring-month-client'
import { isMonthParam, monthOf, MONTH_FILTERS } from '@/lib/reserva/recurring-month'
import { isUuid } from '@/lib/reserva/finance-api'
import { todayStr } from '@/lib/reserva/time'
import { MonthNav } from '@/components/reserva/mensalistas/month-ui'
import { MonthList } from '@/components/reserva/mensalistas/month-list'
import { MonthSearch } from '@/components/reserva/mensalistas/month-search'
import { MonthDetailSheet } from '@/components/reserva/mensalistas/month-detail-sheet'

export function MonthView({ me }) {
  const router = useRouter()
  const pathname = usePathname()
  const sp = useSearchParams()
  const orgId = me?.activeOrg?.id
  const role = me?.role
  const manager = canViewFinance(role)
  const [today] = useState(todayStr)
  const currentMonth = monthOf(today)
  const month = isMonthParam(sp.get('month')) ? sp.get('month') : currentMonth
  const status = manager && MONTH_FILTERS.includes(sp.get('status')) ? sp.get('status') : 'ALL'
  const arenaParam = sp.get('arena')
  const lineage = isUuid(sp.get('l')) ? sp.get('l') : null
  const [forbidden, setForbidden] = useState(false)
  const mode = manager && !forbidden ? 'manager' : 'operator'
  const [arenas, setArenas] = useState({ ready: false, list: [] })
  const [listReload, setListReload] = useState(0)
  const api = useMemo(() => createRecurringMonthApi(), [])
  const lastTrigger = useRef(null)

  const seqs = useRef(null)
  if (!seqs.current) {
    seqs.current = { arenas: createRequestSequence(), list: createRequestSequence(), more: createRequestSequence(), search: createRequestSequence(), detail: createRequestSequence() }
  }
  const invalidateLoads = () => { const s = seqs.current; s.list.invalidate(); s.more.invalidate(); s.search.invalidate(); s.detail.invalidate() }
  useEffect(() => () => { for (const s of Object.values(seqs.current)) s.invalidate() }, [])

  // Arenas só para o filtro do gestor (o modo busca não usa arena).
  useEffect(() => {
    if (!orgId || mode !== 'manager') return
    runLatest(seqs.current.arenas, () => fetch(`/api/arenas?organization_id=${encodeURIComponent(orgId)}`, { cache: 'no-store' }).then((r) => (r.ok ? r.json() : [])), {
      onResult: (d) => setArenas({ ready: true, list: Array.isArray(d) ? d.map((a) => ({ id: a.id, name: a.name })) : [] }),
      onError: () => setArenas({ ready: true, list: [] }),
    })
  }, [orgId, mode])
  const arenaId = arenas.ready && isUuid(arenaParam) && arenas.list.some((a) => a.id === arenaParam) ? arenaParam : null

  // Query canônica: só chaves válidas e diferentes do padrão; view "mes" é o padrão (omitida).
  const navigate = (change, { push = false } = {}) => {
    const next = { month, status, arena: arenaId, l: lineage, ...change }
    const q = new URLSearchParams()
    if (next.month && next.month !== currentMonth) q.set('month', next.month)
    if (next.status && next.status !== 'ALL') q.set('status', next.status)
    if (next.arena) q.set('arena', next.arena)
    if (next.l) q.set('l', next.l)
    const s = q.toString()
    const url = s ? `${pathname}?${s}` : pathname
    if (push) router.push(url, { scroll: false })
    else router.replace(url, { scroll: false })
  }
  const changeMonth = (m) => { if (!isMonthParam(m) || m === month) return; invalidateLoads(); navigate({ month: m }) }
  const changeStatus = (f) => { if (!MONTH_FILTERS.includes(f) || f === status) return; seqs.current.list.invalidate(); seqs.current.more.invalidate(); navigate({ status: f }) }
  const changeArena = (a) => { if ((a || null) === arenaId) return; seqs.current.list.invalidate(); seqs.current.more.invalidate(); navigate({ arena: a || null }) }
  const openLineage = (id, el) => { lastTrigger.current = el || null; navigate({ l: id }, { push: true }) }
  const closeLineage = () => { seqs.current.detail.invalidate(); navigate({ l: null }) }
  // Depois de qualquer mutação no detalhe: a lista/cards do gestor (ou a busca) refazem o fetch.
  const onChanged = () => setListReload((n) => n + 1)

  if (!orgId) return null
  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <MonthNav month={month} currentMonth={currentMonth} onChange={changeMonth} />
        {mode === 'operator' && <p className="text-sm text-muted-foreground">Localize o mensalista para ver os jogos do mês e registrar o recebimento.</p>}
      </div>

      {mode === 'manager' ? (
        <MonthList api={api} seqs={{ list: seqs.current.list, more: seqs.current.more }} orgId={orgId} month={month} arenaId={arenaId} arenas={arenas.list}
          status={status} reloadKey={listReload} onChangeArena={changeArena} onChangeStatus={changeStatus} onOpen={openLineage} onForbidden={() => setForbidden(true)} />
      ) : (
        <MonthSearch api={api} seq={seqs.current.search} orgId={orgId} month={month} reloadKey={listReload} onOpen={openLineage} />
      )}

      {lineage && (
        <MonthDetailSheet api={api} seq={seqs.current.detail} lineageId={lineage} month={month} currentMonth={currentMonth} manager={mode === 'manager'}
          role={role} orgId={orgId} onChangeMonth={changeMonth} onClose={closeLineage} onChanged={onChanged} returnFocusTo={lastTrigger} />
      )}
    </div>
  )
}
