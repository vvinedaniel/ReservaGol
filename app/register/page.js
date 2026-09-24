'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/browser'
import { AuthLayout } from '@/app/login/page'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2 } from 'lucide-react'
import { toast } from 'sonner'

export default function RegisterPage() {
  const supabase = createClient()
  const router = useRouter()
  const [form, setForm] = useState({ full_name: '', email: '', phone: '', password: '' })
  const [loading, setLoading] = useState(false)
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onSubmit(e) {
    e.preventDefault()
    if (form.password.length < 6) { toast.error('A senha deve ter ao menos 6 caracteres'); return }
    setLoading(true)
    const { data, error } = await supabase.auth.signUp({
      email: form.email,
      password: form.password,
      options: { data: { full_name: form.full_name, phone: form.phone } },
    })
    if (error) { setLoading(false); toast.error('Não foi possível criar a conta', { description: error.message }); return }

    // Email confirmation is disabled for this phase => session is active immediately.
    if (!data.session) {
      const { error: signInErr } = await supabase.auth.signInWithPassword({ email: form.email, password: form.password })
      if (signInErr) { setLoading(false); toast.success('Conta criada!', { description: 'Faça login para continuar.' }); router.push('/login'); return }
    }
    setLoading(false)
    toast.success('Conta criada com sucesso!')
    // Give session time to establish before redirecting
    await new Promise(resolve => setTimeout(resolve, 500))
    router.push('/onboarding')
    router.refresh()
  }

  return (
    <AuthLayout>
      <div className="mb-8"><Logo /></div>
      <h1 className="font-display text-2xl font-bold">Criar sua conta</h1>
      <p className="mt-1 text-sm text-muted-foreground">Cadastre sua arena em poucos minutos.</p>
      <form onSubmit={onSubmit} className="mt-8 space-y-4">
        <div className="space-y-2">
          <Label htmlFor="full_name">Nome do responsável</Label>
          <Input id="full_name" required value={form.full_name} onChange={set('full_name')} placeholder="Seu nome" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="email">E-mail</Label>
          <Input id="email" type="email" required value={form.email} onChange={set('email')} placeholder="voce@arena.com" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="phone">Telefone</Label>
          <Input id="phone" value={form.phone} onChange={set('phone')} placeholder="(11) 99999-9999" />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Senha</Label>
          <Input id="password" type="password" required value={form.password} onChange={set('password')} placeholder="Mínimo 6 caracteres" />
        </div>
        <Button type="submit" className="w-full" disabled={loading}>
          {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Criar conta
        </Button>
      </form>
      <p className="mt-6 text-center text-sm text-muted-foreground">
        Já tem conta? <Link href="/login" className="font-medium text-primary hover:underline">Entrar</Link>
      </p>
    </AuthLayout>
  )
}
