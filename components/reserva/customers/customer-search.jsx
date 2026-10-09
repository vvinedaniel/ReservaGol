'use client'

// CLIENTES C2B — busca de cliente existente (nome ou telefone) com filtro NO SERVIDOR (rg_customer_list).
// Espera 250 ms entre teclas; resposta antiga é descartada (runLatest). Nunca carrega todos os clientes.
import { useEffect, useRef, useState } from 'react'
import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'
import { formatBrPhone } from '@/lib/reserva/phone'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Check, Search } from 'lucide-react'
import { cn } from '@/lib/utils'

export const SEARCH_MIN_CHARS = 2

export function CustomerSearch({ api, orgId, picked, onPick, excludeId = null, autoFocus = false, id = 'cs-q', label = 'Buscar cliente' }) {
  const [q, setQ] = useState('')
  const [st, setSt] = useState({ loading: false, items: [], error: false, done: false })
  const seq = useRef(null)
  if (!seq.current) seq.current = createRequestSequence()

  useEffect(() => {
    const t = q.trim()
    if (t.length < SEARCH_MIN_CHARS) { seq.current.invalidate(); setSt({ loading: false, items: [], error: false, done: false }); return undefined }
    const timer = setTimeout(() => {
      runLatest(seq.current, () => api.list({ orgId, q: t, limit: 10 }), {
        onStart: () => setSt((s) => ({ ...s, loading: true, error: false })),
        onResult: (d) => setSt({ loading: false, items: Array.isArray(d?.items) ? d.items.filter((c) => c.id !== excludeId) : [], error: false, done: true }),
        onError: () => setSt({ loading: false, items: [], error: true, done: true }),
      })
    }, 250)
    return () => clearTimeout(timer)
  }, [q, api, orgId, excludeId])
  useEffect(() => () => seq.current.invalidate(), [])

  const hint = q.trim().length < SEARCH_MIN_CHARS ? 'Digite nome ou telefone (ao menos 2 caracteres).'
    : st.loading ? 'Buscando…' : st.error ? 'Não foi possível buscar. Tente novamente.' : st.done ? `${st.items.length} cliente(s) encontrado(s).` : ''
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
        <Input id={id} className="h-11 pl-9 sm:h-9" value={q} autoFocus={autoFocus} placeholder="Nome ou telefone" onChange={(e) => setQ(e.target.value)}
          aria-describedby={`${id}-hint`} autoComplete="off" />
      </div>
      <p id={`${id}-hint`} className="text-xs text-muted-foreground" aria-live="polite">{hint}</p>
      {st.items.length > 0 && (
        <ul className="max-h-64 divide-y divide-border overflow-y-auto rounded-lg border border-border" aria-label="Clientes encontrados">
          {st.items.map((c) => (
            <li key={c.id}>
              <button type="button" aria-pressed={picked?.id === c.id} onClick={() => onPick(c)}
                className={cn('flex min-h-11 w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none', picked?.id === c.id && 'bg-accent/40')}>
                <span className="min-w-0">
                  <span className="block truncate font-medium">{c.name}</span>
                  <span className="block truncate text-xs text-muted-foreground">{c.phone ? formatBrPhone(c.phone) : 'sem telefone'}</span>
                </span>
                {picked?.id === c.id && <Check className="h-4 w-4 shrink-0 text-primary" aria-hidden="true" />}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
