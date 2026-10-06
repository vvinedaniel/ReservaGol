'use client'

// FASE 03B.2B-2B — gerenciador mínimo de categorias de despesa: criar, renomear, ativar/inativar.
// Sem exclusão física (o banco não oferece). Categoria inativa some da criação de despesas, continua
// nas despesas antigas e pode ser reativada. Lista vem da aba (rg_expense_categories com inativas);
// depois de cada mutação a aba recarrega a lista (onChanged) — nada otimista.
// 03B.2B-2B.2: ao fechar, o foco volta ao botão "Categorias" (returnFocusTo).
import { useRef, useState } from 'react'
import { toast } from 'sonner'
import { validateCategoryName } from '@/lib/reserva/expenses'
import { focusReturn } from '@/components/reserva/finance/expense-forms'
import { createSubmitGuard, submitWithBusy, mutationErrorMessage, successMessage } from '@/lib/reserva/expense-mutation'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Loader2, Plus } from 'lucide-react'

export function ExpenseCategoriesDialog({ api, orgId, categories = [], onClose, onChanged, returnFocusTo }) {
  const [name, setName] = useState('')
  const [createError, setCreateError] = useState(null)
  const [editing, setEditing] = useState(null) // { id, name, error }
  const [busy, setBusy] = useState(null) // 'create' | `rename:${id}` | `toggle:${id}`
  const guard = useRef(null)
  if (!guard.current) guard.current = createSubmitGuard()

  // Guarda = autoridade síncrona; uma 2ª invocação durante o envio não toca no estado visual.
  // onChanged (da aba) recarrega categorias E lista/resumo: rg_expenses devolve category_name.
  function run(tag, send, kind, after) {
    return submitWithBusy({
      guard: guard.current,
      setBusy: (b) => setBusy(b ? tag : null),
      send,
      onSuccess: async (res) => { toast.success(successMessage(kind, res.data)); after?.(); await onChanged() },
      onError: (err) => { const msg = mutationErrorMessage(err); if (tag === 'create') setCreateError(msg); else if (tag.startsWith('rename:')) setEditing((s) => (s ? { ...s, error: msg } : s)); else toast.error(msg) },
    })
  }

  function create(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const v = validateCategoryName(name)
    if (!v.ok) { setCreateError(v.error); return }
    run('create', () => api.createCategory(orgId, v.value), 'category-create', () => { setName(''); setCreateError(null) })
  }
  function rename(e) {
    e.preventDefault()
    if (guard.current.busy) return
    const v = validateCategoryName(editing?.name)
    if (!v.ok) { setEditing((s) => ({ ...s, error: v.error })); return }
    const current = categories.find((c) => c.id === editing.id)
    if (current && current.name === v.value) { setEditing(null); return }
    run(`rename:${editing.id}`, () => api.updateCategory(editing.id, { name: v.value }), 'category-update', () => setEditing(null))
  }
  const toggle = (c) => { if (guard.current.busy) return; run(`toggle:${c.id}`, () => api.updateCategory(c.id, { is_active: !c.is_active }), 'category-update') }

  return (
    <Dialog open onOpenChange={(o) => { if (!o && !busy) onClose() }}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto motion-reduce:animate-none motion-reduce:transition-none" onCloseAutoFocus={focusReturn(returnFocusTo)}>
        <DialogHeader>
          <DialogTitle>Categorias de despesa</DialogTitle>
          <DialogDescription>Crie, renomeie ou inative categorias. Categoria inativa não aparece em novas despesas, continua nas despesas antigas e pode ser reativada.</DialogDescription>
        </DialogHeader>

        <form onSubmit={create} className="space-y-1.5" noValidate>
          <Label htmlFor="cat-new">Nova categoria</Label>
          <div className="flex gap-2">
            <Input id="cat-new" className="h-11 min-w-0 flex-1 sm:h-9" value={name} maxLength={60} placeholder="Ex.: Limpeza"
              onChange={(e) => { setName(e.target.value); setCreateError(null) }} aria-invalid={!!createError} aria-describedby={createError ? 'cat-new-error' : undefined} />
            <Button type="submit" className="h-11 sm:h-9" disabled={!!busy}>
              {busy === 'create' ? <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" /> : <Plus className="mr-1 h-4 w-4" />}Criar
            </Button>
          </div>
          {createError && <p id="cat-new-error" className="text-xs text-amber-500" role="alert">{createError}</p>}
        </form>

        <ul className="divide-y divide-border rounded-lg border border-border">
          {categories.map((c) => (
            <li key={c.id} className="px-3 py-2">
              {editing?.id === c.id ? (
                <form onSubmit={rename} className="space-y-1.5" noValidate>
                  <div className="flex flex-wrap gap-2">
                    <Input aria-label={`Novo nome para ${c.name}`} className="h-11 min-w-0 flex-1 sm:h-9" value={editing.name} maxLength={60} autoFocus
                      onChange={(e) => setEditing((s) => ({ ...s, name: e.target.value, error: null }))} aria-invalid={!!editing.error} aria-describedby={editing.error ? `cat-${c.id}-error` : undefined} />
                    <Button type="submit" className="h-11 sm:h-9" disabled={!!busy}>
                      {busy === `rename:${c.id}` && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}Salvar
                    </Button>
                    <Button type="button" variant="ghost" className="h-11 sm:h-9" onClick={() => setEditing(null)} disabled={!!busy}>Cancelar</Button>
                  </div>
                  {editing.error && <p id={`cat-${c.id}-error`} className="text-xs text-amber-500" role="alert">{editing.error}</p>}
                </form>
              ) : (
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="flex min-w-0 items-center gap-2">
                    <span className="truncate text-sm">{c.name}</span>
                    {!c.is_active && <Badge variant="outline" className="text-[10px] font-normal">Inativa</Badge>}
                  </span>
                  <span className="flex shrink-0 gap-1">
                    <Button type="button" variant="ghost" className="h-11 sm:h-8" disabled={!!busy} onClick={() => setEditing({ id: c.id, name: c.name, error: null })}>Renomear</Button>
                    <Button type="button" variant="outline" className="h-11 sm:h-8" disabled={!!busy} onClick={() => toggle(c)}>
                      {busy === `toggle:${c.id}` && <Loader2 className="mr-2 h-4 w-4 animate-spin motion-reduce:animate-none" />}{c.is_active ? 'Inativar' : 'Reativar'}
                    </Button>
                  </span>
                </div>
              )}
            </li>
          ))}
          {categories.length === 0 && <li className="px-3 py-4 text-center text-sm text-muted-foreground">Nenhuma categoria.</li>}
        </ul>
      </DialogContent>
    </Dialog>
  )
}
