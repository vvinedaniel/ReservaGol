'use client'

import { useEffect, useState, useCallback } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { EmptyState } from '@/components/reserva/empty-state'
import { statusMeta, STATUS_META, RESERVATION_STATUSES, SOURCES } from '@/lib/reserva/status'
import { fmtTime, fmtDateTimeLong } from '@/lib/reserva/time'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Card, CardContent } from '@/components/ui/card'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Search, ClipboardList, Loader2, X } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

const TABS = [{ k: 'today', l: 'Hoje' }, { k: 'upcoming', l: 'Próximas' }, { k: 'past', l: 'Anteriores' }, { k: 'cancelled', l: 'Canceladas' }]

export default function ReservasPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const [scope, setScope] = useState('today')
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [q, setQ] = useState('')
  const [courts, setCourts] = useState([])
  const [f, setF] = useState({ court_id: '', status: '', source: '', date_from: '', date_to: '' })
  const [detail, setDetail] = useState(null)

  useEffect(() => { if (orgId) fetch(`/api/courts?organization_id=${orgId}`).then((r) => r.json()).then((c) => setCourts(Array.isArray(c) ? c : [])) }, [orgId])

  const load = useCallback(async () => {
    if (!orgId) return
    setLoading(true)
    const p = new URLSearchParams({ organization_id: orgId, scope })
    if (q) p.set('q', q)
    if (f.court_id) p.set('court_id', f.court_id)
    if (f.status) p.set('status', f.status)
    if (f.source) p.set('source', f.source)
    if (f.date_from) p.set('date_from', f.date_from)
    if (f.date_to) p.set('date_to', f.date_to)
    const r = await fetch(`/api/reservations?${p.toString()}`)
    setRows(r.ok ? await r.json() : [])
    setLoading(false)
  }, [orgId, scope, q, f])
  useEffect(() => { const t = setTimeout(load, 250); return () => clearTimeout(t) }, [load])

  return (
    <div className="space-y-5">
      <div>
        <h1 className="font-display text-2xl font-bold">Reservas</h1>
        <p className="mt-1 text-sm text-muted-foreground">Todas as reservas da sua arena.</p>
      </div>

      <div className="flex flex-wrap gap-2">
        {TABS.map((t) => (
          <button key={t.k} onClick={() => setScope(t.k)} className={cn('rounded-lg border px-3 py-1.5 text-sm font-medium', scope === t.k ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground hover:text-foreground')}>{t.l}</button>
        ))}
      </div>

      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
        <div className="relative lg:col-span-2">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar cliente ou telefone" className="pl-9" />
        </div>
        <Select value={f.court_id || 'all'} onValueChange={(v) => setF((s) => ({ ...s, court_id: v === 'all' ? '' : v }))}>
          <SelectTrigger><SelectValue placeholder="Quadra" /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todas as quadras</SelectItem>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent>
        </Select>
        <Select value={f.status || 'all'} onValueChange={(v) => setF((s) => ({ ...s, status: v === 'all' ? '' : v }))}>
          <SelectTrigger><SelectValue placeholder="Status" /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todos os status</SelectItem>{RESERVATION_STATUSES.map((s) => <SelectItem key={s} value={s}>{STATUS_META[s].label}</SelectItem>)}</SelectContent>
        </Select>
        <Input type="date" value={f.date_from} onChange={(e) => setF((s) => ({ ...s, date_from: e.target.value }))} />
        <Input type="date" value={f.date_to} onChange={(e) => setF((s) => ({ ...s, date_to: e.target.value }))} />
      </div>

      {loading ? (
        <Skeleton className="h-80 w-full" />
      ) : rows.length === 0 ? (
        <EmptyState icon={ClipboardList} title="Nenhuma reserva encontrada" description="Ajuste os filtros ou crie reservas pela Agenda." />
      ) : (
        <>
          <div className="hidden overflow-hidden rounded-xl border border-border lg:block">
            <table className="w-full text-sm">
              <thead className="bg-card text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="p-3 text-left">Horário</th><th className="p-3 text-left">Cliente</th><th className="p-3 text-left">Telefone</th>
                  <th className="p-3 text-left">Quadra</th><th className="p-3 text-left">Origem</th><th className="p-3 text-left">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const m = statusMeta(r.status)
                  return (
                    <tr key={r.id} onClick={() => setDetail(r)} className="cursor-pointer border-t border-border hover:bg-accent/50">
                      <td className="p-3"><div className="font-medium">{fmtTime(r.start_at)}–{fmtTime(r.end_at)}</div><div className="text-xs text-muted-foreground">{fmtDateTimeLong(r.start_at).split(' ')[0]}</div></td>
                      <td className="p-3">{r.status === 'BLOCKED' ? <span className="text-muted-foreground">{r.notes || 'Bloqueio'}</span> : (r.customer?.name || '—')}</td>
                      <td className="p-3 text-muted-foreground">{r.customer?.phone || '—'}</td>
                      <td className="p-3">{r.court?.name || '—'}</td>
                      <td className="p-3 text-muted-foreground">{r.source || '—'}</td>
                      <td className="p-3"><Badge className={cn('border', m.badge)}>{m.label}</Badge></td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          <div className="space-y-2 lg:hidden">
            {rows.map((r) => {
              const m = statusMeta(r.status)
              return (
                <Card key={r.id} onClick={() => setDetail(r)} className="cursor-pointer">
                  <CardContent className="flex items-center justify-between p-4">
                    <div>
                      <p className="font-medium">{fmtTime(r.start_at)}–{fmtTime(r.end_at)} · {r.court?.name}</p>
                      <p className="text-sm text-muted-foreground">{r.status === 'BLOCKED' ? (r.notes || 'Bloqueio') : (r.customer?.name || '—')}</p>
                    </div>
                    <Badge className={cn('border', m.badge)}>{m.label}</Badge>
                  </CardContent>
                </Card>
              )
            })}
          </div>
        </>
      )}

      {detail && <DetailSheet res={detail} onClose={() => setDetail(null)} onChanged={load} />}
    </div>
  )
}

function DetailSheet({ res, onClose, onChanged }) {
  const m = statusMeta(res.status)
  const [cancelling, setCancelling] = useState(false)
  async function doCancel() {
    setCancelling(true)
    const r = await fetch(`/api/reservations/${res.id}/cancel`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) })
    setCancelling(false)
    if (!r.ok) { toast.error('Não foi possível cancelar'); return }
    toast.success('Reserva cancelada'); onClose(); onChanged()
  }
  const Row = ({ label, value }) => (<div className="py-2"><p className="text-xs text-muted-foreground">{label}</p><p className="text-sm">{value || '—'}</p></div>)
  return (
    <Sheet open onOpenChange={onClose}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader><SheetTitle className="flex items-center gap-2">Detalhes <Badge className={cn('border', m.badge)}>{m.label}</Badge></SheetTitle></SheetHeader>
        <div className="mt-4 divide-y divide-border">
          {res.status !== 'BLOCKED' && <Row label="Cliente" value={res.customer?.name} />}
          {res.status !== 'BLOCKED' && <Row label="Telefone" value={res.customer?.phone} />}
          <Row label="Quadra" value={res.court?.name} />
          <Row label="Arena" value={res.arena?.name} />
          <Row label="Horário" value={`${fmtTime(res.start_at)} — ${fmtTime(res.end_at)}`} />
          <Row label="Data" value={fmtDateTimeLong(res.start_at)} />
          <Row label="Origem" value={res.source} />
          <Row label="Observações" value={res.notes} />
        </div>
        {res.status !== 'CANCELLED' && (
          <Button variant="destructive" className="mt-5 w-full" onClick={doCancel} disabled={cancelling}>{cancelling && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}<X className="mr-2 h-4 w-4" /> Cancelar reserva</Button>
        )}
      </SheetContent>
    </Sheet>
  )
}
