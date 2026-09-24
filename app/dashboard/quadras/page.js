'use client'

import { useEffect, useState, useCallback } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { EmptyState } from '@/components/reserva/empty-state'
import { isManagerOrAbove } from '@/lib/auth/permissions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Switch } from '@/components/ui/switch'
import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { LayoutGrid, Plus, Pencil, Loader2 } from 'lucide-react'
import { toast } from 'sonner'

const COURT_TYPES = ['Society', 'Futsal', 'Campo', 'Beach', 'Outra']

export default function CourtsPage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const canEdit = isManagerOrAbove(me?.role)
  const [arenas, setArenas] = useState([])
  const [courts, setCourts] = useState([])
  const [loading, setLoading] = useState(true)
  const [open, setOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [editing, setEditing] = useState(null)
  const [form, setForm] = useState({ name: '', arena_id: '', type: 'Society', description: '', active: true })

  const load = useCallback(async () => {
    if (!orgId) return
    setLoading(true)
    const [aRes, cRes] = await Promise.all([
      fetch(`/api/arenas?organization_id=${orgId}`),
      fetch(`/api/courts?organization_id=${orgId}`),
    ])
    const a = await aRes.json(); const c = await cRes.json()
    setArenas(Array.isArray(a) ? a : [])
    setCourts(Array.isArray(c) ? c : [])
    setLoading(false)
  }, [orgId])

  useEffect(() => { load() }, [load])

  function openNew() {
    setEditing(null)
    setForm({ name: '', arena_id: arenas[0]?.id || '', type: 'Society', description: '', active: true })
    setOpen(true)
  }
  function openEdit(court) {
    setEditing(court)
    setForm({ name: court.name, arena_id: court.arena_id, type: court.type || 'Society', description: court.description || '', active: court.active })
    setOpen(true)
  }

  async function save() {
    if (!form.name.trim()) { toast.error('Informe o nome da quadra'); return }
    if (!form.arena_id) { toast.error('Selecione a arena'); return }
    setSaving(true)
    let res
    if (editing) {
      res = await fetch(`/api/courts/${editing.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: form.name, type: form.type, description: form.description, active: form.active }) })
    } else {
      res = await fetch('/api/courts', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...form, organization_id: orgId }) })
    }
    setSaving(false)
    if (!res.ok) { const e = await res.json().catch(() => ({})); toast.error('Não foi possível salvar', { description: e.error }); return }
    toast.success(editing ? 'Quadra atualizada' : 'Quadra criada')
    setOpen(false)
    load()
  }

  async function toggleActive(court) {
    const res = await fetch(`/api/courts/${court.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ active: !court.active }) })
    if (!res.ok) { toast.error('Não foi possível atualizar'); return }
    toast.success(court.active ? 'Quadra desativada' : 'Quadra ativada')
    load()
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-display text-2xl font-bold">Quadras</h1>
          <p className="mt-1 text-sm text-muted-foreground">Gerencie as quadras das suas unidades.</p>
        </div>
        {canEdit && <Button onClick={openNew} disabled={!arenas.length}><Plus className="mr-2 h-4 w-4" /> Adicionar quadra</Button>}
      </div>

      {loading ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">{Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-40" />)}</div>
      ) : courts.length === 0 ? (
        <EmptyState icon={LayoutGrid} title="Nenhuma quadra cadastrada" description="Adicione a primeira quadra da sua arena para começar." action={canEdit && arenas.length ? <Button onClick={openNew}><Plus className="mr-2 h-4 w-4" /> Adicionar quadra</Button> : null} />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {courts.map((court) => (
            <Card key={court.id} className={court.active ? '' : 'opacity-60'}>
              <CardContent className="p-5">
                <div className="flex items-start justify-between">
                  <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary"><LayoutGrid className="h-5 w-5" /></div>
                  <Badge variant={court.active ? 'default' : 'secondary'} className={court.active ? 'bg-primary/15 text-primary hover:bg-primary/15' : ''}>{court.active ? 'Ativa' : 'Inativa'}</Badge>
                </div>
                <h3 className="mt-4 font-display text-lg font-semibold">{court.name}</h3>
                <p className="text-sm text-muted-foreground">{court.type || 'Sem tipo'} · {court.arena?.name || 'Arena'}</p>
                {court.description && <p className="mt-2 line-clamp-2 text-sm text-muted-foreground">{court.description}</p>}
                {canEdit && (
                  <div className="mt-4 flex items-center gap-2">
                    <Button variant="outline" size="sm" onClick={() => openEdit(court)}><Pencil className="mr-1.5 h-3.5 w-3.5" /> Editar</Button>
                    <div className="ml-auto flex items-center gap-2"><span className="text-xs text-muted-foreground">Ativa</span><Switch checked={court.active} onCheckedChange={() => toggleActive(court)} /></div>
                  </div>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader><DialogTitle>{editing ? 'Editar quadra' : 'Nova quadra'}</DialogTitle></DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2"><Label>Nome</Label><Input value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} placeholder="Society 01" /></div>
            <div className="space-y-2">
              <Label>Arena / Unidade</Label>
              <Select value={form.arena_id} onValueChange={(v) => setForm((f) => ({ ...f, arena_id: v }))} disabled={!!editing}>
                <SelectTrigger><SelectValue placeholder="Selecione a arena" /></SelectTrigger>
                <SelectContent>{arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>Tipo de quadra</Label>
              <Select value={form.type} onValueChange={(v) => setForm((f) => ({ ...f, type: v }))}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{COURT_TYPES.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-2"><Label>Descrição curta</Label><Input value={form.description} onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))} placeholder="Grama sintética, cobertura..." /></div>
            <div className="flex items-center gap-2"><Switch checked={form.active} onCheckedChange={(v) => setForm((f) => ({ ...f, active: v }))} /><span className="text-sm">{form.active ? 'Ativa' : 'Inativa'}</span></div>
          </div>
          <DialogFooter>
            <Button variant="ghost" onClick={() => setOpen(false)}>Cancelar</Button>
            <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
