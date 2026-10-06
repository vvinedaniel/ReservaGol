// Reserva Gol — FASE 03B.2B-2B — escrita de Despesas pela UI (puro/estático, sem rede e sem banco).
// Uso: node tests/phase3b2b_mutations.test.mjs
// Cobre: guarda de duplo envio e regras de intenção (lib/reserva/expense-mutation.js), fluxos de
// criação/edição/pagamento/devolução/anulação/cancelamento/categorias pelo client REAL contra a rota
// REAL (runExpenseRoute com RPC falsa), mensagens/recarga em erro, e os componentes de formulário
// (Title+Description, confirmação com motivo, intenção por campo, sem otimismo, 403 só mensagem,
// ações pelo estado real, mobile 44 px, acessibilidade, termos proibidos).
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createSubmitGuard, submitIntent, submitWithBusy, categoryReloadNeeded, mutationErrorMessage, shouldReloadAfterError, successMessage } from '../lib/reserva/expense-mutation.js'
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
  for (const f of [FORMS]) assert.ok((f.match(/if \((editing && )?shouldReloadAfterError\(err\)\) onDone\(\{[^}]*keepOpen: true \}\)/g) || []).length >= 3, 'recarrega mantendo o formulário aberto')
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
  // 2B.1: spinner (busy) separado de desabilitado (qualquer mutação concorrente)
  assert.ok(FORMS.includes('function SubmitButton({ busy, disabled = busy, children, variant })') && FORMS.includes('<Button type="submit" variant={variant} className="h-11 sm:h-9" disabled={disabled}>'))
  assert.equal((FORMS.match(/onOpenChange=\{\(o\) => \{ if \(!o && !busy\) onClose\(\) \}\}/g) || []).length, 2, 'lançamento + motivo')
  assert.equal((FORMS.match(/onOpenChange=\{\(o\) => \{ if \(!o && !locked\) onClose\(\) \}\}/g) || []).length, 1, 'despesa: travado também pela categoria inline')
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
  assert.ok(TAB.includes("disabled={!cats.ready} onClick={(ev) => openDialog('categories', ev)}") && TAB.includes("disabled={!cats.ready} onClick={(ev) => openDialog('create', ev)}"))
  assert.ok(TAB.includes('Nova despesa') && TAB.includes('Categorias'))
})
await check('U14 B-2A.1 intacta: compareKey e dependências do resumo/lista inalteradas', () => {
  assert.ok(TAB.includes("const compareKey = `${scope.period.compare?.from || ''}|${scope.period.compare?.to || ''}`"))
  assert.ok(TAB.includes('}, [baseKey, compareKey, categoryId, reload])') && TAB.includes('}, [baseKey, categoryId, status, reload])'))
})

// ------------------------------------------------------------------ 03B.2B-2B.1 — estado das mutações
await check('H01 categoria renomeada/inativada/reativada: callback da aba recarrega categorias E lista/resumo; nada otimista', async () => {
  // callback REAL da aba, avaliado com contadores (reloadCats / retry)
  const m = /const onCategoryMutated = (\(\) => \{[^}]*\})/.exec(TAB)
  assert.ok(m, 'onCategoryMutated na aba')
  const counts = { cats: 0, list: 0 }
  const onCategoryMutated = new Function('reloadCats', 'retry', `return ${m[1]}`)(() => { counts.cats += 1 }, () => { counts.list += 1 })
  assert.ok(TAB.includes('categories={cats.list} onClose={() => setDialog(null)} onChanged={onCategoryMutated} />'), 'gerenciador usa o callback completo')
  assert.ok(TAB.includes('onDone={onCreated} onCategoriesChanged={reloadCats} />'), 'criação inline (formulário) recarrega só categorias')
  // fluxo do gerenciador: rename confirmado pela rota real -> onSuccess -> onChanged
  const b = bridge(ok({ category_id: CAT, name: 'Faxina', is_active: true, changed: true }))
  const items = [{ id: CAT, name: 'Limpeza', is_active: true }]
  const snapshot = JSON.stringify(items)
  let busyState = null
  const out = await submitWithBusy({ guard: createSubmitGuard(), setBusy: (x) => { busyState = x }, send: () => b.api.updateCategory(CAT, { name: 'Faxina' }), onSuccess: async () => { onCategoryMutated() } })
  assert.equal(out, 'ok'); assert.deepEqual(b.rpcCalls[0], ['rg_expense_category_update', { p_category_id: CAT, p_changes: { name: 'Faxina' } }])
  assert.deepEqual(counts, { cats: 1, list: 1 }, 'recarrega categorias e lista/resumo')
  assert.equal(JSON.stringify(items), snapshot, 'nenhum item alterado localmente'); assert.equal(busyState, false)
  assert.ok(!/categories\.(push|splice)|\.name\s*=\s|setCats\(/.test(CATS), 'gerenciador não mexe na lista localmente')
})
await check('H02 busy x guarda: B invocada durante A não toca no busy; A segue pendente; só o fim de A libera', async () => {
  const guard = createSubmitGuard(); const history = []; const setBusy = (x) => history.push(x)
  const d = deferred(); let calls = 0
  const A = submitWithBusy({ guard, setBusy, send: () => { calls += 1; return d.p } })
  assert.deepEqual(history, [true]); assert.equal(guard.busy, true)
  const B = await submitWithBusy({ guard, setBusy, send: () => { calls += 1; return Promise.resolve({}) } })
  assert.equal(B, 'busy'); assert.deepEqual(history, [true], 'B não alterou o estado visual'); assert.equal(guard.busy, true, 'A continua pendente')
  d.resolve({ status: 200, data: {} }); assert.equal(await A, 'ok')
  assert.deepEqual(history, [true, false], 'busy liberado só quando A terminou'); assert.equal(calls, 1)
  // erro também libera (finally), e uma nova operação depois funciona
  const e = await submitWithBusy({ guard, setBusy, send: async () => { throw new ExpenseNetworkError() } })
  assert.equal(e, 'error'); assert.deepEqual(history.slice(-2), [true, false])
  // todos os handlers checam a guarda ANTES de mudar estado visual e usam submitWithBusy (sem setBusy manual)
  for (const [f, code, n] of [['forms', FORMS, 4], ['categorias', CATS, 3]]) {
    assert.ok((code.match(/if \((locked \|\| )?guard\.current\.busy\) return/g) || []).length >= n, `${f}: checagem da guarda nos handlers`)
    assert.ok(!/submitIntent\(|setBusy\(true\)|setBusy\(false\)/.test(code), `${f}: sem alternância manual de busy`)
    assert.ok(code.includes('submitWithBusy({'), f)
  }
})
await check('H03 criação inline de categoria trava o diálogo da despesa (sem spinner falso na despesa)', async () => {
  const form = /export function ExpenseFormDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(form.includes('const categoryBusy = newCat?.busy === true') && form.includes('const locked = busy || categoryBusy'))
  assert.ok(form.includes('<Dialog open onOpenChange={(o) => { if (!o && !locked) onClose() }}>'), 'não fecha')
  assert.ok(form.includes('if (locked || guard.current.busy) return'), 'não submete a despesa')
  assert.ok(form.includes('onClick={onClose} disabled={locked}>Cancelar</Button>'), 'não cancela o formulário')
  assert.ok(form.includes('disabled={categoryBusy} onClick={() => setNewCat(null)}>Cancelar</Button>'), 'não esconde a área da nova categoria')
  assert.ok(form.includes('<SubmitButton busy={busy} disabled={locked}>'), 'spinner só da despesa; desabilitado por qualquer mutação')
  assert.ok(form.includes('setBusy: (b) => setNewCat((s) => (s ? { ...s, busy: b } : s)),'), 'busy da categoria pelo submitWithBusy')
  // modelo: enquanto a categoria está em voo, a despesa não pode ser enviada (mesma guarda)
  const guard = createSubmitGuard(); const d = deferred(); let cat = { busy: false }
  const p = submitWithBusy({ guard, setBusy: (b) => { cat = { ...cat, busy: b } }, send: () => d.p })
  const locked = () => cat.busy === true
  assert.equal(locked(), true)
  assert.equal(await submitWithBusy({ guard, setBusy: () => { throw new Error('não deveria marcar busy da despesa') }, send: async () => ({}) }), 'busy')
  d.resolve({ data: { category_id: CAT2, name: 'Nova', is_active: true } }); await p
  assert.equal(locked(), false)
})
await check('H04 CATEGORY_INACTIVE concorrente: mensagem, formulário aberto, recarrega categorias, mantém escolha e intenção', async () => {
  const inactive = new ExpenseRequestError(409, { error: EXPENSE_HINT_MSG.CATEGORY_INACTIVE, code: 'FINANCE_STATE', reason: 'CATEGORY_INACTIVE' })
  assert.equal(categoryReloadNeeded(inactive), true)
  for (const e of [new ExpenseRequestError(409, { code: 'FINANCE_STATE', reason: 'AMOUNT_LOCKED' }), new ExpenseRequestError(409, { reason: 'CATEGORY_INACTIVE_EXISTS' }),
    new ExpenseRequestError(409, { code: 'FINANCE_LIMIT', reason: 'OVER_BALANCE' }), new ExpenseRequestError(400, { reason: 'CATEGORY_INACTIVE' }), new ExpenseNetworkError()])
    assert.equal(categoryReloadNeeded(e), false, `${e.status} ${e.reason}`)
  // fluxo de criação: rota real responde RGP01/CATEGORY_INACTIVE
  const b = bridge(() => ({ data: null, error: { code: 'RGP01', hint: 'CATEGORY_INACTIVE' } }))
  const v = validateExpenseDraft({ description: 'Luz', category_id: CAT, amount: '10,00', due_date: '2026-10-10' }).value
  const intent = createOperationIntent(); const guard = createSubmitGuard()
  let catsReloads = 0, closed = false; const msgs = []; const keys = []
  const onSaveError = (err) => { msgs.push(mutationErrorMessage(err)); if (categoryReloadNeeded(err)) catsReloads += 1 }
  const attempt = () => submitWithBusy({ guard, setBusy: () => {}, intent, send: (op) => { keys.push(op); return b.api.createExpense(op, ORG, v) }, onSuccess: () => { closed = true }, onError: onSaveError })
  assert.equal(await attempt(), 'error'); assert.equal(await attempt(), 'error')
  assert.deepEqual(msgs, [EXPENSE_HINT_MSG.CATEGORY_INACTIVE, EXPENSE_HINT_MSG.CATEGORY_INACTIVE])
  assert.equal(catsReloads, 2); assert.equal(closed, false, 'formulário aberto')
  assert.equal(keys[0], keys[1], 'sem nova intenção até o usuário alterar algum campo'); assert.equal(b.rpcCalls[0][1].p_category, CAT, 'categoria não trocada')
  // componente: a mesma rotina de erro em criar E editar; edição mantém a recarga do detalhe
  const form = /export function ExpenseFormDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(form.includes('if (categoryReloadNeeded(err)) onCategoriesChanged?.()') && form.includes("if (editing && shouldReloadAfterError(err)) onDone({ kind: 'reload', keepOpen: true })"))
  assert.equal((form.match(/onError: onSaveError,/g) || []).length, 2, 'criar e editar')
  assert.ok(!/set\('category_id'/.test(form.slice(form.indexOf('const onSaveError'), form.indexOf('async function submit'))), 'não troca a categoria')
})
await check('H05 categoria recém-criada: rótulo transitório pelo resultado CONFIRMADO da RPC até a lista recarregar', () => {
  const form = /export function ExpenseFormDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(form.includes("if (c?.category_id) setConfirmedCat({ id: c.category_id, name: c.name, is_active: c.is_active === true })"))
  assert.ok(form.includes('const selectable = confirmedCat && confirmedCat.is_active && !options.some((c) => c.id === confirmedCat.id) ? [...options, confirmedCat] : options'))
  assert.ok(form.includes('{selectable.map((c) => <SelectItem key={c.id} value={c.id}>'))
  // mesma regra, aplicada: antes do reload aparece; depois do reload não duplica
  const merge = (options, cc) => (cc && cc.is_active && !options.some((c) => c.id === cc.id) ? [...options, cc] : options)
  const cc = { id: CAT2, name: 'Nova', is_active: true }
  assert.deepEqual(merge([{ id: CAT, name: 'A', is_active: true }], cc).map((c) => c.id), [CAT, CAT2])
  assert.deepEqual(merge([{ id: CAT, name: 'A', is_active: true }, { id: CAT2, name: 'Nova', is_active: true }], cc).map((c) => c.id), [CAT, CAT2])
  assert.deepEqual(merge([{ id: CAT, name: 'A', is_active: true }], { ...cc, is_active: false }).map((c) => c.id), [CAT], 'inativa nunca entra na criação')
})

// ------------------------------------------------------------------ 03B.2B-2B.2 — categoria inline (B1) e foco (B2)
// B1: executa o código REAL do formulário (onSuccess da criação inline, effect de 2ª fase, selectable,
// set, pendingCategoryReady), extraído da fonte, contra um modelo do Select do Radix 2.2.5: a opção
// nativa entra por useLayoutEffect (vale no commit SEGUINTE); o <select> nativo, num effect passivo,
// aplica o valor novo e, se a opção ainda não existe, normaliza para '' e devolve '' ao onValueChange.
// Lote de atualizações = um commit (como o React 18 agrupa o onSuccess inteiro).
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const NEWCAT = '3c1d2e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f'
const BASE_CATS = [{ id: CAT, name: 'Energia', is_active: true }, { id: CAT2, name: 'Antiga', is_active: false }]

function formParts(src) {
  const form = /export function ExpenseFormDialog[\s\S]*?\n\}\n/.exec(src)[0]
  const ready = /export function pendingCategoryReady\(pendingId, selectable\) \{\n([\s\S]*?)\n\}\n/.exec(src)
  const selectable = /\n  const selectable = (.+)\n/.exec(form)
  const hasPending = /\n  const selectableHasPending = (.+)\n/.exec(form)
  const set = /\n  const set = \(k, v\) => (\{.*\})\n/.exec(form)
  const effect = /\n  useEffect\(\(\) => \{\n([\s\S]*?)\n  \}, \[([^\]]*)\]\)\n/.exec(form)
  const onSuccess = /async function createCategory\(\)[\s\S]*?onSuccess: async \(res\) => \{\n([\s\S]*?)\n      \},\n      onError/.exec(form)
  assert.ok(selectable && set && onSuccess, 'partes essenciais do formulário encontradas')
  return { ready: ready?.[1], selectable: selectable[1], hasPending: hasPending?.[1], set: set[1], effect: effect && { body: effect[1], deps: effect[2].split(',').map((x) => x.trim()).filter(Boolean) }, onSuccess: onSuccess[1] }
}

async function runInlineCategory(src, { rpc = { category_id: NEWCAT, name: 'Limpeza', is_active: true, created: true }, reloadAdds = true } = {}) {
  const P = formParts(src)
  const ready = P.ready ? new Function('pendingId', 'selectable', P.ready) : () => false
  const selectableOf = new Function('confirmedCat', 'options', `return ${P.selectable}`)
  const hasPendingOf = P.hasPending ? new Function('pendingCategoryReady', 'pendingCategoryId', 'selectable', `return ${P.hasPending}`) : () => false
  let state = { f: { description: 'Conta', category_id: '', arena_id: '', amount: '10,00', due_date: '2026-10-06', notes: 'n' }, errors: { category_id: 'Escolha a categoria.' }, confirmedCat: null, pendingCategoryId: null, newCat: { name: 'Limpeza' }, categories: BASE_CATS }
  const queue = []
  const trace = { phase: 'idle', resets: 0, setCalls: [], intentResets: 0, commits: [] }
  const intent = { current: { reset: () => { trace.intentResets += 1 } } }
  const setRaw = new Function('intent', 'setErrors', 'setF', `return (k, v) => ${P.set}`)(intent, (fn) => queue.push((s) => ({ ...s, errors: fn(s.errors) })), (fn) => queue.push((s) => ({ ...s, f: fn(s.f) })))
  const set = (k, v) => { trace.setCalls.push({ phase: trace.phase, k, v }); setRaw(k, v) }
  const setConfirmedCat = (v) => queue.push((s) => ({ ...s, confirmedCat: v }))
  const setPendingCategoryId = (v) => queue.push((s) => ({ ...s, pendingCategoryId: v }))
  const setNewCat = (v) => queue.push((s) => ({ ...s, newCat: typeof v === 'function' ? v(s.newCat) : v }))
  let effect = null
  if (P.effect) {
    for (const dep of P.effect.deps) assert.ok(['pendingCategoryId', 'selectableHasPending'].includes(dep), `dependência inesperada do effect: ${dep}`)
    effect = { fn: new Function('set', 'setPendingCategoryId', 'pendingCategoryId', 'selectableHasPending', P.effect.body), deps: P.effect.deps }
  }
  let native = new Set(); let nativeQueued = null; let prevValue; let prevDeps = null
  function commit() {
    let remount = false
    if (nativeQueued) { native = nativeQueued; nativeQueued = null; remount = true } // key do <select> muda => remonta
    for (const u of queue.splice(0)) state = u(state)
    const selectable = selectableOf(state.confirmedCat, categoryOptions(state.categories, null))
    const ids = selectable.map((c) => c.id)
    const value = state.f.category_id || undefined
    const selectableHasPending = hasPendingOf(ready, state.pendingCategoryId, selectable)
    trace.commits.push({ ids, value, native: [...native] })
    if (ids.length !== native.size || ids.some((id) => !native.has(id))) nativeQueued = new Set(ids) // layout effect das opções
    trace.phase = 'bubble' // effect passivo do <select> nativo (filho roda antes do pai)
    if (!remount && value !== prevValue && value !== undefined && !native.has(value)) { trace.resets += 1; set('category_id', '') }
    prevValue = value
    trace.phase = 'effect'
    if (effect) {
      const scope = { pendingCategoryId: state.pendingCategoryId, selectableHasPending }
      const deps = effect.deps.map((d) => scope[d])
      if (!prevDeps || deps.some((d, i) => !Object.is(d, prevDeps[i]))) { prevDeps = deps; effect.fn(set, setPendingCategoryId, state.pendingCategoryId, selectableHasPending) }
    }
    trace.phase = 'idle'
  }
  const settle = () => { let n = 0; while (queue.length || nativeQueued) { commit(); assert.ok(++n < 12, 'loop de renders/effects') } }
  commit(); settle() // diálogo aberto com as categorias atuais
  let reloadRequested = false
  trace.phase = 'onSuccess'
  const onSuccess = new AsyncFunction('res', 'toast', 'successMessage', 'setConfirmedCat', 'setPendingCategoryId', 'onCategoriesChanged', 'set', 'setNewCat', P.onSuccess)
  await onSuccess({ data: rpc }, { success: () => {} }, successMessage, setConfirmedCat, setPendingCategoryId, () => { reloadRequested = true }, set, setNewCat)
  trace.phase = 'idle'
  const rpcCommit = trace.commits.length
  settle()
  if (reloadRequested && reloadAdds) { queue.push((s) => ({ ...s, categories: [...s.categories, { id: rpc.category_id, name: rpc.name, is_active: rpc.is_active }] })); settle() }
  return { state, trace, rpcCommit }
}

function assertTwoPhase(r, label = '') {
  const { state, trace, rpcCommit } = r
  assert.ok(!trace.setCalls.some((c) => c.phase === 'onSuccess' && c.k === 'category_id'), `${label}category_id definido dentro do onSuccess`)
  assert.equal(trace.resets, 0, `${label}o <select> nativo normalizou o valor para vazio`)
  assert.equal(state.f.category_id, NEWCAT, `${label}categoria criada não ficou selecionada`)
  const opt = trace.commits.findIndex((c, i) => i >= rpcCommit && c.ids.includes(NEWCAT))
  const sel = trace.commits.findIndex((c) => c.value === NEWCAT)
  assert.ok(opt >= rpcCommit && sel > opt, `${label}ordem: RPC (${rpcCommit}) -> opção selecionável (${opt}) -> seleção (${sel})`)
  assert.ok(trace.commits[sel].native.includes(NEWCAT), `${label}opção nativa presente quando o valor muda`)
}

await check('I01 B1 duas fases: RPC confirma -> opção entra no conjunto selecionável -> só então category_id é aplicado', async () => {
  const r = await runInlineCategory(FORMS)
  assertTwoPhase(r)
  const applied = r.trace.setCalls.filter((c) => c.k === 'category_id')
  assert.deepEqual(applied.map((c) => [c.phase, c.v]), [['effect', NEWCAT]], 'aplicado uma única vez, pelo effect de 2ª fase')
  assert.ok(r.trace.intentResets >= 1, 'formulário mudou => nova intenção')
  assert.equal(r.state.errors.category_id, undefined, 'erro de categoria limpo')
  assert.deepEqual({ ...r.state.f, category_id: '' }, { description: 'Conta', category_id: '', arena_id: '', amount: '10,00', due_date: '2026-10-06', notes: 'n' }, 'nenhum outro campo alterado')
  assert.equal(r.state.pendingCategoryId, null, 'pendente limpo'); assert.equal(r.state.newCat, null, 'área inline fechada')
  assert.ok(r.trace.commits.length < 10, 'sem loop de effects')
  // categoria já existente devolvida pela RPC (created=false, ativa): mesma seleção em duas fases
  assertTwoPhase(await runInlineCategory(FORMS, { rpc: { category_id: NEWCAT, name: 'Limpeza', is_active: true, created: false } }), 'existente: ')
  // lista recarregada ainda sem a categoria: o rótulo confirmado pela RPC basta
  assertTwoPhase(await runInlineCategory(FORMS, { reloadAdds: false }), 'sem reload: ')
})
await check('I02 B1 mutações: cada parte da correção é necessária (o modelo reproduz o bug do Preview)', async () => {
  const mutate = (from, to) => { assert.ok(FORMS.includes(from), `trecho para mutação não encontrado: ${from.slice(0, 50)}`); return FORMS.replace(from, to) }
  const PHASE1 = 'if (c?.category_id && c.is_active === true) setPendingCategoryId(c.category_id)'
  const EFFECT = /\n  useEffect\(\(\) => \{\n[\s\S]*?\n  \}, \[[^\]]*\]\)\n/.exec(FORMS)[0]
  const fails = async (src, why) => { const r = await runInlineCategory(src); assert.throws(() => assertTwoPhase(r), undefined, why) }
  // código anterior (03B.2B-2B.1): seleção dentro do onSuccess, no mesmo lote em que a opção entra => ''
  await fails(mutate(PHASE1 + '\n        await onCategoriesChanged?.()', "if (c?.category_id) setPendingCategoryId(c.category_id)\n        await onCategoriesChanged?.()\n        if (c?.category_id) set('category_id', c.category_id)"), 'category_id de volta ao onSuccess')
  const oldOnly = mutate(EFFECT, '\n').replace(PHASE1, "if (c?.category_id) set('category_id', c.category_id)")
  const rOld = await runInlineCategory(oldOnly)
  assert.equal(rOld.state.f.category_id, '', 'modelo reproduz o bug: valor volta para vazio'); assert.ok(rOld.trace.resets >= 1)
  await fails(mutate(EFFECT, '\n'), 'effect de 2ª fase removido')
  // presença na lista é condição: sem confirmedCat, o effect precisa esperar a lista recarregada
  const noConfirmed = mutate('if (c?.category_id) setConfirmedCat({ id: c.category_id, name: c.name, is_active: c.is_active === true })', '')
  assertTwoPhase(await runInlineCategory(noConfirmed), 'sem rótulo transitório, espera o reload: ')
  const readyBody = /export function pendingCategoryReady\(pendingId, selectable\) \{\n([\s\S]*?)\n\}\n/.exec(FORMS)[1]
  await fails(noConfirmed.replace(readyBody, '  return !!pendingId'), 'seleção antes de a opção existir')
})
await check('I03 B1 categoria inativa nunca é selecionada pelo fallback', async () => {
  const readyBody = /export function pendingCategoryReady\(pendingId, selectable\) \{\n([\s\S]*?)\n\}\n/.exec(FORMS)[1]
  const ready = new Function('pendingId', 'selectable', readyBody)
  assert.equal(ready(NEWCAT, [{ id: NEWCAT, name: 'X', is_active: true }]), true)
  assert.equal(ready(NEWCAT, [{ id: NEWCAT, name: 'X', is_active: false }]), false, 'inativa na lista')
  assert.equal(ready(NEWCAT, [{ id: CAT, name: 'Energia', is_active: true }]), false, 'ausente')
  assert.equal(ready(null, [{ id: CAT, name: 'Energia', is_active: true }]), false, 'nada pendente')
  // RPC devolvendo categoria inativa: nada é selecionado, nem antes nem depois do reload
  const r = await runInlineCategory(FORMS, { rpc: { category_id: NEWCAT, name: 'Velha', is_active: false, created: false } })
  assert.equal(r.state.f.category_id, ''); assert.ok(!r.trace.setCalls.some((c) => c.k === 'category_id' && c.v === NEWCAT))
  // mutação: fallback aceitando inativa (rótulo transitório + checagem de ativa removidos) => selecionaria
  const loose = FORMS.replace(readyBody, '  return !!pendingId && selectable.some((c) => c.id === pendingId)')
    .replace('confirmedCat && confirmedCat.is_active && !options', 'confirmedCat && !options')
    .replace('if (c?.category_id && c.is_active === true) setPendingCategoryId', 'if (c?.category_id) setPendingCategoryId')
  assert.notEqual(loose, FORMS)
  const rl = await runInlineCategory(loose, { rpc: { category_id: NEWCAT, name: 'Velha', is_active: false, created: false } })
  assert.equal(rl.state.f.category_id, NEWCAT, 'a mutação é detectável: inativa seria selecionada')
})
await check('I04 B1 componente: Fase 1 no onSuccess, Fase 2 em useEffect por primitivas; sem setTimeout; confirmedCat só da RPC', () => {
  const form = /export function ExpenseFormDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  const ok = /async function createCategory\(\)[\s\S]*?onSuccess: async \(res\) => \{\n([\s\S]*?)\n      \},/.exec(form)[1]
  assert.ok(!/set\('category_id'|setF\(/.test(ok), 'onSuccess não mexe no formulário')
  assert.ok(ok.indexOf('setPendingCategoryId(c.category_id)') > ok.indexOf('setConfirmedCat('), 'pendente registrado depois da categoria confirmada')
  assert.ok(form.includes('const selectableHasPending = pendingCategoryReady(pendingCategoryId, selectable)'))
  assert.ok(form.includes('}, [pendingCategoryId, selectableHasPending])'), 'effect depende só das primitivas')
  assert.ok(!/setTimeout|requestAnimationFrame|queueMicrotask/.test(form), 'sem temporizador')
  assert.equal((form.match(/setConfirmedCat\(/g) || []).length, 1, 'confirmedCat vem só da resposta da RPC')
})

// B2: foco devolvido ao botão que abriu cada diálogo (função REAL executada com elementos falsos).
function fakeEl({ connected = true, disabled = false, dialog = null } = {}) {
  return { isConnected: connected, disabled, focused: 0, focus() { this.focused += 1 }, closest: (sel) => (sel === '[role="dialog"]' ? dialog : null) }
}
function fakeEvt() { return { prevented: false, preventDefault() { this.prevented = true } } }
const focusReturnSrc = /export function focusReturn\(ref\) \{\n([\s\S]*?)\n\}\n/.exec(FORMS)
await check('J01 B2 focusReturn: botão montado recebe o foco; desmontado => padrão; desabilitado => diálogo pai', () => {
  assert.ok(focusReturnSrc, 'focusReturn exportado de expense-forms')
  const focusReturn = new Function('ref', focusReturnSrc[1])
  const btn = fakeEl(); let e = fakeEvt(); focusReturn({ current: btn })(e)
  assert.equal(btn.focused, 1); assert.equal(e.prevented, true)
  const gone = fakeEl({ connected: false }); e = fakeEvt(); focusReturn({ current: gone })(e)
  assert.equal(gone.focused, 0); assert.equal(e.prevented, false, 'não impede o padrão do Radix')
  e = fakeEvt(); focusReturn({ current: null })(e); assert.equal(e.prevented, false)
  e = fakeEvt(); focusReturn(undefined)(e); assert.equal(e.prevented, false, 'sem ref (ex.: aberto pelo toast)')
  const sheet = fakeEl(); const busyBtn = fakeEl({ disabled: true, dialog: sheet }); e = fakeEvt(); focusReturn({ current: busyBtn })(e)
  assert.equal(busyBtn.focused, 0); assert.equal(sheet.focused, 1); assert.equal(e.prevented, true)
  const lone = fakeEl({ disabled: true }); e = fakeEvt(); focusReturn({ current: lone })(e); assert.equal(e.prevented, false)
})
await check('J02 B2 todos os diálogos de Despesas restauram o foco; componentes UI globais intocados', () => {
  for (const [f, code, n] of [['forms', FORMS, 3], ['categorias', CATS, 1]]) {
    const contents = code.match(/<(Alert)?DialogContent\b[^>]*>/g) || []
    assert.equal(contents.length, n, f)
    for (const c of contents) assert.ok(c.includes('onCloseAutoFocus={focusReturn(returnFocusTo)}'), `${f}: ${c.slice(0, 70)}`)
  }
  for (const fn of ['ExpenseFormDialog', 'EntryDialog', 'ReasonDialog']) assert.ok(new RegExp(`export function ${fn}\\(\\{[^}]*returnFocusTo \\}\\)`).test(FORMS), fn)
  assert.ok(CATS.includes("import { focusReturn } from '@/components/reserva/finance/expense-forms'") && /ExpenseCategoriesDialog\(\{[^}]*returnFocusTo \}\)/.test(CATS))
  for (const ui of ['components/ui/dialog.jsx', 'components/ui/alert-dialog.jsx', 'components/ui/sheet.jsx']) assert.ok(!/returnFocusTo|focusReturn/.test(read(ui)), ui)
})
await check('J03 B2 aba: "Nova despesa" e "Categorias" guardam o botão real (currentTarget) e o passam aos diálogos', () => {
  const m = /const openDialog = (\(kind, ev\) => \{[^}]*\})/.exec(TAB)
  assert.ok(m, 'openDialog na aba')
  const ref = { current: 'antigo' }; const opened = []
  const openDialog = new Function('dialogTrigger', 'setDialog', `return ${m[1]}`)(ref, (k) => opened.push(k))
  const btn = fakeEl(); openDialog('create', { currentTarget: btn })
  assert.equal(ref.current, btn); assert.deepEqual(opened, ['create'])
  openDialog('categories', undefined); assert.equal(ref.current, null, 'sem evento não reaproveita botão antigo')
  assert.ok(TAB.includes('const dialogTrigger = useRef(null)'))
  assert.ok(TAB.includes('<ExpenseFormDialog mode="create" api={api} orgId={scope.orgId} arenas={arenas} returnFocusTo={dialogTrigger} categories={cats.list}'))
  assert.ok(TAB.includes('<ExpenseCategoriesDialog api={api} orgId={scope.orgId} returnFocusTo={dialogTrigger} categories={cats.list}'))
})
await check('J04 B2 detalhe: Editar/Pagamento/Devolução/Anular/Cancelar guardam o botão de origem; Sheet mantém a restauração para a linha', () => {
  const m = /const openDlg = (\(next, ev\) => \{[^}]*\})/.exec(DETAIL)
  assert.ok(m, 'openDlg no detalhe')
  const ref = { current: null }; const dlgs = []
  const openDlg = new Function('dlgTrigger', 'setDlg', `return ${m[1]}`)(ref, (d) => dlgs.push(d))
  const btn = fakeEl(); openDlg({ type: 'void', entry: { payment_id: PAY } }, { currentTarget: btn })
  assert.equal(ref.current, btn); assert.deepEqual(dlgs, [{ type: 'void', entry: { payment_id: PAY } }])
  for (const h of ["onEdit={(ev) => openDlg({ type: 'edit' }, ev)}", "onPay={(ev) => openDlg({ type: 'payment' }, ev)}", "onCancel={(ev) => openDlg({ type: 'cancel' }, ev)}",
    "onReverse={(e, ev) => openDlg({ type: 'reverse', entry: e }, ev)}", "onVoid={(e, ev) => openDlg({ type: 'void', entry: e }, ev)}", 'onClick={(ev) => onReverse(e, ev)}', 'onClick={(ev) => onVoid(e, ev)}'])
    assert.ok(DETAIL.includes(h), h)
  assert.ok(DETAIL.includes('onClick={onPay}') && DETAIL.includes('onClick={onEdit}') && DETAIL.includes('onClick={onCancel}'), 'botões de ação repassam o evento')
  const children = DETAIL.match(/<(ExpenseFormDialog|EntryDialog|ReasonDialog) [\s\S]*?\/>/g) || []
  assert.equal(children.length, 5)
  for (const c of children) assert.ok(c.includes('returnFocusTo={dlgTrigger}'), c.slice(0, 60))
  assert.ok(DETAIL.includes('onCloseAutoFocus={(e) => { const el = returnFocusTo?.current; if (el && el.isConnected) { e.preventDefault(); el.focus() } }}'), 'Sheet inalterado')
})
await check('J05 foco inicial: nome da nova categoria (autoFocus) e motivo do AlertDialog (autoFocus + onOpenAutoFocus local)', () => {
  assert.ok(/<Input id="exp-new-category"[^>]*\bautoFocus\b/.test(FORMS), 'nova categoria')
  const rd = /export function ReasonDialog[\s\S]*?\n\}\n/.exec(FORMS)[0]
  assert.ok(/<Textarea id=\{id\} ref=\{reasonRef\} autoFocus\b/.test(rd), 'motivo')
  assert.ok(rd.includes('onOpenAutoFocus={(e) => { if (reasonRef.current) { e.preventDefault(); reasonRef.current.focus() } }}'))
  const handler = new Function('reasonRef', 'return (e) => { if (reasonRef.current) { e.preventDefault(); reasonRef.current.focus() } }')
  const ta = fakeEl(); const e = fakeEvt(); handler({ current: ta })(e); assert.equal(ta.focused, 1); assert.equal(e.prevented, true)
  const e2 = fakeEvt(); handler({ current: null })(e2); assert.equal(e2.prevented, false)
})

// ------------------------------------------------------------------ resultado
const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3B2B_MUT_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
