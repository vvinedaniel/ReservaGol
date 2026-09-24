import Link from 'next/link'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { CalendarClock, ShieldCheck, LayoutDashboard, MapPin, Users, BarChart3, ArrowRight } from 'lucide-react'

const FEATURES = [
  { icon: CalendarClock, title: 'Agenda inteligente', desc: 'Controle horários e reservas por quadra, sem risco de reserva dupla.' },
  { icon: LayoutDashboard, title: 'Dashboard em tempo real', desc: 'Ocupação, receita e ticket médio consolidados em um só lugar.' },
  { icon: ShieldCheck, title: 'Multiempresa e seguro', desc: 'Cada arena com dados isolados e protegidos de ponta a ponta.' },
  { icon: Users, title: 'Equipe e permissões', desc: 'Proprietário, gerente e recepção com acessos adequados a cada função.' },
  { icon: MapPin, title: 'Várias unidades', desc: 'Gerencie uma ou várias unidades da mesma organização com facilidade.' },
  { icon: BarChart3, title: 'Relatórios', desc: 'Acompanhe o desempenho da arena com gráficos claros e objetivos.' },
]

export default function LandingPage() {
  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-30 border-b border-border/60 bg-background/80 backdrop-blur">
        <div className="container flex h-16 items-center justify-between">
          <>
            <Logo size="lg" className="hidden sm:flex" />
            <Logo size="md" showText={false} className="sm:hidden" />
          </>
          <div className="flex items-center gap-2">
            <Button asChild variant="ghost" className="hidden sm:inline-flex"><Link href="/jogar">Reservar quadra</Link></Button>
            <Button asChild variant="ghost"><Link href="/login">Entrar</Link></Button>
            <Button asChild><Link href="/register">Criar conta</Link></Button>
          </div>
        </div>
      </header>

      <section className="relative overflow-hidden">
        <div className="absolute inset-0">
          <img src="https://images.unsplash.com/photo-1517747614396-d21a78b850e8" alt="Arena de futebol" className="h-full w-full object-cover opacity-40" />
          <div className="absolute inset-0 bg-gradient-to-r from-background via-background/80 to-background/40" />
          <div className="absolute inset-0 bg-gradient-to-b from-transparent via-transparent to-background" />
        </div>
        <div className="container relative py-24 md:py-32">
          <div className="max-w-2xl">
            <span className="inline-flex items-center rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
              Gestão para arenas e quadras de futebol
            </span>
            <h1 className="mt-6 font-display text-4xl font-extrabold leading-tight text-foreground md:text-6xl">
              Gestão da sua <span className="text-primary">arena</span>, das reservas ao financeiro.
            </h1>
            <p className="mt-6 max-w-xl text-lg text-muted-foreground">
              Organize agenda, reservas, clientes, financeiro e ocupação em um só lugar.
            </p>
            <div className="mt-8 flex flex-col flex-wrap gap-3 sm:flex-row">
              <Button asChild size="lg" className="w-full sm:w-auto">
                <Link href="/register">Quero testar o Reserva Gol <ArrowRight className="ml-2 h-4 w-4" /></Link>
              </Button>
              <Button asChild size="lg" variant="outline" className="w-full sm:w-auto">
                <Link href="#recursos">Conhecer a plataforma</Link>
              </Button>
            </div>
          </div>
        </div>
      </section>

      <section className="border-y border-border/60 bg-card/30">
        <div className="container flex flex-wrap items-center justify-center gap-y-1 py-4 text-xs font-medium uppercase tracking-wide text-muted-foreground sm:text-sm">
          {['Agenda', 'Reservas', 'Clientes', 'Financeiro', 'Relatórios'].map((p, i) => (
            <span key={p} className="flex items-center">
              {i > 0 && <span className="mx-3 text-primary sm:mx-4" aria-hidden>•</span>}
              <span>{p}</span>
            </span>
          ))}
        </div>
      </section>

      <section id="recursos" className="container py-20">
        <div className="mx-auto max-w-2xl text-center">
          <h2 className="font-display text-3xl font-bold">Tudo que a arena precisa</h2>
          <p className="mt-3 text-muted-foreground">Uma base profissional e escalável para crescer com o seu negócio.</p>
        </div>
        <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f) => (
            <div key={f.title} className="rounded-xl border border-border bg-card p-6">
              <div className="flex h-11 w-11 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <f.icon className="h-5 w-5" />
              </div>
              <h3 className="mt-4 font-display text-lg font-semibold">{f.title}</h3>
              <p className="mt-2 text-sm text-muted-foreground">{f.desc}</p>
            </div>
          ))}
        </div>
      </section>

      <footer className="border-t border-border/60">
        <div className="container flex flex-col items-center justify-between gap-4 py-8 sm:flex-row">
          <Logo size="sm" />
          <p className="text-sm text-muted-foreground">© {new Date().getFullYear()} Reserva Gol. Todos os direitos reservados.</p>
        </div>
      </footer>
    </div>
  )
}
