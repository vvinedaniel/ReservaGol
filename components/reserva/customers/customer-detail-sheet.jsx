'use client'

// CLIENTES C2B — ficha operacional do cliente (rg_customer_detail). Cadastro, próximas reservas, histórico
// paginado (cursor), séries de mensalista e — SÓ quando o banco devolve (OWNER/MANAGER) — o financeiro das
// reservas VINCULADAS. Os valores não comprovam quem pagou: nunca são apresentados como "pago pelo cliente".
import { useCallback, useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { formatBrPhone, whatsappUrl } from '@/lib/reserva/phone'
import { formatCents } from '@/lib/reserva/money'
import { fmtDateTimeLong, fmtTime } from '@/lib/reserva/time'
import { STATUS_META } from '@/lib/reserva/status'
import { customerErrorMessage } from '@/lib/reserva/customers-client'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { CalendarClock, History, Loader2, Mail, MapPin, MessageCircle, Pencil, Phone, Repeat, Wallet } from 'lucide-react'

const WEEKDAYS = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
const FREQ_LABEL = { WEEKLY: 'Semanal', BIWEEKLY: 'Quinzenal', MONTHLY: 'Mensal' }
const SERIES_STATUS = { ACTIVE: 'Ativo', PAUSED: 'Pausado', CANCELLED: 'Cancelado' }
const hhmm = (t) => (t || '').slice(0, 5)

function seriesWhen(s) {
  const day = s.frequency === 'MONTHLY' ? `Dia ${s.day_of_month}` : WEEKDAYS[s.weekday] ?? ''
  return `${FREQ_LABEL[s.frequency] ?? s.frequency} · ${day} · ${hhmm(s.start_time)}–${hhmm(s.end_time)}`
}

function ReservationRow({ r }) {
  const meta = STATUS_META[r.status]
  return (
    <li className="flex items-start justify-between gap-3 py-2 text-sm">
      <span className="min-w-0">
        <span className="block font-medium tabular-nums">{fmtDateTimeLong(r.start_at)}–{fmtTime(r.end_at)}</span>
        <span className="block truncate text-xs text-muted-foreground">{r.court?.name ?? 'Quadra'}{r.recurring_reservation_id ? ' · mensalista' : ''}</span>
      </span>
      <Badge variant="outline" className="shrink-0">{meta?.label ?? r.status}</Badge>
    </li>
  )
}

export function CustomerDetailSheet({ api, customerId, reloadKey = 0, onClose, onEdit }) {
  const [st, setSt] = useState({ loading: true, data: null, error: null })
  const [more, setMore] = useState({ loading: false, items: [], next: null, error: null })
  const seq = useRef(null)
  const moreSeq = useRef(null)
  if (!seq.current) seq.current = createRequestSequence()
  if (!moreSeq.current) moreSeq.current = createRequestSequence()

  const load = useCallback(() => {
    moreSeq.current.invalidate()
    runLatest(seq.current, () => api.detail(customerId, { historyLimit: 10 }), {
      onStart: () => setSt((s) => ({ ...s, loading: true, error: null })),
      onResult: (d) => { setSt({ loading: false, data: d, error: null }); setMore({ loading: false, items: [], next: d?.history_next_before ?? null, error: null }) },
      onError: (e) => setSt({ loading: false, data: null, error: customerErrorMessage(e, 'Não foi possível carregar o cliente.') }),
    })
  }, [api, customerId])
  useEffect(() => { load() }, [load, reloadKey])
  useEffect(() => () => { seq.current.invalidate(); moreSeq.current.invalidate() }, [])

  function loadMore() {
    if (!more.next || more.loading) return
    const before = more.next
    runLatest(moreSeq.current, () => api.detail(customerId, { historyBefore: before, historyLimit: 20 }), {
      onStart: () => setMore((m) => ({ ...m, loading: true, error: null })),
      onResult: (d) => setMore((m) => ({ loading: false, items: [...m.items, ...(Array.isArray(d?.history) ? d.history : [])], next: d?.history_next_before ?? null, error: null })),
      onError: (e) => setMore((m) => ({ ...m, loading: false, error: customerErrorMessage(e, 'Não foi possível carregar mais.') })),
    })
  }

  const d = st.data
  const c = d?.customer
  const wa = c ? whatsappUrl(c.phone) : null
  const history = d ? [...(Array.isArray(d.history) ? d.history : []), ...more.items] : []
  const fin = d?.finance && typeof d.finance === 'object' ? d.finance : null

  return (
    <Sheet open onOpenChange={(o) => { if (!o) onClose() }}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-lg motion-reduce:animate-none motion-reduce:transition-none">
        <SheetHeader>
          <SheetTitle>{c?.name ?? 'Cliente'}</SheetTitle>
          <SheetDescription>{c ? `Cliente desde ${fmtDateTimeLong(c.created_at)}` : 'Ficha do cliente'}</SheetDescription>
        </SheetHeader>
        {st.loading && !d && <div className="mt-4 space-y-3" aria-busy="true">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-14 w-full" />)}</div>}
        {st.error && (
          <div className="mt-4 space-y-2 text-sm" role="alert">
            <p className="text-amber-500">{st.error}</p>
            <Button variant="outline" className="h-11 sm:h-9" onClick={load}>Tentar novamente</Button>
          </div>
        )}
        {c && (
          <div className="mt-4 space-y-6">
            <section aria-label="Cadastro" className="space-y-2 text-sm">
              <p className="flex items-center gap-2"><Phone className="h-4 w-4 text-muted-foreground" aria-hidden="true" />{c.phone ? formatBrPhone(c.phone) : 'Sem telefone'}</p>
              <p className="flex items-center gap-2"><Mail className="h-4 w-4 text-muted-foreground" aria-hidden="true" />{c.email || 'Sem e-mail'}</p>
              {c.arena && <p className="flex items-center gap-2"><MapPin className="h-4 w-4 text-muted-foreground" aria-hidden="true" />{c.arena.name}</p>}
              <div className="flex flex-wrap gap-2 pt-1">
                <Button variant="outline" className="h-11 sm:h-9" onClick={() => onEdit(c)}><Pencil className="mr-2 h-4 w-4" aria-hidden="true" />Editar cliente</Button>
                {wa && (
                  <Button asChild variant="outline" className="h-11 sm:h-9">
                    <a href={wa} target="_blank" rel="noopener noreferrer"><MessageCircle className="mr-2 h-4 w-4" aria-hidden="true" />WhatsApp</a>
                  </Button>
                )}
              </div>
            </section>

            <section aria-labelledby="cd-up" className="space-y-1">
              <h3 id="cd-up" className="flex items-center gap-2 text-sm font-semibold"><CalendarClock className="h-4 w-4" aria-hidden="true" />Próximas reservas</h3>
              {d.upcoming?.length ? <ul className="divide-y divide-border">{d.upcoming.map((r) => <ReservationRow key={r.id} r={r} />)}</ul>
                : <p className="text-sm text-muted-foreground">Nenhuma reserva futura.</p>}
            </section>

            <section aria-labelledby="cd-ser" className="space-y-1">
              <h3 id="cd-ser" className="flex items-center gap-2 text-sm font-semibold"><Repeat className="h-4 w-4" aria-hidden="true" />Mensalista</h3>
              {d.series?.length ? (
                <ul className="divide-y divide-border">
                  {d.series.map((s) => (
                    <li key={s.id} className="flex items-center justify-between gap-3 py-2 text-sm">
                      <span className="min-w-0">
                        <span className="block truncate">{seriesWhen(s)}</span>
                        <span className="block truncate text-xs text-muted-foreground">{s.court?.name ?? 'Quadra'} · {SERIES_STATUS[s.status] ?? s.status}</span>
                      </span>
                      <Button asChild variant="ghost" className="h-11 shrink-0 sm:h-8">
                        <Link href={`/dashboard/mensalistas?l=${encodeURIComponent(s.lineage_id ?? s.id)}`}>Ver em Mensalistas</Link>
                      </Button>
                    </li>
                  ))}
                </ul>
              ) : <p className="text-sm text-muted-foreground">Não é mensalista.</p>}
            </section>

            {fin && (
              <section aria-labelledby="cd-fin" className="space-y-2 rounded-lg border border-border p-3">
                <h3 id="cd-fin" className="flex items-center gap-2 text-sm font-semibold"><Wallet className="h-4 w-4" aria-hidden="true" />Financeiro das reservas vinculadas</h3>
                <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
                  <div><dt className="text-xs text-muted-foreground">Esperado nas reservas</dt><dd className="font-medium tabular-nums">{formatCents(fin.expected)}</dd></div>
                  <div><dt className="text-xs text-muted-foreground">Recebido nas reservas</dt><dd className="font-medium tabular-nums">{formatCents(fin.received)}</dd></div>
                  <div><dt className="text-xs text-muted-foreground">Em aberto</dt><dd className="font-medium tabular-nums">{formatCents(fin.open)}</dd></div>
                  <div><dt className="text-xs text-muted-foreground">Vencido</dt><dd className={`font-medium tabular-nums ${fin.overdue > 0 ? 'text-amber-500' : ''}`}>{formatCents(fin.overdue)}</dd></div>
                </dl>
                {fin.unpriced_count > 0 && <p className="text-xs text-muted-foreground">{fin.unpriced_count} reserva(s) sem valor definido não entram no esperado.</p>}
                <p className="text-xs text-muted-foreground">
                  Reservas vinculadas a este cliente nos últimos 12 meses e nos próximos 120 dias. Os valores são das reservas — não identificam quem pagou.
                </p>
              </section>
            )}

            <section aria-labelledby="cd-hist" className="space-y-1">
              <h3 id="cd-hist" className="flex items-center gap-2 text-sm font-semibold"><History className="h-4 w-4" aria-hidden="true" />Histórico</h3>
              {history.length ? <ul className="divide-y divide-border">{history.map((r) => <ReservationRow key={r.id} r={r} />)}</ul>
                : <p className="text-sm text-muted-foreground">Nenhuma reserva anterior.</p>}
              {more.error && <p className="text-xs text-amber-500" role="alert">{more.error}</p>}
              {more.next && (
                <Button variant="outline" className="mt-2 h-11 w-full sm:h-9" onClick={loadMore} disabled={more.loading}>
                  {more.loading && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Carregar mais
                </Button>
              )}
            </section>
          </div>
        )}
      </SheetContent>
    </Sheet>
  )
}
