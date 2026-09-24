'use client'

import { useState } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/browser'
import { AuthLayout } from '@/app/login/page'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2, ArrowLeft } from 'lucide-react'
import { toast } from 'sonner'

export default function ForgotPasswordPage() {
  const supabase = createClient()
  const [email, setEmail] = useState('')
  const [loading, setLoading] = useState(false)
  const [sent, setSent] = useState(false)

  async function onSubmit(e) {
    e.preventDefault()
    setLoading(true)
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/confirm?next=/reset-password`,
    })
    setLoading(false)
    if (error) { toast.error('Não foi possível enviar o e-mail', { description: error.message }); return }
    setSent(true)
    toast.success('E-mail enviado', { description: 'Confira sua caixa de entrada.' })
  }

  return (
    <AuthLayout>
      <div className="mb-8"><Logo /></div>
      <h1 className="font-display text-2xl font-bold">Recuperar senha</h1>
      <p className="mt-1 text-sm text-muted-foreground">Enviaremos um link para redefinir sua senha.</p>
      {sent ? (
        <div className="mt-8 rounded-lg border border-border bg-card p-5 text-sm text-muted-foreground">
          Se existir uma conta para <span className="text-foreground">{email}</span>, você receberá um e-mail com o link de redefinição.
        </div>
      ) : (
        <form onSubmit={onSubmit} className="mt-8 space-y-4">
          <div className="space-y-2">
            <Label htmlFor="email">E-mail</Label>
            <Input id="email" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="voce@arena.com" />
          </div>
          <Button type="submit" className="w-full" disabled={loading}>
            {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Enviar link
          </Button>
        </form>
      )}
      <Link href="/login" className="mt-6 inline-flex items-center text-sm text-primary hover:underline">
        <ArrowLeft className="mr-1 h-4 w-4" /> Voltar ao login
      </Link>
    </AuthLayout>
  )
}
