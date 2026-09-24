'use client'
import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { CheckCircle2, XCircle, Navigation, MessageCircle, Goal } from 'lucide-react'
import { fmtDateTimeLong, fmtTime } from '@/lib/reserva/time'

export default function PublicReservationPage() {
  const { codigo } = useParams()
  const [res, setRes] = useState(undefined)

  useEffect(() => {
    fetch(`/api/public/reservation/${encodeURIComponent(codigo)}`, { cache: 'no-store' }).then((r) => r.ok ? r.json() : null).then(setRes).catch(() => setRes(null))
  }, [codigo])

  if (res === undefined) return <div className="container max-w-md py-16"><Skeleton className="h-64 w-full" /></div>

  if (!res) return (
    <div className="flex min-h-screen flex-col items-center justify-center p-6 text-center">
      <XCircle className="h-12 w-12 text-muted-foreground" />
      <h1 className="mt-3 font-display text-xl font-semibold">Reserva não encontrada</h1>
      <p className="mt-1 text-sm text-muted-foreground">Verifique o código e tente novamente.</p>
      <Button asChild className="mt-6"><Link href="/jogar">Encontrar arenas</Link></Button>
    </div>
  )

  const a = res.arena || {}
  const cancelled = res.status === 'CANCELLED'
  const mapsUrl = a.latitude && a.longitude
    ? `https://www.google.com/maps/dir/?api=1&destination=${a.latitude},${a.longitude}`
    : `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent([a.address, a.number, a.neighborhood, a.city, a.state].filter(Boolean).join(', '))}`
  const waDigits = (a.whatsapp || '').replace(/\D/g, '')
  const waUrl = `https://wa.me/${waDigits.startsWith('55') ? waDigits : '55' + waDigits}?text=${encodeURIComponent(`Olá! Tenho a reserva ${res.public_code} e preciso de ajuda.`)}`

  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-20 border-b border-border/60 bg-background/80 backdrop-blur"><div className="container flex h-16 items-center justify-between"><Logo /><Link href="/jogar" className="text-sm text-muted-foreground hover:text-foreground">Outras arenas</Link></div></header>
      <div className="container max-w-md py-8">
        <div className="flex flex-col items-center text-center">
          {cancelled ? <XCircle className="h-14 w-14 text-destructive" /> : <CheckCircle2 className="h-14 w-14 text-primary" />}
          <h1 className="mt-4 font-display text-2xl font-bold">{cancelled ? 'Reserva cancelada' : 'Reserva confirmada!'}</h1>
          <p className="mt-1 text-sm text-muted-foreground">Código da reserva</p>
          <p className="mt-2 rounded-lg border border-primary/30 bg-primary/10 px-4 py-2 max-w-full break-all font-display text-lg font-bold tracking-widest text-primary sm:text-2xl">{res.public_code}</p>
        </div>

        <div className="mt-6 rounded-xl border border-border bg-card p-4 text-sm">
          <Row l="Arena" v={a.name} />
          <Row l="Quadra" v={res.court?.name} />
          <Row l="Data" v={fmtDateTimeLong(res.start_at)} />
          <Row l="Horário" v={`${fmtTime(res.start_at)} – ${fmtTime(res.end_at)}`} />
          <Row l="Endereço" v={[a.address, a.number, a.neighborhood, a.city, a.state].filter(Boolean).join(', ')} />
        </div>

        {!cancelled && (
          <div className="mt-4 grid grid-cols-2 gap-2">
            <Button asChild variant="outline"><a href={mapsUrl} target="_blank" rel="noreferrer"><Navigation className="mr-2 h-4 w-4" /> Como chegar</a></Button>
            <Button asChild variant="outline" disabled={!waDigits}><a href={waUrl} target="_blank" rel="noreferrer"><MessageCircle className="mr-2 h-4 w-4" /> Falar com a arena</a></Button>
          </div>
        )}

        {a.slug && <Button asChild variant="ghost" className="mt-4 w-full"><Link href={`/jogar/${a.slug}`}><Goal className="mr-2 h-4 w-4" /> Ver arena / reservar novamente</Link></Button>}
      </div>
    </div>
  )
}

function Row({ l, v }) { return <div className="flex justify-between gap-4 border-b border-border/60 py-1.5 last:border-0"><span className="text-muted-foreground">{l}</span><span className="text-right font-medium">{v || '—'}</span></div> }
