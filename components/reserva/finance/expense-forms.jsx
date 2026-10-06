'use client'

// FASE 03B.2B-2B — formulários de escrita de Despesas: criar/editar despesa, registrar pagamento,
// registrar devolução, anular lançamento e cancelar despesa. O banco é a autoridade (RPCs da 03B.2):
// aqui só validação de formato (helpers puros congelados), envio pelo client e mensagens saneadas.
// - operation_id por intenção (createOperationIntent): 1º envio gera, retry reutiliza, qualquer campo
//   alterado ou o fechamento descarta; sucesso descarta.
// - um envio por vez (createSubmitGuard: guarda síncrona contra duplo clique) + botão desabilitado.
// - nenhuma atualização otimista: quem abriu recarrega as fontes depois do sucesso (onDone).
// - 403 numa mutação vira só mensagem (não derruba a página; isso é só para leituras).
// 03B.2B-2B.1: estado visual via submitWithBusy (2ª invocação nunca libera o busy da 1ª); criação inline
// de categoria trava o diálogo; CATEGORY_INACTIVE concorrente recarrega categorias sem trocar a escolha.
// 03B.2B-2B.2: categoria criada inline selecionada em duas fases (pendingCategoryReady); foco devolvido
// ao botão que abriu cada diálogo (focusReturn); motivo recebe o foco inicial no AlertDialog.
import { useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import {
  validateExpenseDraft, buildExpenseChanges, validateEntryDraft, validateReason, validateCategoryName, categoryOptions,
  createOperationIntent, reversibleOf, fmtDueDate,
} from '@/lib/reserva/expenses'
import { createSubmitGuard, submitWithBusy, mutationErrorMessage, shouldReloadAfterError, categoryReloadNeeded, successMessage } from '@/lib/reserva/expense-mutation'
import { formatCents, centsToInput, toCents } from '@/lib/reserva/money'
import { PAYMENT_METHODS, PAYMENT_METHOD_LABELS, nowLocalInput } from '@/lib/reserva/finance'
import { todayStr, fmtDateTimeLong } from '@/lib/reserva/time'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { AlertDialog, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Loader2, Plus } from 'lucide-react'

const GENERAL = 'general'
const DIALOG_CLASS = 'max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none'

// Rótulo + controle + erro associado (aria-describedby / aria-invalid).
function Field({ id, label, error, hint, children }) {
  return (
    <div className="space-y-1.5">
      <Label htmlFor={id}>{label}</Label>
      {children}
      {hint && !error && <p id={`${id}-hint`} className="text-xs text-muted-foreground">{hint}</p>}
      {error && <p id={`${id}-error`} className="text-xs text-amber-500" role="alert">{error}</p>}
    </div>
  )
}
const describedBy = (id, error, hint) => (error ? `${id}-error` : hint ? `${id}-hint` : undefined)

// Devolve o foco ao botão que abriu o diálogo (onCloseAutoFocus). Sem DialogTrigger, o Radix mandaria o
// foco para o body. Botão desmontado: comportamento padrão; botão desabilitado (detalhe recarregando
// depois da mutação): foco no diálogo pai que o contém.
export function focusReturn(ref) {
  return (e) => {
    const el = ref?.current
    if (!el || !el.isConnected) return
    const target = el.disabled ? el.closest('[role="dialog"]') : el
    if (!target) return
    e.preventDefault()
    target.focus()
  }
}

// Categoria criada inline: o Select (Radix) mantém um <select> nativo interno. Se o valor controlado
// mudar no MESMO render em que a opção nova entra, o nativo ainda não tem a opção, normaliza para '' e
// devolve '' ao onValueChange. Fase 1 (sucesso da RPC): guarda a categoria confirmada e o id pendente.
// Fase 2 (effect): aplica o id só quando a opção ATIVA já está no conjunto selecionável renderizado.
export function pendingCategoryReady(pendingId, selectable) {
  return !!pendingId && selectable.some((c) => c.id === pendingId && c.is_active === true)
}

// busy = ESTA mutação está em voo (spinner); disabled = qualquer mutação concorrente (sem spinner).
function SubmitButton({ busy, disabled = busy, children, variant }) {
  return (
    <Button type="submit" variant={variant} className="h-11 sm:h-9" disabled={disabled}>
      {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}{children}
    </Button>
  )
}

// ------------------------------------------------------------------ criar / editar despesa
export function ExpenseFormDialog({ mode, api, orgId, arenas = [], categories = [], detail = null, onClose, onDone, onCategoriesChanged, returnFocusTo }) {
  const editing = mode === 'edit'
  const [f, setF] = useState(() => (editing
    ? { description: detail.description || '', category_id: detail.category_id || '', arena_id: detail.arena_id || '', amount: centsToInput(detail.amount), due_date: detail.due_date || '', notes: detail.notes || '' }
    : { description: '', category_id: '', arena_id: '', amount: '', due_date: todayStr(), notes: '' }))
  const [errors, setErrors] = useState({})
  const [busy, setBusy] = useState(false)
  const [newCat, setNewCat] = useState(null)
  // Categoria criada aqui e JÁ CONFIRMADA pela RPC: rótulo transitório até a lista recarregada chegar.
  const [confirmedCat, setConfirmedCat] = useState(null)
  const [pendingCategoryId, setPendingCategoryId] = useState(null)
  const intent = useRef(null)
  if (!intent.current) intent.current = createOperationIntent()
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()

  const amountLocked = editing && detail.amount_locked === true
  const arenaLocked = editing && detail.arena_locked === true
  // Criação inline de categoria em voo também trava o diálogo (mesma guarda; sem spinner na despesa).
  const categoryBusy = newCat?.busy === true
  const locked = busy || categoryBusy
  const options = categoryOptions(categories, editing ? detail.category_id : null)
  const selectable = confirmedCat && confirmedCat.is_active && !options.some((c) => c.id === confirmedCat.id) ? [...options, confirmedCat] : options
  // Qualquer campo alterado = nova intenção (descarta o operation_id da anterior).
  const set = (k, v) => { intent.current.reset(); setErrors((e) => ({ ...e, [k]: undefined })); setF((s) => ({ ...s, [k]: v })) }
  // Fase 2 da categoria inline: a opção já foi renderizada; só agora o valor controlado muda.
  const selectableHasPending = pendingCategoryReady(pendingCategoryId, selectable)
  useEffect(() => {
    if (!selectableHasPending) return
    set('category_id', pendingCategoryId)
    setPendingCategoryId(null)
  }, [pendingCategoryId, selectableHasPending])
  // Categoria inativada por outra sessão: recarrega as categorias, mantém a escolha e a intenção.
  const onSaveError = (err) => {
    toast.error(mutationErrorMessage(err))
    if (categoryReloadNeeded(err)) onCategoriesChanged?.()
    if (editing && shouldReloadAfterError(err)) onDone({ kind: 'reload', keepOpen: true })
  }

  async function submit(e) {
    e.preventDefault()
    if (locked || guard.current.busy) return
    const r = validateExpenseDraft(f)
    if (!r.ok) { setErrors(r.errors); return }
    if (editing) {
      const changes = buildExpenseChanges(detail, r.value)
      if (Object.keys(changes).length === 0) { toast.info('Nada a alterar'); onClose(); return }
      await submitWithBusy({
        guard: guard.current,
        setBusy,
        send: () => api.updateExpense(detail.expense_id, changes),
        onSuccess: async (res) => { toast.success(successMessage('update', res.data)); await onDone({ kind: 'update' }) },
        onError: onSaveError,
      })
      return
    }
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      intent: intent.current,
      send: (op) => api.createExpense(op, orgId, r.value),
      onSuccess: async (res) => { await onDone({ kind: 'create', expenseId: res.data?.expense_id, idempotent: res.data?.idempotent === true }) },
      onError: onSaveError,
    })
  }

  async function createCategory() {
    if (guard.current.busy) return
    const v = validateCategoryName(newCat?.name)
    if (!v.ok) { setNewCat((s) => ({ ...s, error: v.error })); return }
    setNewCat((s) => ({ ...s, error: null }))
    await submitWithBusy({
      guard: guard.current,
      setBusy: (b) => setNewCat((s) => (s ? { ...s, busy: b } : s)),
      send: () => api.createCategory(orgId, v.value),
      onSuccess: async (res) => {
        toast.success(successMessage('category-create', res.data))
        const c = res.data
        if (c?.category_id) setConfirmedCat({ id: c.category_id, name: c.name, is_active: c.is_active === true })
        if (c?.category_id && c.is_active === true) setPendingCategoryId(c.category_id)
        await onCategoriesChanged?.()
        setNewCat(null)
      },
      onError: (err) => setNewCat((s) => (s ? { ...s, error: mutationErrorMessage(err) } : s)),
    })
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !locked) onClose() }}>
      <DialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>{editing ? 'Editar despesa' : 'Nova despesa'}</DialogTitle>
          <DialogDescription>{editing ? 'Altere os dados da despesa. Valor e arena ficam bloqueados depois de um pagamento.' : 'Registre uma despesa a pagar. Pagamentos são registrados depois, no detalhe da despesa.'}</DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="space-y-3" noValidate>
          <Field id="exp-description" label="Descrição" error={errors.description}>
            <Input id="exp-description" className="h-11 sm:h-9" value={f.description} maxLength={200} onChange={(e) => set('description', e.target.value)}
              aria-invalid={!!errors.description} aria-describedby={describedBy('exp-description', errors.description)} />
          </Field>
          <Field id="exp-category" label="Categoria" error={errors.category_id}>
            <Select value={f.category_id || undefined} onValueChange={(v) => set('category_id', v)}>
              <SelectTrigger id="exp-category" className="h-11 sm:h-9" aria-invalid={!!errors.category_id} aria-describedby={describedBy('exp-category', errors.category_id)}><SelectValue placeholder="Escolha a categoria" /></SelectTrigger>
              <SelectContent>{selectable.map((c) => <SelectItem key={c.id} value={c.id}>{c.is_active ? c.name : `${c.name} (inativa)`}</SelectItem>)}</SelectContent>
            </Select>
            {newCat ? (
              <div className="flex flex-wrap items-start gap-2 pt-1">
                <Input id="exp-new-category" aria-label="Nome da nova categoria" className="h-11 min-w-0 flex-1 sm:h-9" value={newCat.name || ''} maxLength={60} autoFocus
                  onChange={(e) => setNewCat((s) => ({ ...s, name: e.target.value, error: null }))} aria-invalid={!!newCat.error} aria-describedby={newCat.error ? 'exp-new-category-error' : undefined} />
                <Button type="button" variant="outline" className="h-11 sm:h-9" disabled={locked} onClick={createCategory}>
                  {categoryBusy && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Criar
                </Button>
                <Button type="button" variant="ghost" className="h-11 sm:h-9" disabled={categoryBusy} onClick={() => setNewCat(null)}>Cancelar</Button>
                {newCat.error && <p id="exp-new-category-error" className="w-full text-xs text-amber-500" role="alert">{newCat.error}</p>}
              </div>
            ) : (
              <Button type="button" variant="ghost" className="h-11 px-2 sm:h-8" disabled={locked} onClick={() => setNewCat({ name: '' })}><Plus className="mr-1 h-4 w-4" /> Nova categoria</Button>
            )}
          </Field>
          <Field id="exp-arena" label="Arena" error={errors.arena_id} hint={arenaLocked ? 'Bloqueada: a despesa já tem pagamento.' : 'Geral = despesa da organização, sem arena.'}>
            <Select value={f.arena_id || GENERAL} onValueChange={(v) => set('arena_id', v === GENERAL ? '' : v)} disabled={arenaLocked}>
              <SelectTrigger id="exp-arena" className="h-11 sm:h-9" aria-describedby={describedBy('exp-arena', errors.arena_id, true)}><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value={GENERAL}>Geral</SelectItem>
                {arenas.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}
              </SelectContent>
            </Select>
          </Field>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field id="exp-amount" label="Valor" error={errors.amount} hint={amountLocked ? 'Bloqueado: a despesa já tem pagamento.' : undefined}>
              <Input id="exp-amount" className="h-11 sm:h-9" value={f.amount} inputMode="decimal" placeholder="150,00" disabled={amountLocked}
                onChange={(e) => set('amount', e.target.value)} aria-invalid={!!errors.amount} aria-describedby={describedBy('exp-amount', errors.amount, amountLocked)} />
            </Field>
            <Field id="exp-due" label="Vencimento" error={errors.due_date}>
              <Input id="exp-due" type="date" className="h-11 sm:h-9" value={f.due_date} onChange={(e) => set('due_date', e.target.value)}
                aria-invalid={!!errors.due_date} aria-describedby={describedBy('exp-due', errors.due_date)} />
            </Field>
          </div>
          <Field id="exp-notes" label="Observação (opcional)" error={errors.notes}>
            <Textarea id="exp-notes" rows={2} maxLength={500} value={f.notes} onChange={(e) => set('notes', e.target.value)}
              aria-invalid={!!errors.notes} aria-describedby={describedBy('exp-notes', errors.notes)} />
          </Field>
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={locked}>Cancelar</Button>
            <SubmitButton busy={busy} disabled={locked}>{editing ? 'Salvar' : 'Registrar despesa'}</SubmitButton>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

// ------------------------------------------------------------------ pagamento / devolução
// kind 'payment': até o valor a pagar da despesa. kind 'reverse': a partir de UM pagamento, até o
// disponível dele (valor − já devolvido). Data/hora padrão fixada ao abrir (faz parte da intenção).
export function EntryDialog({ kind, api, expense, entry = null, onClose, onDone, returnFocusTo }) {
  const reverse = kind === 'reverse'
  const max = reverse ? reversibleOf(entry) : (toCents(expense.amount_due) ?? 0)
  const [f, setF] = useState(() => ({ amount: centsToInput(max), method: reverse ? entry.method : 'PIX', at: nowLocalInput(), notes: '' }))
  const [errors, setErrors] = useState({})
  const [busy, setBusy] = useState(false)
  const intent = useRef(null)
  if (!intent.current) intent.current = createOperationIntent()
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()
  const set = (k, v) => { intent.current.reset(); setErrors((e) => ({ ...e, [k]: undefined })); setF((s) => ({ ...s, [k]: v })) }

  async function submit(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const r = validateEntryDraft(f, { maxCents: max })
    if (!r.ok) { setErrors(r.errors); return }
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      intent: intent.current,
      send: (op) => (reverse ? api.reversePayment(op, entry.payment_id, r.value) : api.registerPayment(op, expense.expense_id, r.value)),
      onSuccess: async (res) => { toast.success(successMessage(kind, res.data)); await onDone() },
      onError: (err) => { toast.error(mutationErrorMessage(err)); if (shouldReloadAfterError(err)) onDone({ keepOpen: true }) },
    })
  }

  const id = reverse ? 'rev' : 'pay'
  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>{reverse ? 'Registrar devolução' : 'Registrar pagamento'}</DialogTitle>
          <DialogDescription>
            {reverse
              ? 'Devolução registra dinheiro que realmente voltou deste pagamento (ex.: o fornecedor devolveu). Para corrigir um lançamento digitado errado, use Anular lançamento.'
              : `Pagamento da despesa "${expense.description}". Valor a pagar: ${formatCents(expense.amount_due)}.`}
          </DialogDescription>
        </DialogHeader>
        {reverse && (
          <div className="grid grid-cols-3 gap-2 text-xs">
            <div className="rounded-lg bg-muted/30 px-3 py-2"><p className="text-muted-foreground">Pagamento</p><p className="whitespace-nowrap font-medium">{formatCents(entry.amount)}</p></div>
            <div className="rounded-lg bg-muted/30 px-3 py-2"><p className="text-muted-foreground">Já devolvido</p><p className="whitespace-nowrap font-medium">{formatCents(entry.reversed ?? 0)}</p></div>
            <div className="rounded-lg bg-muted/30 px-3 py-2"><p className="text-muted-foreground">Disponível</p><p className="whitespace-nowrap font-semibold">{formatCents(max)}</p></div>
          </div>
        )}
        <form onSubmit={submit} className="space-y-3" noValidate>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field id={`${id}-amount`} label="Valor" error={errors.amount} hint={`Máximo: ${formatCents(max)}`}>
              <Input id={`${id}-amount`} className="h-11 sm:h-9" value={f.amount} inputMode="decimal" placeholder="150,00" onChange={(e) => set('amount', e.target.value)}
                aria-invalid={!!errors.amount} aria-describedby={describedBy(`${id}-amount`, errors.amount, true)} />
            </Field>
            <Field id={`${id}-method`} label="Meio" error={errors.method}>
              <Select value={f.method} onValueChange={(v) => set('method', v)}>
                <SelectTrigger id={`${id}-method`} className="h-11 sm:h-9" aria-invalid={!!errors.method} aria-describedby={describedBy(`${id}-method`, errors.method)}><SelectValue /></SelectTrigger>
                <SelectContent>{PAYMENT_METHODS.map((m) => <SelectItem key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</SelectItem>)}</SelectContent>
              </Select>
            </Field>
          </div>
          <Field id={`${id}-at`} label={reverse ? 'Data da devolução' : 'Data do pagamento'} error={errors.at}>
            <Input id={`${id}-at`} type="datetime-local" className="h-11 sm:h-9" value={f.at} onChange={(e) => set('at', e.target.value)}
              aria-invalid={!!errors.at} aria-describedby={describedBy(`${id}-at`, errors.at)} />
          </Field>
          <Field id={`${id}-notes`} label="Observação (opcional)" error={errors.notes}>
            <Textarea id={`${id}-notes`} rows={2} maxLength={500} value={f.notes} onChange={(e) => set('notes', e.target.value)}
              aria-invalid={!!errors.notes} aria-describedby={describedBy(`${id}-notes`, errors.notes)} />
          </Field>
          <DialogFooter className="gap-2">
            <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Cancelar</Button>
            <SubmitButton busy={busy}>{reverse ? 'Registrar devolução' : 'Registrar pagamento'}</SubmitButton>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

// ------------------------------------------------------------------ anular lançamento / cancelar despesa
// Confirmação explícita (AlertDialog) com motivo obrigatório. Sem operation_id: o banco já é
// idempotente (changed=false quando já estava anulado/cancelado).
export function ReasonDialog({ kind, api, expense, entry = null, onClose, onDone, returnFocusTo }) {
  const isVoid = kind === 'void'
  const reasonRef = useRef(null)
  const [reason, setReason] = useState('')
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()

  async function submit(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const r = validateReason(reason)
    if (!r.ok) { setError(r.error); return }
    await submitWithBusy({
      guard: guard.current,
      setBusy,
      send: () => (isVoid ? api.voidPayment(entry.payment_id, r.value) : api.cancelExpense(expense.expense_id, r.value)),
      onSuccess: async (res) => { toast.success(successMessage(kind, res.data)); await onDone() },
      onError: (err) => { toast.error(mutationErrorMessage(err)); if (shouldReloadAfterError(err)) onDone({ keepOpen: true }) },
    })
  }

  const id = isVoid ? 'void-reason' : 'cancel-reason'
  return (
    <AlertDialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <AlertDialogContent className={DIALOG_CLASS} onCloseAutoFocus={focusReturn(returnFocusTo)}
        onOpenAutoFocus={(e) => { if (reasonRef.current) { e.preventDefault(); reasonRef.current.focus() } }}>
        <AlertDialogHeader>
          <AlertDialogTitle>{isVoid ? 'Anular lançamento' : 'Cancelar despesa'}</AlertDialogTitle>
          <AlertDialogDescription>
            {isVoid
              ? `Anulação corrige um lançamento registrado por engano (o dinheiro não se moveu). Devolução registra dinheiro que realmente voltou. ${entry.kind === 'REVERSAL' ? 'Devolução' : 'Pagamento'} de ${formatCents(entry.amount)} em ${fmtDateTimeLong(entry.paid_at)}. O histórico é preservado.`
              : `A despesa "${expense.description}" (vencimento ${fmtDueDate(expense.due_date)}) ficará cancelada: o valor a pagar passa a ${formatCents(0)} e o histórico continua visível.`}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <form onSubmit={submit} className="space-y-3" noValidate>
          <Field id={id} label="Motivo" error={error}>
            <Textarea id={id} ref={reasonRef} autoFocus rows={2} maxLength={500} value={reason} onChange={(e) => { setReason(e.target.value); setError(null) }}
              placeholder={isVoid ? 'Ex.: valor digitado errado' : 'Ex.: lançada em duplicidade'} aria-invalid={!!error} aria-describedby={describedBy(id, error)} />
          </Field>
          <AlertDialogFooter className="gap-2">
            <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={onClose} disabled={busy}>Voltar</Button>
            <SubmitButton busy={busy} variant="destructive">{isVoid ? 'Anular lançamento' : 'Cancelar despesa'}</SubmitButton>
          </AlertDialogFooter>
        </form>
      </AlertDialogContent>
    </AlertDialog>
  )
}
