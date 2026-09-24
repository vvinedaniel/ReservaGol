'use client'

import { createContext, useContext, useEffect, useState } from 'react'
import { usePathname, useRouter } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/browser'
import { Logo } from '@/components/reserva/logo'
import { DemoBadge } from '@/components/reserva/demo-badge'
import { can, FEATURES, ROLE_LABELS } from '@/lib/auth/permissions'
import { Button } from '@/components/ui/button'
import { Sheet, SheetContent, SheetTrigger, SheetTitle } from '@/components/ui/sheet'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Skeleton } from '@/components/ui/skeleton'
import { cn } from '@/lib/utils'
import {
  LayoutDashboard, CalendarDays, ClipboardList, LayoutGrid, Users,
  DollarSign, BarChart3, Megaphone, UsersRound, Settings, Menu, LogOut, ChevronDown, Globe, Repeat,
} from 'lucide-react'

const MeContext = createContext(null)
export const useMe = () => useContext(MeContext)

const NAV = [
  { label: 'Visão Geral', href: '/dashboard', icon: LayoutDashboard, feature: FEATURES.DASHBOARD, ready: true },
  { label: 'Agenda', href: '/dashboard/agenda', icon: CalendarDays, feature: FEATURES.AGENDA, ready: true },
  { label: 'Reservas', href: '/dashboard/reservas', icon: ClipboardList, feature: FEATURES.RESERVATIONS, ready: true },
  { label: 'Mensalistas', href: '/dashboard/mensalistas', icon: Repeat, feature: FEATURES.MENSALISTAS, ready: true },
  { label: 'Quadras', href: '/dashboard/quadras', icon: LayoutGrid, feature: FEATURES.COURTS, ready: true },
  { label: 'Perfil da arena', href: '/dashboard/perfil', icon: Globe, feature: FEATURES.SETTINGS_ARENA, ready: true },
  { label: 'Clientes', href: '/dashboard/clientes', icon: Users, feature: FEATURES.CUSTOMERS, ready: false },
  { label: 'Financeiro', href: '/dashboard/financeiro', icon: DollarSign, feature: FEATURES.FINANCE, ready: false },
  { label: 'Relatórios', href: '/dashboard/relatorios', icon: BarChart3, feature: FEATURES.REPORTS, ready: false },
  { label: 'Campanhas', href: '/dashboard/campanhas', icon: Megaphone, feature: FEATURES.CAMPAIGNS, ready: false },
  { label: 'Equipe', href: '/dashboard/equipe', icon: UsersRound, feature: FEATURES.TEAM, ready: false },
  { label: 'Configurações', href: '/dashboard/configuracoes', icon: Settings, feature: FEATURES.SETTINGS_USER, ready: true },
]

function NavLinks({ role, onNavigate }) {
  const pathname = usePathname()
  const items = NAV.filter((i) => can(role, i.feature) || i.feature === FEATURES.SETTINGS_USER)
  return (
    <nav className="flex flex-col gap-1">
      {items.map((item) => {
        const active = pathname === item.href
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            className={cn(
              'group flex items-center justify-between rounded-lg px-3 py-2 text-sm font-medium transition-colors',
              active
                ? 'bg-sidebar-accent text-sidebar-accent-foreground'
                : 'text-sidebar-foreground/70 hover:bg-sidebar-accent/60 hover:text-sidebar-foreground'
            )}
          >
            <span className="flex items-center gap-3">
              <item.icon className={cn('h-4.5 w-4.5', active ? 'text-primary' : 'text-sidebar-foreground/60 group-hover:text-primary')} />
              {item.label}
            </span>
            {!item.ready && (
              <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">Em breve</span>
            )}
          </Link>
        )
      })}
    </nav>
  )
}

function UserMenu({ me }) {
  const supabase = createClient()
  const router = useRouter()
  const email = me?.user?.email || ''
  const name = me?.profile?.full_name || email
  const initials = (name || 'U').split(' ').map((s) => s[0]).slice(0, 2).join('').toUpperCase()
  async function logout() {
    await supabase.auth.signOut()
    router.push('/login')
    router.refresh()
  }
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-accent">
          <Avatar className="h-8 w-8"><AvatarFallback className="bg-primary/15 text-xs text-primary">{initials}</AvatarFallback></Avatar>
          <span className="hidden text-sm font-medium sm:inline">{name}</span>
          <ChevronDown className="h-4 w-4 text-muted-foreground" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-56">
        <DropdownMenuLabel>
          <div className="flex flex-col">
            <span className="text-sm font-medium">{name}</span>
            <span className="text-xs font-normal text-muted-foreground">{ROLE_LABELS[me?.role] || 'Usuário'}</span>
          </div>
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={logout} className="text-destructive focus:text-destructive">
          <LogOut className="mr-2 h-4 w-4" /> Sair
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export function DashboardShell({ children }) {
  const router = useRouter()
  const [me, setMe] = useState(null)
  const [loading, setLoading] = useState(true)
  const [mobileOpen, setMobileOpen] = useState(false)

  useEffect(() => {
    let mounted = true
    fetch('/api/me').then(async (r) => {
      if (r.status === 401) { router.push('/login'); return }
      const data = await r.json()
      if (!mounted) return
      if (data.needsOnboarding) { router.push('/onboarding'); return }
      setMe(data)
      setLoading(false)
    }).catch(() => setLoading(false))
    return () => { mounted = false }
  }, [router])

  if (loading || !me) {
    return (
      <div className="flex min-h-screen">
        <div className="hidden w-64 border-r border-sidebar-border bg-sidebar p-4 lg:block">
          <Skeleton className="h-9 w-32" />
          <div className="mt-8 space-y-2">{Array.from({ length: 8 }).map((_, i) => <Skeleton key={i} className="h-9 w-full" />)}</div>
        </div>
        <div className="flex-1 p-8"><Skeleton className="h-8 w-48" /><div className="mt-6 grid gap-4 sm:grid-cols-4">{Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-28" />)}</div></div>
      </div>
    )
  }

  const SidebarInner = (
    <div className="flex h-full flex-col">
      <div className="px-4 py-5"><Logo /></div>
      <div className="px-3 pb-2">
        <div className="rounded-lg border border-sidebar-border bg-sidebar-accent/40 px-3 py-2">
          <p className="truncate text-sm font-semibold text-sidebar-foreground">{me.activeOrg?.name}</p>
          <p className="text-xs text-muted-foreground">Organização</p>
        </div>
      </div>
      <div className="flex-1 overflow-y-auto px-3 py-2"><NavLinks role={me.role} onNavigate={() => setMobileOpen(false)} /></div>
      {me.activeOrg?.is_demo && <div className="px-4 py-3"><DemoBadge /></div>}
    </div>
  )

  return (
    <MeContext.Provider value={me}>
      <div className="flex min-h-screen bg-background">
        <aside className="fixed inset-y-0 left-0 hidden w-64 border-r border-sidebar-border bg-sidebar lg:block">{SidebarInner}</aside>
        <div className="flex min-h-screen w-full flex-col lg:pl-64">
          <header className="sticky top-0 z-20 flex h-16 items-center justify-between border-b border-border bg-background/80 px-4 backdrop-blur lg:px-8">
            <div className="flex items-center gap-3">
              <Sheet open={mobileOpen} onOpenChange={setMobileOpen}>
                <SheetTrigger asChild>
                  <Button variant="outline" size="icon" className="lg:hidden"><Menu className="h-5 w-5" /></Button>
                </SheetTrigger>
                <SheetContent side="left" className="w-72 border-sidebar-border bg-sidebar p-0">
                  <SheetTitle className="sr-only">Menu</SheetTitle>
                  {SidebarInner}
                </SheetContent>
              </Sheet>
              <Logo className="lg:hidden" showText={false} />
            </div>
            <UserMenu me={me} />
          </header>
          <main className="flex-1 p-4 lg:p-8">{children}</main>
        </div>
      </div>
    </MeContext.Provider>
  )
}
