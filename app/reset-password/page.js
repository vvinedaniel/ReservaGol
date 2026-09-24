'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/browser'
import { AuthLayout } from '@/app/login/page'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2 } from 'lucide-react'
import { toast } from 'sonner'

export default function ResetPasswordPage() {
  const supabase = createClient()
  const router = useRouter()
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)

  async function onSubmit(e) {
    e.preventDefault()
    if (password.length < 6) { toast.error('A senha deve ter ao menos 6 caracteres'); return }
    setLoading(true)
    const { error } = await supabase.auth.updateUser({ password })
    setLoading(false)
    if (error) { toast.error('Não foi possível atualizar a senha', { description: error.message }); return }
    toast.success('Senha atualizada!')
    router.push('/dashboard')
  }

  return (
    <AuthLayout>
      <div className="mb-8"><Logo /></div>
      <h1 className="font-display text-2xl font-bold">Definir nova senha</h1>
      <p className="mt-1 text-sm text-muted-foreground">Escolha uma nova senha para sua conta.</p>
      <form onSubmit={onSubmit} className="mt-8 space-y-4">
        <div className="space-y-2">
          <Label htmlFor="password">Nova senha</Label>
          <Input id="password" type="password" required value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Mínimo 6 caracteres" />
        </div>
        <Button type="submit" className="w-full" disabled={loading}>
          {loading && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar nova senha
        </Button>
      </form>
    </AuthLayout>
  )
}
