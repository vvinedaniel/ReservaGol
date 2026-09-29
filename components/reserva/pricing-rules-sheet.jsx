'use client'

// FASE 03A — tabela de preços (OWNER/MANAGER). Escrita somente pelas RPCs via API; o banco
// garante tenant, antiambiguidade (exclusion constraint) e auditoria. Uma criação (vários dias +
// uma faixa) é UMA intenção enviada em UM POST: a RPC rg_pricing_rule_create materializa todas as
// linhas — inclusive as metades de faixas que atravessam a meia-noite — NA MESMA TRANSAÇÃO (todos os
// dias ou nenhum). A prévia é só visual.
import { useCallback, useEffect, useState } from 'react'
import { formatCents, parseMoneyToCents, centsToInput } from '@/lib/reserva/money'
import { WEEKDAY_LABELS, previewRulePeriods } from '@/lib/reserva/finance'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { AlertDialog, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Loader2, Plus, Pencil, Ban } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

const hhmm = (t) => (t || '').slice(0, 5)
const endLabel = (t) => (hhmm(t) === '00:00' ? '24:00' : hhmm(t))
const jsonReq = (url, body, method = 'POST') => fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

export function PricingRulesSheet({ open, onClose, arenas, courts }) {
  const [arenaId, setArenaId] = useState(arenas[0]?.id || '')
  const [rules, setRules] = useState(null)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState(null)
  const arenaCourts = courts.filter((c) => c.arena_id === arenaId)

  const load = useCallback(async () => {
    if (!arenaId) return
    setRules(null)
    const r = await fetch(`/api/pricing-rules?arena_id=${arenaId}`)
    setRules(r.ok ? await r.json() : [])
  }, [arenaId])
  useEffect(() => { if (open) load() }, [open, load])

  // Desativar é terminal: confirma antes. Repetir é seguro (no banco, desativar de novo é no-op).
  const [confirming, setConfirming] = useState(null)
  const [deactivating, setDeactivating] = useState(false)
  async function deactivate(rule) {
    setDeactivating(true)
    try {
      const r = await jsonReq(`/api/pricing-rules/${rule.id}/deactivate`, {})
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error(d.error || 'Não foi possível desativar'); return }
      toast.success('Regra desativada'); setConfirming(null); load()
    } catch {
      toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.')
    } finally { setDeactivating(false) }
  }

  const byDay = WEEKDAY_LABELS.map((label, wd) => ({ label, wd, items: (rules || []).filter((r) => r.weekday === wd) }))
  return (
    <Sheet open={open} onOpenChange={onClose}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-xl">
        <SheetHeader><SheetTitle>Tabela de preços</SheetTitle></SheetHeader>
        <p className="mt-2 text-sm text-muted-foreground">Valor por hora, por dia da semana e faixa de horário. Regras de uma quadra valem antes das regras da arena. Alterar a tabela não muda reservas já criadas.</p>
        <div className="mt-4 flex flex-wrap items-center gap-2">
          {arenas.length > 1 && (
            <Select value={arenaId} onValueChange={setArenaId}><SelectTrigger className="w-48"><SelectValue /></SelectTrigger>
              <SelectContent>{arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent></Select>
          )}
          <Button size="sm" onClick={() => setCreating(true)} disabled={!arenaId}><Plus className="mr-1.5 h-3.5 w-3.5" /> Nova faixa</Button>
        </div>
        {!rules ? <Skeleton className="mt-4 h-48 w-full" /> : (
          <div className="mt-4 space-y-4">
            {rules.length === 0 && <p className="text-sm text-muted-foreground">Nenhuma regra ativa. Sem regras, novas reservas ficam sem valor definido.</p>}
            {byDay.filter((d) => d.items.length).map((d) => (
              <div key={d.wd}>
                <p className="mb-1.5 text-xs font-semibold uppercase text-muted-foreground">{d.label}</p>
                <div className="space-y-1.5">
                  {d.items.map((r) => (
                    <div key={r.id} className="flex items-center justify-between gap-2 rounded-lg border border-border px-3 py-2 text-sm">
                      <div className="min-w-0">
                        <p className="font-medium">{hhmm(r.start_time)}–{endLabel(r.end_time)} · {formatCents(r.price_per_hour)}/h</p>
                        <p className="text-xs text-muted-foreground">
                          <Badge variant="outline" className={cn('mr-1.5 font-normal', r.scope_kind === 'COURT' && 'border-primary/40 text-primary')}>{r.scope_kind === 'COURT' ? (r.court?.name || 'Quadra') : 'Arena toda'}</Badge>
                          {r.valid_from || r.valid_until ? `Válida ${r.valid_from ? `de ${r.valid_from}` : ''} ${r.valid_until ? `até ${r.valid_until}` : ''}` : 'Sem prazo'}
                        </p>
                      </div>
                      <div className="flex shrink-0 gap-1">
                        <Button size="icon" variant="ghost" className="h-8 w-8" title="Editar" onClick={() => setEditing(r)}><Pencil className="h-3.5 w-3.5" /></Button>
                        <Button size="icon" variant="ghost" className="h-8 w-8 hover:text-destructive" title="Desativar" onClick={() => setConfirming(r)}><Ban className="h-3.5 w-3.5" /></Button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
        {creating && <CreateRuleDialog arenaId={arenaId} courts={arenaCourts} onClose={() => setCreating(false)} onDone={() => { setCreating(false); load() }} />}
        {editing && <EditRuleDialog rule={editing} onClose={() => setEditing(null)} onDone={() => { setEditing(null); load() }} />}
        <AlertDialog open={!!confirming} onOpenChange={(o) => { if (!o && !deactivating) setConfirming(null) }}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Desativar esta regra de preço?</AlertDialogTitle>
              <AlertDialogDescription>Ela não poderá ser reativada. Para voltar a usá-la, será necessário criar uma nova regra.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={deactivating}>Cancelar</AlertDialogCancel>
              <Button variant="destructive" onClick={() => deactivate(confirming)} disabled={deactivating}>{deactivating && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Desativar</Button>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </SheetContent>
    </Sheet>
  )
}

function CreateRuleDialog({ arenaId, courts, onClose, onDone }) {
  const [f, setF] = useState({ scope: 'ARENA', weekdays: [1, 2, 3, 4], start: '08:00', end: '18:00', price: '', from: '', until: '' })
  const [busy, setBusy] = useState(false)
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }))
  const toggleDay = (wd) => set('weekdays', f.weekdays.includes(wd) ? f.weekdays.filter((x) => x !== wd) : [...f.weekdays, wd])
  const days = [...new Set(f.weekdays)].sort((a, b) => a - b)
  // Prévia VISUAL dos períodos que a RPC vai materializar (nenhuma lógica de persistência aqui).
  const preview = days.map((wd) => ({ wd, periods: previewRulePeriods({ weekday: wd, start_time: f.start, end_time: f.end }) }))
  const crosses = preview.some((p) => p.periods && p.periods.length > 1)

  async function submit() {
    const price = parseMoneyToCents(f.price)
    if (price === null) { toast.error('Valor por hora inválido', { description: 'Use o formato 150,00.' }); return }
    if (!days.length || preview.some((p) => !p.periods)) { toast.error('Selecione os dias e uma faixa de horário válida'); return }
    setBusy(true)
    try {
      // UMA ação = UM POST com todos os dias: o banco cria todas as regras (e metades cross-midnight)
      // na mesma transação, ou nenhuma.
      const r = await jsonReq('/api/pricing-rules', {
        arena_id: arenaId, court_id: f.scope === 'ARENA' ? null : f.scope, weekdays: days,
        start_time: f.start, end_time: f.end, price_per_hour: price, valid_from: f.from || null, valid_until: f.until || null,
      })
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error('Nenhuma regra foi criada', { description: d.error || 'Não foi possível criar a faixa' }); return }
      toast.success(`Faixa criada: ${d.rules_created ?? (d.rule_ids || []).length} regra(s)`)
      onDone()
    } catch {
      toast.error('Não foi possível confirmar a resposta do servidor. Atualize a lista antes de tentar de novo.')
    } finally { setBusy(false) }
  }

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader><DialogTitle>Nova faixa de preço</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5"><Label>Vale para</Label>
            <Select value={f.scope} onValueChange={(v) => set('scope', v)}><SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent><SelectItem value="ARENA">Arena toda (padrão)</SelectItem>{courts.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}</SelectContent></Select>
          </div>
          <div className="space-y-1.5"><Label>Dias</Label>
            <div className="flex flex-wrap gap-1.5">
              {WEEKDAY_LABELS.map((l, wd) => (
                <button key={wd} type="button" onClick={() => toggleDay(wd)} className={cn('rounded-full border px-3 py-1 text-xs', f.weekdays.includes(wd) ? 'border-primary bg-primary/15 text-primary' : 'border-border text-muted-foreground')}>{l.slice(0, 3)}</button>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={f.start} onChange={(e) => set('start', e.target.value)} /></div>
            <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={f.end} onChange={(e) => set('end', e.target.value)} /></div>
            <div className="space-y-1.5"><Label>Valor/hora</Label><Input value={f.price} onChange={(e) => set('price', e.target.value)} inputMode="decimal" placeholder="150,00" /></div>
          </div>
          <p className="text-xs text-muted-foreground">Fim 00:00 = até a meia-noite. Todos os dias selecionados são criados juntos (ou nenhum).</p>
          {days.length > 0 && preview.every((p) => p.periods) && (
            <div className="rounded-lg border border-border bg-muted/30 p-3 text-xs">
              {crosses ? (
                <>
                  <p className="mb-1 font-medium">Esta faixa será criada em 2 períodos por dia:</p>
                  {preview.map((p) => (
                    <p key={p.wd} className="text-muted-foreground">{p.periods.map((x) => `${WEEKDAY_LABELS[x.weekday]} ${x.start_time}–${endLabel(x.end_time)}`).join(' + ')}</p>
                  ))}
                </>
              ) : (
                <p className="text-muted-foreground">{days.map((wd) => WEEKDAY_LABELS[wd].slice(0, 3)).join(', ')} · {f.start}–{endLabel(f.end)}</p>
              )}
            </div>
          )}
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5"><Label>Válida a partir de (opcional)</Label><Input type="date" value={f.from} onChange={(e) => set('from', e.target.value)} /></div>
            <div className="space-y-1.5"><Label>Válida até (opcional)</Label><Input type="date" value={f.until} onChange={(e) => set('until', e.target.value)} /></div>
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={submit} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Criar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function EditRuleDialog({ rule, onClose, onDone }) {
  const [f, setF] = useState({ start: hhmm(rule.start_time), end: hhmm(rule.end_time), price: centsToInput(rule.price_per_hour), from: rule.valid_from || '', until: rule.valid_until || '' })
  const [busy, setBusy] = useState(false)
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }))
  async function submit() {
    const price = parseMoneyToCents(f.price)
    if (price === null) { toast.error('Valor por hora inválido', { description: 'Use o formato 150,00.' }); return }
    // Uma linha armazenada nunca atravessa a meia-noite: para isso, desativar e recriar a faixa.
    const periods = previewRulePeriods({ weekday: rule.weekday, start_time: f.start, end_time: f.end })
    if (!periods) { toast.error('Horário inválido'); return }
    if (periods.length > 1) { toast.error('Uma regra não pode atravessar a meia-noite', { description: 'Desative esta regra e crie uma nova faixa (ela será gravada em 2 períodos).' }); return }
    setBusy(true)
    try {
      const r = await jsonReq(`/api/pricing-rules/${rule.id}`, { start_time: f.start, end_time: f.end, price_per_hour: price, valid_from: f.from || null, valid_until: f.until || null }, 'PUT')
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error(d.error || 'Não foi possível salvar'); return }
      toast.success(d.changed === false ? 'Nada mudou' : 'Regra atualizada'); onDone()
    } catch { toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.') } finally { setBusy(false) }
  }
  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>Editar regra — {WEEKDAY_LABELS[rule.weekday]} · {rule.scope_kind === 'COURT' ? (rule.court?.name || 'Quadra') : 'Arena toda'}</DialogTitle></DialogHeader>
        <p className="text-sm text-muted-foreground">Dia e escopo não mudam; para isso, desative e crie outra faixa. Uma regra não pode atravessar a meia-noite.</p>
        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5"><Label>Início</Label><Input type="time" value={f.start} onChange={(e) => set('start', e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Fim</Label><Input type="time" value={f.end} onChange={(e) => set('end', e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Valor/hora</Label><Input value={f.price} onChange={(e) => set('price', e.target.value)} inputMode="decimal" /></div>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5"><Label>Válida a partir de</Label><Input type="date" value={f.from} onChange={(e) => set('from', e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Válida até</Label><Input type="date" value={f.until} onChange={(e) => set('until', e.target.value)} /></div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={submit} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
