'use client'

import { useEffect, useState, useCallback, useRef } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { createClient } from '@/lib/supabase/browser'
import { EmptyState } from '@/components/reserva/empty-state'
import { STATUS_META, RESERVATION_STATUSES, SOURCES, BLOCK_REASONS, statusMeta } from '@/lib/reserva/status'
import { buildSlots, overlaps, fmtTime, fmtDateLong, fmtDateTimeLong, todayStr, addDaysStr, weekdayOf, timeToMin, closeTimeToMin } from '@/lib/reserva/time'
import { isManagerOrAbove } from '@/lib/auth/permissions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { ChevronLeft, ChevronRight, Plus, Ban, CalendarDays, Loader2, Clock, Phone, User, Pencil, X, Repeat } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

export default function AgendaPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const canManageSeries = isManagerOrAbove(me?.role)
  const supabase = createClient()
  const [arenas, setArenas] = useState([])
  const [arenaId, setArenaId] = useState('')
  const [date, setDate] = useState(todayStr())
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [dlg, setDlg] = useState(null)
  const [blockDlg, setBlockDlg] = useState(null)
  const [detail, setDetail] = useState(null)
  const loadRef = useRef(null)
  const [view, setView] = useState('day')
  const [week, setWeek] = useState(null)
  const [weekLoading, setWeekLoading] = useState(false)
  const [weekCourt, setWeekCourt] = useState('')
  const reloadRef = useRef(() => {})

  useEffect(() => {
    if (!orgId) return
    fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json()).then((a) => {
      const list = Array.isArray(a) ? a : []
      setArenas(list); setArenaId((p) => p || list[0]?.id || '')
    })
  }, [orgId])

  const load = useCallback(async () => {
    if (!arenaId || !date) return
    setLoading(true)
    const r = await fetch(`/api/agenda?arena_id=${arenaId}&date=${date}`)
    const d = await r.json()
    setData(r.ok ? d : null)
    setLoading(false)
  }, [arenaId, date])
  loadRef.current = load
  useEffect(() => { load() }, [load])

  const mondayOf = (dateStr) => { const wd = weekdayOf(dateStr); return addDaysStr(dateStr, wd === 0 ? -6 : 1 - wd) }
  const loadWeek = useCallback(async () => {
    if (!arenaId || !date) return
    setWeekLoading(true)
    const start = mondayOf(date)
    const dates = Array.from({ length: 7 }, (_, i) => addDaysStr(start, i))
    const results = await Promise.all(dates.map((d) =>
      fetch(`/api/agenda?arena_id=${arenaId}&date=${d}`).then((r) => (r.ok ? r.json() : null)).then((j) => (j ? { ...j, date: d } : { date: d, courts: [], business_hours: null, reservations: [] }))
    ))
    setWeek({ start, days: results, step: results.find((r) => r.default_reservation_minutes)?.default_reservation_minutes || 60, courts: results.find((r) => r.courts?.length)?.courts || [] })
    setWeekLoading(false)
  }, [arenaId, date])
  useEffect(() => { if (view === 'week') loadWeek() }, [view, loadWeek])
  reloadRef.current = () => { if (view === 'week') loadWeek(); else load() }

  useEffect(() => {
    if (!orgId) return
    const ch = supabase.channel(`agenda-${orgId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'reservations', filter: `organization_id=eq.${orgId}` },
        () => { reloadRef.current && reloadRef.current() })
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [orgId, supabase])

  const courts = data?.courts || []
  const hours = data?.business_hours
  const step = data?.default_reservation_minutes || 60
  const slots = hours && !hours.closed ? buildSlots(hours.open_time, hours.close_time, step) : []
  const reservations = data?.reservations || []
  const findRes = (courtId, s) => reservations.find((r) => r.court_id === courtId && overlaps(r, s.startMin, s.endMin))

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h1 className="font-display text-2xl font-bold">Agenda</h1>
          <p className="mt-1 text-sm capitalize text-muted-foreground">{fmtDateLong(date)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex items-center rounded-lg border border-border p-0.5">
            <button onClick={() => setView('day')} className={cn('rounded-md px-3 py-1.5 text-sm font-medium transition-colors', view === 'day' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground')}>Dia</button>
            <button onClick={() => setView('week')} className={cn('rounded-md px-3 py-1.5 text-sm font-medium transition-colors', view === 'week' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground')}>Semana</button>
          </div>
          {arenas.length > 1 && (
            <Select value={arenaId} onValueChange={setArenaId}>
              <SelectTrigger className="w-44"><SelectValue /></SelectTrigger>
              <SelectContent>{arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent>
            </Select>
          )}
          <div className="flex items-center rounded-lg border border-border">
            <Button variant="ghost" size="icon" onClick={() => setDate(addDaysStr(date, -1))}><ChevronLeft className="h-4 w-4" /></Button>
            <Button variant="ghost" size="sm" onClick={() => setDate(todayStr())}>Hoje</Button>
            <Button variant="ghost" size="icon" onClick={() => setDate(addDaysStr(date, 1))}><ChevronRight className="h-4 w-4" /></Button>
          </div>
          <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} className="w-40" />
          <Button variant="outline" onClick={() => setBlockDlg({ court_id: courts[0]?.id || '', start: slots[0]?.start || '18:00', end: slots[0]?.end || '19:00' })} disabled={!courts.length}>
            <Ban className="mr-2 h-4 w-4" /> Bloquear horário
          </Button>
          <Button onClick={() => setDlg({ court_id: courts[0]?.id || '', start: slots[0]?.start || '18:00', end: slots[0]?.end || '19:00' })} disabled={!courts.length}>
            <Plus className="mr-2 h-4 w-4" /> Nova reserva
          </Button>
        </div>
      </div>

      {view === 'week' ? (
        <WeekView week={week} loading={weekLoading} weekCourt={weekCourt} setWeekCourt={setWeekCourt}
          onNew={(courtId, d, s) => setDlg({ court_id: courtId, date: d, start: s.start, end: s.end })} onOpen={setDetail} />
      ) : loading ? (
        <Skeleton className="h-[520px] w-full" />
      ) : !courts.length ? (
        <EmptyState icon={CalendarDays} title="Nenhuma quadra ativa" description="Cadastre e ative quadras para usar a agenda." />
      ) : !slots.length ? (
        <EmptyState icon={Clock} title="Arena fechada neste dia" description="Não há horário de funcionamento configurado para este dia." />
      ) : (
        <>
          <div className="hidden overflow-x-auto rounded-xl border border-border lg:block">
            <table className="w-full border-collapse">
              <thead>
                <tr className="bg-card">
                  <th className="sticky left-0 z-10 w-20 border-b border-r border-border bg-card p-3 text-left text-xs font-medium uppercase text-muted-foreground">Horário</th>
                  {courts.map((c) => (
                    <th key={c.id} className="min-w-[160px] border-b border-border p-3 text-left text-sm font-semibold">{c.name}<span className="ml-1 text-xs font-normal text-muted-foreground">{c.type}</span></th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {slots.map((s) => (
                  <tr key={s.start}>
                    <td className="sticky left-0 z-10 border-r border-t border-border bg-background p-3 text-xs font-medium text-muted-foreground">{s.start}</td>
                    {courts.map((c) => {
                      const res = findRes(c.id, s)
                      const m = res ? statusMeta(res.status) : STATUS_META.LIVRE
                      return (
                        <td key={c.id} className="border-t border-border p-1.5 align-top">
                          {res ? (
                            <button onClick={() => setDetail(res)} className={cn('w-full rounded-md border px-2 py-1.5 text-left text-xs transition-colors', m.cell)}>
                              <span className="flex items-center gap-1.5 font-medium"><span className={cn('h-1.5 w-1.5 rounded-full', m.dot)} />{m.label}{res.recurring_reservation_id && <Repeat className="h-3 w-3 opacity-80" />}</span>
                              <span className="mt-0.5 block truncate opacity-90">{res.status === 'BLOCKED' ? (res.notes || 'Bloqueio') : (res.customer?.name || 'Sem cliente')}</span>
                            </button>
                          ) : (
                            <button onClick={() => setDlg({ court_id: c.id, start: s.start, end: s.end })} className={cn('flex h-11 w-full items-center justify-center rounded-md border border-dashed border-transparent text-xs text-muted-foreground transition-colors', m.cell)}>
                              Livre
                            </button>
                          )}
                        </td>
                      )
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="lg:hidden">
            <MobileAgenda courts={courts} slots={slots} findRes={findRes} onNew={(courtId, s) => setDlg({ court_id: courtId, start: s.start, end: s.end })} onOpen={setDetail} />
          </div>
        </>
      )}

      {dlg && <ReservationDialog open={!!dlg} onClose={() => setDlg(null)} orgId={orgId} arenaId={arenaId} date={date} courts={view === 'week' ? (week?.courts || courts) : courts} initial={dlg} onSaved={() => reloadRef.current()} />}
      {blockDlg && <BlockDialog open={!!blockDlg} onClose={() => setBlockDlg(null)} orgId={orgId} arenaId={arenaId} date={date} courts={view === 'week' ? (week?.courts || courts) : courts} initial={blockDlg} onSaved={() => reloadRef.current()} />}
      {detail && <DetailSheet res={detail} canManageSeries={canManageSeries} courts={view === 'week' ? (week?.courts || courts) : courts} onClose={() => setDetail(null)} onChanged={() => reloadRef.current()} onEdit={(r) => { setDetail(null); setDlg({ edit: r, court_id: r.court_id, date: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(r.start_at)), start: fmtTime(r.start_at), end: fmtTime(r.end_at) }) }} />}
    </div>
  )
}

function MobileAgenda({ courts, slots, findRes, onNew, onOpen }) {
  const [court, setCourt] = useState(courts[0]?.id)
  useEffect(() => { if (courts.length && !courts.find((c) => c.id === court)) setCourt(courts[0]?.id) }, [courts, court])
  const c = courts.find((x) => x.id === court) || courts[0]
  return (
    <div className="space-y-3">
      <div className="flex gap-2 overflow-x-auto pb-1">
        {courts.map((x) => (
          <button key={x.id} onClick={() => setCourt(x.id)} className={cn('whitespace-nowrap rounded-full border px-3 py-1.5 text-sm', x.id === court ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground')}>{x.name}</button>
        ))}
      </div>
      <div className="space-y-2">
        {slots.map((s) => {
          const res = c ? findRes(c.id, s) : null
          const m = res ? statusMeta(res.status) : STATUS_META.LIVRE
          return (
            <div key={s.start} className="flex items-center gap-3">
              <span className="w-12 shrink-0 text-sm font-medium text-muted-foreground">{s.start}</span>
              {res ? (
                <button onClick={() => onOpen(res)} className={cn('flex-1 rounded-lg border px-3 py-2.5 text-left text-sm', m.cell)}>
                  <span className="flex items-center gap-2 font-medium"><span className={cn('h-2 w-2 rounded-full', m.dot)} />{m.label}{res.recurring_reservation_id && <Repeat className="h-3 w-3 opacity-80" />}</span>
                  <span className="mt-0.5 block text-xs opacity-90">{res.status === 'BLOCKED' ? (res.notes || 'Bloqueio') : (res.customer?.name || 'Sem cliente')}</span>
                </button>
              ) : (
                <button onClick={() => onNew(c.id, s)} className="flex-1 rounded-lg border border-dashed border-border px-3 py-2.5 text-left text-sm text-muted-foreground">Livre — toque para reservar</button>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function ReservationDialog({ open, onClose, orgId, arenaId, date, courts, initial, onSaved }) {
  const edit = initial.edit
  const [form, setForm] = useState({
    name: edit?.customer?.name || '', phone: edit?.customer?.phone || '', email: '',
    court_id: initial.court_id, date: initial.date || date, start: initial.start, end: initial.end,
    status: edit?.status || 'CONFIRMED', source: edit?.source || 'RECEPÇÃO', notes: edit?.notes || '',
  })
  const [saving, setSaving] = useState(false)
  const [suggest, setSuggest] = useState([])
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onPhone(v) {
    setForm((f) => ({ ...f, phone: v }))
    if (v.replace(/\D/g, '').length >= 4) {
      const r = await fetch(`/api/customers?organization_id=${orgId}&phone=${encodeURIComponent(v)}`)
      setSuggest(r.ok ? await r.json() : [])
    } else setSuggest([])
  }

  async function save() {
    if (!form.court_id) { toast.error('Selecione a quadra'); return }
    if (!edit && !form.name.trim()) { toast.error('Informe o cliente'); return }
    setSaving(true)
    const payload = {
      organization_id: orgId, arena_id: arenaId, court_id: form.court_id,
      date: form.date, start_time: form.start, end_time: form.end,
      status: form.status, source: form.source, notes: form.notes,
      customer: { name: form.name, phone: form.phone, email: form.email },
    }
    const res = edit
      ? await fetch(`/api/reservations/${edit.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
      : await fetch('/api/reservations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
    setSaving(false)
    if (res.status === 409) { toast.error('Horário indisponível', { description: 'Este horário acabou de ficar indisponível. Escolha outro horário.' }); onSaved(); return }
    if (!res.ok) { const e = await res.json().catch(() => ({})); toast.error('Não foi possível salvar', { description: e.error }); return }
    toast.success(edit ? 'Reserva atualizada' : 'Reserva criada')
    onClose(); onSaved()
  }

  return (
    <Dialog open={open} onOpenChange={onClose}>
      <DialogContent className="max-h-[92vh] overflow-y-auto">
        <DialogHeader><DialogTitle>{edit ? 'Editar reserva' : 'Nova reserva'}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5"><Label>Cliente</Label><Input value={form.name} onChange={set('name')} placeholder="Nome do cliente" /></div>
          <div className="grid grid-cols-2 gap-3">
            <div className="relative space-y-1.5">
              <Label>Telefone</Label>
              <Input value={form.phone} onChange={(e) => onPhone(e.target.value)} placeholder="(11) 90000-0000" />
              {suggest.length > 0 && (
                <div className="absolute z-20 mt-1 w-full rounded-md border border-border bg-popover shadow">
                  {suggest.slice(0, 5).map((c) => (
                    <button key={c.id} type="button" onClick={() => { setForm((f) => ({ ...f, name: c.name, phone: c.phone || '' })); setSuggest([]) }} className="block w-full px-3 py-2 text-left text-sm hover:bg-accent">{c.name} <span className="text-muted-foreground">{c.phone}</span></button>
                  ))}
                </div>
              )}
            </div>
            <div className="space-y-1.5"><Label>E-mail (opcional)</Label><Input value={form.email} onChange={set('email')} placeholder="cliente@email.com" /></div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Quadra</Label>
              <Select value={form.court_id} onValueChange={(v) => setForm((f) => ({ ...f, court_id: v }))}>
                <SelectTrigger><SelectValue placeholder="Quadra" /></SelectTrigger>
                <SelectContent>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5"><Label>Data</Label><Input type="date" value={form.date} onChange={set('date')} /></div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={form.start} onChange={set('start')} /></div>
            <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={form.end} onChange={set('end')} /></div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Status</Label>
              <Select value={form.status} onValueChange={(v) => setForm((f) => ({ ...f, status: v }))}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{RESERVATION_STATUSES.map((s) => <SelectItem key={s} value={s}>{STATUS_META[s].label}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label>Origem</Label>
              <Select value={form.source} onValueChange={(v) => setForm((f) => ({ ...f, source: v }))}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{SOURCES.map((s) => <SelectItem key={s} value={s}>{s}</SelectItem>)}</SelectContent>
              </Select>
            </div>
          </div>
          <div className="space-y-1.5"><Label>Observação</Label><Textarea value={form.notes} onChange={set('notes')} rows={2} placeholder="Opcional" /></div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function BlockDialog({ open, onClose, orgId, arenaId, date, courts, initial, onSaved }) {
  const [form, setForm] = useState({ court_id: initial.court_id, date, start: initial.start, end: initial.end, reason: 'Manutenção' })
  const [saving, setSaving] = useState(false)
  async function save() {
    setSaving(true)
    const res = await fetch('/api/reservations/block', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ organization_id: orgId, arena_id: arenaId, court_id: form.court_id, date: form.date, start_time: form.start, end_time: form.end, reason: form.reason }) })
    setSaving(false)
    if (res.status === 409) { toast.error('Horário indisponível', { description: 'Este horário acabou de ficar indisponível. Escolha outro horário.' }); onSaved(); return }
    if (!res.ok) { toast.error('Não foi possível bloquear'); return }
    toast.success('Horário bloqueado'); onClose(); onSaved()
  }
  return (
    <Dialog open={open} onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>Bloquear horário</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label>Quadra</Label>
            <Select value={form.court_id} onValueChange={(v) => setForm((f) => ({ ...f, court_id: v }))}>
              <SelectTrigger><SelectValue placeholder="Quadra" /></SelectTrigger>
              <SelectContent>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent>
            </Select>
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-1.5"><Label>Data</Label><Input type="date" value={form.date} onChange={(e) => setForm((f) => ({ ...f, date: e.target.value }))} /></div>
            <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={form.start} onChange={(e) => setForm((f) => ({ ...f, start: e.target.value }))} /></div>
            <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={form.end} onChange={(e) => setForm((f) => ({ ...f, end: e.target.value }))} /></div>
          </div>
          <div className="space-y-1.5">
            <Label>Motivo</Label>
            <Select value={form.reason} onValueChange={(v) => setForm((f) => ({ ...f, reason: v }))}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{BLOCK_REASONS.map((r) => <SelectItem key={r} value={r}>{r}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Bloquear</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function DetailSheet({ res, courts, canManageSeries, onClose, onEdit, onChanged }) {
  const m = statusMeta(res.status)
  const [cancelling, setCancelling] = useState(false)
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState(false)
  const [reschedule, setReschedule] = useState(false)
  const isRecurring = !!res.recurring_reservation_id
  async function doCancel() {
    setCancelling(true)
    const r = await fetch(`/api/reservations/${res.id}/cancel`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ reason }) })
    setCancelling(false)
    if (!r.ok) { toast.error('Não foi possível cancelar'); return }
    toast.success(isRecurring ? 'Data cancelada (a série continua)' : 'Reserva cancelada'); onClose(); onChanged()
  }
  const Row = ({ icon: Icon, label, value }) => (
    <div className="flex items-start gap-3 py-2"><Icon className="mt-0.5 h-4 w-4 text-muted-foreground" /><div><p className="text-xs text-muted-foreground">{label}</p><p className="text-sm">{value || '—'}</p></div></div>
  )
  return (
    <Sheet open onOpenChange={onClose}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader><SheetTitle className="flex items-center gap-2">Detalhes da reserva <Badge className={cn('border', m.badge)}>{m.label}</Badge>{isRecurring && <Badge variant="outline" className="gap-1"><Repeat className="h-3 w-3" /> Recorrente</Badge>}</SheetTitle></SheetHeader>
        {isRecurring && <p className="mt-3 rounded-lg border border-border bg-muted/40 px-3 py-2 text-xs text-muted-foreground">Esta reserva faz parte de uma recorrência (mensalista).</p>}
        <div className="mt-4 divide-y divide-border">
          {res.status !== 'BLOCKED' && <Row icon={User} label="Cliente" value={res.customer?.name} />}
          {res.status !== 'BLOCKED' && <Row icon={Phone} label="Telefone" value={res.customer?.phone} />}
          <Row icon={CalendarDays} label="Quadra" value={res.court?.name} />
          <Row icon={Clock} label="Horário" value={`${fmtTime(res.start_at)} — ${fmtTime(res.end_at)}`} />
          <Row icon={CalendarDays} label="Data" value={fmtDateTimeLong(res.start_at)} />
          <Row icon={User} label="Origem" value={res.source} />
          <Row icon={Pencil} label="Observações" value={res.notes} />
          <Row icon={Clock} label="Criada em" value={fmtDateTimeLong(res.created_at)} />
        </div>
        {res.status !== 'CANCELLED' && (
          <div className="mt-5 space-y-3">
            {res.status !== 'BLOCKED' && !isRecurring && <Button variant="outline" className="w-full" onClick={() => onEdit(res)}><Pencil className="mr-2 h-4 w-4" /> Editar</Button>}
            {res.status !== 'BLOCKED' && isRecurring && (
              <div className="space-y-2">
                <p className="text-xs font-medium text-muted-foreground">Editar</p>
                <div className="grid grid-cols-1 gap-2">
                  <Button variant="outline" className="w-full justify-start" onClick={() => onEdit(res)}><Pencil className="mr-2 h-4 w-4" /> Apenas esta reserva</Button>
                  {canManageSeries && <Button variant="outline" className="w-full justify-start" onClick={() => setReschedule(true)}><Repeat className="mr-2 h-4 w-4" /> Esta e as próximas</Button>}
                </div>
              </div>
            )}
            {!confirm ? (
              <Button variant="destructive" className="w-full" onClick={() => setConfirm(true)}><X className="mr-2 h-4 w-4" /> {isRecurring ? 'Cancelar apenas esta data' : 'Cancelar reserva'}</Button>
            ) : (
              <div className="space-y-2 rounded-lg border border-destructive/30 bg-destructive/5 p-3">
                <Label className="text-xs">Motivo (opcional)</Label>
                <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motivo do cancelamento" />
                <div className="flex gap-2">
                  <Button variant="ghost" size="sm" className="flex-1" onClick={() => setConfirm(false)}>Voltar</Button>
                  <Button variant="destructive" size="sm" className="flex-1" onClick={doCancel} disabled={cancelling}>{cancelling && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirmar</Button>
                </div>
              </div>
            )}
          </div>
        )}
      </SheetContent>
      {reschedule && canManageSeries && <RescheduleDialog res={res} courts={courts} onClose={() => setReschedule(false)} onDone={() => { setReschedule(false); onClose(); onChanged() }} />}
    </Sheet>
  )
}

const WD = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
function RescheduleDialog({ res, courts, onClose, onDone }) {
  const fromDate = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date(res.start_at))
  const [series, setSeries] = useState(null)
  const [f, setF] = useState(null)
  const [busy, setBusy] = useState(false)
  const [conflicts, setConflicts] = useState(null)
  useEffect(() => {
    fetch(`/api/recurring-reservations/${res.recurring_reservation_id}`).then((r) => r.json()).then((s) => {
      setSeries(s)
      setF({ court_id: res.court_id, weekday: String(s.weekday ?? weekdayOf(fromDate)), day_of_month: String(s.day_of_month || 10), start_time: fmtTime(res.start_at), end_time: fmtTime(res.end_at) })
    }).catch(() => {})
  }, [])
  if (!f || !series) return null
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }))
  const payload = (extra) => ({ from_date: fromDate, court_id: f.court_id, start_time: f.start_time, end_time: f.end_time, weekday: series.frequency === 'MONTHLY' ? null : Number(f.weekday), day_of_month: series.frequency === 'MONTHLY' ? Number(f.day_of_month) : null, ...extra })
  async function apply(skip) {
    setBusy(true)
    const r = await fetch(`/api/recurring-reservations/${res.recurring_reservation_id}/reschedule`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload({ skip_conflicts: skip })) })
    const d = await r.json().catch(() => ({}))
    setBusy(false)
    if (r.status === 409) { setConflicts(d.conflicts || []); return }
    if (!r.ok) { toast.error(d.error || 'Não foi possível reagendar'); return }
    toast.success(`Série atualizada a partir de ${fromDate} — ${d.created} reserva(s)`); onDone()
  }
  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader><DialogTitle>Editar esta e as próximas</DialogTitle></DialogHeader>
        <p className="text-sm text-muted-foreground">As reservas anteriores a {fromDate} permanecem intactas. As futuras serão recalculadas com as novas informações.</p>
        <div className="mt-4 space-y-4">
          <div className="space-y-1.5"><Label>Quadra</Label>
            <Select value={f.court_id} onValueChange={(v) => set('court_id', v)}><SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent></Select>
          </div>
          {series.frequency === 'MONTHLY' ? (
            <div className="space-y-1.5"><Label>Dia do mês</Label><Input type="number" min="1" max="31" value={f.day_of_month} onChange={(e) => set('day_of_month', e.target.value)} /></div>
          ) : (
            <div className="space-y-1.5"><Label>Dia da semana</Label>
              <Select value={f.weekday} onValueChange={(v) => set('weekday', v)}><SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{WD.map((w, i) => <SelectItem key={i} value={String(i)}>{w}</SelectItem>)}</SelectContent></Select>
            </div>
          )}
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={f.start_time} onChange={(e) => set('start_time', e.target.value)} /></div>
            <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={f.end_time} onChange={(e) => set('end_time', e.target.value)} /></div>
          </div>
          {conflicts && (
            <div className="rounded-lg border border-amber-500/30 bg-amber-500/[0.06] p-3 text-sm">
              <p className="font-medium text-amber-500">{conflicts.length} data(s) com conflito</p>
              <ul className="mt-1 max-h-32 space-y-1 overflow-y-auto text-muted-foreground">{conflicts.map((c, i) => <li key={i}>{c.date} — {c.reason}</li>)}</ul>
            </div>
          )}
        </div>
        <DialogFooter className="mt-4 flex-col gap-2 sm:flex-row">
          <Button variant="outline" onClick={onClose}>Cancelar</Button>
          {conflicts ? (
            <Button onClick={() => apply(true)} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Aplicar ignorando conflitos</Button>
          ) : (
            <Button onClick={() => apply(false)} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Aplicar</Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function WeekView({ week, loading, weekCourt, setWeekCourt, onNew, onOpen }) {
  if (loading || !week) return <Skeleton className="h-[520px] w-full" />
  const courts = week.courts || []
  if (!courts.length) return <EmptyState icon={CalendarDays} title="Nenhuma quadra ativa" description="Cadastre e ative quadras para usar a agenda." />
  const active = (weekCourt && courts.find((c) => c.id === weekCourt)) ? weekCourt : courts[0].id
  const days = week.days || []
  const hhmm = (min) => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`
  let minO = Infinity, maxC = -Infinity
  for (const d of days) { const bh = d.business_hours; if (bh && !bh.closed) { minO = Math.min(minO, timeToMin(bh.open_time)); maxC = Math.max(maxC, closeTimeToMin(bh.close_time)) } }
  const slots = maxC > minO ? buildSlots(hhmm(minO), hhmm(maxC), week.step) : []
  const wlabel = (ds) => new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', weekday: 'short' }).format(new Date(`${ds}T12:00:00-03:00`)).replace('.', '')
  const cellFor = (d, s) => {
    const bh = d.business_hours
    const open = bh && !bh.closed && s.startMin >= timeToMin(bh.open_time) && s.endMin <= closeTimeToMin(bh.close_time)
    if (!open) return { closed: true }
    const res = (d.reservations || []).find((r) => r.court_id === active && overlaps(r, s.startMin, s.endMin))
    return { res }
  }
  const CourtPicker = courts.length > 1 ? (
    <div className="flex gap-2 overflow-x-auto pb-1">
      {courts.map((c) => (
        <button key={c.id} onClick={() => setWeekCourt(c.id)} className={cn('whitespace-nowrap rounded-full border px-3 py-1.5 text-sm', c.id === active ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground')}>{c.name}</button>
      ))}
    </div>
  ) : null

  if (!slots.length) return (<div className="space-y-3">{CourtPicker}<EmptyState icon={Clock} title="Arena fechada nesta semana" description="Nenhum horário de funcionamento configurado." /></div>)

  return (
    <div className="space-y-3">
      {CourtPicker}
      <div className="hidden overflow-x-auto rounded-xl border border-border lg:block">
        <table className="w-full border-collapse">
          <thead><tr className="bg-card">
            <th className="sticky left-0 z-10 w-16 border-b border-r border-border bg-card p-2 text-left text-xs font-medium uppercase text-muted-foreground">Hora</th>
            {days.map((d) => (
              <th key={d.date} className="min-w-[120px] border-b border-border p-2 text-center text-xs font-semibold capitalize">{wlabel(d.date)}<span className="ml-1 font-normal text-muted-foreground">{d.date.slice(8, 10)}</span></th>
            ))}
          </tr></thead>
          <tbody>
            {slots.map((s) => (
              <tr key={s.start}>
                <td className="sticky left-0 z-10 border-r border-t border-border bg-background p-2 text-xs font-medium text-muted-foreground">{s.start}</td>
                {days.map((d) => {
                  const { closed, res } = cellFor(d, s)
                  const m = res ? statusMeta(res.status) : STATUS_META.LIVRE
                  return (
                    <td key={d.date} className="border-t border-border p-1 align-top">
                      {closed ? (
                        <div className="flex h-9 items-center justify-center rounded-md bg-muted/30 text-[10px] text-muted-foreground">—</div>
                      ) : res ? (
                        <button onClick={() => onOpen(res)} className={cn('h-9 w-full truncate rounded-md border px-1.5 text-left text-[11px]', m.cell)}>
                          <span className="flex items-center gap-1 font-medium"><span className={cn('h-1.5 w-1.5 rounded-full', m.dot)} />{m.label}{res.recurring_reservation_id && <Repeat className="h-2.5 w-2.5 opacity-80" />}</span>
                        </button>
                      ) : (
                        <button onClick={() => onNew(active, d.date, s)} className="h-9 w-full rounded-md border border-dashed border-transparent text-[11px] text-muted-foreground hover:border-primary/40 hover:bg-primary/5">Livre</button>
                      )}
                    </td>
                  )
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="lg:hidden"><WeekMobile days={days} slots={slots} active={active} cellFor={cellFor} wlabel={wlabel} onNew={onNew} onOpen={onOpen} /></div>
    </div>
  )
}

function WeekMobile({ days, slots, active, cellFor, wlabel, onNew, onOpen }) {
  const [idx, setIdx] = useState(0)
  const d = days[idx] || days[0]
  return (
    <div className="space-y-3">
      <div className="flex gap-2 overflow-x-auto pb-1">
        {days.map((x, i) => (
          <button key={x.date} onClick={() => setIdx(i)} className={cn('flex flex-col items-center whitespace-nowrap rounded-lg border px-3 py-1.5 text-xs', i === idx ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground')}>
            <span className="capitalize">{wlabel(x.date)}</span><span className="font-semibold">{x.date.slice(8, 10)}</span>
          </button>
        ))}
      </div>
      <div className="space-y-2">
        {slots.map((s) => {
          const { closed, res } = cellFor(d, s)
          const m = res ? statusMeta(res.status) : STATUS_META.LIVRE
          return (
            <div key={s.start} className="flex items-center gap-3">
              <span className="w-12 shrink-0 text-sm font-medium text-muted-foreground">{s.start}</span>
              {closed ? (
                <div className="flex-1 rounded-lg border border-border/60 bg-muted/20 px-3 py-2.5 text-sm text-muted-foreground">Fechado</div>
              ) : res ? (
                <button onClick={() => onOpen(res)} className={cn('flex-1 rounded-lg border px-3 py-2.5 text-left text-sm', m.cell)}>
                  <span className="flex items-center gap-2 font-medium"><span className={cn('h-2 w-2 rounded-full', m.dot)} />{m.label}{res.recurring_reservation_id && <Repeat className="h-3 w-3 opacity-80" />}</span>
                  <span className="mt-0.5 block text-xs opacity-90">{res.status === 'BLOCKED' ? (res.notes || 'Bloqueio') : (res.customer?.name || 'Sem cliente')}</span>
                </button>
              ) : (
                <button onClick={() => onNew(active, d.date, s)} className="flex-1 rounded-lg border border-dashed border-border px-3 py-2.5 text-left text-sm text-muted-foreground">Livre — toque para reservar</button>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
