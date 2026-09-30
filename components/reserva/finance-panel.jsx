'use client'

// FASE 03A — painel financeiro de UMA reserva (agenda / reservas).
// Autoridade é sempre o banco: este componente só exibe o que a RPC de detalhe devolve e envia
// intenções às RPCs. Cada intenção (pagamento/estorno) tem operation_id + received_at gerados UMA vez
// e reenviados iguais em retry; qualquer edição do formulário descarta a chave (nova intenção).
import { useCallback, useEffect, useRef, useState } from 'react'
import { newOperationId } from '@/lib/reserva/operation-id'
import { formatCents, parseMoneyToCents, centsToInput } from '@/lib/reserva/money'
import { PAYMENT_METHODS, PAYMENT_METHOD_LABELS, PRICE_REASONS, PRICE_REASON_LABELS, paymentStatusMeta, localInputToISO, nowLocalInput } from '@/lib/reserva/finance'
import { fmtDateTimeLong } from '@/lib/reserva/time'
import { isManagerOrAbove } from '@/lib/auth/permissions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Textarea } from '@/components/ui/textarea'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Loader2, Plus, Undo2, Ban, Tag } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

export function PaymentStatusBadge({ status, className }) {
  if (!status) return null
  const m = paymentStatusMeta(status)
  return <Badge className={cn('border font-normal', m.badge, className)}>{m.label}</Badge>
}

const jsonPost = (url, body, method = 'POST') => fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

function refundableOf(entry, entries) {
  const refunded = entries.filter((e) => e.kind === 'REFUND' && e.refund_of === entry.id && !e.voided_at).reduce((s, e) => s + e.amount, 0)
  return entry.amount - refunded
}

export function FinancePanel({ reservationId, role, onLoaded, onChanged }) {
  const canManage = isManagerOrAbove(role)
  const [fin, setFin] = useState(null)
  const [failed, setFailed] = useState(false)
  const [dlg, setDlg] = useState(null)
  const onLoadedRef = useRef(onLoaded)
  onLoadedRef.current = onLoaded

  const load = useCallback(async () => {
    try {
      const r = await fetch(`/api/reservations/${reservationId}/financials`)
      if (!r.ok) { setFailed(true); return }
      const d = await r.json()
      setFin(d); setFailed(false); onLoadedRef.current?.(d)
    } catch { setFailed(true) }
  }, [reservationId])
  useEffect(() => { load() }, [load])

  const done = async () => { setDlg(null); await load(); onChanged?.() }

  if (failed) return <p className="mt-4 rounded-lg border border-border px-3 py-2 text-xs text-muted-foreground">Financeiro indisponível no momento.</p>
  if (!fin) return <Skeleton className="mt-4 h-28 w-full" />
  if (fin.payment_status === 'NOT_APPLICABLE') return null

  const entries = fin.entries || []
  const canPay = fin.collectible && fin.amount_due != null && fin.collectible_balance > 0
  return (
    <div className="mt-5 space-y-3 rounded-xl border border-border bg-card p-4">
      <div className="flex items-center justify-between">
        <p className="text-sm font-semibold">Financeiro</p>
        <PaymentStatusBadge status={fin.payment_status} />
      </div>
      <div className="grid grid-cols-2 gap-2 text-sm">
        <Amount label="Valor da reserva" value={fin.amount_due == null ? 'Sem valor' : formatCents(fin.amount_due)} />
        <Amount label="Recebido (líquido)" value={formatCents(fin.net_received)} />
        {fin.amount_refunded > 0 && <Amount label="Estornado" value={formatCents(fin.amount_refunded)} />}
        {fin.collectible && fin.amount_due != null && <Amount label="A receber" value={formatCents(fin.collectible_balance)} strong />}
      </div>
      {!fin.collectible && fin.net_received > 0 && (
        <p className="rounded-lg border border-amber-500/30 bg-amber-500/[0.06] px-3 py-2 text-xs text-amber-500">Reserva cancelada com {formatCents(fin.net_received)} retidos. Estorne se o valor precisar ser devolvido.</p>
      )}
      <div className="flex flex-wrap gap-2">
        {canPay && <Button size="sm" onClick={() => setDlg({ type: 'payment' })}><Plus className="mr-1.5 h-3.5 w-3.5" /> Registrar pagamento</Button>}
        {fin.collectible && fin.amount_due == null && !canManage && <p className="text-xs text-muted-foreground">Sem valor definido. Peça a um gerente para definir o valor.</p>}
        {canManage && <Button size="sm" variant="outline" onClick={() => setDlg({ type: 'price' })}><Tag className="mr-1.5 h-3.5 w-3.5" /> Alterar valor</Button>}
      </div>
      {entries.length > 0 && (
        <div className="space-y-1.5 border-t border-border pt-3">
          <p className="text-xs font-medium text-muted-foreground">Lançamentos</p>
          {entries.map((e) => (
            <div key={e.id} className={cn('flex items-start justify-between gap-2 rounded-lg border border-border px-3 py-2 text-xs', e.voided_at && 'opacity-60')}>
              <div className="min-w-0">
                <p className={cn('font-medium', e.voided_at && 'line-through')}>
                  {e.kind === 'REFUND' ? 'Estorno' : 'Pagamento'} · {PAYMENT_METHOD_LABELS[e.method] || e.method} · {e.kind === 'REFUND' ? '−' : ''}{formatCents(e.amount)}
                </p>
                <p className="text-muted-foreground">{fmtDateTimeLong(e.received_at)}{e.notes ? ` · ${e.notes}` : ''}</p>
                {e.voided_at && <p className="text-muted-foreground">Anulado{e.void_reason ? `: ${e.void_reason}` : ''}</p>}
              </div>
              {canManage && !e.voided_at && (
                <div className="flex shrink-0 gap-1">
                  {e.kind === 'PAYMENT' && refundableOf(e, entries) > 0 && (
                    <Button size="icon" variant="ghost" className="h-7 w-7" title="Estornar" onClick={() => setDlg({ type: 'refund', entry: e, refundable: refundableOf(e, entries) })}><Undo2 className="h-3.5 w-3.5" /></Button>
                  )}
                  <Button size="icon" variant="ghost" className="h-7 w-7 hover:text-destructive" title="Anular lançamento" onClick={() => setDlg({ type: 'void', entry: e })}><Ban className="h-3.5 w-3.5" /></Button>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
      {dlg?.type === 'payment' && <EntryDialog title="Registrar pagamento" url={`/api/reservations/${reservationId}/payments`} defaultCents={fin.collectible_balance} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.type === 'refund' && <EntryDialog title="Estornar pagamento" url={`/api/payments/${dlg.entry.id}/refund`} defaultCents={dlg.refundable} defaultMethod={dlg.entry.method} refund onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.type === 'void' && <VoidDialog entry={dlg.entry} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.type === 'price' && <PriceDialog reservationId={reservationId} current={fin.amount_due} onClose={() => setDlg(null)} onDone={done} />}
    </div>
  )
}

function Amount({ label, value, strong }) {
  return <div className="rounded-lg bg-muted/30 px-3 py-2"><p className="text-xs text-muted-foreground">{label}</p><p className={cn('text-sm', strong && 'font-semibold')}>{value}</p></div>
}

// Pagamento ou estorno: mesma forma de intenção (valor, meio, data, observação).
function EntryDialog({ title, url, defaultCents, defaultMethod = 'PIX', refund = false, onClose, onDone }) {
  const [f, setF] = useState({ amount: centsToInput(defaultCents), method: defaultMethod, received: nowLocalInput(), notes: '' })
  const [busy, setBusy] = useState(false)
  const opRef = useRef(null)
  const set = (k, v) => { opRef.current = null; setF((s) => ({ ...s, [k]: v })) }

  async function submit() {
    const amount = parseMoneyToCents(f.amount)
    if (amount === null || amount < 1) { toast.error('Valor inválido', { description: 'Use o formato 150,00.' }); return }
    const received_at = localInputToISO(f.received)
    if (!received_at) { toast.error('Informe a data e a hora'); return }
    if (!opRef.current) {
      try { opRef.current = newOperationId() } catch { toast.error('Não foi possível iniciar a operação neste navegador'); return }
    }
    setBusy(true)
    try {
      const r = await jsonPost(url, { operation_id: opRef.current, method: f.method, amount, received_at, notes: f.notes || null })
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error(d.error || 'Não foi possível concluir'); return }
      toast.success(d.idempotent ? 'Lançamento já registrado' : refund ? 'Estorno registrado' : 'Pagamento registrado')
      await onDone()
    } catch {
      // Falha de rede: o servidor PODE ter confirmado. A chave é mantida para o retry receber o replay.
      toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.')
    } finally { setBusy(false) }
  }

  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>{title}</DialogTitle></DialogHeader>
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5"><Label>Valor</Label><Input value={f.amount} onChange={(e) => set('amount', e.target.value)} inputMode="decimal" placeholder="150,00" /></div>
            <div className="space-y-1.5"><Label>Meio</Label>
              <Select value={f.method} onValueChange={(v) => set('method', v)}><SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>{PAYMENT_METHODS.map((m) => <SelectItem key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</SelectItem>)}</SelectContent></Select>
            </div>
          </div>
          <div className="space-y-1.5"><Label>{refund ? 'Data do estorno' : 'Data do recebimento'}</Label><Input type="datetime-local" value={f.received} onChange={(e) => set('received', e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Observação (opcional)</Label><Textarea rows={2} value={f.notes} onChange={(e) => set('notes', e.target.value)} maxLength={500} /></div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={submit} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirmar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function VoidDialog({ entry, onClose, onDone }) {
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  async function submit() {
    if (!reason.trim()) { toast.error('Informe o motivo da anulação'); return }
    setBusy(true)
    try {
      const r = await jsonPost(`/api/payments/${entry.id}/void`, { reason: reason.trim() })
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error(d.error || 'Não foi possível anular'); return }
      toast.success(d.changed === false ? 'Lançamento já estava anulado' : 'Lançamento anulado')
      await onDone()
    } catch { toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.') } finally { setBusy(false) }
  }
  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>Anular lançamento</DialogTitle></DialogHeader>
        <p className="text-sm text-muted-foreground">Use para corrigir um lançamento registrado por engano (o dinheiro não se moveu). Para devolver dinheiro ao cliente, use Estornar. O histórico é preservado.</p>
        <div className="space-y-1.5"><Label>Motivo</Label><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} placeholder="Ex.: valor digitado errado" /></div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Voltar</Button>
          <Button variant="destructive" onClick={submit} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Anular</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function PriceDialog({ reservationId, current, onClose, onDone }) {
  const [mode, setMode] = useState('MANUAL')
  const [value, setValue] = useState(centsToInput(current))
  const [reason, setReason] = useState('CORRECTION')
  const [busy, setBusy] = useState(false)
  async function submit() {
    let price = null
    if (mode === 'MANUAL' && value.trim() !== '') {
      price = parseMoneyToCents(value)
      if (price === null) { toast.error('Valor inválido', { description: 'Use o formato 150,00.' }); return }
    }
    setBusy(true)
    try {
      const r = await jsonPost(`/api/reservations/${reservationId}/price`, { mode, price, reason: mode === 'RULE' ? 'RULE_RECALC' : reason }, 'PUT')
      const d = await r.json().catch(() => ({}))
      if (!r.ok) { toast.error(d.error || 'Não foi possível alterar o valor'); return }
      toast.success(d.changed === false ? 'O valor já era este' : 'Valor atualizado')
      await onDone()
    } catch { toast.error('Não foi possível confirmar a resposta do servidor. Tente novamente.') } finally { setBusy(false) }
  }
  return (
    <Dialog open onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader><DialogTitle>Alterar valor da reserva</DialogTitle></DialogHeader>
        <p className="text-sm text-muted-foreground">Valor atual: {current == null ? 'sem valor' : formatCents(current)}. Pagamentos já registrados não mudam.</p>
        <div className="space-y-3">
          <div className="inline-flex rounded-lg border border-border p-0.5">
            {[['MANUAL', 'Informar valor'], ['RULE', 'Recalcular pela tabela']].map(([k, l]) => (
              <button key={k} onClick={() => setMode(k)} className={cn('rounded-md px-3 py-1.5 text-sm', mode === k ? 'bg-primary text-primary-foreground' : 'text-muted-foreground')}>{l}</button>
            ))}
          </div>
          {mode === 'MANUAL' && (
            <>
              <div className="space-y-1.5"><Label>Novo valor</Label><Input value={value} onChange={(e) => setValue(e.target.value)} inputMode="decimal" placeholder="150,00 (vazio = sem valor)" /></div>
              <div className="space-y-1.5"><Label>Motivo</Label>
                <Select value={reason} onValueChange={setReason}><SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>{PRICE_REASONS.filter((r) => r !== 'RULE_RECALC').map((r) => <SelectItem key={r} value={r}>{PRICE_REASON_LABELS[r]}</SelectItem>)}</SelectContent></Select>
              </div>
            </>
          )}
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>Cancelar</Button>
          <Button onClick={submit} disabled={busy}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Salvar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// Quantas das ocorrências informadas já têm dinheiro líquido recebido (aviso antes de reagendar,
// pausar ou cancelar uma série: essas ocorrências ficariam canceladas com valor retido).
export async function countPaidOccurrences(ids) {
  const map = await fetchPaymentSummaries(ids)
  return Object.values(map).filter((x) => (x.net_received != null ? x.net_received > 0 : ['PARTIAL', 'PAID', 'OVERPAID'].includes(x.payment_status))).length
}

// Resumos (status de pagamento) para listas; falha = mapa vazio (a lista nunca quebra por isso).
export async function fetchPaymentSummaries(ids) {
  const list = [...new Set((ids || []).filter(Boolean))].slice(0, 500)
  if (!list.length) return {}
  try {
    const r = await jsonPost('/api/reservations/financial-summaries', { reservation_ids: list })
    if (!r.ok) return {}
    const rows = await r.json()
    return Object.fromEntries((Array.isArray(rows) ? rows : []).map((x) => [x.reservation_id, x]))
  } catch { return {} }
}
