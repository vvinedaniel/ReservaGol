'use client'

// CLIENTES C2B — cadastrar ou editar cliente (OWNER/MANAGER/RECEPTIONIST). O banco é a autoridade:
//   criar  => rg_customer_resolve (organização + telefone canônico; telefone já cadastrado devolve o cliente
//             EXISTENTE sem renomear — a tela avisa e abre o cadastro existente; nunca junta cadastros)
//   editar => rg_customer_update (só campos alterados; versão updated_at => STALE_UPDATE; PHONE_IN_USE)
// Sem atualização otimista: quem abriu recarrega depois do sucesso. Envio duplicado bloqueado (guard).
import { useMemo, useRef, useState } from 'react'
import { toast } from 'sonner'
import { canonicalBrPhone, formatBrPhone, PHONE_INVALID_MSG } from '@/lib/reserva/phone'
import { normalizeCustomerName, normalizeCustomerEmail } from '@/lib/reserva/customers-api'
import { CustomerRequestError, customerErrorMessage } from '@/lib/reserva/customers-client'
import { createSubmitGuard, submitWithBusy } from '@/lib/reserva/expense-mutation'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { AlertTriangle, Loader2 } from 'lucide-react'

const NO_ARENA = '__none__'

/** Valida o formulário; devolve { ok, value } com valores normalizados ou { ok: false, errors }. */
export function validateCustomerForm(f) {
  const errors = {}
  const name = normalizeCustomerName(f?.name ?? '')
  if (!name) errors.name = 'Informe o nome (até 120 caracteres).'
  const phone = canonicalBrPhone(typeof f?.phone === 'string' ? f.phone : null)
  if (!phone.ok) errors.phone = PHONE_INVALID_MSG
  const email = normalizeCustomerEmail(typeof f?.email === 'string' ? f.email : null)
  if (!email.ok) errors.email = 'E-mail inválido.'
  if (Object.keys(errors).length) return { ok: false, errors }
  return { ok: true, value: { name, phone: phone.value, email: email.value, arena_id: f?.arena_id || null } }
}

/** Só o que mudou em relação ao cadastro atual (o banco também compara). */
export function customerChanges(current, value) {
  const changes = {}
  if (value.name !== current.name) changes.name = value.name
  if ((value.phone ?? null) !== (current.phone ?? null)) changes.phone = value.phone
  if ((value.email ?? null) !== (current.email ?? null)) changes.email = value.email
  const curArena = current.arena?.id ?? current.arena_id ?? null
  if ((value.arena_id ?? null) !== curArena) changes.arena_id = value.arena_id
  return changes
}

export function CustomerFormDialog({ api, orgId, arenas = [], customer = null, onClose, onSaved, onOpenCustomer, onStale }) {
  const editing = !!customer
  const [f, setF] = useState(() => ({
    name: customer?.name ?? '',
    phone: customer?.phone ? formatBrPhone(customer.phone) : '',
    email: customer?.email ?? '',
    arena_id: customer?.arena?.id ?? customer?.arena_id ?? (arenas.length === 1 ? arenas[0].id : ''),
  }))
  const [errors, setErrors] = useState({})
  const [submitError, setSubmitError] = useState(null)
  const [conflict, setConflict] = useState(null) // { kind: 'PHONE_IN_USE' | 'STALE_UPDATE', customerId? }
  const [busy, setBusy] = useState(false)
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()
  const set = (k) => (e) => { const v = e.target.value; setF((s) => ({ ...s, [k]: v })); setConflict(null); setSubmitError(null) }
  const showArena = arenas.length > 1 || (editing && (customer?.arena?.id ?? customer?.arena_id))
  const arenaValue = useMemo(() => f.arena_id || NO_ARENA, [f.arena_id])

  async function submit(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const v = validateCustomerForm(f)
    if (!v.ok) { setErrors(v.errors); return }
    setErrors({}); setSubmitError(null); setConflict(null)
    let send
    if (editing) {
      const changes = customerChanges(customer, v.value)
      if (Object.keys(changes).length === 0) { toast.info('Nada para salvar.'); onClose(); return }
      send = () => api.update(customer.id, { changes, expectedUpdatedAt: customer.updated_at })
    } else {
      send = () => api.create({ orgId, name: v.value.name, phone: v.value.phone, email: v.value.email, arenaId: v.value.arena_id })
    }
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send,
      onSuccess: async (res) => {
        if (editing) {
          toast.success(res?.changed === false ? 'Nada mudou no cadastro.' : 'Cliente atualizado')
          await onSaved(customer.id, { created: false })
          return
        }
        if (res?.created === false) {
          // telefone já cadastrado: abre o cliente EXISTENTE (nunca renomeia nem junta cadastros)
          toast.info(res?.name_differs
            ? `Este telefone já está cadastrado para "${res?.existing?.name ?? 'outro cliente'}". Abrimos o cadastro existente — nada foi alterado.`
            : 'Cliente já cadastrado com este telefone. Abrimos o cadastro existente.')
        } else toast.success('Cliente cadastrado')
        await onSaved(res.customer_id, { created: res?.created === true })
      },
      onError: (err) => {
        if (err instanceof CustomerRequestError && err.code === 'PHONE_IN_USE') {
          setConflict({ kind: 'PHONE_IN_USE', customerId: err.conflictCustomerId }); return
        }
        if (err instanceof CustomerRequestError && err.code === 'STALE_UPDATE') { setConflict({ kind: 'STALE_UPDATE' }); return }
        if (err instanceof CustomerRequestError && ['INVALID_PHONE', 'INVALID_NAME', 'INVALID_EMAIL'].includes(err.code)) {
          setErrors({ [err.code === 'INVALID_PHONE' ? 'phone' : err.code === 'INVALID_NAME' ? 'name' : 'email']: err.message }); return
        }
        setSubmitError(customerErrorMessage(err))
      },
    })
  }

  const fieldErr = (k) => errors[k] && <p id={`cf-${k}-error`} className="text-xs text-amber-500" role="alert">{errors[k]}</p>
  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none">
        <DialogHeader>
          <DialogTitle>{editing ? 'Editar cliente' : 'Novo cliente'}</DialogTitle>
          <DialogDescription>
            {editing ? 'Os dados valem para todas as reservas e mensalistas deste cliente.' : 'O telefone identifica o cliente na organização. Se já existir, o cadastro existente é usado.'}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="space-y-3" noValidate>
          <div className="space-y-1.5">
            <Label htmlFor="cf-name">Nome</Label>
            <Input id="cf-name" className="h-11 sm:h-9" value={f.name} maxLength={120} autoFocus onChange={set('name')}
              aria-invalid={!!errors.name} aria-describedby={errors.name ? 'cf-name-error' : undefined} />
            {fieldErr('name')}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="cf-phone">Telefone / WhatsApp (opcional)</Label>
            <Input id="cf-phone" className="h-11 sm:h-9" value={f.phone} inputMode="tel" placeholder="(41) 99999-1111" onChange={set('phone')}
              aria-invalid={!!errors.phone} aria-describedby={errors.phone ? 'cf-phone-error' : 'cf-phone-hint'} />
            {errors.phone ? fieldErr('phone') : <p id="cf-phone-hint" className="text-xs text-muted-foreground">Somente números brasileiros, com DDD. Deixe vazio se não houver.</p>}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="cf-email">E-mail (opcional)</Label>
            <Input id="cf-email" className="h-11 sm:h-9" type="email" value={f.email} maxLength={254} onChange={set('email')}
              aria-invalid={!!errors.email} aria-describedby={errors.email ? 'cf-email-error' : undefined} />
            {fieldErr('email')}
          </div>
          {showArena && (
            <div className="space-y-1.5">
              <Label htmlFor="cf-arena">Arena (opcional)</Label>
              <Select value={arenaValue} onValueChange={(v) => { setF((s) => ({ ...s, arena_id: v === NO_ARENA ? '' : v })); setConflict(null) }}>
                <SelectTrigger id="cf-arena" className="h-11 sm:h-9"><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value={NO_ARENA}>Sem arena definida</SelectItem>
                  {arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
          )}
          {conflict?.kind === 'PHONE_IN_USE' && (
            <div className="space-y-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm" role="alert">
              <p className="flex items-start gap-2"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" aria-hidden="true" />
                Este telefone já pertence a outro cliente. Não fazemos junção automática de cadastros.</p>
              {conflict.customerId && onOpenCustomer && (
                <Button type="button" variant="outline" className="h-11 sm:h-8" onClick={() => onOpenCustomer(conflict.customerId)}>Ver o outro cliente</Button>
              )}
            </div>
          )}
          {conflict?.kind === 'STALE_UPDATE' && (
            <div className="space-y-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm" role="alert">
              <p className="flex items-start gap-2"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" aria-hidden="true" />
                Outra pessoa alterou este cliente enquanto você editava. Recarregue para ver os dados atuais.</p>
              {onStale && <Button type="button" variant="outline" className="h-11 sm:h-8" onClick={onStale}>Recarregar dados</Button>}
            </div>
          )}
          {submitError && <p className="text-sm text-amber-500" role="alert">{submitError}</p>}
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Cancelar</Button>
            <Button type="submit" className="h-11 sm:h-9" disabled={busy}>
              {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}{editing ? 'Salvar' : 'Cadastrar'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
