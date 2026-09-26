'use client'

import { useEffect, useState, useCallback, useRef } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { isManagerOrAbove } from '@/lib/auth/permissions'
import { fmtDateTimeLong } from '@/lib/reserva/time'
import { newOperationId } from '@/lib/reserva/operation-id'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Card, CardContent } from '@/components/ui/card'
import { Textarea } from '@/components/ui/textarea'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Repeat, Plus, Loader2, Search, Clock, MapPin, User, CalendarClock, AlertTriangle, CheckCircle2, Pause, Play, X, Ban, RefreshCw, ChevronRight } from 'lucide-react'
import { toast } from 'sonner'

const WEEKDAYS = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
const FREQ_LABEL = { WEEKLY: 'Semanal', BIWEEKLY: 'Quinzenal', MONTHLY: 'Mensal' }
const STATUS_META = { ACTIVE: { l: 'Ativo', c: 'bg-primary/15 text-primary' }, PAUSED: { l: 'Pausado', c: 'bg-amber-500/15 text-amber-500' }, CANCELLED: { l: 'Cancelado', c: 'bg-muted text-muted-foreground' } }
const TABS = [{ k: 'ACTIVE', l: 'Ativos' }, { k: 'PAUSED', l: 'Pausados' }, { k: 'CANCELLED', l: 'Cancelados' }]

const centsToBRL = (c) => (c == null ? null : (c / 100).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
const brlToCents = (v) => { const n = parseFloat(String(v).replace(/\./g, '').replace(',', '.')); return isNaN(n) ? null : Math.round(n * 100) }

export default function MensalistasPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const canManage = isManagerOrAbove(me?.role)
  const [arena, setArena] = useState(null)
  const [courts, setCourts] = useState([])
  const [status, setStatus] = useState('ACTIVE')
  const [q, setQ] = useState('')
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [openCreate, setOpenCreate] = useState(false)
  const [detailId, setDetailId] = useState(null)

  useEffect(() => {
    if (!orgId) return
    ;(async () => {
      const arenas = await fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json()).catch(() => [])
      const a = Array.isArray(arenas) ? arenas[0] : null
      setArena(a)
      if (a) { const c = await fetch(`/api/courts?arena_id=${a.id}`).then((r) => r.json()).catch(() => []); setCourts((Array.isArray(c) ? c : []).filter((x) => x.active)) }
    })()
  }, [orgId])

  const load = useCallback(async () => {
    if (!orgId) return
    setLoading(true)
    const p = new URLSearchParams({ organization_id: orgId, status })
    if (q) p.set('q', q)
    const r = await fetch(`/api/recurring-reservations?${p.toString()}`)
    setRows(r.ok ? await r.json() : [])
    setLoading(false)
  }, [orgId, status, q])

  useEffect(() => { const t = setTimeout(load, 250); return () => clearTimeout(t) }, [load])

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-display text-2xl font-bold">Mensalistas</h1>
          <p className="mt-1 text-sm text-muted-foreground">Reservas recorrentes — configure uma vez e o Reserva Gol cuida das próximas datas.</p>
        </div>
        {canManage && <Button onClick={() => setOpenCreate(true)} disabled={!arena || courts.length === 0}><Plus className="mr-2 h-4 w-4" /> Novo mensalista</Button>}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-lg border border-border bg-card p-1">
          {TABS.map((t) => (
            <button key={t.k} onClick={() => setStatus(t.k)} className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${status === t.k ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'}`}>{t.l}</button>
          ))}
        </div>
        <div className="relative min-w-[220px] flex-1">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar por nome ou telefone" className="pl-9" />
        </div>
      </div>

      {loading ? (
        <div className="space-y-3">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16 w-full" />)}</div>
      ) : rows.length === 0 ? (
        <Card><CardContent className="flex flex-col items-center py-14 text-center">
          <Repeat className="h-10 w-10 text-muted-foreground" />
          <p className="mt-3 font-medium">Nenhum mensalista {status === 'ACTIVE' ? 'ativo' : status === 'PAUSED' ? 'pausado' : 'cancelado'}</p>
          {canManage && status === 'ACTIVE' && <p className="text-sm text-muted-foreground">Clique em “Novo mensalista” para começar.</p>}
        </CardContent></Card>
      ) : (
        <>
          {/* Desktop */}
          <div className="hidden overflow-hidden rounded-xl border border-border md:block">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 text-left text-xs uppercase text-muted-foreground">
                <tr><th className="px-4 py-3">Cliente</th><th className="px-4 py-3">Quadra</th><th className="px-4 py-3">Quando</th><th className="px-4 py-3">Frequência</th><th className="px-4 py-3">Próxima</th><th className="px-4 py-3">Preço</th><th className="px-4 py-3">Status</th><th /></tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} onClick={() => setDetailId(r.id)} className="cursor-pointer border-t border-border hover:bg-muted/30">
                    <td className="px-4 py-3 font-medium">{r.customer?.name || '—'}<div className="text-xs text-muted-foreground">{r.customer?.phone || ''}</div></td>
                    <td className="px-4 py-3">{r.court?.name || '—'}</td>
                    <td className="px-4 py-3">{whenLabel(r)}</td>
                    <td className="px-4 py-3">{FREQ_LABEL[r.frequency]}</td>
                    <td className="px-4 py-3">{r.next_occurrence ? fmtDateTimeLong(r.next_occurrence) : '—'}</td>
                    <td className="px-4 py-3">{centsToBRL(r.default_price) || '—'}</td>
                    <td className="px-4 py-3"><span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_META[r.status].c}`}>{STATUS_META[r.status].l}</span></td>
                    <td className="px-4 py-3 text-muted-foreground"><ChevronRight className="h-4 w-4" /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {/* Mobile */}
          <div className="space-y-3 md:hidden">
            {rows.map((r) => (
              <Card key={r.id} onClick={() => setDetailId(r.id)} className="cursor-pointer">
                <CardContent className="p-4">
                  <div className="flex items-center justify-between">
                    <p className="font-medium">{r.customer?.name || '—'}</p>
                    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_META[r.status].c}`}>{STATUS_META[r.status].l}</span>
                  </div>
                  <div className="mt-2 space-y-1 text-sm text-muted-foreground">
                    <p className="flex items-center gap-1.5"><MapPin className="h-3.5 w-3.5" /> {r.court?.name}</p>
                    <p className="flex items-center gap-1.5"><Clock className="h-3.5 w-3.5" /> {whenLabel(r)} · {FREQ_LABEL[r.frequency]}</p>
                    {r.next_occurrence && <p className="flex items-center gap-1.5"><CalendarClock className="h-3.5 w-3.5" /> Próxima: {fmtDateTimeLong(r.next_occurrence)}</p>}
                    {r.default_price != null && <p>{centsToBRL(r.default_price)} por jogo</p>}
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        </>
      )}

      {openCreate && arena && <CreateDialog orgId={orgId} arena={arena} courts={courts} onClose={() => setOpenCreate(false)} onCreated={() => { setOpenCreate(false); load() }} />}
      {detailId && <DetailSheet id={detailId} canManage={canManage} courts={courts} onClose={() => setDetailId(null)} onChanged={load} />}
    </div>
  )
}

function whenLabel(r) {
  if (r.frequency === 'MONTHLY') return `Dia ${r.day_of_month} · ${(r.start_time || '').slice(0, 5)}–${(r.end_time || '').slice(0, 5)}`
  return `${WEEKDAYS[r.weekday]} · ${(r.start_time || '').slice(0, 5)}–${(r.end_time || '').slice(0, 5)}`
}

// -------------------------------------------------- Create
function CreateDialog({ orgId, arena, courts, onClose, onCreated }) {
  const todayStr = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  const [f, setF] = useState({ court_id: courts[0]?.id || '', frequency: 'WEEKLY', weekday: '3', day_of_month: '10', start_time: '20:00', end_time: '21:00', start_date: todayStr, end_date: '', has_no_end_date: true, price: '', notes: '', name: '', phone: '' })
  const [preview, setPreview] = useState(null)
  const [busy, setBusy] = useState(false)
  // B3: uma chave por intenção de criação; reutilizada em retry/needs_decision; some ao fechar.
  const operationIdRef = useRef(null)
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }))

  const body = () => ({
    organization_id: orgId, arena_id: arena.id, court_id: f.court_id, frequency: f.frequency,
    weekday: f.frequency === 'MONTHLY' ? null : Number(f.weekday), day_of_month: f.frequency === 'MONTHLY' ? Number(f.day_of_month) : null,
    start_time: f.start_time, end_time: f.end_time, start_date: f.start_date,
    end_date: f.has_no_end_date ? null : (f.end_date || null), has_no_end_date: f.has_no_end_date,
    default_price: brlToCents(f.price), notes: f.notes || null, customer: { name: f.name, phone: f.phone },
  })

  async function doPreview() {
    if (!f.name || !f.court_id) { toast.error('Informe o cliente e a quadra'); return }
    if (!f.has_no_end_date && !f.end_date) { toast.error('Informe a data final ou marque “sem data final”'); return }
    setBusy(true)
    const r = await fetch('/api/recurring-reservations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body(), dry_run: true }) })
    const d = await r.json().catch(() => ({}))
    setBusy(false)
    if (!r.ok) { toast.error(d.error || 'Não foi possível validar'); return }
    setPreview(d)
  }

  async function create(skip_conflicts) {
    if (!operationIdRef.current) {
      try { operationIdRef.current = newOperationId() } catch { toast.error('Não foi possível iniciar a operação neste navegador'); return }
    }
    setBusy(true)
    try {
      const r = await fetch('/api/recurring-reservations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body(), skip_conflicts, operation_id: operationIdRef.current }) })
      const d = await r.json().catch(() => ({}))
      if (r.status === 409 && d.needs_decision) { setPreview({ toCreate: d.toCreate, conflicts: d.conflicts, needs_decision: true }); return }
      if (!r.ok) { toast.error(d.error || 'Não foi possível criar'); return }
      if (d.idempotent) { toast.success('Mensalista já criado'); onCreated(); return }
      toast.success(`Mensalista criado — ${d.created} reserva(s) gerada(s)${d.ignored?.length ? `, ${d.ignored.length} ignorada(s)` : ''}`)
      onCreated()
    } catch {
      // Falha de rede/timeout: o servidor PODE ter confirmado. A chave da intenção é mantida para
      // que o retry (mesmo botão) reenvie o MESMO operation_id e receba o replay idempotente.
      toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader><DialogTitle>Novo mensalista</DialogTitle></DialogHeader>
        {!preview ? (
          <div className="space-y-4">
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5 col-span-2 sm:col-span-1"><Label>Cliente</Label><Input value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="Nome" /></div>
              <div className="space-y-1.5 col-span-2 sm:col-span-1"><Label>WhatsApp / telefone</Label><Input value={f.phone} onChange={(e) => set('phone', e.target.value)} placeholder="(11) 90000-0000" /></div>
            </div>
            <div className="space-y-1.5"><Label>Quadra</Label>
              <Select value={f.court_id} onValueChange={(v) => set('court_id', v)}><SelectTrigger><SelectValue placeholder="Selecione" /></SelectTrigger>
                <SelectContent>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent></Select>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5"><Label>Frequência</Label>
                <Select value={f.frequency} onValueChange={(v) => set('frequency', v)}><SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent><SelectItem value="WEEKLY">Semanal</SelectItem><SelectItem value="BIWEEKLY">Quinzenal</SelectItem><SelectItem value="MONTHLY">Mensal</SelectItem></SelectContent></Select>
              </div>
              {f.frequency === 'MONTHLY' ? (
                <div className="space-y-1.5"><Label>Dia do mês</Label><Input type="number" min="1" max="31" value={f.day_of_month} onChange={(e) => set('day_of_month', e.target.value)} /></div>
              ) : (
                <div className="space-y-1.5"><Label>Dia da semana</Label>
                  <Select value={f.weekday} onValueChange={(v) => set('weekday', v)}><SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>{WEEKDAYS.map((w, i) => <SelectItem key={i} value={String(i)}>{w}</SelectItem>)}</SelectContent></Select>
                </div>
              )}
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={f.start_time} onChange={(e) => set('start_time', e.target.value)} /></div>
              <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={f.end_time} onChange={(e) => set('end_time', e.target.value)} /></div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5"><Label>Data de início</Label><Input type="date" value={f.start_date} onChange={(e) => set('start_date', e.target.value)} /></div>
              <div className="space-y-1.5"><Label>Data final</Label><Input type="date" value={f.end_date} onChange={(e) => set('end_date', e.target.value)} disabled={f.has_no_end_date} /></div>
            </div>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.has_no_end_date} onChange={(e) => set('has_no_end_date', e.target.checked)} className="h-4 w-4 accent-[var(--primary)]" /> Sem data final</label>
            <div className="space-y-1.5"><Label>Preço por jogo (opcional)</Label><Input value={f.price} onChange={(e) => set('price', e.target.value)} placeholder="Ex.: 180,00" inputMode="decimal" /></div>
            <div className="space-y-1.5"><Label>Observação (opcional)</Label><Textarea rows={2} value={f.notes} onChange={(e) => set('notes', e.target.value)} /></div>
            <DialogFooter>
              <Button variant="outline" onClick={onClose}>Cancelar</Button>
              <Button onClick={doPreview} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Revisar</Button>
            </DialogFooter>
          </div>
        ) : (
          <div className="space-y-4">
            <div className="rounded-xl border border-border bg-muted/30 p-4 text-sm">
              <p className="font-semibold">{f.name}</p>
              <p className="text-muted-foreground">{courts.find((c) => c.id === f.court_id)?.name} · {f.frequency === 'MONTHLY' ? `Dia ${f.day_of_month}` : WEEKDAYS[Number(f.weekday)]} · {f.start_time}–{f.end_time}</p>
              <p className="text-muted-foreground">{FREQ_LABEL[f.frequency]} · a partir de {f.start_date} · {f.has_no_end_date ? 'sem data final' : `até ${f.end_date}`}{f.price ? ` · ${f.price} por jogo` : ''}</p>
            </div>
            <div className="flex items-start gap-2 rounded-lg border border-primary/30 bg-primary/[0.06] p-3 text-sm">
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
              <span>Serão criadas <b>{preview.toCreate}</b> reservas nos próximos 90 dias.</span>
            </div>
            {preview.conflicts?.length > 0 && (
              <div className="rounded-lg border border-amber-500/30 bg-amber-500/[0.06] p-3 text-sm">
                <p className="flex items-center gap-2 font-medium text-amber-500"><AlertTriangle className="h-4 w-4" /> {preview.conflicts.length} data(s) com conflito</p>
                <ul className="mt-2 max-h-40 space-y-1 overflow-y-auto text-muted-foreground">
                  {preview.conflicts.map((c, i) => <li key={i}>{c.date} — {c.reason}</li>)}
                </ul>
              </div>
            )}
            <DialogFooter className="flex-col gap-2 sm:flex-row">
              <Button variant="outline" onClick={() => setPreview(null)} disabled={busy}>Voltar</Button>
              {preview.conflicts?.length > 0 ? (
                <Button onClick={() => create(true)} disabled={busy || preview.toCreate === 0}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Criar somente horários disponíveis</Button>
              ) : (
                <Button onClick={() => create(false)} disabled={busy || preview.toCreate === 0}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirmar criação</Button>
              )}
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}

// -------------------------------------------------- Detail
function DetailSheet({ id, canManage, courts, onClose, onChanged }) {
  const [s, setS] = useState(null)
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState(null) // {type, ...}

  const load = useCallback(async () => {
    const r = await fetch(`/api/recurring-reservations/${id}`)
    setS(r.ok ? await r.json() : null)
  }, [id])
  useEffect(() => { load() }, [load])

  async function act(path, payload, okMsg) {
    setBusy(true)
    const r = await fetch(`/api/recurring-reservations/${id}/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload || {}) })
    const d = await r.json().catch(() => ({}))
    setBusy(false); setConfirm(null)
    if (!r.ok) { toast.error(d.error || 'Não foi possível concluir'); return }
    toast.success(okMsg)
    await load(); onChanged()
  }

  async function cancelOccurrence(occId) {
    setBusy(true)
    const r = await fetch(`/api/reservations/${occId}/cancel`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ reason: 'Cancelada pelo gestor (mensalista)' }) })
    setBusy(false)
    if (!r.ok) { toast.error('Não foi possível cancelar esta data'); return }
    toast.success('Data cancelada'); await load(); onChanged()
  }

  return (
    <Sheet open onOpenChange={onClose}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader><SheetTitle>Mensalista</SheetTitle></SheetHeader>
        {!s ? <div className="mt-6 space-y-3"><Skeleton className="h-24 w-full" /><Skeleton className="h-40 w-full" /></div> : (
          <div className="mt-4 space-y-5">
            <div className="rounded-xl border border-border bg-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold">{s.customer?.name || '—'}</p>
                <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_META[s.status].c}`}>{STATUS_META[s.status].l}</span>
              </div>
              <div className="mt-3 space-y-1.5 text-sm">
                <Row i={<User className="h-3.5 w-3.5" />} v={s.customer?.phone || '—'} />
                <Row i={<MapPin className="h-3.5 w-3.5" />} v={`${s.arena?.name || ''} · ${s.court?.name || ''}`} />
                <Row i={<Repeat className="h-3.5 w-3.5" />} v={`${FREQ_LABEL[s.frequency]} · ${whenLabel(s)}`} />
                <Row i={<CalendarClock className="h-3.5 w-3.5" />} v={`A partir de ${s.start_date}${s.has_no_end_date ? ' · sem data final' : ` · até ${s.end_date}`}`} />
                {s.default_price != null && <Row i={<span className="text-xs">R$</span>} v={`${centsToBRL(s.default_price)} por jogo`} />}
                {s.notes && <p className="pt-1 text-muted-foreground">{s.notes}</p>}
              </div>
            </div>

            {canManage && s.status !== 'CANCELLED' && (
              <div className="flex flex-wrap gap-2">
                {s.status === 'ACTIVE' ? (
                  <>
                    <Button size="sm" variant="outline" onClick={() => act('generate', {}, 'Próximas reservas geradas')} disabled={busy}><RefreshCw className="mr-1.5 h-3.5 w-3.5" /> Gerar próximas</Button>
                    <Button size="sm" variant="outline" onClick={() => setConfirm({ type: 'pause' })} disabled={busy}><Pause className="mr-1.5 h-3.5 w-3.5" /> Pausar</Button>
                  </>
                ) : (
                  <Button size="sm" variant="outline" onClick={() => act('reactivate', {}, 'Série reativada')} disabled={busy}><Play className="mr-1.5 h-3.5 w-3.5" /> Reativar</Button>
                )}
                <Button size="sm" variant="outline" className="text-destructive" onClick={() => setConfirm({ type: 'cancel' })} disabled={busy}><Ban className="mr-1.5 h-3.5 w-3.5" /> Cancelar série</Button>
              </div>
            )}

            <div>
              <p className="mb-2 text-sm font-semibold">Próximas reservas</p>
              {(!s.upcoming || s.upcoming.length === 0) ? (
                <p className="text-sm text-muted-foreground">Nenhuma reserva futura.</p>
              ) : (
                <div className="space-y-2">
                  {s.upcoming.map((o) => (
                    <div key={o.id} className="flex items-center justify-between rounded-lg border border-border px-3 py-2 text-sm">
                      <div>
                        <p className="font-medium">{fmtDateTimeLong(o.start_at)}</p>
                        <p className="text-xs text-muted-foreground">{o.court?.name}{o.is_exception ? ' · alterada' : ''}{o.status === 'CANCELLED' ? ' · cancelada' : ''}</p>
                      </div>
                      {o.status !== 'CANCELLED' && <Button size="icon" variant="ghost" className="h-8 w-8 text-muted-foreground hover:text-destructive" onClick={() => cancelOccurrence(o.id)} disabled={busy} title="Cancelar apenas esta data"><X className="h-4 w-4" /></Button>}
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </SheetContent>

      {confirm?.type === 'pause' && (
        <AlertDialog open onOpenChange={() => setConfirm(null)}>
          <AlertDialogContent>
            <AlertDialogHeader><AlertDialogTitle>Pausar mensalista</AlertDialogTitle>
              <AlertDialogDescription>Enquanto pausada, nenhuma nova reserva será gerada. Deseja cancelar também as reservas futuras já geradas?</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter className="flex-col gap-2 sm:flex-row">
              <AlertDialogCancel>Voltar</AlertDialogCancel>
              <Button variant="outline" onClick={() => act('pause', { cancel_future: false }, 'Série pausada')} disabled={busy}>Não, manter futuras</Button>
              <AlertDialogAction onClick={() => act('pause', { cancel_future: true }, 'Série pausada e futuras canceladas')} disabled={busy}>Sim, cancelar futuras</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
      {confirm?.type === 'cancel' && (
        <AlertDialog open onOpenChange={() => setConfirm(null)}>
          <AlertDialogContent>
            <AlertDialogHeader><AlertDialogTitle>Cancelar toda a recorrência?</AlertDialogTitle>
              <AlertDialogDescription>As reservas futuras ainda não realizadas serão canceladas. O histórico passado é preservado.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Voltar</AlertDialogCancel>
              <AlertDialogAction className="bg-destructive text-destructive-foreground hover:bg-destructive/90" onClick={() => act('cancel', {}, 'Recorrência cancelada')} disabled={busy}>Cancelar recorrência</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
    </Sheet>
  )
}

function Row({ i, v }) { return <div className="flex items-center gap-2 text-muted-foreground"><span className="shrink-0">{i}</span><span className="text-foreground">{v}</span></div> }
