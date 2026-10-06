'use client'

// FASE 03B.3B — "Receber mês": UMA operação atômica no servidor (rg_recurring_month_payment_record).
// Regras do freeze:
// - expected_open SEMPRE enviado = summary.open do estado que o usuário confirmou;
// - STATE_CHANGED: invalida a confirmação, descarta o intent, refaz o fetch e exige NOVA confirmação
//   (novo intent na nova tentativa);
// - operation_id por intenção: gerado no 1º envio; mantido em falha de rede/503; descartado no sucesso,
//   em IDEMPOTENCY_MISMATCH, em STATE_CHANGED e quando qualquer campo muda;
// - a distribuição exibida na confirmação é PREVISÃO VISUAL (não é enviada); o split real vem da resposta;
// - nenhuma atualização otimista: quem abriu refaz o fetch depois do sucesso.
import { useRef, useState } from 'react'
import { toast } from 'sonner'
import {
  validateMonthPaymentDraft, previewMonthSplit, monthName, monthLabel, dayMonth, moneyOrDash, monthErrorMessage, monthErrorReason,
  keepsIntent, MONTH_REASON_MSG,
} from '@/lib/reserva/recurring-month'
import { createOperationIntent } from '@/lib/reserva/expenses'
import { createSubmitGuard, submitWithBusy } from '@/lib/reserva/expense-mutation'
import { PAYMENT_METHODS, PAYMENT_METHOD_LABELS, nowLocalInput } from '@/lib/reserva/finance'
import { centsToInput } from '@/lib/reserva/money'
import { focusReturn } from '@/components/reserva/finance/expense-forms'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { AlertTriangle, Loader2 } from 'lucide-react'

const DIALOG_CLASS = 'max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none'

// Motivos que exigem recarregar o detalhe e reabrir o formulário com os valores novos.
const RELOAD_AND_REVIEW = ['STATE_CHANGED', 'OVER_BALANCE']
// Motivos em que o recebimento deixou de ser possível: fecha e recarrega (o detalhe mostra o bloqueio).
const RELOAD_AND_CLOSE = ['NOTHING_DUE', 'UNPRICED', 'CUSTOMER_REQUIRED']

/**
 * @param {{ api: object, detail: import('@/lib/reserva/recurring-month').MonthDetail, month: string,
 *   onClose: () => void, onDone: (r: object) => void, onReload: () => Promise<void>|void, returnFocusTo?: object }} props
 */
export function ReceiveMonthDialog({ api, detail, month, onClose, onDone, onReload, returnFocusTo }) {
  const open = detail.summary.open
  const [f, setF] = useState(() => ({ amount: centsToInput(open), method: 'PIX', at: nowLocalInput(), notes: '' }))
  const [errors, setErrors] = useState({})
  const [step, setStep] = useState('form') // 'form' | 'confirm'
  const [confirmed, setConfirmed] = useState(null) // { value, expectedOpen, preview }
  const [notice, setNotice] = useState(null) // aviso de estado (ex.: STATE_CHANGED)
  const [submitError, setSubmitError] = useState(null)
  const [busy, setBusy] = useState(false)
  const intent = useRef(null)
  if (!intent.current) intent.current = createOperationIntent()
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()

  // Qualquer campo alterado = nova intenção e nova confirmação.
  const set = (k, v) => { intent.current.reset(); setErrors((e) => ({ ...e, [k]: undefined })); setSubmitError(null); setF((s) => ({ ...s, [k]: v })) }

  function review(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const r = validateMonthPaymentDraft(f, { openCents: open })
    if (!r.ok) { setErrors(r.errors); return }
    setNotice(null)
    setSubmitError(null)
    // o saldo confirmado é o do detalhe que está na tela AGORA (vem do servidor)
    setConfirmed({ value: r.value, expectedOpen: open, preview: previewMonthSplit(detail.occurrences, r.value.amount) })
    setStep('confirm')
  }

  async function submit() {
    if (!confirmed || guard.current.busy) return
    const { value, expectedOpen } = confirmed
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      intent: intent.current,
      send: (op) => api.recordPayment(op, detail.lineage_id, {
        month, amount: value.amount, method: value.method, receivedAt: value.at, notes: value.notes, expectedOpen,
      }),
      onSuccess: async (res) => {
        const d = res.data
        toast.success(d?.idempotent ? 'Recebimento já registrado' : `Recebimento registrado: ${moneyOrDash(d?.applied)} em ${d?.items?.length ?? 0} jogo(s)`)
        await onDone(d)
      },
      onError: async (err) => {
        const reason = monthErrorReason(err)
        if (err?.code === 'IDEMPOTENCY_MISMATCH') intent.current.reset()
        if (!keepsIntent(err)) intent.current.reset()
        if (RELOAD_AND_REVIEW.includes(reason)) {
          // confirmação anterior invalidada: refetch e nova confirmação explícita com intent novo
          setConfirmed(null)
          setStep('form')
          setNotice(MONTH_REASON_MSG[reason])
          await onReload()
          return
        }
        if (RELOAD_AND_CLOSE.includes(reason)) {
          toast.error(monthErrorMessage(err))
          await onReload()
          onClose()
          return
        }
        if (err?.status === 403 || err?.status === 404) { toast.error(monthErrorMessage(err)); onClose(); return }
        setSubmitError(monthErrorMessage(err))
      },
    })
  }

  const back = () => { if (busy) return; setStep('form'); setConfirmed(null) }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>Receber {monthName(month)}</DialogTitle>
          <DialogDescription>
            {detail.customer?.name || 'Mensalista'} · saldo do mês de {monthLabel(month)}: <strong>{moneyOrDash(open)}</strong>.
            O valor é distribuído pelo sistema, dos jogos mais antigos para os mais novos.
          </DialogDescription>
        </DialogHeader>

        {notice && (
          <p className="flex items-start gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-200" role="alert">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />{notice}
          </p>
        )}

        {step === 'form' ? (
          <form onSubmit={review} className="space-y-3" noValidate>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1.5">
                <Label htmlFor="rm-amount">Valor</Label>
                <Input id="rm-amount" className="h-11 sm:h-9" value={f.amount} inputMode="decimal" placeholder="150,00" autoFocus
                  onChange={(e) => set('amount', e.target.value)} aria-invalid={!!errors.amount} aria-describedby={errors.amount ? 'rm-amount-error' : 'rm-amount-hint'} />
                {errors.amount
                  ? <p id="rm-amount-error" className="text-xs text-amber-500" role="alert">{errors.amount}</p>
                  : <p id="rm-amount-hint" className="text-xs text-muted-foreground">Máximo: {moneyOrDash(open)}. Menos que isso = recebimento parcial.</p>}
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="rm-method">Meio</Label>
                <Select value={f.method} onValueChange={(v) => set('method', v)}>
                  <SelectTrigger id="rm-method" className="h-11 sm:h-9" aria-invalid={!!errors.method}><SelectValue /></SelectTrigger>
                  <SelectContent>{PAYMENT_METHODS.map((m) => <SelectItem key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</SelectItem>)}</SelectContent>
                </Select>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="rm-at">Data do recebimento</Label>
              <Input id="rm-at" type="datetime-local" className="h-11 sm:h-9" value={f.at} onChange={(e) => set('at', e.target.value)}
                aria-invalid={!!errors.at} aria-describedby={errors.at ? 'rm-at-error' : undefined} />
              {errors.at && <p id="rm-at-error" className="text-xs text-amber-500" role="alert">{errors.at}</p>}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="rm-notes">Observação (opcional)</Label>
              <Textarea id="rm-notes" rows={2} maxLength={500} value={f.notes} onChange={(e) => set('notes', e.target.value)}
                aria-invalid={!!errors.notes} aria-describedby={errors.notes ? 'rm-notes-error' : undefined} />
              {errors.notes && <p id="rm-notes-error" className="text-xs text-amber-500" role="alert">{errors.notes}</p>}
            </div>
            <DialogFooter className="gap-2">
              <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose}>Cancelar</Button>
              <Button type="submit" className="h-11 sm:h-9">Revisar recebimento</Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-3">
            <dl className="grid grid-cols-2 gap-2 rounded-lg bg-muted/30 p-3 text-sm">
              <dt className="text-muted-foreground">Valor</dt><dd className="text-right font-semibold">{moneyOrDash(confirmed.value.amount)}</dd>
              <dt className="text-muted-foreground">Meio</dt><dd className="text-right">{PAYMENT_METHOD_LABELS[confirmed.value.method]}</dd>
              <dt className="text-muted-foreground">Saldo confirmado do mês</dt><dd className="text-right">{moneyOrDash(confirmed.expectedOpen)}</dd>
            </dl>
            <div>
              <p className="text-sm font-medium">Prévia da distribuição</p>
              <p className="text-xs text-muted-foreground">Previsão visual. O sistema confirma a distribuição real ao registrar.</p>
              <ul className="mt-2 divide-y divide-border rounded-lg border border-border text-sm" aria-label="Prévia da distribuição por jogo">
                {confirmed.preview.map((p) => (
                  <li key={p.reservation_id} className="flex justify-between px-3 py-2"><span>Jogo de {dayMonth(p.occurrence_date)}</span><span className="tabular-nums">{moneyOrDash(p.amount)}</span></li>
                ))}
              </ul>
            </div>
            {submitError && <p className="text-sm text-amber-500" role="alert">{submitError}</p>}
            <DialogFooter className="gap-2">
              <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={back} disabled={busy}>Voltar</Button>
              <Button type="button" className="h-11 sm:h-9" onClick={submit} disabled={busy} autoFocus>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Confirmar recebimento
              </Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
