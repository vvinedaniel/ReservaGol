import { Construction } from 'lucide-react'

export function ComingSoon({ title, description }) {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="font-display text-2xl font-bold text-foreground">{title}</h1>
        <p className="mt-1 text-sm text-muted-foreground">{description}</p>
      </div>
      <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-border bg-card/40 px-6 py-20 text-center">
        <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-full bg-primary/10 text-primary">
          <Construction className="h-7 w-7" />
        </div>
        <h3 className="font-display text-lg font-semibold">Recurso em desenvolvimento</h3>
        <p className="mt-2 max-w-md text-sm text-muted-foreground">
          Este módulo fará parte das próximas fases do Reserva Gol. A estrutura já
          está preparada — em breve estará disponível por aqui.
        </p>
        <span className="mt-4 inline-flex items-center rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
          Em breve
        </span>
      </div>
    </div>
  )
}
