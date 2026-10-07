'use client'

// FASE 03C — "Datas não geradas" de uma ou mais séries (lacunas persistidas no banco). SOMENTE OWNER/MANAGER
// (quem renderiza decide; a API também recusa 403 para a recepção). Leitura pura via GET /:id/gaps.
// Respostas antigas são descartadas (sequência local). Nenhuma decisão de negócio no front.
import { useEffect, useRef, useState } from 'react'
import { normalizeGaps, gapReasonLabel, gapReasonHint, gapDateLabel, gapConflictLabel } from '@/lib/reserva/recurring-gaps'
import { AlertTriangle, Loader2 } from 'lucide-react'

export function SeriesGaps({ seriesIds, onlyDates = null, reloadKey = 0, title = 'Datas não geradas' }) {
  const [st, setSt] = useState({ loading: true, items: [], error: false })
  const seq = useRef(0)
  const key = (seriesIds || []).join(',')

  useEffect(() => {
    const ids = key ? key.split(',') : []
    const my = ++seq.current
    if (!ids.length) { setSt({ loading: false, items: [], error: false }); return }
    setSt((s) => ({ ...s, loading: true, error: false }))
    Promise.all(ids.map((id) => fetch(`/api/recurring-reservations/${encodeURIComponent(id)}/gaps`, { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))))
      .then((rows) => { if (my === seq.current) setSt({ loading: false, items: rows.flatMap((p) => normalizeGaps(p)), error: false }) })
      .catch(() => { if (my === seq.current) setSt({ loading: false, items: [], error: true }) })
  }, [key, reloadKey])

  const items = onlyDates ? st.items.filter((g) => onlyDates.includes(g.date)) : st.items
  if (st.loading) {
    return <p className="flex items-center gap-2 text-xs text-muted-foreground" aria-live="polite"><Loader2 className="h-3.5 w-3.5 animate-spin motion-reduce:animate-none" aria-hidden="true" />Verificando datas não geradas…</p>
  }
  if (st.error) return <p className="text-xs text-amber-500" role="status">Não foi possível carregar as datas não geradas.</p>
  if (!items.length) return null
  return (
    <section aria-label={title} className="rounded-lg border border-amber-500/40 bg-amber-500/5 px-3 py-3 text-sm">
      <p className="flex items-center gap-2 font-medium"><AlertTriangle className="h-4 w-4 text-amber-500" aria-hidden="true" />{title} ({items.length})</p>
      <ul className="mt-2 space-y-2">
        {items.map((g) => {
          const conflict = gapConflictLabel(g.conflict)
          return (
            <li key={g.id || `${g.series_id}:${g.date}`} className="text-xs">
              <span className="font-medium tabular-nums">{gapDateLabel(g.date)}</span>
              <span className="text-muted-foreground"> · {gapReasonLabel(g.reason)}{conflict ? ` (${conflict})` : ''}</span>
              {gapReasonHint(g.reason) && <span className="block text-muted-foreground">{gapReasonHint(g.reason)}</span>}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
