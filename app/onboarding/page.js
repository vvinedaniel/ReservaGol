'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/browser'
import { Logo } from '@/components/reserva/logo'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Switch } from '@/components/ui/switch'
import { Card, CardContent } from '@/components/ui/card'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Check, Plus, Trash2, Loader2, ArrowRight, ArrowLeft, Building2, MapPin, LayoutGrid, Clock, Settings } from 'lucide-react'
import { toast } from 'sonner'

const COURT_TYPES = ['Society', 'Futsal', 'Campo', 'Beach', 'Outra']
const WEEK = [
  { wd: 1, label: 'Segunda' }, { wd: 2, label: 'Terça' }, { wd: 3, label: 'Quarta' },
  { wd: 4, label: 'Quinta' }, { wd: 5, label: 'Sexta' }, { wd: 6, label: 'Sábado' }, { wd: 0, label: 'Domingo' },
]
const STEPS = [
  { icon: Building2, title: 'Organização' },
  { icon: MapPin, title: 'Arena' },
  { icon: LayoutGrid, title: 'Quadras' },
  { icon: Clock, title: 'Horários' },
  { icon: Settings, title: 'Configuração' },
]

export default function OnboardingPage() {
  const router = useRouter()
  const supabase = createClient()
  const [step, setStep] = useState(0)
  const [saving, setSaving] = useState(false)

  const [org, setOrg] = useState({ name: '', owner_name: '', phone: '', email: '', is_demo: false })
  const [arena, setArena] = useState({ name: '', postal_code: '', address: '', number: '', complement: '', neighborhood: '', city: '', state: '', whatsapp: '' })
  const [courts, setCourts] = useState([{ name: '', type: 'Society', description: '', active: true }])
  const [hours, setHours] = useState(WEEK.map((w) => ({ weekday: w.wd, open_time: '08:00', close_time: '23:00', closed: false })))
  const [duration, setDuration] = useState('60')

  const setOrgF = (k) => (e) => setOrg((s) => ({ ...s, [k]: e.target.value }))
  const setArenaF = (k) => (e) => setArena((s) => ({ ...s, [k]: e.target.value }))

  function addCourt() { setCourts((c) => [...c, { name: '', type: 'Society', description: '', active: true }]) }
  function removeCourt(i) { setCourts((c) => c.filter((_, idx) => idx !== i)) }
  function updateCourt(i, k, v) { setCourts((c) => c.map((row, idx) => idx === i ? { ...row, [k]: v } : row)) }
  function updateHour(wd, k, v) { setHours((h) => h.map((row) => row.weekday === wd ? { ...row, [k]: v } : row)) }
  function applyToAll(wd) {
    const src = hours.find((h) => h.weekday === wd)
    setHours((h) => h.map((row) => ({ ...row, open_time: src.open_time, close_time: src.close_time, closed: src.closed })))
    toast.success('Horário aplicado a todos os dias')
  }

  function validateStep() {
    if (step === 0 && !org.name.trim()) { toast.error('Informe o nome da organização'); return false }
    if (step === 1 && !arena.name.trim()) { toast.error('Informe o nome da arena'); return false }
    if (step === 2 && !courts.some((c) => c.name.trim())) { toast.error('Cadastre ao menos uma quadra'); return false }
    return true
  }
  function next() { if (validateStep()) setStep((s) => Math.min(s + 1, STEPS.length - 1)) }
  function back() { setStep((s) => Math.max(s - 1, 0)) }

  async function finish() {
    if (!validateStep()) return
    setSaving(true)
    const payload = {
      organization: org,
      arena,
      courts: courts.filter((c) => c.name.trim()),
      hours,
      default_reservation_minutes: Number(duration),
    }
    const res = await fetch('/api/onboarding', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    })
    setSaving(false)
    if (!res.ok) { const e = await res.json().catch(() => ({})); toast.error('Não foi possível concluir', { description: e.error }); return }
    toast.success('Arena configurada com sucesso!')
    router.push('/dashboard')
    router.refresh()
  }

  return (
    <div className="min-h-screen bg-background bg-grid">
      <div className="border-b border-border bg-background/80 backdrop-blur">
        <div className="container flex h-16 items-center justify-between"><Logo /><span className="text-sm text-muted-foreground">Configuração inicial</span></div>
      </div>

      <div className="container max-w-3xl py-10">
        {/* Stepper */}
        <div className="mb-8 flex items-center justify-between">
          {STEPS.map((s, i) => (
            <div key={i} className="flex flex-1 items-center">
              <div className="flex flex-col items-center">
                <div className={`flex h-10 w-10 items-center justify-center rounded-full border-2 transition-colors ${i < step ? 'border-primary bg-primary text-primary-foreground' : i === step ? 'border-primary text-primary' : 'border-border text-muted-foreground'}`}>
                  {i < step ? <Check className="h-5 w-5" /> : <s.icon className="h-5 w-5" />}
                </div>
                <span className={`mt-2 hidden text-xs sm:block ${i === step ? 'font-medium text-foreground' : 'text-muted-foreground'}`}>{s.title}</span>
              </div>
              {i < STEPS.length - 1 && <div className={`mx-2 h-0.5 flex-1 ${i < step ? 'bg-primary' : 'bg-border'}`} />}
            </div>
          ))}
        </div>

        <Card>
          <CardContent className="p-6">
            <h1 className="font-display text-xl font-bold">{STEPS[step].title}</h1>

            {step === 0 && (
              <div className="mt-6 space-y-4">
                <p className="text-sm text-muted-foreground">Dados da sua empresa / arena.</p>
                <Field label="Nome da empresa / arena"><Input value={org.name} onChange={setOrgF('name')} placeholder="Arena Champions" /></Field>
                <Field label="Nome do responsável"><Input value={org.owner_name} onChange={setOrgF('owner_name')} placeholder="Seu nome" /></Field>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="Telefone"><Input value={org.phone} onChange={setOrgF('phone')} placeholder="(11) 99999-9999" /></Field>
                  <Field label="E-mail"><Input type="email" value={org.email} onChange={setOrgF('email')} placeholder="contato@arena.com" /></Field>
                </div>
                <div className="flex items-center justify-between rounded-lg border border-amber-500/30 bg-amber-500/5 p-4">
                  <div><p className="text-sm font-medium">Conta de demonstração</p><p className="text-xs text-muted-foreground">Marque para usar dados fictícios em apresentações comerciais.</p></div>
                  <Switch checked={org.is_demo} onCheckedChange={(v) => setOrg((s) => ({ ...s, is_demo: v }))} />
                </div>
              </div>
            )}

            {step === 1 && (
              <div className="mt-6 space-y-4">
                <p className="text-sm text-muted-foreground">Crie a primeira unidade da sua organização.</p>
                <Field label="Nome da arena"><Input value={arena.name} onChange={setArenaF('name')} placeholder="Arena Champions — Centro" /></Field>
                <div className="grid gap-4 sm:grid-cols-3">
                  <Field label="CEP"><Input value={arena.postal_code} onChange={setArenaF('postal_code')} placeholder="00000-000" /></Field>
                  <div className="sm:col-span-2"><Field label="Endereço"><Input value={arena.address} onChange={setArenaF('address')} placeholder="Rua..." /></Field></div>
                </div>
                <div className="grid gap-4 sm:grid-cols-3">
                  <Field label="Número"><Input value={arena.number} onChange={setArenaF('number')} placeholder="123" /></Field>
                  <Field label="Complemento"><Input value={arena.complement} onChange={setArenaF('complement')} placeholder="Opcional" /></Field>
                  <Field label="Bairro"><Input value={arena.neighborhood} onChange={setArenaF('neighborhood')} placeholder="Centro" /></Field>
                </div>
                <div className="grid gap-4 sm:grid-cols-3">
                  <div className="sm:col-span-2"><Field label="Cidade"><Input value={arena.city} onChange={setArenaF('city')} placeholder="São Paulo" /></Field></div>
                  <Field label="Estado"><Input value={arena.state} onChange={setArenaF('state')} placeholder="SP" /></Field>
                </div>
                <Field label="WhatsApp"><Input value={arena.whatsapp} onChange={setArenaF('whatsapp')} placeholder="(11) 99999-9999" /></Field>
              </div>
            )}

            {step === 2 && (
              <div className="mt-6 space-y-4">
                <p className="text-sm text-muted-foreground">Cadastre as quadras desta arena.</p>
                {courts.map((c, i) => (
                  <div key={i} className="rounded-lg border border-border p-4">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium text-muted-foreground">Quadra {i + 1}</span>
                      {courts.length > 1 && <Button variant="ghost" size="icon" onClick={() => removeCourt(i)}><Trash2 className="h-4 w-4 text-destructive" /></Button>}
                    </div>
                    <div className="mt-3 grid gap-3 sm:grid-cols-2">
                      <Field label="Nome"><Input value={c.name} onChange={(e) => updateCourt(i, 'name', e.target.value)} placeholder="Society 01" /></Field>
                      <Field label="Tipo">
                        <Select value={c.type} onValueChange={(v) => updateCourt(i, 'type', v)}>
                          <SelectTrigger><SelectValue /></SelectTrigger>
                          <SelectContent>{COURT_TYPES.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}</SelectContent>
                        </Select>
                      </Field>
                    </div>
                    <div className="mt-3"><Field label="Descrição curta"><Input value={c.description} onChange={(e) => updateCourt(i, 'description', e.target.value)} placeholder="Grama sintética, cobertura..." /></Field></div>
                    <div className="mt-3 flex items-center gap-2"><Switch checked={c.active} onCheckedChange={(v) => updateCourt(i, 'active', v)} /><span className="text-sm">{c.active ? 'Ativa' : 'Inativa'}</span></div>
                  </div>
                ))}
                <Button variant="outline" onClick={addCourt} className="w-full"><Plus className="mr-2 h-4 w-4" /> Adicionar quadra</Button>
              </div>
            )}

            {step === 3 && (
              <div className="mt-6 space-y-3">
                <p className="text-sm text-muted-foreground">Defina o horário de funcionamento por dia.</p>
                {WEEK.map((w) => {
                  const h = hours.find((x) => x.weekday === w.wd)
                  return (
                    <div key={w.wd} className="flex flex-wrap items-center gap-3 rounded-lg border border-border p-3">
                      <span className="w-20 text-sm font-medium">{w.label}</span>
                      <Switch checked={!h.closed} onCheckedChange={(v) => updateHour(w.wd, 'closed', !v)} />
                      {h.closed ? (
                        <span className="text-sm text-muted-foreground">Fechado</span>
                      ) : (
                        <div className="flex items-center gap-2">
                          <Input type="time" value={h.open_time} onChange={(e) => updateHour(w.wd, 'open_time', e.target.value)} className="w-32" />
                          <span className="text-muted-foreground">até</span>
                          <Input type="time" value={h.close_time} onChange={(e) => updateHour(w.wd, 'close_time', e.target.value)} className="w-32" />
                        </div>
                      )}
                      <Button variant="ghost" size="sm" onClick={() => applyToAll(w.wd)} className="ml-auto text-xs">Aplicar a todos</Button>
                    </div>
                  )
                })}
              </div>
            )}

            {step === 4 && (
              <div className="mt-6 space-y-4">
                <p className="text-sm text-muted-foreground">Duração padrão de cada reserva. Você poderá configurar preços por horário nas próximas fases.</p>
                <Field label="Duração padrão da reserva">
                  <Select value={duration} onValueChange={setDuration}>
                    <SelectTrigger className="w-full"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {['30', '60', '90', '120'].map((m) => <SelectItem key={m} value={m}>{m} minutos</SelectItem>)}
                    </SelectContent>
                  </Select>
                </Field>
                <div className="rounded-lg border border-primary/30 bg-primary/5 p-4 text-sm text-muted-foreground">
                  Tudo pronto! Ao concluir, sua arena estará configurada e você irá para o painel.
                </div>
              </div>
            )}

            <div className="mt-8 flex items-center justify-between">
              <Button variant="ghost" onClick={back} disabled={step === 0}><ArrowLeft className="mr-2 h-4 w-4" /> Voltar</Button>
              {step < STEPS.length - 1 ? (
                <Button onClick={next}>Continuar <ArrowRight className="ml-2 h-4 w-4" /></Button>
              ) : (
                <Button onClick={finish} disabled={saving}>{saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Concluir configuração</Button>
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

function Field({ label, children }) {
  return <div className="space-y-2"><Label>{label}</Label>{children}</div>
}
