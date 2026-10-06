'use client'

// FASE 03B.3B — W1: vincular cliente a um mensalista SEM cliente (OWNER/MANAGER; o banco é a autoridade:
// rg_recurring_link_customer só aceita NULL -> cliente da mesma organização). Cliente existente pela busca
// por telefone (filtro no servidor) ou novo cliente por nome/telefone (a RPC reaproveita pelo telefone).
// Depois do sucesso quem abriu refaz o fetch (sem atualização otimista).
import { useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import { validateNewCustomer, normalizePhoneDigits, monthErrorMessage, monthErrorReason } from '@/lib/reserva/recurring-month'
import { createSubmitGuard, submitWithBusy } from '@/lib/reserva/expense-mutation'
import { focusReturn } from '@/components/reserva/finance/expense-forms'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { AlertTriangle, Check, Loader2 } from 'lucide-react'
import { cn } from '@/lib/utils'

const DIALOG_CLASS = 'max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none'

export function LinkCustomerDialog({ api, orgId, lineageId, onClose, onDone, returnFocusTo }) {
  const [mode, setMode] = useState('find') // 'find' | 'new'
  const [phoneQ, setPhoneQ] = useState('')
  const [found, setFound] = useState({ loading: false, items: [], error: false })
  const [picked, setPicked] = useState(null)
  const [nf, setNf] = useState({ name: '', phone: '' })
  const [errors, setErrors] = useState({})
  const [submitError, setSubmitError] = useState(null)
  const [busy, setBusy] = useState(false)
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()
  const seq = useRef(0)

  // Busca por telefone (>= 4 dígitos), filtro aplicado no servidor; resposta antiga é descartada.
  useEffect(() => {
    const digits = normalizePhoneDigits(phoneQ)
    if (mode !== 'find' || digits.length < 4) { setFound({ loading: false, items: [], error: false }); return }
    const id = ++seq.current
    setFound((s) => ({ ...s, loading: true, error: false }))
    const t = setTimeout(async () => {
      try {
        const r = await fetch(`/api/customers?organization_id=${encodeURIComponent(orgId)}&phone=${encodeURIComponent(digits)}`, { cache: 'no-store' })
        const d = r.ok ? await r.json() : null
        if (id !== seq.current) return
        setFound({ loading: false, items: Array.isArray(d) ? d.slice(0, 10) : [], error: !r.ok })
      } catch { if (id === seq.current) setFound({ loading: false, items: [], error: true }) }
    }, 250)
    return () => clearTimeout(t)
  }, [phoneQ, mode, orgId])

  async function submit(e) {
    e.preventDefault()
    if (guard.current.busy) return
    let payload
    if (mode === 'find') {
      if (!picked) { setErrors({ picked: 'Escolha um cliente da lista ou cadastre um novo.' }); return }
      payload = { customerId: picked.id }
    } else {
      const v = validateNewCustomer(nf)
      if (!v.ok) { setErrors(v.errors); return }
      payload = { customer: v.value }
    }
    setErrors({})
    setSubmitError(null)
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: () => api.linkCustomer(lineageId, payload),
      onSuccess: async (res) => {
        toast.success(res.data?.changed === false ? 'Cliente já estava vinculado' : 'Cliente vinculado ao mensalista')
        await onDone()
      },
      onError: async (err) => {
        if (monthErrorReason(err) === 'CUSTOMER_ALREADY_SET') { toast.error(monthErrorMessage(err)); await onDone(); return }
        setSubmitError(monthErrorMessage(err))
      },
    })
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>Vincular cliente</DialogTitle>
          <DialogDescription>
            Vincula o cliente a este mensalista (todas as séries do horário) e aos jogos que ainda estão sem cliente.
          </DialogDescription>
        </DialogHeader>
        <p className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />Depois de vinculado, o cliente não pode ser trocado por outro.
        </p>
        <div className="inline-flex rounded-lg border border-border p-1" role="group" aria-label="Como escolher o cliente">
          <Button type="button" variant={mode === 'find' ? 'default' : 'ghost'} aria-pressed={mode === 'find'} className="h-11 sm:h-8"
            onClick={() => { setMode('find'); setErrors({}) }}>Buscar existente</Button>
          <Button type="button" variant={mode === 'new' ? 'default' : 'ghost'} aria-pressed={mode === 'new'} className="h-11 sm:h-8"
            onClick={() => { setMode('new'); setErrors({}) }}>Novo cliente</Button>
        </div>
        <form onSubmit={submit} className="space-y-3" noValidate>
          {mode === 'find' ? (
            <div className="space-y-2">
              <Label htmlFor="lc-phone">Telefone do cliente</Label>
              <Input id="lc-phone" className="h-11 sm:h-9" value={phoneQ} inputMode="tel" placeholder="(11) 99999-0000" autoFocus
                onChange={(e) => { setPhoneQ(e.target.value); setPicked(null) }} aria-describedby="lc-phone-hint" />
              <p id="lc-phone-hint" className="text-xs text-muted-foreground" aria-live="polite">
                {found.loading ? 'Buscando…' : found.error ? 'Não foi possível buscar.' : normalizePhoneDigits(phoneQ).length < 4 ? 'Digite ao menos 4 dígitos.' : `${found.items.length} cliente(s) encontrado(s).`}
              </p>
              {found.items.length > 0 && (
                <ul className="divide-y divide-border rounded-lg border border-border" aria-label="Clientes encontrados">
                  {found.items.map((c) => (
                    <li key={c.id}>
                      <button type="button" aria-pressed={picked?.id === c.id} onClick={() => { setPicked(c); setErrors({}) }}
                        className={cn('flex min-h-11 w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-accent/40 focus-visible:bg-accent/40 focus-visible:outline-none', picked?.id === c.id && 'bg-accent/50')}>
                        <span className="min-w-0"><span className="block truncate font-medium">{c.name}</span><span className="block truncate text-xs text-muted-foreground">{c.phone || 'sem telefone'}</span></span>
                        {picked?.id === c.id && <Check className="h-4 w-4 shrink-0 text-primary" aria-hidden="true" />}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {errors.picked && <p className="text-xs text-amber-500" role="alert">{errors.picked}</p>}
            </div>
          ) : (
            <div className="space-y-3">
              <div className="space-y-1.5">
                <Label htmlFor="lc-name">Nome</Label>
                <Input id="lc-name" className="h-11 sm:h-9" value={nf.name} maxLength={120} autoFocus onChange={(e) => setNf((s) => ({ ...s, name: e.target.value }))}
                  aria-invalid={!!errors.name} aria-describedby={errors.name ? 'lc-name-error' : undefined} />
                {errors.name && <p id="lc-name-error" className="text-xs text-amber-500" role="alert">{errors.name}</p>}
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="lc-newphone">Telefone (opcional)</Label>
                <Input id="lc-newphone" className="h-11 sm:h-9" value={nf.phone} inputMode="tel" onChange={(e) => setNf((s) => ({ ...s, phone: e.target.value }))}
                  aria-invalid={!!errors.phone} aria-describedby={errors.phone ? 'lc-newphone-error' : 'lc-newphone-hint'} />
                {errors.phone
                  ? <p id="lc-newphone-error" className="text-xs text-amber-500" role="alert">{errors.phone}</p>
                  : <p id="lc-newphone-hint" className="text-xs text-muted-foreground">Se já existir cliente com esse telefone, ele é reaproveitado.</p>}
              </div>
            </div>
          )}
          {submitError && <p className="text-sm text-amber-500" role="alert">{submitError}</p>}
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Cancelar</Button>
            <Button type="submit" className="h-11 sm:h-9" disabled={busy}>
              {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Vincular cliente
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
