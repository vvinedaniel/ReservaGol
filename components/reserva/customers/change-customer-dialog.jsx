'use client'

// CLIENTES C2B — troca EXPLÍCITA do cliente de uma reserva avulsa (rg_reservation_change_customer).
// Separada da edição da reserva: escolher cliente existente (busca no servidor) ou cadastrar um novo
// (rg_customer_resolve), confirmar e só então trocar. expected_customer_id = cliente que a tela mostrou
// (outra pessoa trocou antes => STALE_UPDATE). Ocorrência de mensalista, bloqueio e cancelada são recusados
// pelo banco. Sem atualização otimista: quem abriu recarrega depois do sucesso.
import { useRef, useState } from 'react'
import { toast } from 'sonner'
import { formatBrPhone } from '@/lib/reserva/phone'
import { CustomerRequestError, customerErrorMessage } from '@/lib/reserva/customers-client'
import { createSubmitGuard, submitWithBusy } from '@/lib/reserva/expense-mutation'
import { validateCustomerForm } from '@/components/reserva/customers/customer-form-dialog'
import { CustomerSearch } from '@/components/reserva/customers/customer-search'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { AlertTriangle, ArrowRight, Loader2 } from 'lucide-react'

const BLOCKING = {
  STALE_UPDATE: 'O cliente desta reserva foi alterado por outra pessoa. Feche e abra a reserva de novo para ver o cliente atual.',
  RECURRING_OCCURRENCE: 'Esta reserva é de um mensalista. O cliente é o da série — altere pelo módulo Mensalistas.',
  BLOCKED_SLOT: 'Bloqueios de horário não têm cliente.',
  CANCELLED_RESERVATION: 'Reservas canceladas não podem trocar de cliente.',
  CUSTOMER_NOT_FOUND: 'Cliente não encontrado nesta organização. Busque de novo.',
}

/** Rótulo curto de um cliente para confirmação. */
export function customerLabel(c) {
  if (!c) return 'Sem cliente'
  return c.phone ? `${c.name} · ${formatBrPhone(c.phone)}` : c.name
}

export function ChangeCustomerDialog({ api, orgId, reservation, onClose, onChanged }) {
  const current = reservation.customer_id ? { id: reservation.customer_id, name: reservation.customer?.name ?? 'Cliente', phone: reservation.customer?.phone ?? null } : null
  const [mode, setMode] = useState('pick') // pick | new | confirm
  const [picked, setPicked] = useState(null)
  const [nf, setNf] = useState({ name: '', phone: '' })
  const [nfErrors, setNfErrors] = useState({})
  const [error, setError] = useState(null)
  const [blocked, setBlocked] = useState(null)
  const [busy, setBusy] = useState(false)
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()

  // Novo cliente: resolve no banco ANTES de confirmar (telefone já cadastrado devolve o existente, sem renomear).
  async function resolveNew(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const v = validateCustomerForm({ name: nf.name, phone: nf.phone, email: '' })
    if (!v.ok) { setNfErrors(v.errors); return }
    setNfErrors({}); setError(null)
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: () => api.create({ orgId, name: v.value.name, phone: v.value.phone, origin: 'RESERVATION' }),
      onSuccess: (res) => {
        if (res?.created === false) {
          toast.info(res?.name_differs
            ? `Este telefone já é de "${res?.existing?.name ?? 'outro cliente'}". Vamos usar o cadastro existente — nada foi renomeado.`
            : 'Cliente já cadastrado com este telefone. Vamos usar o cadastro existente.')
        }
        setPicked({ id: res.customer_id, name: res?.name_differs ? (res?.existing?.name ?? v.value.name) : v.value.name, phone: v.value.phone })
        setMode('confirm')
      },
      onError: (err) => {
        if (err instanceof CustomerRequestError && err.code === 'INVALID_PHONE') { setNfErrors({ phone: err.message }); return }
        if (err instanceof CustomerRequestError && err.code === 'INVALID_NAME') { setNfErrors({ name: err.message }); return }
        setError(customerErrorMessage(err))
      },
    })
  }

  async function confirm() {
    if (guard.current.busy || !picked) return
    setError(null)
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: () => api.changeReservationCustomer(reservation.id, { customerId: picked.id, expectedCustomerId: current?.id ?? null }),
      onSuccess: async (res) => {
        toast.success(res?.changed === false ? 'A reserva já estava com este cliente.' : 'Cliente da reserva trocado')
        await onChanged()
      },
      onError: (err) => {
        if (err instanceof CustomerRequestError && BLOCKING[err.code]) { setBlocked(BLOCKING[err.code]); return }
        setError(customerErrorMessage(err))
      },
    })
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none">
        <DialogHeader>
          <DialogTitle>Trocar cliente da reserva</DialogTitle>
          <DialogDescription>Só o cliente muda. Data, horário, quadra, valor e pagamentos continuam iguais.</DialogDescription>
        </DialogHeader>
        <p className="rounded-lg border border-border px-3 py-2 text-sm"><span className="text-muted-foreground">Cliente atual: </span>{customerLabel(current)}</p>

        {blocked ? (
          <div className="space-y-3">
            <p className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm" role="alert">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" aria-hidden="true" />{blocked}
            </p>
            <DialogFooter><Button className="h-11 sm:h-9" onClick={onClose}>Fechar</Button></DialogFooter>
          </div>
        ) : mode === 'confirm' && picked ? (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-2 text-sm" aria-live="polite">
              <span className="text-muted-foreground line-through">{customerLabel(current)}</span>
              <ArrowRight className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
              <span className="font-medium">{customerLabel(picked)}</span>
            </div>
            <p className="text-xs text-muted-foreground">Confirme para trocar. A troca fica registrada no histórico de auditoria.</p>
            {error && <p className="text-sm text-amber-500" role="alert">{error}</p>}
            <DialogFooter className="gap-2">
              <Button variant="ghost" className="h-11 sm:h-9" disabled={busy} onClick={() => { setMode('pick'); setError(null) }}>Voltar</Button>
              <Button className="h-11 sm:h-9" disabled={busy} onClick={confirm}>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Confirmar troca
              </Button>
            </DialogFooter>
          </div>
        ) : mode === 'new' ? (
          <form onSubmit={resolveNew} className="space-y-3" noValidate>
            <div className="space-y-1.5">
              <Label htmlFor="cc-name">Nome</Label>
              <Input id="cc-name" className="h-11 sm:h-9" value={nf.name} maxLength={120} autoFocus onChange={(e) => setNf((s) => ({ ...s, name: e.target.value }))}
                aria-invalid={!!nfErrors.name} aria-describedby={nfErrors.name ? 'cc-name-error' : undefined} />
              {nfErrors.name && <p id="cc-name-error" className="text-xs text-amber-500" role="alert">{nfErrors.name}</p>}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="cc-phone">Telefone / WhatsApp (opcional)</Label>
              <Input id="cc-phone" className="h-11 sm:h-9" value={nf.phone} inputMode="tel" placeholder="(41) 99999-1111" onChange={(e) => setNf((s) => ({ ...s, phone: e.target.value }))}
                aria-invalid={!!nfErrors.phone} aria-describedby={nfErrors.phone ? 'cc-phone-error' : undefined} />
              {nfErrors.phone && <p id="cc-phone-error" className="text-xs text-amber-500" role="alert">{nfErrors.phone}</p>}
            </div>
            {error && <p className="text-sm text-amber-500" role="alert">{error}</p>}
            <DialogFooter className="gap-2">
              <Button type="button" variant="ghost" className="h-11 sm:h-9" disabled={busy} onClick={() => { setMode('pick'); setError(null) }}>Voltar</Button>
              <Button type="submit" className="h-11 sm:h-9" disabled={busy}>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Continuar
              </Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-3">
            <CustomerSearch api={api} orgId={orgId} picked={picked} excludeId={current?.id ?? null} autoFocus id="cc-q"
              onPick={(c) => { setPicked(c); setMode('confirm'); setError(null) }} />
            <Button type="button" variant="link" className="h-11 px-0 sm:h-8" onClick={() => setMode('new')}>Cliente novo? Cadastrar</Button>
            <DialogFooter><Button variant="ghost" className="h-11 sm:h-9" onClick={onClose}>Cancelar</Button></DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
