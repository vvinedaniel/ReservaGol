'use client'
import { useEffect, useState } from 'react'
import Link from 'next/link'
import { Logo } from '@/components/reserva/logo'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { EmptyState } from '@/components/reserva/empty-state'
import { Search, MapPin, ArrowRight, Goal } from 'lucide-react'

export default function JogarPage() {
  const [q, setQ] = useState('')
  const [arenas, setArenas] = useState(null)
  useEffect(() => {
    const t = setTimeout(() => {
      fetch(`/api/public/arenas${q ? `?q=${encodeURIComponent(q)}` : ''}`).then((r) => r.json()).then((d) => setArenas(Array.isArray(d) ? d : []))
    }, 250)
    return () => clearTimeout(t)
  }, [q])
  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-20 border-b border-border/60 bg-background/80 backdrop-blur"><div className="container flex h-16 items-center justify-between"><Logo /><Link href="/login" className="text-sm text-muted-foreground hover:text-foreground">Sou gestor</Link></div></header>
      <section className="container py-8">
        <h1 className="font-display text-3xl font-extrabold">Encontre sua quadra</h1>
        <p className="mt-1 text-muted-foreground">Reserve em segundos, direto com a arena.</p>
        <div className="relative mt-5 max-w-xl"><Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" /><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar por arena, cidade ou bairro" className="h-12 pl-10 text-base" /></div>
        <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {arenas === null ? Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-64" />)
            : arenas.length === 0 ? <div className="sm:col-span-2 lg:col-span-3"><EmptyState icon={Goal} title="Nenhuma arena encontrada" description="Tente outra busca ou volte mais tarde." /></div>
            : arenas.map((a) => (
              <Card key={a.slug} className="overflow-hidden">
                <div className="aspect-[16/9] w-full overflow-hidden bg-muted">{a.cover_image_url ? <img src={a.cover_image_url} alt={a.name} className="h-full w-full object-cover" /> : <div className="flex h-full w-full items-center justify-center text-muted-foreground"><Goal className="h-10 w-10" /></div>}</div>
                <CardContent className="p-4">
                  <h3 className="font-display text-lg font-semibold">{a.name}</h3>
                  <p className="mt-0.5 flex items-center gap-1 text-sm text-muted-foreground"><MapPin className="h-3.5 w-3.5" />{[a.neighborhood, a.city].filter(Boolean).join(', ') || 'Localização'}</p>
                  <p className="mt-2 text-xs text-muted-foreground">{a.courts_count} quadra(s){a.types?.length ? ` · ${a.types.join(', ')}` : ''}</p>
                  <Button asChild className="mt-4 w-full"><Link href={`/jogar/${a.slug}`}>Ver arena <ArrowRight className="ml-2 h-4 w-4" /></Link></Button>
                </CardContent>
              </Card>
            ))}
        </div>
      </section>
    </div>
  )
}
