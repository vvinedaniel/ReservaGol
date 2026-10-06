'use client'

// FASE 03B.3B — jogos sem valor no mês (OWNER/MANAGER):
//   1) "Definir valor da série" — só para as séries do mês que ainda não têm default_price, pelo PATCH já
//      existente (/api/recurring-reservations/:id {default_price}); depois do PATCH: refetch.
//   2) W2 "Aplicar valor da série" — rg_recurring_month_apply_series_price: preenche SOMENTE price IS NULL
//      dos jogos cobráveis do mês com o default_price da própria série; nunca sobrescreve valor existente.
// Quais séries precisam de valor vem dos dados do servidor (unpricedSeries); nenhum valor é calculado aqui.
import { useRef, useState } from 'react'
import { toast } from 'sonner'
import { unpricedSeries, validateSeriesPrice, slotLabel, monthName, moneyOrDash, monthErrorMessage } from '@/lib/reserva/recurring-month'
import { createSubmitGuard, submitWithBusy } from '@/lib/reserva/expense-mutation'
import { focusReturn } from '@/components/reserva/finance/expense-forms'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2 } from 'lucide-react'

const DIALOG_CLASS = 'max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none'

async function patchSeriesPrice(seriesId, cents) {
  let r
  try {
    r = await fetch(`/api/recurring-reservations/${encodeURIComponent(seriesId)}`, {
      method: 'PATCH', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ default_price: cents }),
    })
  } catch { throw new Error('Não foi possível confirmar a resposta do servidor. Atualize e confira o valor da série.') }
  if (!r.ok) {
    const d = await r.json().catch(() => null)
    throw new Error(typeof d?.error === 'string' ? d.error : 'Não foi possível salvar o valor da série.')
  }
}

export function ApplySeriesPriceDialog({ api, detail, month, onClose, onDone, onReload, returnFocusTo }) {
  const { withoutPrice, withPrice } = unpricedSeries(detail)
  const [prices, setPrices] = useState({})
  const [errors, setErrors] = useState({})
  const [submitError, setSubmitError] = useState(null)
  const [busy, setBusy] = useState(false)
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()
  const needsPrice = withoutPrice.length > 0

  async function savePrices(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const parsed = {}
    const errs = {}
    for (const s of withoutPrice) {
      const v = validateSeriesPrice(prices[s.series_id] ?? '')
      if (!v.ok) errs[s.series_id] = v.error
      else parsed[s.series_id] = v.value
    }
    if (Object.keys(errs).length) { setErrors(errs); return }
    setErrors({})
    setSubmitError(null)
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: async () => { for (const s of withoutPrice) await patchSeriesPrice(s.series_id, parsed[s.series_id]) },
      onSuccess: async () => { toast.success('Valor da série definido'); await onReload() },
      onError: async (err) => { setSubmitError(err?.message || 'Não foi possível salvar o valor da série.'); await onReload() },
    })
  }

  async function apply() {
    if (guard.current.busy) return
    setSubmitError(null)
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: () => api.applySeriesPrice(detail.lineage_id, month),
      onSuccess: async (res) => {
        const d = res.data
        toast.success(d?.updated > 0 ? `${d.updated} jogo(s) receberam o valor da série` : 'Nenhum jogo sem valor para atualizar')
        if (d?.remaining_unpriced > 0) toast.message(`${d.remaining_unpriced} jogo(s) continuam sem valor`)
        await onDone()
      },
      onError: async (err) => { setSubmitError(monthErrorMessage(err)); await onReload() },
    })
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>{needsPrice ? 'Definir valor da série' : 'Aplicar valor da série'}</DialogTitle>
          <DialogDescription>
            {needsPrice
              ? 'Defina o valor por jogo desta série. Ele vale para jogos futuros e pode ser aplicado aos jogos sem valor do mês no passo seguinte.'
              : `Preenche somente os ${detail.summary.unpriced} jogo(s) sem valor de ${monthName(month)} com o valor da própria série. Jogos que já têm valor não mudam.`}
          </DialogDescription>
        </DialogHeader>

        {needsPrice ? (
          <form onSubmit={savePrices} className="space-y-3" noValidate>
            {withoutPrice.map((s, i) => (
              <div key={s.series_id} className="space-y-1.5">
                <Label htmlFor={`sp-${s.series_id}`}>Valor por jogo — {slotLabel(s)} · {s.court_name}</Label>
                <Input id={`sp-${s.series_id}`} className="h-11 sm:h-9" inputMode="decimal" placeholder="150,00" autoFocus={i === 0}
                  value={prices[s.series_id] ?? ''} onChange={(e) => { const v = e.target.value; setPrices((p) => ({ ...p, [s.series_id]: v })); setErrors((x) => ({ ...x, [s.series_id]: undefined })) }}
                  aria-invalid={!!errors[s.series_id]} aria-describedby={errors[s.series_id] ? `sp-${s.series_id}-error` : undefined} />
                {errors[s.series_id] && <p id={`sp-${s.series_id}-error`} className="text-xs text-amber-500" role="alert">{errors[s.series_id]}</p>}
              </div>
            ))}
            {submitError && <p className="text-sm text-amber-500" role="alert">{submitError}</p>}
            <DialogFooter className="gap-2">
              <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Cancelar</Button>
              <Button type="submit" className="h-11 sm:h-9" disabled={busy}>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Salvar valor
              </Button>
            </DialogFooter>
          </form>
        ) : (
          <div className="space-y-3">
            <ul className="divide-y divide-border rounded-lg border border-border text-sm" aria-label="Valor de cada série">
              {withPrice.map((s) => (
                <li key={s.series_id} className="flex justify-between gap-2 px-3 py-2"><span className="truncate">{slotLabel(s)} · {s.court_name}</span><span className="tabular-nums">{moneyOrDash(s.default_price)}</span></li>
              ))}
            </ul>
            {submitError && <p className="text-sm text-amber-500" role="alert">{submitError}</p>}
            <DialogFooter className="gap-2">
              <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Cancelar</Button>
              <Button type="button" className="h-11 sm:h-9" onClick={apply} disabled={busy || withPrice.length === 0} autoFocus>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Aplicar aos jogos sem valor
              </Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
