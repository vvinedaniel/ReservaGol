'use client'
import { useEffect, useMemo, useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { MapPin, MessageCircle, Navigation, Goal, Loader2, CheckCircle2, Clock } from 'lucide-react'
import { toast } from 'sonner'
import { todayStr, addDaysStr, weekdayOf, fmtDateLong } from '@/lib/reserva/time'

export default function ArenaPublicPage() {
  const { slug } = useParams()
  const router = useRouter()
  const [arena, setArena] = useState(null)
  const [notFound, setNotFound] = useState(false)
  const [courtId, setCourtId] = useState('')
  const [date, setDate] = useState(todayStr())
  const [avail, setAvail] = useState(null)
  const [pick, setPick] = useState(null)

  useEffect(() => {
    fetch(`/api/public/arena/${slug}`).then((r) => r.ok ? r.json() : Promise.reject()).then((d) => { setArena(d); setCourtId(d.courts?.[0]?.id || '') }).catch(() => setNotFound(true))
  }, [slug])

  const loadAvail = () => { if (slug && courtId && date) fetch(`/api/public/availability?slug=${slug}&court_id=${courtId}&date=${date}`).then((r) => r.json()).then(setAvail) }
  useEffect(() => { setAvail(null); loadAvail(); const iv = setInterval(loadAvail, 10000); return () => clearInterval(iv) }, [slug, courtId, date])

  const openNow = useMemo(() => {
    if (!arena?.business_hours) return null
    const wd = weekdayOf(todayStr()); const h = arena.business_hours.find((x) => x.weekday === wd)
    if (!h || h.closed) return false
    const now = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Sao_Paulo', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date())
    return now >= (h.open_time || '').slice(0, 5) && now < (h.close_time || '').slice(0, 5)
  }, [arena])

  if (notFound) return <div className="flex min-h-screen items-center justify-center p-6 text-center"><div><Goal className="mx-auto h-10 w-10 text-muted-foreground" /><p className="mt-3 font-display text-lg font-semibold">Arena não disponível</p><p className="text-sm text-muted-foreground">Esta arena não está publicada.</p></div></div>
  if (!arena) return <div className="container py-10"><Skeleton className="h-56 w-full" /><Skeleton className="mt-4 h-40 w-full" /></div>

  const mapsUrl = arena.latitude && arena.longitude ? `https://www.google.com/maps/dir/?api=1&destination=${arena.latitude},${arena.longitude}` : `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent([arena.address, arena.number, arena.neighborhood, arena.city, arena.state].filter(Boolean).join(', '))}`
  const waDigits = (arena.whatsapp || '').replace(/\D/g, '')
  const waUrl = `https://wa.me/${waDigits.startsWith('55') ? waDigits : '55' + waDigits}?text=${encodeURIComponent('Olá! Encontrei sua arena pelo Reserva Gol e preciso de ajuda.')}`

  return (
    <div className="min-h-screen bg-background pb-24">
      <header className="sticky top-0 z-20 border-b border-border/60 bg-background/80 backdrop-blur"><div className="container flex h-16 items-center justify-between"><Logo /></div></header>
      <div className="relative h-52 w-full overflow-hidden bg-muted sm:h-64">{arena.cover_image_url ? <img src={arena.cover_image_url} alt={arena.name} className="h-full w-full object-cover" /> : <div className="flex h-full items-center justify-center text-muted-foreground"><Goal className="h-12 w-12" /></div>}<div className="absolute inset-0 bg-gradient-to-t from-background to-transparent" /></div>
      <div className="container -mt-10 relative">
        <span className={`inline-flex items-center rounded-full border px-2.5 py-1 text-xs font-medium ${openNow ? 'border-primary/30 bg-primary/15 text-primary' : 'border-border bg-muted text-muted-foreground'}`}>{openNow == null ? '—' : openNow ? 'Aberto agora' : 'Fechado agora'}</span>
        <h1 className="mt-2 font-display text-2xl font-bold sm:text-3xl">{arena.name}</h1>
        <p className="mt-1 flex items-center gap-1 text-sm text-muted-foreground"><MapPin className="h-4 w-4" />{[arena.address, arena.number, arena.neighborhood, arena.city, arena.state].filter(Boolean).join(', ')}</p>
        {arena.description && <p className="mt-3 text-sm text-muted-foreground">{arena.description}</p>}
        <div className="mt-4 grid grid-cols-2 gap-2">
          <Button asChild variant="outline"><a href={mapsUrl} target="_blank" rel="noreferrer"><Navigation className="mr-2 h-4 w-4" /> Como chegar</a></Button>
          <Button asChild variant="outline" disabled={!waDigits}><a href={waUrl} target="_blank" rel="noreferrer"><MessageCircle className="mr-2 h-4 w-4" /> WhatsApp</a></Button>
        </div>
        {arena.amenities?.length > 0 && <div className="mt-4 flex flex-wrap gap-2">{arena.amenities.map((am) => <span key={am} className="rounded-full border border-border bg-card px-2.5 py-1 text-xs text-muted-foreground">{am}</span>)}</div>}

        <div className="mt-8 rounded-xl border border-border bg-card p-4">
          <h2 className="font-display text-lg font-semibold">Ver horários</h2>
          <div className="mt-3 grid grid-cols-2 gap-3">
            <div><Label className="text-xs">Quadra</Label><Select value={courtId} onValueChange={setCourtId}><SelectTrigger className="mt-1"><SelectValue placeholder="Quadra" /></SelectTrigger><SelectContent>{arena.courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent></Select></div>
            <div><Label className="text-xs">Data</Label><Input type="date" value={date} min={todayStr()} onChange={(e) => setDate(e.target.value)} className="mt-1" /></div>
          </div>
          <p className="mt-3 text-xs capitalize text-muted-foreground">{fmtDateLong(date)}</p>
          <div className="mt-3 grid grid-cols-3 gap-2 sm:grid-cols-4">
            {avail === null ? Array.from({ length: 8 }).map((_, i) => <Skeleton key={i} className="h-11" />)
              : avail.closed ? <p className="col-span-full py-6 text-center text-sm text-muted-foreground">Fechado nesta data.</p>
              : avail.slots.length === 0 ? <p className="col-span-full py-6 text-center text-sm text-muted-foreground">Sem horários para esta data.</p>
              : avail.slots.map((s) => (
                <button key={s.start} disabled={!s.available} onClick={() => setPick(s)} className={`rounded-lg border px-2 py-2.5 text-sm font-medium transition-colors ${s.available ? 'border-primary/40 bg-primary/10 text-primary hover:bg-primary/20' : 'cursor-not-allowed border-border bg-muted/40 text-muted-foreground line-through'}`}>{s.start}<span className="mt-0.5 block text-[10px] font-normal">{s.available ? 'Disponível' : 'Indisponível'}</span></button>
              ))}
          </div>
        </div>
        {arena.booking_rules && <div className="mt-4 rounded-xl border border-border bg-card p-4"><h3 className="text-sm font-semibold">Regras da arena</h3><p className="mt-1 whitespace-pre-line text-sm text-muted-foreground">{arena.booking_rules}</p></div>}
      </div>

      {pick && <ReserveDialog arena={arena} slug={slug} courtId={courtId} date={date} slot={pick} onClose={() => setPick(null)} onDone={(code) => router.push(`/reserva/${code}`)} />}
    </div>
  )
}

function ReserveDialog({ arena, slug, courtId, date, slot, onClose, onDone }) {
  const court = arena.courts.find((c) => c.id === courtId)
  const [f, setF] = useState({ name: '', phone: '', email: '', accept: false })
  const [saving, setSaving] = useState(false)
  const [key] = useState(() => (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()))
  async function submit() {
    if (!f.name.trim() || !f.phone.trim()) { toast.error('Preencha nome e WhatsApp'); return }
    if (!f.accept) { toast.error('Aceite as regras para continuar'); return }
    setSaving(true)
    const r = await fetch('/api/public/reserve', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ slug, court_id: courtId, date, start_time: slot.start, end_time: slot.end, name: f.name, phone: f.phone, email: f.email, accept_terms: f.accept, idempotency_key: key }) })
    const d = await r.json().catch(() => ({}))
    setSaving(false)
    if (r.status === 409) { toast.error('Horário indisponível', { description: d.error }); onClose(); return }
    if (!r.ok) { toast.error('Não foi possível reservar', { description: d.error }); return }
    onDone(d.public_code)
  }
  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-h-[92vh] overflow-y-auto">
        <DialogHeader><DialogTitle>Confirmar reserva</DialogTitle></DialogHeader>
        <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm"><p><b>{arena.name}</b></p><p className="text-muted-foreground">{court?.name} · {date} · {slot.start}–{slot.end}</p></div>
        <div className="space-y-3">
          <div className="space-y-1.5"><Label>Nome completo</Label><Input value={f.name} onChange={(e) => setF((s) => ({ ...s, name: e.target.value }))} placeholder="Seu nome" /></div>
          <div className="space-y-1.5"><Label>WhatsApp</Label><Input value={f.phone} onChange={(e) => setF((s) => ({ ...s, phone: e.target.value }))} placeholder="(11) 90000-0000" /></div>
          <div className="space-y-1.5"><Label>E-mail (opcional)</Label><Input value={f.email} onChange={(e) => setF((s) => ({ ...s, email: e.target.value }))} placeholder="voce@email.com" /></div>
          <label className="flex items-start gap-2 text-sm text-muted-foreground"><input type="checkbox" checked={f.accept} onChange={(e) => setF((s) => ({ ...s, accept: e.target.checked }))} className="mt-0.5 h-4 w-4 accent-[#19C463]" />Li e concordo com as regras da arena e com os termos aplicáveis.</label>
        </div>
        <DialogFooter><Button variant="ghost" onClick={onClose}>Cancelar</Button><Button onClick={submit} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirmar reserva</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

