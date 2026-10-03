'use client'

// FASE 03B.1 — seletor de período (+ arena) do Financeiro. Só intenção: o período resolvido
// vem de lib/reserva/finance-period e é validado de novo na API e na RPC.
// Datas digitadas seguem o padrão 03A.1: o campo (input) é separado da última data válida;
// valor parcial/inválido nunca vira período e o blur restaura a última data válida.
import { useState } from 'react'
import { PRESETS, PRESET_LABELS, MAX_PERIOD_DAYS, resolvePeriod, isValidCustomPeriod, periodDays, fmtPeriodShort } from '@/lib/reserva/finance-period'
import { applyDateInput, isValidDateStr } from '@/lib/reserva/time'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { CalendarRange } from 'lucide-react'
import { cn } from '@/lib/utils'

export const ALL_ARENAS = 'all'

function customError(from, to) {
  if (!isValidDateStr(from) || !isValidDateStr(to)) return 'Informe as duas datas.'
  const n = periodDays(from, to)
  if (n < 1) return 'A data inicial deve ser anterior ou igual à final.'
  if (n > MAX_PERIOD_DAYS) return `O período pode ter no máximo ${MAX_PERIOD_DAYS} dias.`
  return null
}

export function PeriodPicker({ period, today, onChange, arenas = [], arenaId = null, onArenaChange }) {
  const [customOpen, setCustomOpen] = useState(period.preset === 'custom')
  // Campos do personalizado: input (o que está digitado) x date (última data válida).
  const [from, setFrom] = useState({ dateInput: period.from, date: period.from })
  const [to, setTo] = useState({ dateInput: period.to, date: period.to })
  const err = customError(from.date, to.date)

  function pickPreset(p) {
    if (p === 'custom') {
      setFrom({ dateInput: period.from, date: period.from })
      setTo({ dateInput: period.to, date: period.to })
      setCustomOpen(true)
      return
    }
    setCustomOpen(false)
    if (p === period.preset) return
    const next = resolvePeriod(p, today)
    if (next) onChange(next)
  }

  function applyCustom() {
    if (!isValidCustomPeriod(from.date, to.date)) return
    if (period.preset === 'custom' && period.from === from.date && period.to === to.date) return
    const next = resolvePeriod('custom', today, { from: from.date, to: to.date })
    if (next) onChange(next)
  }

  const active = customOpen ? 'custom' : period.preset
  return (
    <div className="space-y-3 rounded-xl border border-border bg-card/60 p-3 sm:p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="-mx-1 flex flex-wrap gap-1.5 px-1" role="group" aria-label="Período">
          {PRESETS.map((p) => (
            <Button
              key={p}
              type="button"
              size="sm"
              variant={active === p ? 'default' : 'outline'}
              aria-pressed={active === p}
              className="h-8"
              onClick={() => pickPreset(p)}
            >
              {PRESET_LABELS[p]}
            </Button>
          ))}
        </div>
        {arenas.length > 1 && (
          <Select value={arenaId || ALL_ARENAS} onValueChange={(v) => onArenaChange(v === ALL_ARENAS ? null : v)}>
            <SelectTrigger className="h-8 w-full sm:w-56" aria-label="Arena"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL_ARENAS}>Todas as arenas</SelectItem>
              {arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}
            </SelectContent>
          </Select>
        )}
      </div>

      {customOpen && (
        <div className="flex flex-wrap items-end gap-3 border-t border-border pt-3">
          <div className="space-y-1">
            <Label htmlFor="fin-from" className="text-xs text-muted-foreground">De</Label>
            <Input id="fin-from" type="date" className="h-9 w-40" value={from.dateInput}
              onChange={(e) => setFrom((s) => applyDateInput(s.date, e.target.value))}
              onBlur={() => setFrom((s) => ({ dateInput: s.date, date: s.date }))} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="fin-to" className="text-xs text-muted-foreground">Até</Label>
            <Input id="fin-to" type="date" className="h-9 w-40" value={to.dateInput}
              onChange={(e) => setTo((s) => applyDateInput(s.date, e.target.value))}
              onBlur={() => setTo((s) => ({ dateInput: s.date, date: s.date }))} />
          </div>
          <Button type="button" size="sm" className="h-9" disabled={!!err} onClick={applyCustom}>Aplicar</Button>
          {err && <p className="w-full text-xs text-amber-500">{err}</p>}
        </div>
      )}

      <p className={cn('flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground')}>
        <CalendarRange className="h-3.5 w-3.5 text-primary" />
        <span className="font-medium text-foreground">{fmtPeriodShort(period.from, period.to)}</span>
        <span>· {period.days} {period.days === 1 ? 'dia' : 'dias'}</span>
        <span>· comparado a {fmtPeriodShort(period.compare.from, period.compare.to)}</span>
      </p>
    </div>
  )
}
