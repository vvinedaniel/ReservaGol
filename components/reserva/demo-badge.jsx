import { cn } from '@/lib/utils'
import { FlaskConical } from 'lucide-react'

export function DemoBadge({ className }) {
  return (
    <span className={cn(
      'inline-flex items-center gap-1.5 rounded-full border border-amber-500/40 bg-amber-500/10 px-2.5 py-1 text-xs font-medium text-amber-400',
      className
    )}>
      <FlaskConical className="h-3.5 w-3.5" />
      Dados demonstrativos
    </span>
  )
}
