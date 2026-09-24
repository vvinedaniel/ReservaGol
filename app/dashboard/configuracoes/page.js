'use client'

import { useEffect, useState, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { useMe } from '@/components/reserva/dashboard-shell'
import { createClient } from '@/lib/supabase/browser'
import { isOwnerOrAbove, ROLE_LABELS } from '@/lib/auth/permissions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Switch } from '@/components/ui/switch'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Loader2, LogOut } from 'lucide-react'
import { toast } from 'sonner'

const WEEK = [
  { wd: 1, label: 'Segunda' }, { wd: 2, label: 'Terça' }, { wd: 3, label: 'Quarta' },
  { wd: 4, label: 'Quinta' }, { wd: 5, label: 'Sexta' }, { wd: 6, label: 'Sábado' }, { wd: 0, label: 'Domingo' },
]

export default function SettingsPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const canOrg = isOwnerOrAbove(me?.role)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="font-display text-2xl font-bold">Configurações</h1>
        <p className="mt-1 text-sm text-muted-foreground">Gerencie os dados da sua organização, arenas e conta.</p>
      </div>
      <Tabs defaultValue="org">
        <TabsList className="flex-wrap">
          <TabsTrigger value="org">Organização</TabsTrigger>
          <TabsTrigger value="arena">Arena</TabsTrigger>
          <TabsTrigger value="hours">Horários</TabsTrigger>
          <TabsTrigger value="user">Usuário</TabsTrigger>
        </TabsList>
        <TabsContent value="org" className="mt-6"><OrgTab orgId={orgId} canEdit={canOrg} /></TabsContent>
        <TabsContent value="arena" className="mt-6"><ArenaTab orgId={orgId} /></TabsContent>
        <TabsContent value="hours" className="mt-6"><HoursTab orgId={orgId} /></TabsContent>
        <TabsContent value="user" className="mt-6"><UserTab me={me} /></TabsContent>
      </Tabs>
    </div>
  )
}

function OrgTab({ orgId, canEdit }) {
  const [org, setOrg] = useState(null)
  const [saving, setSaving] = useState(false)
  useEffect(() => {
    if (!orgId) return
    fetch(`/api/organization?organization_id=${orgId}`).then((r) => r.json()).then(setOrg)
  }, [orgId])
  if (!org) return <Card><CardContent className="p-6 text-sm text-muted-foreground">Carregando...</CardContent></Card>
  const set = (k) => (e) => setOrg((s) => ({ ...s, [k]: e.target.value }))
  async function save() {
    setSaving(true)
    const res = await fetch('/api/organization', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ organization_id: orgId, name: org.name, owner_name: org.owner_name, phone: org.phone, email: org.email, default_reservation_minutes: Number(org.default_reservation_minutes) }) })
    setSaving(false)
    if (!res.ok) { toast.error('Não foi possível salvar'); return }
    toast.success('Organização atualizada')
  }
  return (
    <Card>
      <CardHeader><CardTitle>Dados da organização</CardTitle><CardDescription>Informações gerais da empresa.</CardDescription></CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2"><Label>Nome</Label><Input value={org.name || ''} onChange={set('name')} disabled={!canEdit} /></div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2"><Label>Responsável</Label><Input value={org.owner_name || ''} onChange={set('owner_name')} disabled={!canEdit} /></div>
          <div className="space-y-2"><Label>Telefone</Label><Input value={org.phone || ''} onChange={set('phone')} disabled={!canEdit} /></div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2"><Label>E-mail</Label><Input value={org.email || ''} onChange={set('email')} disabled={!canEdit} /></div>
          <div className="space-y-2">
            <Label>Duração padrão da reserva</Label>
            <Select value={String(org.default_reservation_minutes || 60)} onValueChange={(v) => setOrg((s) => ({ ...s, default_reservation_minutes: v }))} disabled={!canEdit}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{['30', '60', '90', '120'].map((m) => <SelectItem key={m} value={m}>{m} minutos</SelectItem>)}</SelectContent>
            </Select>
          </div>
        </div>
        {canEdit && <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar alterações</Button>}
      </CardContent>
    </Card>
  )
}

function ArenaTab({ orgId }) {
  const [arenas, setArenas] = useState([])
  const [sel, setSel] = useState(null)
  const [saving, setSaving] = useState(false)
  const load = useCallback(async () => {
    if (!orgId) return
    const a = await fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json())
    setArenas(Array.isArray(a) ? a : [])
    setSel((prev) => prev || (a[0] || null))
  }, [orgId])
  useEffect(() => { load() }, [load])
  if (!sel) return <Card><CardContent className="p-6 text-sm text-muted-foreground">Carregando...</CardContent></Card>
  const set = (k) => (e) => setSel((s) => ({ ...s, [k]: e.target.value }))
  async function save() {
    setSaving(true)
    const res = await fetch(`/api/arenas/${sel.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(sel) })
    setSaving(false)
    if (!res.ok) { toast.error('Não foi possível salvar'); return }
    toast.success('Arena atualizada')
    load()
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle>Dados da unidade</CardTitle>
        <CardDescription>Endereço e contato da arena.</CardDescription>
        {arenas.length > 1 && (
          <div className="pt-2">
            <Select value={sel.id} onValueChange={(v) => setSel(arenas.find((a) => a.id === v))}>
              <SelectTrigger className="w-full sm:w-72"><SelectValue /></SelectTrigger>
              <SelectContent>{arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        )}
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2"><Label>Nome da arena</Label><Input value={sel.name || ''} onChange={set('name')} /></div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2"><Label>CEP</Label><Input value={sel.postal_code || ''} onChange={set('postal_code')} /></div>
          <div className="space-y-2 sm:col-span-2"><Label>Endereço</Label><Input value={sel.address || ''} onChange={set('address')} /></div>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2"><Label>Número</Label><Input value={sel.number || ''} onChange={set('number')} /></div>
          <div className="space-y-2"><Label>Complemento</Label><Input value={sel.complement || ''} onChange={set('complement')} /></div>
          <div className="space-y-2"><Label>Bairro</Label><Input value={sel.neighborhood || ''} onChange={set('neighborhood')} /></div>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-2 sm:col-span-2"><Label>Cidade</Label><Input value={sel.city || ''} onChange={set('city')} /></div>
          <div className="space-y-2"><Label>Estado</Label><Input value={sel.state || ''} onChange={set('state')} /></div>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2"><Label>WhatsApp</Label><Input value={sel.whatsapp || ''} onChange={set('whatsapp')} /></div>
          <div className="space-y-2"><Label>Telefone</Label><Input value={sel.phone || ''} onChange={set('phone')} /></div>
        </div>
        <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar alterações</Button>
      </CardContent>
    </Card>
  )
}

function HoursTab({ orgId }) {
  const [arenas, setArenas] = useState([])
  const [arenaId, setArenaId] = useState('')
  const [hours, setHours] = useState([])
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!orgId) return
    fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json()).then((a) => {
      const list = Array.isArray(a) ? a : []
      setArenas(list); setArenaId((prev) => prev || list[0]?.id || '')
    })
  }, [orgId])

  useEffect(() => {
    if (!arenaId) return
    fetch(`/api/business-hours?arena_id=${arenaId}`).then((r) => r.json()).then((h) => {
      const byDay = {}; (Array.isArray(h) ? h : []).forEach((x) => { byDay[x.weekday] = x })
      setHours(WEEK.map((w) => byDay[w.wd] || { weekday: w.wd, open_time: '08:00', close_time: '23:00', closed: false }))
    })
  }, [arenaId])

  function upd(wd, k, v) { setHours((h) => h.map((r) => r.weekday === wd ? { ...r, [k]: v } : r)) }
  async function save() {
    setSaving(true)
    const res = await fetch('/api/business-hours', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ organization_id: orgId, arena_id: arenaId, hours }) })
    setSaving(false)
    if (!res.ok) { toast.error('Não foi possível salvar'); return }
    toast.success('Horários atualizados')
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle>Horário de funcionamento</CardTitle>
        <CardDescription>Defina os horários por dia da semana.</CardDescription>
        {arenas.length > 1 && (
          <div className="pt-2">
            <Select value={arenaId} onValueChange={setArenaId}>
              <SelectTrigger className="w-full sm:w-72"><SelectValue /></SelectTrigger>
              <SelectContent>{arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        )}
      </CardHeader>
      <CardContent className="space-y-3">
        {WEEK.map((w) => {
          const h = hours.find((x) => x.weekday === w.wd)
          if (!h) return null
          return (
            <div key={w.wd} className="flex flex-wrap items-center gap-3 rounded-lg border border-border p-3">
              <span className="w-20 text-sm font-medium">{w.label}</span>
              <Switch checked={!h.closed} onCheckedChange={(v) => upd(w.wd, 'closed', !v)} />
              {h.closed ? <span className="text-sm text-muted-foreground">Fechado</span> : (
                <div className="flex items-center gap-2">
                  <Input type="time" value={h.open_time || ''} onChange={(e) => upd(w.wd, 'open_time', e.target.value)} className="w-32" />
                  <span className="text-muted-foreground">até</span>
                  <Input type="time" value={h.close_time || ''} onChange={(e) => upd(w.wd, 'close_time', e.target.value)} className="w-32" />
                </div>
              )}
            </div>
          )
        })}
        <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar horários</Button>
      </CardContent>
    </Card>
  )
}

function UserTab({ me }) {
  const supabase = createClient()
  const router = useRouter()
  async function logout() { await supabase.auth.signOut(); router.push('/login'); router.refresh() }
  return (
    <Card>
      <CardHeader><CardTitle>Sua conta</CardTitle><CardDescription>Dados do seu usuário.</CardDescription></CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2"><Label>Nome</Label><Input defaultValue={me?.profile?.full_name || ''} disabled /></div>
        <div className="space-y-2"><Label>E-mail</Label><Input defaultValue={me?.user?.email || ''} disabled /></div>
        <div className="space-y-2"><Label>Função</Label><Input defaultValue={ROLE_LABELS[me?.role] || ''} disabled /></div>
        <Button variant="destructive" onClick={logout}><LogOut className="mr-2 h-4 w-4" /> Sair da conta</Button>
      </CardContent>
    </Card>
  )
}
