// Visual status metadata for reservations. Always use COLOR + TEXT (never color alone).
export const STATUS_META = {
  LIVRE:     { label: 'Livre',      badge: 'border-border bg-muted/40 text-muted-foreground',            cell: 'hover:border-primary/50 hover:bg-primary/5',                    dot: 'bg-muted-foreground/50' },
  PENDING:   { label: 'Pendente',   badge: 'border-amber-500/30 bg-amber-500/10 text-amber-300',         cell: 'border-amber-500/40 bg-amber-500/10 text-amber-200',            dot: 'bg-amber-400' },
  CONFIRMED: { label: 'Confirmada', badge: 'border-primary/30 bg-primary/15 text-primary',               cell: 'border-primary/40 bg-primary/15 text-primary',                  dot: 'bg-primary' },
  PAID:      { label: 'Paga',       badge: 'border-emerald-500/30 bg-emerald-500/15 text-emerald-300',   cell: 'border-emerald-500/40 bg-emerald-500/15 text-emerald-200',      dot: 'bg-emerald-400' },
  BLOCKED:   { label: 'Bloqueada',  badge: 'border-zinc-500/30 bg-zinc-500/15 text-zinc-300',            cell: 'border-zinc-500/40 bg-zinc-600/25 text-zinc-300',               dot: 'bg-zinc-400' },
  CANCELLED: { label: 'Cancelada',  badge: 'border-destructive/30 bg-destructive/15 text-red-300',       cell: 'border-destructive/40 bg-destructive/10 text-red-300',          dot: 'bg-red-400' },
  NO_SHOW:   { label: 'No-show',    badge: 'border-orange-500/30 bg-orange-500/10 text-orange-300',      cell: 'border-orange-500/40 bg-orange-500/10 text-orange-200',         dot: 'bg-orange-400' },
}

export const RESERVATION_STATUSES = ['PENDING', 'CONFIRMED', 'PAID', 'NO_SHOW', 'CANCELLED']
export const SOURCES = ['RECEPÇÃO', 'WHATSAPP', 'TELEFONE', 'OUTRO']
export const BLOCK_REASONS = ['Manutenção', 'Limpeza', 'Evento interno', 'Interdição', 'Uso próprio', 'Outro']

export function statusMeta(s) { return STATUS_META[s] || STATUS_META.LIVRE }
