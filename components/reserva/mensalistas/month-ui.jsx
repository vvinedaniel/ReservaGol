'use client'

// FASE 03B.3B — peças visuais compartilhadas da visão mensal de Mensalistas: badge de status do mês
// (texto + ícone, nunca só cor), navegação de mês e célula de valor. Só apresentação.
import { monthStatusMeta, monthLabel, capitalizeFirst, prevMonth, nextMonth, moneyOrDash } from '@/lib/reserva/recurring-month'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { AlertTriangle, AlertCircle, CircleDashed, Circle, CheckCircle2, MinusCircle, ChevronLeft, ChevronRight, UserX } from 'lucide-react'
import { cn } from '@/lib/utils'

const ICONS = { AlertTriangle, AlertCircle, CircleDashed, Circle, CheckCircle2, MinusCircle }

export function MonthStatusBadge({ status, className }) {
  const meta = monthStatusMeta(status)
  const Icon = ICONS[meta.icon] || Circle
  return (
    <Badge className={cn('gap-1 border font-normal', meta.badge, className)}>
      <Icon className="h-3 w-3" aria-hidden="true" />{meta.label}
    </Badge>
  )
}

export function NoCustomerBadge({ className }) {
  return (
    <Badge className={cn('gap-1 border border-amber-500/30 bg-amber-500/10 font-normal text-amber-300', className)}>
      <UserX className="h-3 w-3" aria-hidden="true" />Sem cliente
    </Badge>
  )
}

export function OverdueBadge({ amount, className }) {
  return (
    <Badge className={cn('gap-1 border border-red-500/40 bg-red-500/10 font-normal text-red-300', className)}>
      <AlertCircle className="h-3 w-3" aria-hidden="true" />Vencido {moneyOrDash(amount)}
    </Badge>
  )
}

// Navegação ‹ mês › + "Mês atual". `disabled` durante carga não bloqueia: troca invalida a anterior.
export function MonthNav({ month, currentMonth, onChange, className, compact = false }) {
  const prev = prevMonth(month)
  const next = nextMonth(month)
  return (
    <div className={cn('flex flex-wrap items-center gap-2', className)} role="group" aria-label="Mês de referência">
      <Button type="button" variant="outline" size="icon" className="h-11 w-11 sm:h-9 sm:w-9" onClick={() => prev && onChange(prev)} disabled={!prev}
        aria-label={prev ? `Mês anterior: ${monthLabel(prev)}` : 'Mês anterior'}>
        <ChevronLeft className="h-4 w-4" />
      </Button>
      <p className={cn('min-w-[10rem] text-center font-display font-semibold', compact ? 'text-base' : 'text-lg')} aria-live="polite">
        {capitalizeFirst(monthLabel(month))}
      </p>
      <Button type="button" variant="outline" size="icon" className="h-11 w-11 sm:h-9 sm:w-9" onClick={() => next && onChange(next)} disabled={!next}
        aria-label={next ? `Próximo mês: ${monthLabel(next)}` : 'Próximo mês'}>
        <ChevronRight className="h-4 w-4" />
      </Button>
      {currentMonth && month !== currentMonth && (
        <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={() => onChange(currentMonth)}>Mês atual</Button>
      )}
    </div>
  )
}

export function Money({ value, strong = false, className }) {
  return <span className={cn('whitespace-nowrap tabular-nums', strong && 'font-semibold', className)}>{moneyOrDash(value)}</span>
}
