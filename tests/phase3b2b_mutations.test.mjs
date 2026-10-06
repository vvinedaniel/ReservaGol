// Reserva Gol — FASE 03B.2B-2B — escrita de Despesas pela UI (puro/estático, sem rede e sem banco).
// Uso: node tests/phase3b2b_mutations.test.mjs
// Cobre: guarda de duplo envio e regras de intenção (lib/reserva/expense-mutation.js), fluxos de
// criação/edição/pagamento/devolução/anulação/cancelamento/categorias pelo client REAL contra a rota
// REAL (runExpenseRoute com RPC falsa), mensagens/recarga em erro, e os componentes de formulário
// (Title+Description, confirmação com motivo, intenção por campo, sem otimismo, 403 só mensagem,
// ações pelo estado real, mobile 44 px, acessibilidade, termos proibidos).
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createSubmitGuard, submitIntent, mutationErrorMessage, shouldReloadAfterError, successMessage } from '../lib/reserva/expense-mutation.js'
import { createExpensesApi, ExpenseRequestError, ExpenseNetworkError } from '../lib/reserva/expenses-client.js'
import { runExpenseRoute, financePathSegments, EXPENSE_HINT_MSG } from '../lib/reserva/expenses-api.js'
import { createOperationIntent, validateExpenseDraft, buildExpenseChanges, validateEntryDraft, validateReason, validateCategoryName, deriveExpenseActions, categoryOptions } from '../lib/reserva/expenses.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripJsComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const FORMS = stripJsComments(read('components/reserva/finance/expense-forms.jsx'))
const CATS = stripJsComments(read('components/reserva/finance/expense-categories-dialog.jsx'))
const DETAIL = stripJsComments(read('components/reserva/finance/expense-detail-sheet.jsx'))
const TAB = stripJsComments(read('components/reserva/finance/expenses-tab.jsx'))
const PAGE = stripJsComments(read('app/dashboard/financeiro/page.js'))
const HELPER = stripJsComments(read('lib/reserva/expense-mutation.js'))

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
function deferred() { let resolve, reject; const p = new Promise((res, rej) => { resolve = res; reject = rej }); return { p, resolve, reject } }
const ORG = '1b728e0e-cc5f-4d3f-9e10-2864238754fc'
const ARENA = '0df00495-9f3f-4b8b-b14c-1392f6b99b83'
const CAT = '5a3c7e10-2b4d-4f6a-8c9e-1d2f3a4b5c6d'
const CAT2 = '9a3c7e10-2b4d-4f6a-8c9e-1d2f3a4b5c6d'
const EXP = '6f1c2a8e-1d3b-4c55-9a77-0b8e2d4c6f10'
const PAY = '7e2d3b9f-2e4c-4d66-8b88-1c9f3e5d7a21'
const NOW = Date.parse('2026-10-03T12:00:00-03:00')

// Ponte client REAL -> rota REAL (runExpenseRoute) com RPC falsa: prova que o corpo gerado pela UI é
// aceito pela API e chega à RPC com os argumentos esperados.
function bridge(rpcImpl) {
  const rpcCalls = []
  const fetchImpl = async (url, init) => {
    const u = new URL(url, 'http://x')
    const out = await runExpenseRoute({
      method: init.method, segments: financePathSegments(u.pathname), searchParams: u.searchParams, rawBody: init.body ?? null,
      user: { id: 'u' }, log: () => {},
      callRpc: async (name, args) => { rpcCalls.push([name, args]); return rpcImpl(name, args) },
    })
    return { ok: out.status < 300, status: out.status, json: async () => out.body }
  }
  return { api: createExpensesApi(fetchImpl), rpcCalls }
}
const ok = (data) => () => ({ data, error: null })

// ------------------------------------------------------------------ guarda + intenção (puro)
await check('G01 guarda síncrona: um envio por vez', () => {
  const g = createSubmitGuard()
  assert.equal(g.begin(), true); assert.equal(g.busy, true); assert.equal(g.begin(), false)
  g.end(); assert.equal(g.busy, false); assert.equal(g.begin(), true)
})
await check('G02 duplo clique: o 2º envio simultâneo é recusado ("busy") e a chamada acontece uma vez', async () => {
  const g = createSubmitGuard(); const d = deferred(); let calls = 0
  const send = () => { calls += 1; return d.p }
  const a = submitIntent({ guard: g, send }); const b = submitIntent({ guard: g, send })
  const timeout = new Promise((r) => setTimeout(() => r('timeout: 2º envio não foi recusado'), 200))
  assert.equal(await Promise.race([b, timeout]), 'busy')
  d.resolve({ status: 201, data: {} }); assert.equal(await a, 'ok'); assert.equal(calls, 1)
  assert.equal(await submitIntent({ guard: g, send: async () => ({}) }), 'ok', 'liberado depois')
})
await check('G03 intenção: rede/5xx/409 de estado mantêm o operation_id; sucesso e RGP02 descartam', async () => {
  let n = 0
  const intent = createOperationIntent(() => `op-${++n}`)
  const g = createSubmitGuard(); const keys = []
  const failWith = (err) => submitIntent({ guard: g, intent, send: async (k) => { keys.push(k); throw err } })
  await failWith(new ExpenseNetworkError())
  await failWith(new ExpenseRequestError(500, { error: 'x' }))
  await failWith(new ExpenseRequestError(409, { error: 'x', code: 'FINANCE_STATE', reason: 'OVER_BALANCE' }))
  await failWith(new ExpenseRequestError(503, { error: 'x' }))
  assert.deepEqual(keys, ['op-1', 'op-1', 'op-1', 'op-1'], 'retry da mesma intenção reutiliza a chave')
  await submitIntent({ guard: g, intent, send: async (k) => { keys.push(k); return { status: 201, data: {} } } })
  assert.equal(keys[4], 'op-1'); assert.equal(intent.peek(), null, 'sucesso descarta')
  await failWith(new ExpenseRequestError(409, { error: 'x', code: 'IDEMPOTENCY_MISMATCH' }))
  assert.equal(keys[5], 'op-2'); assert.equal(intent.peek(), null, 'RGP02 descarta (próxima tentativa = nova intenção)')
  await failWith(new ExpenseNetworkError()); assert.equal(keys[6], 'op-3')
})
await check('G04 submitIntent nunca rejeita; erro no onSuccess conta como erro; sem intenção => operationId undefined', async () => {
  const g = createSubmitGuard(); const errs = []
  assert.equal(await submitIntent({ guard: g, send: async () => ({}), onSuccess: () => { throw new Error('boom') }, onError: (e) => errs.push(e.message) }), 'error')
  assert.deepEqual(errs, ['boom']); assert.equal(g.busy, false)
  let got = 'x'
  await submitIntent({ guard: g, send: async (k) => { got = k; return {} } }); assert.equal(got, undefined)
})
await check('G05 mensagens: rede => confirmar resposta; HTTP => mensagem saneada da API; resto => genérica', () => {
  assert.equal(mutationErrorMessage(new ExpenseNetworkError()), 'Não foi possível confirmar a resposta do servidor. Tente novamente.')
  assert.equal(mutationErrorMessage(new ExpenseRequestError(409, { error: EXPENSE_HINT_MSG.AMOUNT_LOCKED })), EXPENSE_HINT_MSG.AMOUNT_LOCKED)
  assert.equal(mutationErrorMessage(new ExpenseRequestError(500, null)), 'Não foi possível concluir. Tente novamente.', 'sem corpo => genérica')
  assert.equal(mutationErrorMessage(new TypeError('stack interna')), 'Não foi possível concluir. Tente novamente.')
})
await check('G06 recarregar depois de erro só quando o estado mudou no servidor (404/409)', () => {
  assert.equal(shouldReloadAfterError(new ExpenseRequestError(409, {})), true); assert.equal(shouldReloadAfterError(new ExpenseRequestError(404, {})), true)
  for (const e of [new ExpenseRequestError(400, {}), new ExpenseRequestError(403, {}), new ExpenseRequestError(500, {}), new ExpenseNetworkError(), new Error('x')]) assert.equal(shouldReloadAfterError(e), false)
})
await check('G07 toasts de sucesso distinguem replay idempotente / "nada mudou"', () => {
  const want = [['create', { idempotent: false }, 'Despesa registrada'], ['create', { idempotent: true }, 'Despesa já registrada'], ['update', { changed: false }, 'Nada a alterar'],
    ['update', { changed: true }, 'Despesa atualizada'], ['payment', { idempotent: true }, 'Pagamento já registrado'], ['reverse', { idempotent: false }, 'Devolução registrada'],
    ['void', { changed: false }, 'Lançamento já estava anulado'], ['cancel', { changed: true }, 'Despesa cancelada'], ['category-create', { created: false }, 'Categoria já existia'],
    ['category-update', { changed: true }, 'Categoria atualizada']]
  for (const [k, d, msg] of want) assert.equal(successMessage(k, d), msg, k)
})

// ------------------------------------------------------------------ fluxos: client real -> rota real
await check('F01 criar despesa: corpo do formulário aceito pela API; retry após rede reusa o operation_id; sucesso => nova intenção', async () => {
  const v = validateExpenseDraft({ description: ' Conta  de luz ', category_id: CAT, arena_id: '', amount: '1.250,50', due_date: '2026-10-10', notes: '' })
  assert.ok(v.ok)
  const b = bridge(ok({ expense_id: EXP, idempotent: false }))
  const intent = createOperationIntent(); const g = createSubmitGuard()
  let fail = true
  const flaky = createExpensesApi(async (url, init) => { if (fail) { fail = false; throw new TypeError('offline') } return (await bridgeFetch(b, url, init)) })
  async function bridgeFetch(br, url, init) { return { ok: true, status: 201, json: async () => { await br.api.createExpense(JSON.parse(init.body).operation_id, ORG, v.value); return { expense_id: EXP, idempotent: false } } } }
  assert.equal(await submitIntent({ guard: g, intent, send: (op) => flaky.createExpense(op, ORG, v.value) }), 'error')
  const first = intent.peek()
  assert.equal(await submitIntent({ guard: g, intent, send: (op) => flaky.createExpense(op, ORG, v.value) }), 'ok')
  assert.equal(b.rpcCalls.length, 1)
  assert.deepEqual(b.rpcCalls[0], ['rg_expense_create', { p_operation_id: first, p_org: ORG, p_arena: null, p_category: CAT, p_description: 'Conta de luz', p_amount: 125050, p_due_date: '2026-10-10', p_notes: null }])
  assert.equal(intent.peek(), null); assert.notEqual(intent.get(), first, 'novo clique depois do sucesso = nova chave')
})
await check('F02 editar: só os campos alterados; travados nunca enviados; nada alterado => nenhuma chamada', async () => {
  const detail = { expense_id: EXP, description: 'Luz', category_id: CAT, arena_id: ARENA, amount: 10000, due_date: '2026-10-10', notes: null, amount_locked: true, arena_locked: true }
  const v = validateExpenseDraft({ description: 'Luz de outubro', category_id: CAT2, arena_id: '', amount: '999,00', due_date: '2026-10-10', notes: 'x' }).value
  const changes = buildExpenseChanges(detail, v)
  assert.deepEqual(changes, { description: 'Luz de outubro', category_id: CAT2, notes: 'x' })
  const b = bridge(ok({ expense_id: EXP, changed: true }))
  await b.api.updateExpense(EXP, changes)
  assert.deepEqual(b.rpcCalls[0], ['rg_expense_update', { p_expense_id: EXP, p_changes: { description: 'Luz de outubro', category_id: CAT2, notes: 'x' } }])
  const same = validateExpenseDraft({ description: 'Luz', category_id: CAT, arena_id: ARENA, amount: '100,00', due_date: '2026-10-10', notes: '' }).value
  assert.deepEqual(buildExpenseChanges(detail, same), {}, 'componente fecha com "Nada a alterar" sem chamar a API')
  assert.ok(FORMS.includes("if (Object.keys(changes).length === 0) { toast.info('Nada a alterar'); onClose(); return }"))
})
await check('F03 pagamento: teto visual = valor a pagar; acima => erro sem chamada; ok => POST com paid_at -03:00', async () => {
  const exp = { expense_id: EXP, amount_due: 6000 }
  const over = validateEntryDraft({ amount: '60,01', method: 'PIX', at: '2026-10-03T11:00', notes: '' }, { maxCents: exp.amount_due, nowMs: NOW })
  assert.equal(over.ok, false)
  const v = validateEntryDraft({ amount: '60,00', method: 'CASH', at: '2026-10-03T11:00', notes: 'boleto' }, { maxCents: exp.amount_due, nowMs: NOW }).value
  const b = bridge(ok({ payment_id: PAY, idempotent: false }))
  const intent = createOperationIntent()
  const r = await b.api.registerPayment(intent.get(), EXP, v)
  assert.equal(r.status, 201)
  assert.deepEqual(b.rpcCalls[0], ['rg_expense_payment_register', { p_operation_id: intent.peek(), p_expense_id: EXP, p_method: 'CASH', p_amount: 6000, p_paid_at: '2026-10-03T11:00:00-03:00', p_notes: 'boleto' }])
})
await check('F04 devolução: nasce de UM pagamento (payment_id), teto = disponível; inexistente p/ devolução/anulado/totalmente devolvido', async () => {
  const d = { cancelled_at: null, amount_due: 0, can_cancel: false, entries: [
    { payment_id: PAY, kind: 'PAYMENT', amount: 5000, reversed: 1500, voided_at: null },
    { payment_id: 'r1', kind: 'REVERSAL', amount: 1500, reversal_of: PAY, voided_at: null },
    { payment_id: 'p2', kind: 'PAYMENT', amount: 3000, reversed: 0, voided_at: '2026-10-02T10:00:00Z' },
    { payment_id: 'p3', kind: 'PAYMENT', amount: 2000, reversed: 2000, voided_at: null }] }
  const a = deriveExpenseActions(d)
  assert.deepEqual(a.entries.map((e) => e.canReverse), [true, false, false, false])
  assert.equal(a.entries[0].reversible, 3500)
  const v = validateEntryDraft({ amount: '35,00', method: 'PIX', at: '2026-10-03T11:00', notes: '' }, { maxCents: a.entries[0].reversible, nowMs: NOW }).value
  const b = bridge(ok({ payment_id: 'r2', idempotent: false }))
  await b.api.reversePayment('8f3e4c0a-3f5d-4e77-9c99-2d0a4f6e8b32', PAY, v)
  assert.equal(b.rpcCalls[0][0], 'rg_expense_payment_reverse'); assert.equal(b.rpcCalls[0][1].p_payment_id, PAY); assert.equal(b.rpcCalls[0][1].p_reversed_at, '2026-10-03T11:00:00-03:00')
  assert.ok(FORMS.includes('api.reversePayment(op, entry.payment_id, r.value)') && FORMS.includes("const max = reverse ? reversibleOf(entry) : (toCents(expense.amount_due) ?? 0)"))
})
await check('F05 anular / cancelar: motivo obrigatório e aparado; PAYMENT com devolução válida => anulação bloqueada (HAS_REVERSALS)', async () => {
  assert.equal(validateReason('   ').ok, false)
  const b = bridge(ok({ changed: true }))
  await b.api.voidPayment('a1aaaaaa-3f5d-4e77-9c99-2d0a4f6e8b32', validateReason('  valor errado ').value)
  await b.api.cancelExpense(EXP, validateReason(' duplicada ').value)
  assert.deepEqual(b.rpcCalls, [['rg_expense_payment_void', { p_payment_id: 'a1aaaaaa-3f5d-4e77-9c99-2d0a4f6e8b32', p_reason: 'valor errado' }], ['rg_expense_cancel', { p_expense_id: EXP, p_reason: 'duplicada' }]])
  const a = deriveExpenseActions({ cancelled_at: null, amount_due: 0, can_cancel: false, entries: [{ payment_id: PAY, kind: 'PAYMENT', amount: 5000, reversed: 1000, voided_at: null }] })
  assert.deepEqual([a.entries[0].canVoid, a.entries[0].voidBlocked], [false, 'HAS_REVERSALS'])
  assert.ok(DETAIL.includes("disabled={busy || !e.canVoid}") && DETAIL.includes('Anule primeiro as devoluções deste pagamento.'), 'botão desabilitado com explicação; nada é anulado automaticamente')
})
await check('F06 categorias: criar / renomear / inativar / reativar pelo contrato; recusas de nome chegam com mensagem saneada', async () => {
  const b = bridge(ok({ category_id: CAT, created: true }))
  await b.api.createCategory(ORG, validateCategoryName(' Limpeza  geral ').value)
  await b.api.updateCategory(CAT, { name: 'Faxina' }); await b.api.updateCategory(CAT, { is_active: false }); await b.api.updateCategory(CAT, { is_active: true })
  assert.deepEqual(b.rpcCalls.map((c) => c[0]), ['rg_expense_category_create', 'rg_expense_category_update', 'rg_expense_category_update', 'rg_expense_category_update'])
  assert.deepEqual(b.rpcCalls[0][1], { p_org: ORG, p_name: 'Limpeza geral' })
  assert.deepEqual(b.rpcCalls[2][1], { p_category_id: CAT, p_changes: { is_active: false } })
  for (const hint of ['CATEGORY_INACTIVE_EXISTS', 'CATEGORY_NAME_EXISTS']) {
    const br = bridge(() => ({ data: null, error: { code: 'RGP01', hint, message: 'SQL interno' } }))
    const e = await br.api.createCategory(ORG, 'Luz').catch((x) => x)
    assert.ok(e instanceof ExpenseRequestError && e.status === 409 && e.reason === hint)
    assert.equal(mutationErrorMessage(e), EXPENSE_HINT_MSG[hint]); assert.ok(!mutationErrorMessage(e).includes('SQL'))
  }
  assert.ok(!/delete|excluir|remover/i.test(CATS.replace(/aria-[a-z]+/g, '')), 'sem exclusão física')
})
await check('F07 recusa do banco por estado (ex.: AMOUNT_LOCKED / OVER_BALANCE) => mensagem do hint e recarga do detalhe', async () => {
  const br = bridge(() => ({ data: null, error: { code: 'RGP01', hint: 'AMOUNT_LOCKED' } }))
  const e = await br.api.updateExpense(EXP, { amount: 5 }).catch((x) => x)
  assert.equal(e.status, 409); assert.equal(mutationErrorMessage(e), EXPENSE_HINT_MSG.AMOUNT_LOCKED); assert.equal(shouldReloadAfterError(e), true)
  const br2 = bridge(() => ({ data: null, error: { code: 'RGP03', hint: 'OVER_BALANCE' } }))
  const e2 = await br2.api.registerPayment('8f3e4c0a-3f5d-4e77-9c99-2d0a4f6e8b32', EXP, { method: 'PIX', amount: 1, at: '2026-10-03T11:00:00-03:00', notes: null }).catch((x) => x)
  assert.equal(e2.code, 'FINANCE_LIMIT'); assert.equal(mutationErrorMessage(e2), EXPENSE_HINT_MSG.OVER_BALANCE)
  for (const f of [FORMS]) assert.ok((f.match(/if \(shouldReloadAfterError\(err\)\) onDone\(\{[^}]*keepOpen: true \}\)/g) || []).length >= 3, 'recarrega mantendo o formulário aberto')
})

// ------------------------------------------------------------------ componentes
await check('U01 todo Dialog/AlertDialog novo tem Title + Description', () => {
  for (const [f, code] of [['forms', FORMS], ['categorias', CATS]]) {
    const contents = (code.match(/<(Alert)?DialogContent[\s>]/g) || []).length
    assert.ok(contents >= 1, f)
    assert.equal((code.match(/<(Alert)?DialogTitle>/g) || []).length, contents, `${f}: Title`)
    assert.equal((code.match(/<(Alert)?DialogDescription>/g) || []).length, contents, `${f}: Description`)
  }
})
await check('U02 anular/cancelar: AlertDialog com motivo obrigatório, confirmação destrutiva explícita e texto anulação x devolução', () => {
  const rd = /export function ReasonDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(rd.includes('<AlertDialog open') && rd.includes('const r = validateReason(reason)') && rd.includes('if (!r.ok) { setError(r.error); return }'))
  assert.ok(rd.includes('<SubmitButton busy={busy} variant="destructive">'))
  assert.ok(rd.includes('Anulação corrige um lançamento registrado por engano (o dinheiro não se moveu). Devolução registra dinheiro que realmente voltou.'))
  assert.ok(FORMS.includes('Devolução registra dinheiro que realmente voltou deste pagamento') && !/[Ee]storno/.test(FORMS), 'UI usa "devolução", não "estorno"')
})
await check('U03 operation_id: só criar/pagar/devolver; qualquer campo alterado descarta a chave; fechar descarta (estado do componente)', () => {
  assert.equal((FORMS.match(/intent: intent\.current,/g) || []).length, 2, 'criar despesa + lançamento (pagamento/devolução)')
  assert.equal((FORMS.match(/const set = \(k, v\) => \{ intent\.current\.reset\(\);/g) || []).length, 2)
  assert.ok(FORMS.includes('send: (op) => api.createExpense(op, orgId, r.value)'))
  assert.ok(FORMS.includes('send: (op) => (reverse ? api.reversePayment(op, entry.payment_id, r.value) : api.registerPayment(op, expense.expense_id, r.value))'))
  const rd = /export function ReasonDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(!rd.includes('intent'), 'anular/cancelar sem operation_id (banco idempotente)')
  assert.ok(!CATS.includes('createOperationIntent'))
  // intenção vive no ref do componente: desmontar (fechar) descarta
  assert.ok(FORMS.includes('if (!intent.current) intent.current = createOperationIntent()'))
})
await check('U04 envio único: toda mutação via submitIntent + guarda; botão desabilitado e fechamento bloqueado durante o envio', () => {
  for (const [f, code] of [['forms', FORMS], ['categorias', CATS]]) {
    const sends = (code.match(/api\.(createExpense|updateExpense|cancelExpense|registerPayment|reversePayment|voidPayment|createCategory|updateCategory)\(/g) || []).length
    assert.ok(sends > 0, f)
    for (const m of code.matchAll(/api\.(createExpense|updateExpense|cancelExpense|registerPayment|reversePayment|voidPayment|createCategory|updateCategory)\(/g)) {
      const before = code.slice(Math.max(0, m.index - 120), m.index)
      assert.ok(/send: \(op\) => \(?|send: \(\) => \(?|run\([^)]*, \(\) => /.test(before), `${f}: chamada fora de submitIntent: ${code.slice(m.index, m.index + 40)}`)
    }
    assert.ok(code.includes('guard: guard.current'), `${f}: guarda`)
  }
  assert.ok(FORMS.includes('<Button type="submit" variant={variant} className="h-11 sm:h-9" disabled={busy}>'))
  assert.equal((FORMS.match(/onOpenChange=\{\(o\) => \{ if \(!o && !busy\) onClose\(\) \}\}/g) || []).length, 3)
  assert.ok(CATS.includes('onOpenChange={(o) => { if (!o && !busy) onClose() }}'))
})
await check('U05 403 numa mutação não derruba a página (só mensagem): formulários não usam onForbidden', () => {
  assert.ok(!/onForbidden/.test(FORMS) && !/onForbidden/.test(CATS))
  assert.ok(HELPER.includes('if (onError) onError(e)'))
})
await check('U06 sem atualização otimista: sucesso => recarregar fontes (detalhe + lista/resumo; categorias)', () => {
  assert.ok(DETAIL.includes('const done = async (opts) => {\n    if (!opts?.keepOpen) setDlg(null)\n    setReload((n) => n + 1)\n    onChanged?.()\n  }'))
  assert.ok(TAB.includes('onChanged={retry}') && TAB.includes('onCategoriesChanged={reloadCats}') && TAB.includes('}, [scope.orgId, catsReload])'))
  assert.ok(TAB.includes("const onCreated = async ({ expenseId, idempotent }) => {\n    setDialog(null)") && /retry\(\)\n  \}/.test(TAB))
  for (const code of [FORMS, CATS]) assert.ok(!/setList\(|items:\s*\[\.\.\./.test(code), 'formulário não mexe na lista')
  // recarga da mesma despesa mantém o conteúdo; outra despesa nunca herda dados da anterior
  assert.ok(DETAIL.includes('data: s.data?.expense_id === expenseId ? s.data : null'))
})
await check('U07 criação: fecha, recarrega e oferece "Abrir" a despesa criada', () => {
  assert.ok(TAB.includes("toast.success(successMessage('create', { idempotent }), expenseId ? { action: { label: 'Abrir', onClick: () => openDetail(expenseId, null) } } : undefined)"))
  assert.ok(FORMS.includes("onSuccess: async (res) => { await onDone({ kind: 'create', expenseId: res.data?.expense_id, idempotent: res.data?.idempotent === true }) }"))
})
await check('U08 ações do detalhe pelo estado real; cancelada => nenhuma ação; edição respeita travas e categoria atual inativa', () => {
  assert.ok(DETAIL.includes('if (!a || (!a.canEdit && !a.canPay && !a.canCancel)) return null'))
  const cancelled = deriveExpenseActions({ cancelled_at: '2026-10-03T10:00:00Z', amount_due: 0, can_cancel: false, entries: [{ payment_id: PAY, kind: 'PAYMENT', amount: 1, reversed: 0, voided_at: null }] })
  assert.deepEqual([cancelled.canEdit, cancelled.canPay, cancelled.canCancel, cancelled.entries[0].canReverse, cancelled.entries[0].canVoid, cancelled.entries[0].voidBlocked], [false, false, false, false, false, null])
  assert.ok(FORMS.includes("const amountLocked = editing && detail.amount_locked === true") && FORMS.includes("const arenaLocked = editing && detail.arena_locked === true"))
  assert.ok(FORMS.includes('disabled={amountLocked}') && FORMS.includes('disabled={arenaLocked}'))
  assert.ok(FORMS.includes('const options = categoryOptions(categories, editing ? detail.category_id : null)'))
  const cats = [{ id: CAT, name: 'A', is_active: true }, { id: CAT2, name: 'B', is_active: false }]
  assert.deepEqual(categoryOptions(cats).map((c) => c.id), [CAT], 'criação: só ativas'); assert.deepEqual(categoryOptions(cats, CAT2).map((c) => c.id), [CAT, CAT2], 'edição: + atual inativa')
})
await check('U09 padrões dos lançamentos: pagamento = valor a pagar; devolução = disponível e meio do pagamento; data fixada ao abrir', () => {
  assert.ok(FORMS.includes("const [f, setF] = useState(() => ({ amount: centsToInput(max), method: reverse ? entry.method : 'PIX', at: nowLocalInput(), notes: '' }))"))
  assert.ok(FORMS.includes('const r = validateEntryDraft(f, { maxCents: max })'))
  assert.ok(FORMS.includes('PAYMENT_METHODS.map((m) => <SelectItem key={m} value={m}>{PAYMENT_METHOD_LABELS[m]}</SelectItem>)'))
})
await check('U10 mobile 390×844 e acessibilidade: 44 px, rótulos reais, erro associado, rolagem, reduced motion', () => {
  for (const [f, code] of [['forms', FORMS], ['categorias', CATS], ['detail', DETAIL], ['tab', TAB]]) {
    for (const b of code.match(/<Button[^>]*>/g) || []) assert.ok(/h-11/.test(b) || /aria-pressed/.test(b), `${f}: botão sem alvo de 44 px: ${b}`)
    for (const m of code.matchAll(/animate-spin[^"]*/g)) assert.ok(m[0].includes('motion-reduce:animate-none'), `${f}: ${m[0]}`)
  }
  for (const [f, code] of [['forms', FORMS], ['categorias', CATS]]) {
    for (const i of code.match(/<(Input|Textarea|SelectTrigger)\b[^>]*>/g) || []) {
      assert.ok(/\bid=|aria-label=/.test(i), `${f}: controle sem id/aria-label: ${i.slice(0, 60)}`)
      if (!/<Textarea/.test(i)) assert.ok(/h-11/.test(i), `${f}: controle sem 44 px: ${i.slice(0, 60)}`)
    }
    assert.equal((code.match(/max-h-\[90dvh\] overflow-y-auto/g) || []).length >= 1, true, `${f}: diálogo rola no mobile`)
  }
  assert.ok(FORMS.includes('<Label htmlFor={id}>{label}</Label>') && FORMS.includes("{error && <p id={`${id}-error`} className=\"text-xs text-amber-500\" role=\"alert\">{error}</p>}"))
  assert.ok(FORMS.includes('aria-invalid={!!errors.description} aria-describedby={describedBy(\'exp-description\', errors.description)}'))
  for (const id of ['exp-description', 'exp-category', 'exp-arena', 'exp-amount', 'exp-due', 'exp-notes']) assert.ok(FORMS.includes(`<Field id="${id}"`) && FORMS.includes(`id="${id}"`), id)
})
await check('U11 RECEPTIONIST / permissão: formulários só existem dentro da aba Despesas (já atrás do canViewFinance)', () => {
  assert.ok(!/expense-forms|expense-categories-dialog|ExpenseFormDialog|ExpenseCategoriesDialog/.test(PAGE), 'página não importa formulários')
  assert.ok(TAB.includes("import { ExpenseFormDialog } from '@/components/reserva/finance/expense-forms'") && DETAIL.includes("import { ExpenseFormDialog, EntryDialog, ReasonDialog } from '@/components/reserva/finance/expense-forms'"))
  assert.ok(PAGE.includes("{tab === 'expenses' && <ExpensesTab api={api}") && PAGE.includes('arenas={arenas.list} />}'))
})
await check('U12 nada fora do client: sem fetch direto, sem service-role; termos proibidos ausentes', () => {
  for (const [f, code] of [['forms', FORMS], ['categorias', CATS], ['helper', HELPER]]) {
    assert.ok(!/fetch\(|createAdminClient|service_role|SERVICE_ROLE|supabase/i.test(code), f)
    for (const bad of ['faturamento', 'saldo', 'lucro']) assert.ok(!code.toLowerCase().includes(bad), `${f}: ${bad}`)
  }
  for (const bad of ['faturamento', 'saldo', 'lucro']) assert.ok(!DETAIL.toLowerCase().includes(bad) && !TAB.toLowerCase().includes(bad), bad)
})
await check('U13 entradas de escrita na aba: "Nova despesa" e "Categorias" só com categorias carregadas', () => {
  assert.ok(TAB.includes("disabled={!cats.ready} onClick={() => setDialog('categories')}") && TAB.includes("disabled={!cats.ready} onClick={() => setDialog('create')}"))
  assert.ok(TAB.includes('Nova despesa') && TAB.includes('Categorias'))
})
await check('U14 B-2A.1 intacta: compareKey e dependências do resumo/lista inalteradas', () => {
  assert.ok(TAB.includes("const compareKey = `${scope.period.compare?.from || ''}|${scope.period.compare?.to || ''}`"))
  assert.ok(TAB.includes('}, [baseKey, compareKey, categoryId, reload])') && TAB.includes('}, [baseKey, categoryId, status, reload])'))
})

// ------------------------------------------------------------------ resultado
const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3B2B_MUT_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
