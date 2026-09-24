'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useMe } from '@/components/reserva/dashboard-shell'
import { StatCard } from '@/components/reserva/stat-card'
import { EmptyState } from '@/components/reserva/empty-state'
import { DemoBadge } from '@/components/reserva/demo-badge'
import { statusMeta } from '@/lib/reserva/status'
import { buildSlots, overlaps, fmtTime, todayStr } from '@/lib/reserva/time'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { DollarSign, CalendarCheck, Percent, Receipt, CalendarClock, BarChart3, ArrowRight, Globe } from 'lucide-react'
import { cn } from '@/lib/utils'

export default function OverviewPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const isDemo = me?.activeOrg?.is_demo
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [pubCheck, setPubCheck] = useState(null)

  useEffect(() => {
    if (!orgId) return
    ;(async () => {
      setLoading(true)
      const arenas = await fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json()).catch(() => [])
      const arena = Array.isArray(arenas) ? arenas[0] : null
      if (!arena) { setLoading(false); return }
      fetch(`/api/arenas/${arena.id}/publish-check`).then((r) => r.json()).then(setPubCheck).catch(() => {})
      const ag = await fetch(`/api/agenda?arena_id=${arena.id}&date=${todayStr()}`).then((r) => r.json()).catch(() => null)
      setData(ag)
      setLoading(false)
    })()
  }, [orgId])

  const courts = data?.courts || []
  const hours = data?.business_hours
  const step = data?.default_reservation_minutes || 60
  const slots = hours && !hours.closed ? buildSlots(hours.open_time, hours.close_time, step) : []
  const reservations = (data?.reservations || [])
  const bookings = reservations.filter((r) => r.status !== 'BLOCKED')

  let occupied = 0
  const total = courts.length * slots.length
  for (const c of courts) for (const s of slots) if (reservations.find((r) => r.court_id === c.id && overlaps(r, s.startMin, s.endMin))) occupied++
  const occupancy = total ? Math.round((occupied / total) * 100) : 0

  const upcoming = [...reservations].sort((a, b) => a.start_at.localeCompare(b.start_at))

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-display text-2xl font-bold text-foreground">Visão Geral</h1>
          <p className="mt-1 text-sm text-muted-foreground">Acompanhe o desempenho da {me?.activeOrg?.name}.</p>
        </div>
        <div className="flex items-center gap-2">
          {isDemo && <DemoBadge />}
          <Button asChild variant="outline" size="sm"><Link href="/dashboard/agenda">Abrir agenda <ArrowRight className="ml-2 h-4 w-4" /></Link></Button>
        </div>
      </div>

      {pubCheck && !pubCheck.published && (
        <Card className="border-primary/30 bg-primary/[0.06]">
          <CardContent className="flex flex-wrap items-center justify-between gap-4 py-5">
            <div className="flex items-start gap-3">
              <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-primary"><Globe className="h-5 w-5" /></span>
              <div>
                <p className="font-semibold">{pubCheck.canPublish ? 'Sua arena está pronta para publicar' : 'Complete sua arena'}</p>
                <p className="text-sm text-muted-foreground">{pubCheck.canPublish ? 'Publique e receba reservas de jogadores pela página pública.' : `Faltam ${pubCheck.missing.length} item(ns) para publicar sua página pública.`}</p>
              </div>
            </div>
            <Button asChild><Link href="/dashboard/perfil">{pubCheck.canPublish ? 'Publicar arena' : 'Completar perfil'} <ArrowRight className="ml-2 h-4 w-4" /></Link></Button>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label="Receita" value="R$ 0,00" hint="Em breve" icon={DollarSign} accent="muted" />
        <StatCard label="Reservas de hoje" value={loading ? '—' : String(bookings.length)} hint="Confirmadas e pendentes" icon={CalendarCheck} />
        <StatCard label="Ocupação de hoje" value={loading ? '—' : `${occupancy}%`} hint={total ? `${occupied}/${total} horários` : 'Sem horários'} icon={Percent} />
        <StatCard label="Ticket médio" value="R$ 0,00" hint="Em breve" icon={Receipt} accent="muted" />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader><CardTitle className="flex items-center gap-2 text-base"><CalendarClock className="h-4 w-4 text-primary" /> Hoje na Arena</CardTitle></CardHeader>
          <CardContent>
            {loading ? <Skeleton className="h-40 w-full" /> : upcoming.length === 0 ? (
              <EmptyState icon={CalendarClock} title="Nenhuma reserva para hoje" description="Quando houver reservas para o dia, elas aparecerão aqui." />
            ) : (
              <div className="divide-y divide-border">
                {upcoming.map((r) => {
                  const m = statusMeta(r.status)
                  return (
                    <div key={r.id} className="flex items-center justify-between py-2.5">
                      <div className="flex items-center gap-3">
                        <span className="w-24 text-sm font-medium">{fmtTime(r.start_at)}–{fmtTime(r.end_at)}</span>
                        <div>
                          <p className="text-sm font-medium">{r.court?.name}</p>
                          <p className="text-xs text-muted-foreground">{r.status === 'BLOCKED' ? (r.notes || 'Bloqueio') : (r.customer?.name || 'Sem cliente')}</p>
                        </div>
                      </div>
                      <Badge className={cn('border', m.badge)}>{m.label}</Badge>
                    </div>
                  )
                })}
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle className="flex items-center gap-2 text-base"><BarChart3 className="h-4 w-4 text-primary" /> Ocupação de hoje</CardTitle></CardHeader>
          <CardContent>
            {loading ? <Skeleton className="h-40 w-full" /> : !total ? (
              <EmptyState icon={BarChart3} title="Sem dados de ocupação" description="Configure horários e quadras para acompanhar a ocupação." />
            ) : (
              <div className="space-y-4">
                <div className="flex items-end justify-between">
                  <span className="font-display text-4xl font-bold text-primary">{occupancy}%</span>
                  <span className="text-sm text-muted-foreground">{occupied} de {total} horários ocupados</span>
                </div>
                <div className="h-3 w-full overflow-hidden rounded-full bg-muted">
                  <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${occupancy}%` }} />
                </div>
                <p className="text-xs text-muted-foreground">{courts.length} quadra(s) ativa(s) · {slots.length} horário(s) por quadra</p>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
