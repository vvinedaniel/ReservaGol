'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import { useMe } from '@/components/reserva/dashboard-shell'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import { Switch } from '@/components/ui/switch'
import { Progress } from '@/components/ui/progress'
import { Skeleton } from '@/components/ui/skeleton'
import { Separator } from '@/components/ui/separator'
import { toast } from 'sonner'
import {
  Globe, Eye, ImagePlus, Loader2, Check, X, ExternalLink, Upload,
  CheckCircle2, AlertCircle, MapPin, MessageCircle, Trash2, Link2,
} from 'lucide-react'

const AMENITY_SUGGESTIONS = ['Estacionamento', 'Vestiário', 'Chuveiro', 'Bar / Lanchonete', 'Wi-Fi', 'Cobertura', 'Iluminação', 'Aluguel de material', 'Acessibilidade']
const REQUIRED_TOTAL = 8

export default function ArenaProfilePage() {
  const me = useMe()
  const orgId = me?.activeOrg?.id
  const [arena, setArena] = useState(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [check, setCheck] = useState(null)
  const [form, setForm] = useState(null)
  const [amenityInput, setAmenityInput] = useState('')
  const coverRef = useRef(null)
  const galleryRef = useRef(null)
  const [uploading, setUploading] = useState('')

  const load = async (arenaId) => {
    const chk = await fetch(`/api/arenas/${arenaId}/publish-check`).then((r) => r.json()).catch(() => null)
    setCheck(chk)
  }

  useEffect(() => {
    if (!orgId) return
    ;(async () => {
      setLoading(true)
      const arenas = await fetch(`/api/arenas?organization_id=${orgId}`).then((r) => r.json()).catch(() => [])
      const a = Array.isArray(arenas) ? arenas[0] : null
      setArena(a)
      if (a) {
        setForm({
          slug: a.slug || '', description: a.description || '', whatsapp: a.whatsapp || '',
          address: a.address || '', number: a.number || '', neighborhood: a.neighborhood || '',
          city: a.city || '', state: a.state || '', booking_rules: a.booking_rules || '',
          amenities: Array.isArray(a.amenities) ? a.amenities : [],
        })
        await load(a.id)
      }
      setLoading(false)
    })()
  }, [orgId])

  const pct = useMemo(() => {
    if (!check) return 0
    return Math.round(((REQUIRED_TOTAL - (check.missing?.length || 0)) / REQUIRED_TOTAL) * 100)
  }, [check])

  const suggestedSlug = useMemo(() => {
    return (form?.slug || arena?.name || '').toString().normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
  }, [form?.slug, arena?.name])

  if (loading || !form) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-8 w-56" />
        <div className="grid gap-6 lg:grid-cols-3">
          <Skeleton className="h-64 lg:col-span-2" />
          <Skeleton className="h-64" />
        </div>
      </div>
    )
  }

  if (!arena) {
    return (
      <Card><CardContent className="py-12 text-center">
        <Globe className="mx-auto h-10 w-10 text-muted-foreground" />
        <p className="mt-3 font-medium">Nenhuma arena encontrada</p>
        <p className="text-sm text-muted-foreground">Complete o onboarding para criar sua arena.</p>
      </CardContent></Card>
    )
  }

  const setF = (k, v) => setForm((s) => ({ ...s, [k]: v }))

  async function save() {
    setSaving(true)
    const payload = { ...form, slug: suggestedSlug }
    const r = await fetch(`/api/arenas/${arena.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
    const d = await r.json().catch(() => ({}))
    setSaving(false)
    if (r.status === 409) { toast.error('Link em uso', { description: d.error }); return }
    if (!r.ok) { toast.error('Não foi possível salvar', { description: d.error }); return }
    setArena(d)
    setF('slug', d.slug || '')
    await load(arena.id)
    toast.success('Perfil atualizado')
  }

  async function upload(kind, fileList) {
    const files = Array.from(fileList || [])
    if (!files.length) return
    setUploading(kind)
    const fd = new FormData()
    fd.set('kind', kind)
    if (kind === 'cover') fd.set('file', files[0])
    else files.forEach((f) => fd.append('files', f))
    const r = await fetch(`/api/arenas/${arena.id}/images`, { method: 'POST', body: fd })
    const d = await r.json().catch(() => ({}))
    setUploading('')
    if (!r.ok) { toast.error('Falha no upload', { description: d.error }); return }
    setArena(d.arena)
    await load(arena.id)
    toast.success(kind === 'cover' ? 'Capa atualizada' : 'Fotos adicionadas')
  }

  async function removePhoto(url) {
    const next = (arena.photos || []).filter((p) => p !== url)
    const r = await fetch(`/api/arenas/${arena.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ photos: next }) })
    const d = await r.json().catch(() => ({}))
    if (!r.ok) { toast.error('Não foi possível remover'); return }
    setArena(d)
    toast.success('Foto removida')
  }

  async function togglePublish() {
    const next = !arena.public_booking_enabled
    setPublishing(true)
    // Salva o rascunho atual antes de publicar para garantir consistência
    if (next) await fetch(`/api/arenas/${arena.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...form, slug: suggestedSlug }) })
    const r = await fetch(`/api/arenas/${arena.id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ public_booking_enabled: next }) })
    const d = await r.json().catch(() => ({}))
    setPublishing(false)
    if (r.status === 400 && d.missing) { toast.error('Complete o perfil antes de publicar', { description: d.missing.join(' · ') }); await load(arena.id); return }
    if (!r.ok) { toast.error('Não foi possível atualizar', { description: d.error }); return }
    setArena(d)
    await load(arena.id)
    toast.success(next ? 'Arena publicada!' : 'Publicação pausada')
  }

  const published = !!arena.public_booking_enabled
  const publicUrl = arena.slug ? `/jogar/${arena.slug}` : null

  const CHECKLIST = [
    { label: 'Nome da arena', ok: !check?.missing?.includes('Nome da arena') },
    { label: 'Link público (slug)', ok: !check?.missing?.includes('Link público (slug)') },
    { label: 'Endereço', ok: !check?.missing?.includes('Endereço') },
    { label: 'Cidade', ok: !check?.missing?.includes('Cidade') },
    { label: 'WhatsApp', ok: !check?.missing?.includes('WhatsApp') },
    { label: 'Imagem de capa', ok: !check?.missing?.includes('Imagem de capa') },
    { label: 'Ao menos 1 quadra ativa', ok: !check?.missing?.includes('Ao menos 1 quadra ativa') },
    { label: 'Ao menos 1 dia com horário aberto', ok: !check?.missing?.includes('Ao menos 1 dia com horário aberto') },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-display text-2xl font-bold">Perfil da arena</h1>
          <p className="mt-1 text-sm text-muted-foreground">Página pública para os jogadores descobrirem e reservarem sua arena.</p>
        </div>
        <div className="flex items-center gap-2">
          {publicUrl && <Button asChild variant="outline" size="sm"><a href={publicUrl} target="_blank" rel="noreferrer"><Eye className="mr-2 h-4 w-4" /> Ver como jogador</a></Button>}
          <Button size="sm" onClick={togglePublish} disabled={publishing || (!published && !check?.canPublish)} variant={published ? 'outline' : 'default'}>
            {publishing ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Globe className="mr-2 h-4 w-4" />}
            {published ? 'Pausar publicação' : 'Publicar arena'}
          </Button>
        </div>
      </div>

      {/* Status + progresso */}
      <Card>
        <CardContent className="flex flex-wrap items-center justify-between gap-4 py-5">
          <div className="min-w-[220px] flex-1">
            <div className="flex items-center gap-2">
              <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${published ? 'bg-primary/15 text-primary' : 'bg-muted text-muted-foreground'}`}>
                <span className={`h-1.5 w-1.5 rounded-full ${published ? 'bg-primary' : 'bg-muted-foreground'}`} />
                {published ? 'Publicada' : 'Não publicada'}
              </span>
              <span className="text-sm font-medium">Perfil da arena — {pct}% concluído</span>
            </div>
            <Progress value={pct} className="mt-3 h-2" />
          </div>
          {publicUrl && (
            <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm">
              <Link2 className="h-4 w-4 text-muted-foreground" />
              <span className="text-muted-foreground">reservagol.com{publicUrl}</span>
            </div>
          )}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          {/* Imagens */}
          <Card>
            <CardHeader><CardTitle className="text-base">Imagens</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <div>
                <Label className="text-xs text-muted-foreground">Capa (aparece no topo da página pública)</Label>
                <div className="mt-2 overflow-hidden rounded-xl border border-border bg-muted">
                  <div className="relative aspect-[16/7] w-full">
                    {arena.cover_image_url
                      ? <img src={arena.cover_image_url} alt="Capa" className="h-full w-full object-cover" />
                      : <div className="flex h-full w-full items-center justify-center text-muted-foreground"><ImagePlus className="h-8 w-8" /></div>}
                  </div>
                </div>
                <input ref={coverRef} type="file" accept="image/jpeg,image/png,image/webp" className="hidden" onChange={(e) => upload('cover', e.target.files)} />
                <Button variant="outline" size="sm" className="mt-2" onClick={() => coverRef.current?.click()} disabled={uploading === 'cover'}>
                  {uploading === 'cover' ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Upload className="mr-2 h-4 w-4" />}
                  {arena.cover_image_url ? 'Trocar capa' : 'Enviar capa'}
                </Button>
              </div>
              <Separator />
              <div>
                <Label className="text-xs text-muted-foreground">Galeria (até 12 fotos)</Label>
                <div className="mt-2 grid grid-cols-3 gap-2 sm:grid-cols-4">
                  {(arena.photos || []).map((p) => (
                    <div key={p} className="group relative aspect-square overflow-hidden rounded-lg border border-border">
                      <img src={p} alt="Foto" className="h-full w-full object-cover" />
                      <button onClick={() => removePhoto(p)} className="absolute right-1 top-1 rounded-md bg-background/80 p-1 opacity-0 transition-opacity group-hover:opacity-100" aria-label="Remover">
                        <Trash2 className="h-3.5 w-3.5 text-destructive" />
                      </button>
                    </div>
                  ))}
                  <button onClick={() => galleryRef.current?.click()} disabled={uploading === 'gallery' || (arena.photos || []).length >= 12} className="flex aspect-square items-center justify-center rounded-lg border border-dashed border-border text-muted-foreground hover:border-primary/50 hover:text-primary disabled:opacity-50">
                    {uploading === 'gallery' ? <Loader2 className="h-5 w-5 animate-spin" /> : <ImagePlus className="h-5 w-5" />}
                  </button>
                </div>
                <input ref={galleryRef} type="file" accept="image/jpeg,image/png,image/webp" multiple className="hidden" onChange={(e) => upload('gallery', e.target.files)} />
              </div>
            </CardContent>
          </Card>

          {/* Sobre + link */}
          <Card>
            <CardHeader><CardTitle className="text-base">Sobre a arena</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-1.5">
                <Label>Link público</Label>
                <div className="flex items-center gap-2">
                  <span className="text-sm text-muted-foreground">/jogar/</span>
                  <Input value={form.slug} onChange={(e) => setF('slug', e.target.value)} placeholder="minha-arena" />
                </div>
                {suggestedSlug && suggestedSlug !== form.slug && <p className="text-xs text-muted-foreground">Ficará como: /jogar/{suggestedSlug}</p>}
              </div>
              <div className="space-y-1.5">
                <Label>Descrição</Label>
                <Textarea value={form.description} onChange={(e) => setF('description', e.target.value)} placeholder="Conte o que torna sua arena especial..." rows={3} />
              </div>
              <div className="space-y-1.5">
                <Label>Regras da reserva</Label>
                <Textarea value={form.booking_rules} onChange={(e) => setF('booking_rules', e.target.value)} placeholder="Ex.: tolerância de 15 min, levar documento, cancelamento com 2h de antecedência..." rows={3} />
              </div>
              <div className="space-y-2">
                <Label>Comodidades</Label>
                <div className="flex flex-wrap gap-2">
                  {form.amenities.map((am) => (
                    <span key={am} className="inline-flex items-center gap-1 rounded-full border border-border bg-muted px-2.5 py-1 text-xs">
                      {am}<button onClick={() => setF('amenities', form.amenities.filter((x) => x !== am))}><X className="h-3 w-3" /></button>
                    </span>
                  ))}
                </div>
                <div className="flex gap-2">
                  <Input value={amenityInput} onChange={(e) => setAmenityInput(e.target.value)} placeholder="Adicionar comodidade" onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); const v = amenityInput.trim(); if (v && !form.amenities.includes(v)) setF('amenities', [...form.amenities, v]); setAmenityInput('') } }} />
                  <Button type="button" variant="outline" onClick={() => { const v = amenityInput.trim(); if (v && !form.amenities.includes(v)) setF('amenities', [...form.amenities, v]); setAmenityInput('') }}>Adicionar</Button>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {AMENITY_SUGGESTIONS.filter((s) => !form.amenities.includes(s)).map((s) => (
                    <button key={s} onClick={() => setF('amenities', [...form.amenities, s])} className="rounded-full border border-dashed border-border px-2 py-0.5 text-xs text-muted-foreground hover:border-primary/50 hover:text-primary">+ {s}</button>
                  ))}
                </div>
              </div>
            </CardContent>
          </Card>

          {/* Contato e localização */}
          <Card>
            <CardHeader><CardTitle className="text-base">Contato e localização</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-1.5">
                <Label className="flex items-center gap-1.5"><MessageCircle className="h-3.5 w-3.5" /> WhatsApp</Label>
                <Input value={form.whatsapp} onChange={(e) => setF('whatsapp', e.target.value)} placeholder="(11) 90000-0000" />
              </div>
              <div className="grid gap-4 sm:grid-cols-3">
                <div className="space-y-1.5 sm:col-span-2"><Label>Endereço</Label><Input value={form.address} onChange={(e) => setF('address', e.target.value)} placeholder="Rua / Av." /></div>
                <div className="space-y-1.5"><Label>Número</Label><Input value={form.number} onChange={(e) => setF('number', e.target.value)} placeholder="123" /></div>
              </div>
              <div className="grid gap-4 sm:grid-cols-3">
                <div className="space-y-1.5"><Label>Bairro</Label><Input value={form.neighborhood} onChange={(e) => setF('neighborhood', e.target.value)} /></div>
                <div className="space-y-1.5"><Label>Cidade</Label><Input value={form.city} onChange={(e) => setF('city', e.target.value)} /></div>
                <div className="space-y-1.5"><Label>UF</Label><Input value={form.state} onChange={(e) => setF('state', e.target.value)} maxLength={2} placeholder="SP" /></div>
              </div>
            </CardContent>
          </Card>

          <div className="flex justify-end">
            <Button onClick={save} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar alterações</Button>
          </div>
        </div>

        {/* Checklist */}
        <div className="space-y-6">
          <Card className="lg:sticky lg:top-24">
            <CardHeader><CardTitle className="flex items-center gap-2 text-base">
              {check?.canPublish ? <CheckCircle2 className="h-4 w-4 text-primary" /> : <AlertCircle className="h-4 w-4 text-muted-foreground" />}
              Checklist para publicar
            </CardTitle></CardHeader>
            <CardContent>
              <ul className="space-y-2.5">
                {CHECKLIST.map((c) => (
                  <li key={c.label} className="flex items-center gap-2.5 text-sm">
                    <span className={`flex h-5 w-5 items-center justify-center rounded-full ${c.ok ? 'bg-primary/15 text-primary' : 'bg-muted text-muted-foreground'}`}>
                      {c.ok ? <Check className="h-3 w-3" /> : <X className="h-3 w-3" />}
                    </span>
                    <span className={c.ok ? 'text-foreground' : 'text-muted-foreground'}>{c.label}</span>
                  </li>
                ))}
              </ul>
              {!check?.canPublish && <p className="mt-4 text-xs text-muted-foreground">Complete os itens pendentes e salve para liberar a publicação.</p>}
              {check?.canPublish && !published && <p className="mt-4 text-xs text-primary">Tudo pronto! Clique em “Publicar arena”.</p>}
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  )
}
