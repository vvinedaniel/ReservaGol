'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/browser'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2 } from 'lucide-react'
import { toast } from 'sonner'

export default function LoginPage() {
  const supabase = createClient()
  const router = useRouter()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)

  async function onSubmit(e) {
    e.preventDefault()
    setLoading(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    setLoading(false)
    if (error) { toast.error('Não foi possível entrar', { description: 'Verifique seu e-mail e senha.' }); return }
    toast.success('Bem-vindo de volta!')
    // Give session time to establish before redirecting
    await new Promise(resolve => setTimeout(resolve, 500))
    router.push('/dashboard')
    router.refresh()
  }

  return (
    <AuthLayout>
      <div className="mb-8"><Logo /></div>
      <h1 className="font-display text-2xl font-bold">Entrar na sua conta</h1>
      <p className="mt-1 text-sm text-muted-foreground">Gerencie sua arena com o Reserva Gol.</p>
      <form onSubmit={onSubmit} className="mt-8 space-y-4">
        <div className="space-y-2">
          <Label htmlFor="email">E-mail</Label>
          <Input id="email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="voce@arena.com" />
        </div>
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <Label htmlFor="password">Senha</Label>
            <Link href="/forgot-password" className="text-xs text-primary hover:underline">Esqueceu a senha?</Link>
          </div>
          <Input id="password" type="password" required value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" />
        </div>
        <Button type="submit" className="w-full" disabled={loading}>
          {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Entrar
        </Button>
      </form>
      <p className="mt-6 text-center text-sm text-muted-foreground">
        Não tem conta? <Link href="/register" className="font-medium text-primary hover:underline">Criar conta</Link>
      </p>
    </AuthLayout>
  )
}

export function AuthLayout({ children }) {
  return (
    <div className="grid min-h-screen lg:grid-cols-2">
      <div className="flex items-center justify-center px-6 py-12">
        <div className="w-full max-w-sm">{children}</div>
      </div>
      <div className="relative hidden lg:block">
        <img src="https://images.unsplash.com/photo-1556056504-5c7696c4c28d" alt="Quadra de futebol" className="h-full w-full object-cover" />
        <div className="absolute inset-0 bg-gradient-to-tr from-background via-background/50 to-transparent" />
        <div className="absolute bottom-10 left-10 right-10">
          <p className="font-display text-2xl font-bold text-foreground">Sua arena, no controle total.</p>
          <p className="mt-2 text-sm text-muted-foreground">Reservas, quadras e ocupação em uma plataforma feita para o futebol.</p>
        </div>
      </div>
    </div>
  )
}
