// Reserva Gol — FASE 03B.2B-1 — API + client + helpers puros de Despesas & Caixa (sem rede e sem banco).
// Uso: node tests/phase3b2b_expenses.test.mjs
// Cobre: money.js (teto opcional, padrão inalterado), roteamento /api/finance da 03B.2B, allowlist de
// query/body, limites (período, valor R$ 1.000.000,00, cursores), mapeamento de erros sem vazamento,
// status 201/200 (replay), argumentos EXATOS das 14 RPCs (conferidos contra a migration congelada),
// route (no-store, sessão, sem service-role, 03B.1 intacta), client (URLs, no-store, erros, rede) e
// helpers de apresentação (badges no feminino, ações pelo estado real, diff, validação, intenção,
// direção do Caixa pelo banco).
// 03B.2B-2A (UI de leitura): URL das abas (finance-nav), lazy mount, RECEPTIONIST sem chamadas, nenhuma
// escrita na UI, cards/filtros/lista/detalhe de Despesas, Caixa consolidado, mobile/a11y e corridas
// (lista, "mais", detalhe A/B, fechar Sheet, cursor composto do Caixa) com runLatest + client reais.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { parseMoneyToCents, MAX_CENTS } from '../lib/reserva/money.js'
import {
  EXPENSE_ENDPOINTS, isExpenseEndpoint, EXPENSE_MAX_CENTS, EXPENSE_HINT_MSG, EXPENSE_ERRORS, parseExpenseQuery, parseJsonBody,
  parseExpenseCreate, parseExpenseUpdate, parseCategoryCreate, parseCategoryUpdate, parsePaymentRegister, parsePaymentReverse,
  parseExpenseCancel, parsePaymentVoid, financePathSegments, resolveExpenseRoute, mapExpenseError, runExpenseRoute, normalizeExpenseText,
} from '../lib/reserva/expenses-api.js'
import { expensesUrl, fetchExpenses, sendExpense, createExpensesApi, ExpenseRequestError, ExpenseNetworkError } from '../lib/reserva/expenses-client.js'
import {
  EXPENSE_STATUS_FILTERS, DEFAULT_EXPENSE_FILTER, EXPENSE_FILTER_LABELS, EXPENSE_STATUS_META, OVERDUE_META, expenseBadges, fmtDueDate,
  reversibleOf, deriveExpenseActions, validateExpenseDraft, buildExpenseChanges, validateEntryDraft, validateReason, validateCategoryName,
  categoryOptions, createOperationIntent, MOVEMENT_LABELS, movementView,
} from '../lib/reserva/expenses.js'
import { resolvePeriod, periodFromSearch } from '../lib/reserva/finance-period.js'
import { periodParams } from '../lib/reserva/finance-client.js'
import { FINANCE_TABS, tabFromSearch, financeSearch, nextFinanceSearch, urlArena } from '../lib/reserva/finance-nav.js'
import { canViewFinance, ROLES } from '../lib/auth/permissions.js'
import { createRequestSequence, runLatest } from '../lib/reserva/latest-request.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripJsComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ROUTE = read('app/api/[[...path]]/route.js')
const MIGRATION = read('supabase/migration_phase3b2_expenses.sql')

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
const sp = (o = {}) => { const q = new URLSearchParams(); for (const [k, v] of Object.entries(o)) (Array.isArray(v) ? v : [v]).forEach((x) => q.append(k, x)); return q }
const ORG = '1b728e0e-cc5f-4d3f-9e10-2864238754fc'
const ARENA = '0df00495-9f3f-4b8b-b14c-1392f6b99b83'
const CAT = '5a3c7e10-2b4d-4f6a-8c9e-1d2f3a4b5c6d'
const EXP = '6f1c2a8e-1d3b-4c55-9a77-0b8e2d4c6f10'
const PAY = '7e2d3b9f-2e4c-4d66-8b88-1c9f3e5d7a21'
const OP = '8f3e4c0a-3f5d-4e77-9c99-2d0a4f6e8b32'
const BASE = { organization_id: ORG, from: '2026-10-01', to: '2026-10-31' }
const USER = { id: 'u' }
const silent = () => {}
function fakeRpc(respond) {
  const calls = []
  return { calls, fn: async (name, args) => { calls.push([name, args]); return respond(name, args) } }
}
const run = (o) => runExpenseRoute({ searchParams: sp(), rawBody: null, user: USER, log: silent, ...o })
const okRpc = (data = { ok: true }) => fakeRpc(() => ({ data, error: null }))
const isBad = (r) => r.ok === false && r.status === 400

// ------------------------------------------------------------------ money.js
await check('M01 parseMoneyToCents sem opção: comportamento 03A inalterado', () => {
  const want = { '150': 15000, '150,5': 15050, '1.500,00': 150000, '1,500.00': 150000, '100.000,00': MAX_CENTS, '100.000,01': null,
    '1.000.000,00': null, '1.234.567': null, '0': 0, '007': 700, '12,345': null, '-1': null, 'abc': null }
  for (const [i, w] of Object.entries(want)) assert.equal(parseMoneyToCents(i), w, i)
  for (const bad of [null, undefined, 150, {}]) assert.equal(parseMoneyToCents(bad), null)
})
await check('M02 parseMoneyToCents { max: R$ 1.000.000,00 } para despesas', () => {
  const o = { max: EXPENSE_MAX_CENTS }
  assert.equal(EXPENSE_MAX_CENTS, 100000000)
  const want = { '1.000.000,00': 100000000, '1000000': 100000000, '999.999,99': 99999999, '1.000.000,01': null, '10.000.000,00': null, '150,00': 15000, '9999999999999': null }
  for (const [i, w] of Object.entries(want)) assert.equal(parseMoneyToCents(i, o), w, i)
  for (const max of [-1, 1.5, NaN, '100']) assert.equal(parseMoneyToCents('1,00', { max }), null, String(max))
})
await check('M03 money.js continua sem parseFloat / toFixed / * 100 / Math.round', () => {
  const code = stripJsComments(read('lib/reserva/money.js'))
  for (const bad of ['parseFloat', 'toFixed', '* 100', '*100', 'Math.round', 'Number(input']) assert.ok(!code.includes(bad), bad)
})

// ------------------------------------------------------------------ roteamento
await check('R01 endpoints da 03B.2B e separação da 03B.1', () => {
  assert.deepEqual(EXPENSE_ENDPOINTS, ['expense-categories', 'expense-overview', 'expenses', 'expense-payments', 'cash-result', 'cash-movements'])
  for (const e of ['overview', 'receivables', 'cashflow', 'cash-entries', '', undefined, 'Expenses']) assert.equal(isExpenseEndpoint(e), false, String(e))
})
await check('R02 tabela de rotas: método + caminho exatos; o resto é 404', () => {
  const ok = [['GET', ['expense-categories']], ['POST', ['expense-categories']], ['PATCH', ['expense-categories', CAT]], ['GET', ['expense-overview']],
    ['GET', ['expenses']], ['POST', ['expenses']], ['GET', ['expenses', EXP]], ['PATCH', ['expenses', EXP]], ['POST', ['expenses', EXP, 'cancel']],
    ['POST', ['expenses', EXP, 'payments']], ['POST', ['expense-payments', PAY, 'reverse']], ['POST', ['expense-payments', PAY, 'void']],
    ['GET', ['cash-result']], ['GET', ['cash-movements']]]
  for (const [m, s] of ok) assert.ok(resolveExpenseRoute(m, s), `${m} ${s.join('/')}`)
  const bad = [['DELETE', ['expenses', EXP]], ['PUT', ['expenses', EXP]], ['GET', ['expense-categories', CAT]], ['POST', ['expense-overview']],
    ['GET', ['expenses', EXP, 'payments']], ['POST', ['expenses', EXP, 'void']], ['POST', ['expense-payments', PAY]], ['GET', ['expense-payments']],
    ['PATCH', ['expenses']], ['POST', ['expenses', EXP, 'cancel', 'x']], ['GET', []], ['GET', ['cash-result', EXP]]]
  for (const [m, s] of bad) assert.equal(resolveExpenseRoute(m, s), null, `${m} ${s.join('/')}`)
})
await check('R03 financePathSegments: até 3 segmentos, sem segmento vazio, só sob /api/finance/', () => {
  assert.deepEqual(financePathSegments(`/api/finance/expenses/${EXP}/payments`), ['expenses', EXP, 'payments'])
  assert.deepEqual(financePathSegments('/api/finance/cash-result'), ['cash-result'])
  for (const p of ['/api/finance/', '/api/finance//x', `/api/finance/expenses/${EXP}/`, '/api/finance/a/b/c/d', '/api/other/expenses', null]) assert.equal(financePathSegments(p), null, String(p))
})
await check('R04 sem usuário => 401 antes de qualquer validação ou RPC', async () => {
  const r = okRpc()
  for (const [m, s] of [['GET', ['expenses']], ['POST', ['expenses']], ['GET', ['nada']]]) {
    const out = await run({ method: m, segments: s, user: null, callRpc: r.fn })
    assert.equal(out.status, 401)
  }
  assert.equal(r.calls.length, 0)
})
await check('R05 rota desconhecida => 404; id não-uuid => 404 com mensagem da entidade; nenhuma RPC', async () => {
  const r = okRpc()
  assert.equal((await run({ method: 'DELETE', segments: ['expenses', EXP], callRpc: r.fn })).status, 404)
  assert.equal((await run({ method: 'GET', segments: null, callRpc: r.fn })).status, 404)
  const d = await run({ method: 'GET', segments: ['expenses', 'abc'], callRpc: r.fn })
  assert.equal(d.status, 404); assert.equal(d.body.error, EXPENSE_ERRORS.expenseNotFound)
  const v = await run({ method: 'POST', segments: ['expense-payments', 'x1', 'void'], rawBody: '{"reason":"a"}', callRpc: r.fn })
  assert.equal(v.status, 404); assert.equal(v.body.error, EXPENSE_ERRORS.entryNotFound)
  const c = await run({ method: 'PATCH', segments: ['expense-categories', '1'], rawBody: '{"name":"a"}', callRpc: r.fn })
  assert.equal(c.status, 404); assert.equal(c.body.error, EXPENSE_ERRORS.categoryNotFound)
  assert.equal(r.calls.length, 0)
})

// ------------------------------------------------------------------ query (GET)
await check('Q01 expense-categories: include_inactive 0|1 => boolean; outros valores 400', () => {
  assert.deepEqual(parseExpenseQuery('expense-categories', sp({ organization_id: ORG })), { ok: true, rpc: 'rg_expense_categories', args: { p_org: ORG, p_include_inactive: false } })
  assert.deepEqual(parseExpenseQuery('expense-categories', sp({ organization_id: ORG, include_inactive: '1' })).args, { p_org: ORG, p_include_inactive: true })
  for (const v of ['true', '2', 'yes']) assert.ok(isBad(parseExpenseQuery('expense-categories', sp({ organization_id: ORG, include_inactive: v }))), v)
  assert.ok(isBad(parseExpenseQuery('expense-categories', sp({ organization_id: ORG, from: '2026-10-01' }))), 'período não pertence a categorias')
})
await check('Q02 expense-overview: argumentos exatos; comparação opcional e sempre antes do período', () => {
  assert.deepEqual(parseExpenseQuery('expense-overview', sp({ ...BASE, arena_id: ARENA, category_id: CAT, compare_from: '2026-09-01', compare_to: '2026-09-30' })), {
    ok: true, rpc: 'rg_expense_overview',
    args: { p_org: ORG, p_arena: ARENA, p_category: CAT, p_from: '2026-10-01', p_to: '2026-10-31', p_compare_from: '2026-09-01', p_compare_to: '2026-09-30' },
  })
  assert.deepEqual(parseExpenseQuery('expense-overview', sp(BASE)).args, { p_org: ORG, p_arena: null, p_category: null, p_from: '2026-10-01', p_to: '2026-10-31', p_compare_from: null, p_compare_to: null })
  for (const c of [{ compare_from: '2026-09-01' }, { compare_from: '2026-09-01', compare_to: '2026-10-01' }, { compare_from: '2026-09-10', compare_to: '2026-09-01' },
    { compare_from: '2025-01-01', compare_to: '2026-09-30' }, { compare_from: 'x', compare_to: '2026-09-30' }]) assert.ok(isBad(parseExpenseQuery('expense-overview', sp({ ...BASE, ...c }))), JSON.stringify(c))
})
await check('Q03 expenses: status padrão ACTIVE, limit 1..200, cursor (due_date, id) completo', () => {
  assert.deepEqual(parseExpenseQuery('expenses', sp(BASE)), {
    ok: true, rpc: 'rg_expenses',
    args: { p_org: ORG, p_arena: null, p_category: null, p_from: '2026-10-01', p_to: '2026-10-31', p_status: 'ACTIVE', p_limit: 50, p_after_due: null, p_after_id: null },
  })
  for (const s of ['ACTIVE', 'OPEN', 'OVERDUE', 'PAID', 'CANCELLED']) assert.equal(parseExpenseQuery('expenses', sp({ ...BASE, status: s })).args.p_status, s)
  assert.deepEqual(parseExpenseQuery('expenses', sp({ ...BASE, limit: '200', after_due: '2026-10-05', after_id: EXP })).args.p_after_due, '2026-10-05')
  for (const bad of [{ status: 'PARTIAL' }, { status: 'active' }, { limit: '0' }, { limit: '201' }, { limit: '01' }, { limit: '1.5' }, { after_due: '2026-10-05' },
    { after_id: EXP }, { after_due: '2026-02-30', after_id: EXP }, { after_due: '2026-10-05', after_id: 'x' }]) assert.ok(isBad(parseExpenseQuery('expenses', sp({ ...BASE, ...bad }))), JSON.stringify(bad))
})
await check('Q04 cash-result: teto por granularidade igual ao da RPC (366 dias / 60 meses / 10 anos)', () => {
  assert.deepEqual(parseExpenseQuery('cash-result', sp(BASE)), { ok: true, rpc: 'rg_fin_cash_result', args: { p_org: ORG, p_arena: null, p_from: '2026-10-01', p_to: '2026-10-31', p_granularity: 'day' } })
  assert.ok(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2025-10-01', to: '2026-09-30', granularity: 'day' })).ok, '365 dias')
  assert.ok(isBad(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2025-01-01', to: '2026-01-02', granularity: 'day' }))), '367 dias')
  assert.ok(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2021-11-01', to: '2026-10-31', granularity: 'month' })).ok, '60 meses')
  assert.ok(isBad(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2021-10-31', to: '2026-10-01', granularity: 'month' }))), '61 meses')
  assert.ok(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2017-01-01', to: '2026-12-31', granularity: 'year' })).ok, '10 anos')
  assert.ok(isBad(parseExpenseQuery('cash-result', sp({ organization_id: ORG, from: '2016-12-31', to: '2026-01-01', granularity: 'year' }))), '11 anos')
  for (const g of ['week', 'DAY', 'hour']) assert.ok(isBad(parseExpenseQuery('cash-result', sp({ ...BASE, granularity: g }))), g)
})
await check('Q05 cash-movements: cursor composto (occurred_at, source_kind 1|2, id) completo e válido', () => {
  const at = '2026-10-03T15:00:00.123456+00:00'
  assert.deepEqual(parseExpenseQuery('cash-movements', sp({ ...BASE, after_at: at, after_source: '2', after_id: PAY })).args,
    { p_org: ORG, p_arena: null, p_from: '2026-10-01', p_to: '2026-10-31', p_limit: 50, p_after_at: at, p_after_source: 2, p_after_id: PAY })
  assert.deepEqual(parseExpenseQuery('cash-movements', sp(BASE)).args.p_after_source, null)
  for (const bad of [{ after_at: at }, { after_at: at, after_source: '1' }, { after_source: '1', after_id: PAY }, { after_at: at, after_source: '3', after_id: PAY },
    { after_at: at, after_source: '0', after_id: PAY }, { after_at: '2026-10-03T15:00:00', after_source: '1', after_id: PAY }, { after_at: at, after_source: '1', after_id: 'x' }, { limit: '500' }])
    assert.ok(isBad(parseExpenseQuery('cash-movements', sp({ ...BASE, ...bad }))), JSON.stringify(bad))
})
await check('Q06 comuns: parâmetro repetido/desconhecido, org/arena/categoria inválidas, período 1..366', () => {
  for (const ep of ['expense-overview', 'expenses', 'cash-result', 'cash-movements']) {
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, organization_id: [ORG, ORG] }))), `${ep} repetido`)
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, filter: 'OPEN' }))), `${ep} desconhecido`)
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, organization_id: 'x' }))), `${ep} org`)
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, arena_id: 'x' }))), `${ep} arena`)
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, from: '2026-11-01' }))), `${ep} from > to`)
    assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, to: '2026-13-01' }))), `${ep} data inválida`)
  }
  for (const ep of ['expense-overview', 'expenses', 'cash-movements']) assert.ok(isBad(parseExpenseQuery(ep, sp({ organization_id: ORG, from: '2025-01-01', to: '2026-01-02' }))), `${ep} 367 dias`)
  for (const ep of ['expense-overview', 'expenses']) assert.ok(isBad(parseExpenseQuery(ep, sp({ ...BASE, category_id: 'x' }))), `${ep} categoria`)
  assert.ok(isBad(parseExpenseQuery('cash-result', sp({ ...BASE, category_id: CAT }))), 'categoria não pertence ao caixa')
  assert.equal(parseExpenseQuery('overview', sp(BASE)).status, 404)
})
await check('Q07 detalhe e escritas não aceitam parâmetros de query', async () => {
  const r = okRpc()
  assert.equal((await run({ method: 'GET', segments: ['expenses', EXP], searchParams: sp({ x: '1' }), callRpc: r.fn })).status, 400)
  assert.equal((await run({ method: 'POST', segments: ['expenses', EXP, 'cancel'], searchParams: sp({ organization_id: ORG }), rawBody: '{"reason":"a"}', callRpc: r.fn })).status, 400)
  assert.equal(r.calls.length, 0)
})

// ------------------------------------------------------------------ body (POST/PATCH)
const CREATE = { operation_id: OP, organization_id: ORG, arena_id: ARENA, category_id: CAT, description: 'Conta de luz', amount: 15000, due_date: '2026-10-10', notes: 'ref. set' }
await check('B01 corpo: só objeto JSON até 16384 caracteres', () => {
  for (const raw of [null, '', 'x', '[]', 'null', '"a"', '1', '{', `{"a":"${'x'.repeat(16400)}"}`]) assert.equal(parseJsonBody(raw), null, String(raw).slice(0, 20))
  assert.deepEqual(parseJsonBody('{"a":1}'), { a: 1 })
})
await check('B02 criar despesa: argumentos exatos e validação estrita', () => {
  assert.deepEqual(parseExpenseCreate(CREATE), { ok: true, args: { p_operation_id: OP, p_org: ORG, p_arena: ARENA, p_category: CAT, p_description: 'Conta de luz', p_amount: 15000, p_due_date: '2026-10-10', p_notes: 'ref. set' } })
  const { arena_id: _a, notes: _n, ...min } = CREATE
  assert.deepEqual(parseExpenseCreate(min).args, { p_operation_id: OP, p_org: ORG, p_arena: null, p_category: CAT, p_description: 'Conta de luz', p_amount: 15000, p_due_date: '2026-10-10', p_notes: null })
  assert.equal(parseExpenseCreate({ ...CREATE, arena_id: null, notes: '   ' }).args.p_notes, null)
  assert.ok(parseExpenseCreate({ ...CREATE, amount: 1 }).ok && parseExpenseCreate({ ...CREATE, amount: 100000000 }).ok)
  assert.ok(parseExpenseCreate({ ...CREATE, description: `  ${'a'.repeat(100)}   ${'b'.repeat(99)}  ` }).ok, '200 após normalizar')
  const bad = [{ amount: 0 }, { amount: -5 }, { amount: 100000001 }, { amount: 1.5 }, { amount: '15000' }, { amount: null }, { description: '' }, { description: ' \t\n ' },
    { description: 'a'.repeat(201) }, { description: 5 }, { due_date: '2026-02-30' }, { due_date: '10/10/2026' }, { due_date: '1999-12-31' }, { notes: 'x'.repeat(501) }, { notes: 5 },
    { arena_id: 'x' }, { category_id: null }, { operation_id: 'x' }, { organization_id: 'x' }, { extra: 1 }, { organization: ORG }]
  for (const b of bad) assert.ok(isBad(parseExpenseCreate({ ...CREATE, ...b })), JSON.stringify(b).slice(0, 60))
  for (const k of ['operation_id', 'organization_id', 'category_id', 'description', 'amount', 'due_date']) {
    const b = { ...CREATE }; delete b[k]; assert.ok(isBad(parseExpenseCreate(b)), `sem ${k}`)
  }
})
await check('B03 editar despesa: allowlist, ao menos um campo, tipos estritos, só as chaves enviadas', () => {
  assert.deepEqual(parseExpenseUpdate(EXP, { amount: 2000 }), { ok: true, args: { p_expense_id: EXP, p_changes: { amount: 2000 } } })
  assert.deepEqual(parseExpenseUpdate(EXP, { arena_id: null, notes: '' }).args.p_changes, { arena_id: null, notes: null })
  assert.deepEqual(parseExpenseUpdate(EXP, { description: 'Água', category_id: CAT, due_date: '2026-11-01', notes: ' x ' }).args.p_changes,
    { description: 'Água', category_id: CAT, due_date: '2026-11-01', notes: 'x' })
  for (const b of [{}, { status: 'PAID' }, { amount: '10' }, { amount: 0 }, { amount: 100000001 }, { arena_id: 'x' }, { category_id: null }, { due_date: 'x' }, { description: '  ' },
    { notes: 'x'.repeat(501) }, { cancelled_at: null }, { organization_id: ORG }]) assert.ok(isBad(parseExpenseUpdate(EXP, b)), JSON.stringify(b).slice(0, 50))
})
await check('B04 pagamento e devolução: meio do banco, instante com fuso (2000..2100), chave de data própria', () => {
  const at = '2026-10-03T10:30:00-03:00'
  assert.deepEqual(parsePaymentRegister(EXP, { operation_id: OP, method: 'PIX', amount: 500, paid_at: at }),
    { ok: true, args: { p_operation_id: OP, p_expense_id: EXP, p_method: 'PIX', p_amount: 500, p_paid_at: at, p_notes: null } })
  assert.deepEqual(parsePaymentReverse(PAY, { operation_id: OP, method: 'CASH', amount: 200, reversed_at: at, notes: 'troco' }),
    { ok: true, args: { p_operation_id: OP, p_payment_id: PAY, p_method: 'CASH', p_amount: 200, p_reversed_at: at, p_notes: 'troco' } })
  const P = { operation_id: OP, method: 'PIX', amount: 500, paid_at: at }
  for (const b of [{ method: 'BOLETO' }, { method: 'pix' }, { amount: 0 }, { amount: 100000001 }, { paid_at: '2026-10-03T10:30' }, { paid_at: '2026-10-03T10:30:00' },
    { paid_at: '2101-01-01T00:00:00Z' }, { paid_at: '1999-12-31T23:59:59Z' }, { operation_id: null }, { notes: 'x'.repeat(501) }, { reversed_at: at }])
    assert.ok(isBad(parsePaymentRegister(EXP, { ...P, ...b })), JSON.stringify(b))
  assert.ok(isBad(parsePaymentReverse(PAY, P)), 'devolução exige reversed_at')
  for (const m of ['PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER']) assert.ok(parsePaymentRegister(EXP, { ...P, method: m }).ok, m)
})
await check('B05 cancelar despesa / anular lançamento: motivo obrigatório (1..500), aparado', () => {
  assert.deepEqual(parseExpenseCancel(EXP, { reason: '  lançada em duplicidade ' }), { ok: true, args: { p_expense_id: EXP, p_reason: 'lançada em duplicidade' } })
  assert.deepEqual(parsePaymentVoid(PAY, { reason: 'valor errado' }), { ok: true, args: { p_payment_id: PAY, p_reason: 'valor errado' } })
  for (const b of [{}, { reason: '' }, { reason: '   ' }, { reason: 'x'.repeat(501) }, { reason: 5 }, { reason: 'a', extra: 1 }]) {
    assert.ok(isBad(parseExpenseCancel(EXP, b)), JSON.stringify(b).slice(0, 40)); assert.ok(isBad(parsePaymentVoid(PAY, b)), JSON.stringify(b).slice(0, 40))
  }
})
await check('B06 categorias: nome 1..60 após normalizar; is_active boolean; ao menos um campo', () => {
  assert.deepEqual(parseCategoryCreate({ organization_id: ORG, name: 'Limpeza' }), { ok: true, args: { p_org: ORG, p_name: 'Limpeza' } })
  assert.deepEqual(parseCategoryUpdate(CAT, { is_active: false }), { ok: true, args: { p_category_id: CAT, p_changes: { is_active: false } } })
  assert.deepEqual(parseCategoryUpdate(CAT, { name: 'Luz', is_active: true }).args.p_changes, { name: 'Luz', is_active: true })
  for (const b of [{ organization_id: ORG }, { organization_id: ORG, name: '  ' }, { organization_id: ORG, name: 'x'.repeat(61) }, { organization_id: 'x', name: 'a' }, { organization_id: ORG, name: 'a', is_active: true }])
    assert.ok(isBad(parseCategoryCreate(b)), JSON.stringify(b).slice(0, 40))
  for (const b of [{}, { is_active: 'false' }, { name: '' }, { name: 'a', extra: 1 }]) assert.ok(isBad(parseCategoryUpdate(CAT, b)), JSON.stringify(b))
  assert.equal(normalizeExpenseText('  a \t b\n c  '), 'a b c')
})

// ------------------------------------------------------------------ execução / status
await check('X01 201 para criação nova; 200 para replay idempotente / categoria existente / demais', async () => {
  const cases = [
    ['POST', ['expenses'], JSON.stringify(CREATE), { expense_id: EXP, idempotent: false }, 201],
    ['POST', ['expenses'], JSON.stringify(CREATE), { expense_id: EXP, idempotent: true }, 200],
    ['POST', ['expenses', EXP, 'payments'], JSON.stringify({ operation_id: OP, method: 'PIX', amount: 1, paid_at: '2026-10-03T10:00:00-03:00' }), { payment_id: PAY, idempotent: false }, 201],
    ['POST', ['expense-payments', PAY, 'reverse'], JSON.stringify({ operation_id: OP, method: 'PIX', amount: 1, reversed_at: '2026-10-03T10:00:00-03:00' }), { idempotent: true }, 200],
    ['POST', ['expense-categories'], JSON.stringify({ organization_id: ORG, name: 'Luz' }), { created: true }, 201],
    ['POST', ['expense-categories'], JSON.stringify({ organization_id: ORG, name: 'Luz' }), { created: false }, 200],
    ['PATCH', ['expenses', EXP], '{"amount":10}', { changed: true }, 200],
    ['POST', ['expenses', EXP, 'cancel'], '{"reason":"x"}', { changed: false }, 200],
    ['POST', ['expense-payments', PAY, 'void'], '{"reason":"x"}', { changed: true }, 200],
    ['GET', ['expenses', EXP], null, { expense_id: EXP }, 200],
  ]
  for (const [m, s, raw, data, want] of cases) {
    const out = await run({ method: m, segments: s, rawBody: raw, callRpc: okRpc(data).fn })
    assert.equal(out.status, want, `${m} ${s.join('/')}`); assert.equal(out.body, data)
  }
})
await check('X02 cada rota chama a RPC certa com os argumentos certos', async () => {
  const at = '2026-10-03T10:00:00-03:00'
  const cases = [
    ['GET', ['expense-categories'], sp({ organization_id: ORG }), null, 'rg_expense_categories'],
    ['GET', ['expense-overview'], sp(BASE), null, 'rg_expense_overview'],
    ['GET', ['expenses'], sp(BASE), null, 'rg_expenses'],
    ['GET', ['expenses', EXP], sp(), null, 'rg_expense_detail', { p_expense_id: EXP }],
    ['GET', ['cash-result'], sp(BASE), null, 'rg_fin_cash_result'],
    ['GET', ['cash-movements'], sp(BASE), null, 'rg_fin_cash_movements'],
    ['POST', ['expense-categories'], sp(), '{"organization_id":"' + ORG + '","name":"Luz"}', 'rg_expense_category_create', { p_org: ORG, p_name: 'Luz' }],
    ['PATCH', ['expense-categories', CAT], sp(), '{"is_active":true}', 'rg_expense_category_update', { p_category_id: CAT, p_changes: { is_active: true } }],
    ['POST', ['expenses'], sp(), JSON.stringify(CREATE), 'rg_expense_create'],
    ['PATCH', ['expenses', EXP], sp(), '{"due_date":"2026-11-01"}', 'rg_expense_update', { p_expense_id: EXP, p_changes: { due_date: '2026-11-01' } }],
    ['POST', ['expenses', EXP, 'cancel'], sp(), '{"reason":"dup"}', 'rg_expense_cancel', { p_expense_id: EXP, p_reason: 'dup' }],
    ['POST', ['expenses', EXP, 'payments'], sp(), JSON.stringify({ operation_id: OP, method: 'PIX', amount: 7, paid_at: at }), 'rg_expense_payment_register'],
    ['POST', ['expense-payments', PAY, 'reverse'], sp(), JSON.stringify({ operation_id: OP, method: 'PIX', amount: 7, reversed_at: at }), 'rg_expense_payment_reverse'],
    ['POST', ['expense-payments', PAY, 'void'], sp(), '{"reason":"erro"}', 'rg_expense_payment_void', { p_payment_id: PAY, p_reason: 'erro' }],
  ]
  for (const [m, s, q, raw, rpc, args] of cases) {
    const r = okRpc()
    const out = await run({ method: m, segments: s, searchParams: q, rawBody: raw, callRpc: r.fn })
    assert.equal(out.status < 300, true, `${m} ${s.join('/')} => ${out.status} ${JSON.stringify(out.body)}`)
    assert.equal(r.calls.length, 1); assert.equal(r.calls[0][0], rpc)
    if (args) assert.deepEqual(r.calls[0][1], args)
  }
})
await check('X03 corpo inválido => 400 sem RPC; resposta vazia/array/exceção => 500 genérico com log', async () => {
  const r = okRpc()
  for (const raw of [null, '', '[]', '{bad', JSON.stringify({ ...CREATE, amount: 100000001 })]) assert.equal((await run({ method: 'POST', segments: ['expenses'], rawBody: raw, callRpc: r.fn })).status, 400)
  assert.equal(r.calls.length, 0)
  for (const data of [null, undefined, 'x', 5, []]) {
    const logs = []
    const out = await run({ method: 'GET', segments: ['expenses', EXP], callRpc: fakeRpc(() => ({ data, error: null })).fn, log: (...a) => logs.push(a) })
    assert.equal(out.status, 500); assert.deepEqual(out.body, { error: EXPENSE_ERRORS.internal }); assert.equal(logs.length, 1)
  }
  const out = await run({ method: 'GET', segments: ['expenses', EXP], callRpc: async () => { throw new Error('SEGREDO') } })
  assert.equal(out.status, 500); assert.ok(!JSON.stringify(out.body).includes('SEGREDO'))
})

// ------------------------------------------------------------------ erros
await check('E01 mapeamento: 22023/23514/RGT->400, 42501->403, P0002->404, RGP01/02/03->409, concorrência->503, resto->500', () => {
  const want = { 22023: 400, 23514: 400, 23502: 400, 23503: 400, '22P02': 400, P0001: 400, RGT01: 400, RGT02: 400, 42501: 403, P0002: 404,
    RGP01: 409, RGP02: 409, RGP03: 409, 40001: 503, '40P01': 503, '55P03': 503, 23505: 500, XX000: 500, undefined: 500 }
  for (const [code, status] of Object.entries(want)) assert.equal(mapExpenseError({ code: code === 'undefined' ? undefined : code }).status, status, code)
  assert.equal(mapExpenseError({ code: 'RGP02' }).body.code, 'IDEMPOTENCY_MISMATCH')
  assert.equal(mapExpenseError({ code: 'RGP01' }).body.code, 'FINANCE_STATE')
  assert.equal(mapExpenseError({ code: 'RGP03' }).body.code, 'FINANCE_LIMIT')
})
await check('E02 hints estáveis da 03B.2 viram mensagem + reason; hint desconhecido não vaza', () => {
  const hints = ['EXPENSE_CANCELLED', 'AMOUNT_LOCKED', 'ARENA_LOCKED', 'NET_PAID', 'CATEGORY_INACTIVE', 'CATEGORY_INACTIVE_EXISTS', 'CATEGORY_NAME_EXISTS',
    'NOT_A_PAYMENT', 'PAYMENT_VOIDED', 'HAS_REVERSALS', 'OVER_BALANCE', 'OVER_REVERSIBLE']
  assert.deepEqual(Object.keys(EXPENSE_HINT_MSG).sort(), [...hints].sort())
  for (const h of hints) {
    const m = mapExpenseError({ code: h.startsWith('OVER') ? 'RGP03' : 'RGP01', hint: h })
    assert.equal(m.body.reason, h); assert.equal(m.body.error, EXPENSE_HINT_MSG[h])
  }
  // os hints usados pelas RPCs da migration congelada estão todos cobertos
  const used = [...new Set([...MIGRATION.matchAll(/hint = '([A-Z_]+)'/g)].map((x) => x[1]))]
  for (const h of used) assert.ok(hints.includes(h), `hint da migration sem mensagem: ${h}`)
  const u = mapExpenseError({ code: 'RGP01', hint: 'INTERNO_X', message: 'SQL secreto', details: 'tabela' })
  assert.deepEqual(u.body, { error: EXPENSE_ERRORS.state, code: 'FINANCE_STATE' })
})
await check('E03 nenhuma mensagem/detalhe/hint cru do banco chega ao cliente; log só com código', async () => {
  const logs = []
  const secret = { code: 'XX000', message: 'relation private.x SEGREDO', details: 'SEGREDO2', hint: 'SEGREDO3' }
  const out = await run({ method: 'GET', segments: ['expenses'], searchParams: sp(BASE), callRpc: async () => ({ data: null, error: secret }), log: (...a) => logs.push(a) })
  assert.equal(out.status, 500); assert.ok(!/SEGREDO/.test(JSON.stringify(out.body)))
  assert.ok(!/SEGREDO/.test(JSON.stringify(logs))); assert.deepEqual(logs[0], ['rpc despesas 03B.2B', 'rg_expenses', 'XX000'])
  for (const code of ['42501', 'P0002', 'RGP01', '22023']) {
    const o = await run({ method: 'GET', segments: ['expenses', EXP], callRpc: async () => ({ data: null, error: { ...secret, code } }) })
    assert.ok(!/SEGREDO/.test(JSON.stringify(o.body)), code)
  }
  const nf = await run({ method: 'GET', segments: ['expenses', EXP], callRpc: async () => ({ data: null, error: { code: 'P0002' } }) })
  assert.deepEqual(nf, { status: 404, body: { error: EXPENSE_ERRORS.expenseNotFound } })
})

// ------------------------------------------------------------------ contrato com a migration congelada
await check('S01 as 14 RPCs: nomes e parâmetros EXATOS da migration_phase3b2_expenses.sql', async () => {
  const sig = {}
  for (const m of MIGRATION.matchAll(/create function public\.(\w+)\(([\s\S]*?)\)\s*returns/g)) {
    sig[m[1]] = m[2].split(',').map((p) => p.trim().split(/\s+/)[0]).filter(Boolean).sort()
  }
  const at = '2026-10-03T10:00:00-03:00'
  const calls = {}
  const capture = { fn: async (name, args) => { calls[name] = Object.keys(args).sort(); return { data: {}, error: null } } }
  const reqs = [
    ['GET', ['expense-categories'], sp({ organization_id: ORG }), null], ['GET', ['expense-overview'], sp(BASE), null], ['GET', ['expenses'], sp(BASE), null],
    ['GET', ['expenses', EXP], sp(), null], ['GET', ['cash-result'], sp(BASE), null], ['GET', ['cash-movements'], sp(BASE), null],
    ['POST', ['expense-categories'], sp(), JSON.stringify({ organization_id: ORG, name: 'a' })], ['PATCH', ['expense-categories', CAT], sp(), '{"name":"b"}'],
    ['POST', ['expenses'], sp(), JSON.stringify(CREATE)], ['PATCH', ['expenses', EXP], sp(), '{"amount":5}'], ['POST', ['expenses', EXP, 'cancel'], sp(), '{"reason":"r"}'],
    ['POST', ['expenses', EXP, 'payments'], sp(), JSON.stringify({ operation_id: OP, method: 'PIX', amount: 1, paid_at: at })],
    ['POST', ['expense-payments', PAY, 'reverse'], sp(), JSON.stringify({ operation_id: OP, method: 'PIX', amount: 1, reversed_at: at })],
    ['POST', ['expense-payments', PAY, 'void'], sp(), '{"reason":"r"}'],
  ]
  for (const [m, s, q, raw] of reqs) await run({ method: m, segments: s, searchParams: q, rawBody: raw, callRpc: capture.fn })
  const rpcs = Object.keys(calls).sort()
  assert.equal(rpcs.length, 14)
  for (const name of rpcs) assert.deepEqual(calls[name], sig[name], `${name}: api=${calls[name]} migration=${sig[name]}`)
})

// ------------------------------------------------------------------ route
await check('T01 route: /api/finance da 03B.2B no handleFinance — sessão, no-store em toda resposta, sem service-role', () => {
  const m = /async function handleFinance\([^)]*\) \{([\s\S]*?)\n\}\n/.exec(ROUTE)
  assert.ok(m, 'handleFinance')
  const body = m[1]
  for (const r of body.match(/return [^\n]+/g)) assert.ok(r.startsWith('return jsonNoStore('), r)
  assert.ok(body.includes('runExpenseRoute(') && body.includes('financePathSegments(pathname)') && body.includes('isExpenseEndpoint(endpoint)'))
  assert.ok(body.includes('const callRpc = (name, args) => supabase.rpc(name, args)') && body.includes('getContext(request)'))
  assert.ok(!/createAdminClient|admin\.|service_role|SERVICE_ROLE/.test(body), 'sem service-role')
  assert.ok(!/error\.message|\.stack/.test(body), 'sem vazar erro')
  assert.ok(body.includes("if (!expense && (method !== 'GET' || extra !== undefined || !endpoint)) return jsonNoStore({ error: 'Rota não encontrada' }, 404)"), '03B.1: só GET, sem segmento extra')
  assert.ok(body.includes('const r = await runFinanceEndpoint({ endpoint, searchParams, user, callRpc })'), '03B.1 inalterada')
  assert.ok(ROUTE.includes("if (resource === 'finance') return await handleFinance(request, id, sub, method)"))
  assert.ok(ROUTE.includes("import { isExpenseEndpoint, financePathSegments, runExpenseRoute } from '@/lib/reserva/expenses-api'"))
  // as 14 RPCs da 03B.2 só são chamadas via expenses-api (nenhum .rpc('rg_expense... direto no route)
  assert.ok(!/\.rpc\('rg_(expense|exp_|fin_cash_result|fin_cash_movements)/.test(ROUTE))
})
await check('T02 módulos puros: sem Supabase/Next/service-role; sem termos proibidos', () => {
  for (const f of ['lib/reserva/expenses-api.js', 'lib/reserva/expenses-client.js', 'lib/reserva/expenses.js']) {
    const code = stripJsComments(read(f))
    assert.ok(!/supabase|next\/|createAdminClient|SERVICE_ROLE/i.test(code), f)
    for (const bad of ['lucro', 'faturamento', 'saldo']) assert.ok(!code.toLowerCase().includes(bad), `${f}: ${bad}`)
    for (const bad of ['parseFloat', 'toFixed', '* 100', 'Math.round']) assert.ok(!code.includes(bad), `${f}: ${bad}`)
  }
})

// ------------------------------------------------------------------ client
function fakeFetch(respond) {
  const calls = []
  return { calls, fn: async (url, init) => { calls.push([url, init]); return respond(url, init) } }
}
const resp = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => { if (body === undefined) throw new Error('sem json'); return body } })
await check('C01 expensesUrl: segmentos seguros, vazios omitidos', () => {
  assert.equal(expensesUrl('expenses', { organization_id: ORG, arena_id: null, category_id: '', status: 'OPEN' }), `/api/finance/expenses?organization_id=${ORG}&status=OPEN`)
  assert.equal(expensesUrl(['expenses', EXP, 'payments']), `/api/finance/expenses/${EXP}/payments`)
  for (const s of [[], ['a', 'b', 'c', 'd'], ['../x'], ['a b'], ['expenses', ''], [5]]) assert.throws(() => expensesUrl(s), JSON.stringify(s))
})
await check('C02 fetchExpenses: GET no-store; HTTP de erro => ExpenseRequestError(status, code, reason); rede => ExpenseNetworkError', async () => {
  const f = fakeFetch(() => resp(200, { items: [] }))
  assert.deepEqual(await fetchExpenses('expenses', { organization_id: ORG }, f.fn), { items: [] })
  assert.equal(f.calls[0][1].cache, 'no-store'); assert.equal(f.calls[0][1].method, 'GET')
  const e = await fetchExpenses('expenses', {}, fakeFetch(() => resp(409, { error: 'm', code: 'FINANCE_STATE', reason: 'AMOUNT_LOCKED' })).fn).catch((x) => x)
  assert.ok(e instanceof ExpenseRequestError); assert.equal(e.status, 409); assert.equal(e.code, 'FINANCE_STATE'); assert.equal(e.reason, 'AMOUNT_LOCKED'); assert.equal(e.message, 'm')
  const e2 = await fetchExpenses('expenses', {}, fakeFetch(() => resp(500, undefined)).fn).catch((x) => x)
  assert.ok(e2 instanceof ExpenseRequestError && e2.status === 500 && e2.code === null)
  const n = await fetchExpenses('expenses', {}, async () => { throw new TypeError('offline') }).catch((x) => x)
  assert.ok(n instanceof ExpenseNetworkError && n.network === true)
})
await check('C03 sendExpense: POST/PATCH com JSON e no-store; outros métodos recusados', async () => {
  const f = fakeFetch(() => resp(201, { expense_id: EXP }))
  assert.deepEqual(await sendExpense('POST', 'expenses', { a: 1 }, f.fn), { status: 201, data: { expense_id: EXP } })
  const [url, init] = f.calls[0]
  assert.equal(url, '/api/finance/expenses'); assert.equal(init.method, 'POST'); assert.equal(init.cache, 'no-store')
  assert.equal(init.headers['Content-Type'], 'application/json'); assert.equal(init.body, '{"a":1}')
  await assert.rejects(() => sendExpense('DELETE', 'expenses', {}, f.fn)); await assert.rejects(() => sendExpense('GET', 'expenses', {}, f.fn))
})
await check('C04 createExpensesApi: um método por RPC, URL/método/corpo do contrato, cursores mapeados', async () => {
  const f = fakeFetch(() => resp(200, {}))
  const api = createExpensesApi(f.fn)
  const period = resolvePeriod('custom', '2026-10-15', { from: '2026-10-01', to: '2026-10-15' })
  const scope = { orgId: ORG, arenaId: null, period }
  const v = { arena_id: null, category_id: CAT, description: 'Luz', amount: 100, due_date: '2026-10-10', notes: null }
  const e = { method: 'PIX', amount: 50, at: '2026-10-03T10:00:00-03:00', notes: null }
  await api.categories(ORG, true)
  await api.overview(scope, { categoryId: CAT })
  await api.list(scope, { status: 'OPEN', cursor: { due_date: '2026-10-05', id: EXP } })
  await api.detail(EXP)
  await api.cashResult(scope, 'day')
  await api.cashMovements(scope, { cursor: { occurred_at: '2026-10-03T15:00:00+00:00', source_kind: 2, id: PAY } })
  await api.createCategory(ORG, 'Luz'); await api.updateCategory(CAT, { is_active: false })
  await api.createExpense(OP, ORG, v); await api.updateExpense(EXP, { amount: 5 }); await api.cancelExpense(EXP, 'dup')
  await api.registerPayment(OP, EXP, e); await api.reversePayment(OP, PAY, e); await api.voidPayment(PAY, 'erro')
  const got = f.calls.map(([u, i]) => [i.method, u, i.body ? JSON.parse(i.body) : null])
  const P = `organization_id=${ORG}&from=2026-10-01&to=2026-10-15`
  assert.deepEqual(got, [
    ['GET', `/api/finance/expense-categories?organization_id=${ORG}&include_inactive=1`, null],
    ['GET', `/api/finance/expense-overview?${P}&category_id=${CAT}&compare_from=2026-09-16&compare_to=2026-09-30`, null],
    ['GET', `/api/finance/expenses?${P}&status=OPEN&limit=50&after_due=2026-10-05&after_id=${EXP}`, null],
    ['GET', `/api/finance/expenses/${EXP}`, null],
    ['GET', `/api/finance/cash-result?${P}&granularity=day`, null],
    ['GET', `/api/finance/cash-movements?${P}&limit=50&after_at=2026-10-03T15%3A00%3A00%2B00%3A00&after_source=2&after_id=${PAY}`, null],
    ['POST', '/api/finance/expense-categories', { organization_id: ORG, name: 'Luz' }],
    ['PATCH', `/api/finance/expense-categories/${CAT}`, { is_active: false }],
    ['POST', '/api/finance/expenses', { operation_id: OP, organization_id: ORG, arena_id: null, category_id: CAT, description: 'Luz', amount: 100, due_date: '2026-10-10', notes: null }],
    ['PATCH', `/api/finance/expenses/${EXP}`, { amount: 5 }],
    ['POST', `/api/finance/expenses/${EXP}/cancel`, { reason: 'dup' }],
    ['POST', `/api/finance/expenses/${EXP}/payments`, { operation_id: OP, method: 'PIX', amount: 50, paid_at: '2026-10-03T10:00:00-03:00', notes: null }],
    ['POST', `/api/finance/expense-payments/${PAY}/reverse`, { operation_id: OP, method: 'PIX', amount: 50, reversed_at: '2026-10-03T10:00:00-03:00', notes: null }],
    ['POST', `/api/finance/expense-payments/${PAY}/void`, { reason: 'erro' }],
  ])
  assert.ok(f.calls.every(([, i]) => i.cache === 'no-store'))
})
await check('C05 ida e volta: corpo gerado pelo client é aceito pela API (create/payment/reverse/cancel/void/categoria)', async () => {
  const bodies = []
  const api = createExpensesApi(async (url, init) => { bodies.push([init.method, url, init.body]); return resp(200, {}) })
  await api.createExpense(OP, ORG, { arena_id: ARENA, category_id: CAT, description: 'Luz', amount: 100000000, due_date: '2026-10-10', notes: 'x' })
  await api.registerPayment(OP, EXP, { method: 'TRANSFER', amount: 1, at: '2026-10-03T10:00:00-03:00', notes: null })
  await api.reversePayment(OP, PAY, { method: 'OTHER', amount: 1, at: '2026-10-03T10:00:00-03:00', notes: 'n' })
  await api.cancelExpense(EXP, 'r'); await api.voidPayment(PAY, 'r'); await api.createCategory(ORG, 'Luz'); await api.updateExpense(EXP, { notes: null })
  for (const [m, url, body] of bodies) {
    const out = await run({ method: m, segments: financePathSegments(url.split('?')[0]), rawBody: body, callRpc: okRpc().fn })
    assert.ok(out.status < 300, `${m} ${url}: ${out.status} ${JSON.stringify(out.body)}`)
  }
})

// ------------------------------------------------------------------ apresentação
await check('P01 status e filtros no feminino (K3), filtro padrão Ativas', () => {
  assert.deepEqual(EXPENSE_STATUS_FILTERS, ['ACTIVE', 'OPEN', 'OVERDUE', 'PAID', 'CANCELLED']); assert.equal(DEFAULT_EXPENSE_FILTER, 'ACTIVE')
  assert.deepEqual(EXPENSE_FILTER_LABELS, { ACTIVE: 'Ativas', OPEN: 'Em aberto', OVERDUE: 'Vencidas', PAID: 'Pagas', CANCELLED: 'Canceladas' })
  assert.deepEqual(Object.fromEntries(Object.entries(EXPENSE_STATUS_META).map(([k, v]) => [k, v.label])), { OPEN: 'Em aberto', PARTIAL: 'Parcial', PAID: 'Paga', CANCELLED: 'Cancelada' })
  assert.equal(OVERDUE_META.label, 'Vencida')
})
await check('P02 badges: Vencida é flag só sobre Em aberto/Parcial; status desconhecido => nenhum', () => {
  const L = (r) => expenseBadges(r).map((b) => b.label)
  assert.deepEqual(L({ status: 'OPEN', overdue: false }), ['Em aberto']); assert.deepEqual(L({ status: 'OPEN', overdue: true }), ['Em aberto', 'Vencida'])
  assert.deepEqual(L({ status: 'PARTIAL', overdue: true }), ['Parcial', 'Vencida']); assert.deepEqual(L({ status: 'PAID', overdue: true }), ['Paga'])
  assert.deepEqual(L({ status: 'CANCELLED', overdue: true }), ['Cancelada']); assert.deepEqual(L({ status: 'OVERDUE' }), []); assert.deepEqual(L(null), [])
  assert.equal(fmtDueDate('2026-10-05'), '05/10/2026'); assert.equal(fmtDueDate('x'), '')
})
const D = (o = {}) => ({ expense_id: EXP, status: 'OPEN', amount: 10000, amount_due: 10000, net_paid: 0, cancelled_at: null, can_cancel: true, amount_locked: false, arena_locked: false, entries: [], ...o })
const pay = (o = {}) => ({ payment_id: PAY, kind: 'PAYMENT', amount: 4000, reversed: 0, voided_at: null, ...o })
await check('P03 ações pelo estado real: aberta, parcial, devolução parcial/total, anulado, cancelada, paga', () => {
  let a = deriveExpenseActions(D())
  assert.deepEqual([a.canEdit, a.canPay, a.canCancel, a.amountLocked, a.arenaLocked], [true, true, true, false, false])
  a = deriveExpenseActions(D({ status: 'PARTIAL', amount_due: 6000, net_paid: 4000, can_cancel: false, amount_locked: true, arena_locked: true, entries: [pay()] }))
  assert.deepEqual([a.canPay, a.canCancel, a.amountLocked], [true, false, true])
  assert.deepEqual([a.entries[0].canReverse, a.entries[0].reversible, a.entries[0].canVoid, a.entries[0].voidBlocked], [true, 4000, true, null])
  a = deriveExpenseActions(D({ entries: [pay({ reversed: 1500 }), { payment_id: 'r1', kind: 'REVERSAL', amount: 1500, voided_at: null }] }))
  assert.deepEqual([a.entries[0].canReverse, a.entries[0].reversible, a.entries[0].canVoid, a.entries[0].voidBlocked], [true, 2500, false, 'HAS_REVERSALS'])
  assert.deepEqual([a.entries[1].canReverse, a.entries[1].canVoid], [false, true], 'devolução: só anular')
  a = deriveExpenseActions(D({ entries: [pay({ reversed: 4000 })] }))
  assert.deepEqual([a.entries[0].canReverse, a.entries[0].reversible, a.entries[0].canVoid], [false, 0, false], 'totalmente devolvido')
  a = deriveExpenseActions(D({ entries: [pay({ voided_at: '2026-10-03T10:00:00Z' })] }))
  assert.deepEqual([a.entries[0].active, a.entries[0].canReverse, a.entries[0].canVoid, a.entries[0].voidBlocked], [false, false, false, null], 'anulado')
  a = deriveExpenseActions(D({ status: 'CANCELLED', cancelled_at: '2026-10-03T10:00:00Z', amount_due: 0, can_cancel: false, entries: [pay({ voided_at: '2026-10-02T10:00:00Z' })] }))
  assert.deepEqual([a.cancelled, a.canEdit, a.canPay, a.canCancel, a.entries[0].canVoid], [true, false, false, false, false], 'cancelada')
  a = deriveExpenseActions(D({ status: 'PAID', amount_due: 0, net_paid: 10000, can_cancel: false, entries: [pay({ amount: 10000 })] }))
  assert.deepEqual([a.canPay, a.canCancel, a.entries[0].canReverse], [false, false, true], 'paga')
  assert.equal(deriveExpenseActions(null), null)
  assert.equal(reversibleOf({ kind: 'REVERSAL', amount: 5 }), 0); assert.equal(reversibleOf(pay({ reversed: 999 })), 3001)
})
await check('P04 diff da edição: só campos alterados; travados pelo banco nunca entram; {} = nada a alterar', () => {
  const det = { description: 'Luz', category_id: CAT, arena_id: ARENA, amount: 10000, due_date: '2026-10-10', notes: null, amount_locked: false, arena_locked: false }
  const same = { description: 'Luz', category_id: CAT, arena_id: ARENA, amount: 10000, due_date: '2026-10-10', notes: null }
  assert.deepEqual(buildExpenseChanges(det, same), {})
  assert.deepEqual(buildExpenseChanges(det, { ...same, amount: 12000, notes: 'x', arena_id: null }), { amount: 12000, notes: 'x', arena_id: null })
  assert.deepEqual(buildExpenseChanges({ ...det, amount_locked: true, arena_locked: true }, { ...same, amount: 1, arena_id: null, description: 'Luz 2' }), { description: 'Luz 2' })
})
await check('P05 validação do rascunho: centavos até R$ 1.000.000,00, erros por campo, texto normalizado', () => {
  const ok = validateExpenseDraft({ description: '  Conta   de luz ', category_id: CAT, arena_id: '', amount: '1.000.000,00', due_date: '2026-10-10', notes: '  ' })
  assert.deepEqual(ok, { ok: true, value: { description: 'Conta de luz', category_id: CAT, arena_id: null, amount: 100000000, due_date: '2026-10-10', notes: null } })
  const bad = validateExpenseDraft({ description: ' ', category_id: '', arena_id: 'x', amount: '1.000.000,01', due_date: '', notes: 'x'.repeat(501) })
  assert.deepEqual(Object.keys(bad.errors).sort(), ['amount', 'arena_id', 'category_id', 'description', 'due_date', 'notes'])
  assert.ok(validateExpenseDraft({ description: 'a'.repeat(201), category_id: CAT, amount: '1', due_date: '2026-10-10' }).errors.description)
  assert.ok(validateExpenseDraft({ description: 'a', category_id: CAT, amount: '0', due_date: '2026-10-10' }).errors.amount)
})
await check('P06 validação de pagamento/devolução: teto visual, data não futura, ISO -03:00, meio do banco', () => {
  const now = Date.parse('2026-10-03T12:00:00-03:00')
  const ok = validateEntryDraft({ amount: '60,00', method: 'PIX', at: '2026-10-03T11:59', notes: '' }, { maxCents: 6000, nowMs: now })
  assert.deepEqual(ok, { ok: true, value: { amount: 6000, method: 'PIX', at: '2026-10-03T11:59:00-03:00', notes: null } })
  const over = validateEntryDraft({ amount: '60,01', method: 'PIX', at: '2026-10-03T11:59' }, { maxCents: 6000, nowMs: now })
  assert.equal(over.errors.amount, 'O valor máximo é R$ 60,00.')
  assert.ok(validateEntryDraft({ amount: '1', method: 'PIX', at: '2026-10-03T12:01' }, { maxCents: 6000, nowMs: now }).errors.at, 'futuro')
  assert.ok(validateEntryDraft({ amount: '1', method: 'BOLETO', at: '2026-10-03T11:00' }, { maxCents: 6000, nowMs: now }).errors.method)
  assert.ok(validateEntryDraft({ amount: '1', method: 'PIX', at: '03/10/2026 11:00' }, { maxCents: 6000, nowMs: now }).errors.at)
  assert.ok(validateEntryDraft({ amount: '1', method: 'PIX', at: '2026-10-03T11:00' }, { maxCents: 0, nowMs: now }).errors.amount, 'nada a pagar')
})
await check('P07 motivo e nome de categoria', () => {
  assert.deepEqual(validateReason('  erro  '), { ok: true, value: 'erro' })
  for (const s of ['', '   ', null, 'x'.repeat(501)]) assert.equal(validateReason(s).ok, false)
  assert.deepEqual(validateCategoryName(' Material  de limpeza '), { ok: true, value: 'Material de limpeza' })
  for (const s of ['', '  ', 'x'.repeat(61)]) assert.equal(validateCategoryName(s).ok, false)
})
await check('P08 opções de categoria: ativas + a atual inativa (nunca outras inativas)', () => {
  const cats = [{ id: 'a', name: 'A', is_active: true }, { id: 'b', name: 'B', is_active: false }, { id: 'c', name: 'C', is_active: false }]
  assert.deepEqual(categoryOptions(cats).map((c) => c.id), ['a']); assert.deepEqual(categoryOptions(cats, 'b').map((c) => c.id), ['a', 'b'])
  assert.deepEqual(categoryOptions(null), [])
})
await check('P09 intenção: mesmo operation_id em todo retry; reset => novo; gerado uma vez por intenção', () => {
  let n = 0
  const it = createOperationIntent(() => `op-${++n}`)
  assert.equal(it.peek(), null)
  const a = it.get(); assert.equal(it.get(), a); assert.equal(it.get(), a); assert.equal(n, 1)
  it.reset(); assert.equal(it.peek(), null)
  const b = it.get(); assert.notEqual(a, b); assert.equal(n, 2)
  const real = createOperationIntent()
  assert.match(real.get(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
})
await check('P10 Caixa: rótulo por origem+tipo; direção/sinal SEMPRE do banco (dado adversarial não é "corrigido")', () => {
  assert.deepEqual(MOVEMENT_LABELS, { 'RESERVATION:PAYMENT': 'Recebimento de reserva', 'RESERVATION:REFUND': 'Estorno de reserva', 'EXPENSE:PAYMENT': 'Pagamento de despesa', 'EXPENSE:REVERSAL': 'Devolução de despesa' })
  const v = (m) => { const x = movementView(m); return [x.label, x.tone, x.value, x.consistent] }
  assert.deepEqual(v({ source: 'RESERVATION', kind: 'PAYMENT', direction: 'IN', signed_amount: 5000 }), ['Recebimento de reserva', 'in', '+R$ 50,00', true])
  assert.deepEqual(v({ source: 'RESERVATION', kind: 'REFUND', direction: 'OUT', signed_amount: -2000 }), ['Estorno de reserva', 'out', '-R$ 20,00', true])
  assert.deepEqual(v({ source: 'EXPENSE', kind: 'PAYMENT', direction: 'OUT', signed_amount: -3000 }), ['Pagamento de despesa', 'out', '-R$ 30,00', true])
  assert.deepEqual(v({ source: 'EXPENSE', kind: 'REVERSAL', direction: 'IN', signed_amount: 1000 }), ['Devolução de despesa', 'in', '+R$ 10,00', true])
  // origem "despesa" com direção IN do banco continua IN (nunca inferido pela origem); incoerência é sinalizada
  assert.deepEqual(v({ source: 'EXPENSE', kind: 'PAYMENT', direction: 'IN', signed_amount: 3000 }).slice(1), ['in', '+R$ 30,00', true])
  assert.equal(movementView({ source: 'EXPENSE', kind: 'PAYMENT', direction: 'IN', signed_amount: -3000 }).consistent, false)
  assert.deepEqual(v({ source: 'X', kind: 'Y', direction: 'SIDE', signed_amount: 'abc' }), ['Movimento', 'neutral', '—', false])
})

// ================================================================== 03B.2B-2A — UI de leitura
const PAGE_SRC = stripJsComments(read('app/dashboard/financeiro/page.js'))
const EXP_TAB = stripJsComments(read('components/reserva/finance/expenses-tab.jsx'))
const DETAIL = stripJsComments(read('components/reserva/finance/expense-detail-sheet.jsx'))
const CASH_TAB = stripJsComments(read('components/reserva/finance/cash-tab.jsx'))
const UI = [['page', PAGE_SRC], ['expenses-tab', EXP_TAB], ['detail', DETAIL], ['cash-tab', CASH_TAB]]
function deferred() { let resolve, reject; const p = new Promise((res, rej) => { resolve = res; reject = rej }); return { p, resolve, reject } }
const tick = () => new Promise((r) => setImmediate(r))
const P10 = resolvePeriod('custom', '2026-10-15', { from: '2026-10-01', to: '2026-10-15' })
const PJUL = resolvePeriod('custom', '2026-10-15', { from: '2026-07-01', to: '2026-07-31' })

// ---------------------------------------------------------------- URL / abas (puro)
await check('N01 tabFromSearch: sem tab / inválida / repetida => overview; as 4 abas válidas', () => {
  assert.deepEqual(FINANCE_TABS, ['overview', 'receivables', 'cash', 'expenses'])
  for (const t of FINANCE_TABS) assert.equal(tabFromSearch(new URLSearchParams({ tab: t })), t)
  for (const q of ['', 'tab=', 'tab=EXPENSES', 'tab=despesas', 'tab=cash&tab=expenses', 'tab=__proto__']) assert.equal(tabFromSearch(new URLSearchParams(q)), 'overview', q)
  assert.equal(tabFromSearch(null), 'overview')
})
await check('N02 financeSearch: query canônica (período + arena + aba; overview omitida)', () => {
  const pm = resolvePeriod('this_month', '2026-10-15')
  assert.equal(financeSearch({ period: pm, arenaId: null, tab: 'overview' }), 'preset=this_month')
  assert.equal(financeSearch({ period: pm, arenaId: ARENA, tab: 'expenses' }), `preset=this_month&arena=${ARENA}&tab=expenses`)
  assert.equal(financeSearch({ period: PJUL, arenaId: null, tab: 'cash' }), 'from=2026-07-01&to=2026-07-31&tab=cash')
  assert.equal(financeSearch({ period: pm, tab: 'lixo' }), 'preset=this_month')
})
await check('N03 trocas preservam as outras chaves; parâmetros inválidos antigos não contaminam a URL', () => {
  const cur = { period: PJUL, arenaId: ARENA, tab: 'expenses' }
  const pm = resolvePeriod('last7', '2026-10-15')
  assert.equal(nextFinanceSearch(cur, { tab: 'cash' }), `from=2026-07-01&to=2026-07-31&arena=${ARENA}&tab=cash`, 'aba preserva período e arena')
  assert.equal(nextFinanceSearch(cur, { period: pm }), `preset=last7&arena=${ARENA}&tab=expenses`, 'período preserva aba e arena')
  assert.equal(nextFinanceSearch(cur, { arenaId: null }), 'from=2026-07-01&to=2026-07-31&tab=expenses', 'arena preserva aba e período')
  assert.equal(nextFinanceSearch(cur, { tab: 'overview' }), `from=2026-07-01&to=2026-07-31&arena=${ARENA}`)
  // URL suja: estado é sempre o validado; nenhuma chave desconhecida é copiada
  const dirty = new URLSearchParams(`preset=hack&from=2026-99-99&arena=xyz&tab=bad&utm=1&status=PAID`)
  const p = periodFromSearch(dirty, '2026-10-15')
  const qs = nextFinanceSearch({ period: p, arenaId: urlArena(dirty.get('arena'), { ready: true, list: [{ id: ARENA }] }), tab: tabFromSearch(dirty) }, { tab: 'cash' })
  assert.equal(qs, 'preset=this_month&tab=cash')
})
await check('N04 urlArena: lista carregada => só arena da organização; antes disso preserva uuid bem formado', () => {
  const list = [{ id: ARENA }]
  assert.equal(urlArena(ARENA, { ready: true, list }), ARENA)
  assert.equal(urlArena(EXP, { ready: true, list }), null, 'arena de outra organização')
  assert.equal(urlArena(EXP, { ready: false, list: [] }), EXP, 'troca precoce não perde a arena')
  for (const v of ['x', null, undefined, '']) assert.equal(urlArena(v, { ready: false, list: [] }), null)
})
await check('N05 ida e volta: reload em ?tab=expenses reabre Despesas com o mesmo período e arena', () => {
  for (const [period, arenaId, tab] of [[P10, ARENA, 'expenses'], [resolvePeriod('today', '2026-10-15'), null, 'cash'], [PJUL, null, 'receivables'], [resolvePeriod('last_month', '2026-10-15'), ARENA, 'overview']]) {
    const sp2 = new URLSearchParams(financeSearch({ period, arenaId, tab }))
    assert.deepEqual(periodFromSearch(sp2, '2026-10-15'), period); assert.equal(tabFromSearch(sp2), tab); assert.equal(sp2.get('arena'), arenaId)
  }
})

// ---------------------------------------------------------------- página: fonte única, lazy, permissão
await check('L01 aba vem só da URL (sem useState de aba); troca de aba entra no histórico; voltar/avançar troca a aba', () => {
  assert.ok(PAGE_SRC.includes('const tab = tabFromSearch(searchParams)'))
  assert.ok(!/useState\('overview'\)|setTab\(/.test(PAGE_SRC), 'sem segunda fonte de verdade')
  assert.ok(PAGE_SRC.includes("const changeTab = (t) => { if (!FINANCE_TABS.includes(t) || t === tab) return; invalidateFinance(); navigate({ tab: t }, { push: true }) }"))
  assert.ok(PAGE_SRC.includes('if (push) router.push(url, { scroll: false })') && PAGE_SRC.includes('else router.replace(url, { scroll: false })'))
  assert.ok(!PAGE_SRC.includes('replaceQuery('), 'troca de período/arena não substitui mais a query inteira')
})
await check('L02 só a aba ativa monta e busca; invalidação síncrona cobre as 11 sequências financeiras', () => {
  assert.ok(PAGE_SRC.includes("{tab === 'cash' && <CashTab api={api}") && PAGE_SRC.includes("{tab === 'expenses' && <ExpensesTab api={api}"))
  for (const k of ['cashResult', 'cashMoves', 'cashMovesMore', 'expCats', 'expOverview', 'expList', 'expListMore', 'expDetail']) {
    assert.ok(PAGE_SRC.includes(`${k}: createRequestSequence()`), k)
  }
  assert.ok(PAGE_SRC.includes("const FINANCE_SEQS = ['overview', 'rec', 'recMore', 'cashResult', 'cashMoves', 'cashMovesMore', 'expCats', 'expOverview', 'expList', 'expListMore', 'expDetail']"))
  // desmontar a aba invalida o que ela tinha em andamento (inclusive via voltar/avançar)
  assert.ok(CASH_TAB.includes('return () => { seqs.result.invalidate(); seqs.moves.invalidate(); seqs.more.invalidate() }'))
  assert.ok(EXP_TAB.includes('return () => { seqs.list.invalidate(); seqs.more.invalidate() }') && EXP_TAB.includes('return () => seqs.overview.invalidate()') && EXP_TAB.includes('return () => seqs.cats.invalidate()'))
  assert.ok(DETAIL.includes('return () => seq.invalidate()'))
})
await check('L03 RECEPTIONIST: nada da 03B.2 é criado/montado antes do guard canViewFinance (zero chamadas)', async () => {
  const m = /export default function FinanceiroPage\(\) \{([\s\S]*?)\n\}/.exec(PAGE_SRC)
  const body = m[1]
  assert.ok(body.indexOf('if (!canViewFinance(me?.role)) return <FinanceAccessDenied />') < body.indexOf('<FinanceView'))
  assert.ok(!/createExpensesApi|ExpensesTab|CashTab/.test(body), 'nada da 03B.2 no componente de entrada')
  const iView = PAGE_SRC.indexOf('function FinanceView(')
  assert.ok(PAGE_SRC.indexOf('const api = useMemo(() => createExpensesApi(), [])') > iView, 'client só existe dentro da vista autorizada')
  // modelo do portão: mesma decisão do componente
  for (const role of [ROLES.RECEPTIONIST, ROLES.PLATFORM_SUPER_ADMIN, undefined]) {
    const calls = []
    const api = createExpensesApi(async (u) => { calls.push(u); return resp(200, {}) })
    if (canViewFinance(role)) { await api.categories(ORG, true); await api.cashResult({ orgId: ORG, arenaId: null, period: P10 }, 'day') }
    assert.equal(calls.length, 0, String(role))
  }
  for (const role of [ROLES.OWNER, ROLES.MANAGER]) assert.equal(canViewFinance(role), true)
})
// B-2B: a escrita passou a existir, mas SÓ nos diálogos (expense-forms / expense-categories-dialog,
// cobertos em tests/phase3b2b_mutations.test.mjs). Página, Caixa, aba e detalhe não chamam escrita direto.
await check('L04 escrita só pelos diálogos da B-2B: página/Caixa sem escrita; aba/detalhe sem chamada direta de mutação', () => {
  const WRITES = ['createExpense', 'updateExpense', 'cancelExpense', 'registerPayment', 'reversePayment', 'voidPayment', 'createCategory', 'updateCategory']
  for (const [f, code] of UI) {
    for (const w of WRITES) assert.ok(!new RegExp(`api\\.${w}\\(`).test(code), `${f}: api.${w}( direto`)
    for (const bad of ['sendExpense', "method: 'POST'", "method: 'PATCH'", 'newOperationId']) assert.ok(!code.includes(bad), `${f}: ${bad}`)
  }
  for (const [f, code] of [['page', PAGE_SRC], ['cash-tab', CASH_TAB]]) {
    for (const w of [...WRITES, 'ExpenseFormDialog', 'EntryDialog', 'ReasonDialog', 'ExpenseCategoriesDialog']) assert.ok(!new RegExp(`\\b${w}\\b`).test(code), `${f}: ${w}`)
  }
  assert.ok(fs.existsSync(new URL('../components/reserva/finance/expense-forms.jsx', import.meta.url)) && fs.existsSync(new URL('../components/reserva/finance/expense-categories-dialog.jsx', import.meta.url)))
})
await check('L05 toda chamada à API nos componentes passa por runLatest com sequência da página', () => {
  for (const [f, code, n] of [['expenses-tab', EXP_TAB, 4], ['detail', DETAIL, 1], ['cash-tab', CASH_TAB, 3]]) {
    const total = (code.match(/api\.\w+\(/g) || []).length
    const wrapped = (code.match(/runLatest\(seqs?\.?\w*, \(\) => api\.\w+\(/g) || []).length
    assert.equal(total, n, `${f}: chamadas`); assert.equal(wrapped, total, `${f}: todas via runLatest`)
  }
  assert.ok(!/fetch\(/.test(EXP_TAB + DETAIL + CASH_TAB), 'nenhum fetch direto')
  assert.ok(/status === 403\) onForbidden\(\)/.test(EXP_TAB) && /status === 403\) onForbidden\(\)/.test(DETAIL) && /status === 403\) onForbidden\(\)/.test(CASH_TAB), '403 de leitura => acesso negado')
})

// ---------------------------------------------------------------- Despesas: conteúdo
await check('D01 cards: Despesas previstas / Pago / A pagar / Vencidas; Situação atual só nos dois últimos; comparação neutra', () => {
  for (const label of ['Despesas previstas', 'Pago', 'A pagar', 'Vencidas']) assert.ok(EXP_TAB.includes(`<ExpenseMetric label="${label}"`), label)
  const card = (label) => { const i = EXP_TAB.indexOf(`<ExpenseMetric label="${label}"`); return EXP_TAB.slice(i, EXP_TAB.indexOf('/>', i)) }
  assert.ok(card('Despesas previstas').includes('cmpLabel={cmpLabel}') && !card('Despesas previstas').includes('situation'))
  for (const l of ['A pagar', 'Vencidas']) { assert.ok(card(l).includes('situation'), l); assert.ok(!card(l).includes('cmpLabel'), l) }
  assert.ok(card('Despesas previstas').includes('d.expected?.current') && card('Pago').includes('d.paid_of_period?.current') && card('A pagar').includes('d.payable?.total') && card('Vencidas').includes('d.overdue?.total'))
  const metric = /function ExpenseMetric\([^)]*\) \{([\s\S]*?)\n\}/.exec(EXP_TAB)[1]
  const cmp = metric.slice(metric.indexOf('{hasCompare && ('))
  assert.ok(!/text-primary|text-red|text-emerald|text-green/.test(cmp), 'comparação de despesa sem cor de bom/ruim')
})
await check('D02 semântica explícita: vencimento no período x data real dos pagamentos (Caixa)', () => {
  assert.ok(EXP_TAB.includes('Os valores desta área consideram despesas com vencimento no período. As Saídas do Caixa consideram a data real dos pagamentos.'))
  assert.ok(CASH_TAB.includes('Movimentos pela data real do recebimento ou do pagamento.'))
})
await check('D03 filtros: 5 status (padrão Ativas) com aria-pressed; categoria com inativas marcadas; troca invalida e zera paginação', () => {
  assert.ok(EXP_TAB.includes('useState(DEFAULT_EXPENSE_FILTER)') && EXP_TAB.includes('{EXPENSE_STATUS_FILTERS.map((s) => (') && EXP_TAB.includes('aria-pressed={status === s}'))
  assert.ok(EXP_TAB.includes('api.categories(scope.orgId, true)') && EXP_TAB.includes("c.is_active ? c.name : `${c.name} (inativa)`"))
  assert.ok(EXP_TAB.includes('seqs.overview.invalidate(); seqs.list.invalidate(); seqs.more.invalidate()') && EXP_TAB.includes('seqs.list.invalidate(); seqs.more.invalidate()\n    setStatus(s)'))
  assert.ok(EXP_TAB.includes('seqs.more.invalidate()\n    setMore({ loading: false, error: false })\n    runLatest(seqs.list, () => api.list('), 'carga principal invalida o "mais" antes')
  assert.ok(EXP_TAB.includes('}, [baseKey, categoryId, status, reload])') && EXP_TAB.includes('}, [baseKey, compareKey, categoryId, reload])'))
})
await check('D04 excludes_general: mesma mensagem nas Despesas e no Caixa, só quando o banco sinaliza', () => {
  assert.ok(EXP_TAB.includes("export const GENERAL_EXCLUDED_MSG = 'Despesas gerais da organização não estão incluídas neste filtro.'"))
  assert.ok(EXP_TAB.includes('const excludesGeneral = ov.data?.excludes_general === true || list.excludesGeneral') && EXP_TAB.includes('{excludesGeneral && <GeneralExcludedNotice />}'))
  assert.ok(CASH_TAB.includes('{res.data?.excludes_general === true && <GeneralExcludedNotice />}'))
})
await check('D05 lista: campos do contrato, badges do banco (Vencida é flag), linha é <button>, desktop grade / mobile card', () => {
  for (const f of ['it.description', 'it.category_name', "it.arena_id ? it.arena_name : 'Geral'", 'fmtDueDate(it.due_date)', 'formatCents(it.amount)', 'formatCents(it.net_paid)', 'formatCents(it.amount_due)', '<ExpenseBadges row={it}'])
    assert.ok(EXP_TAB.includes(f), f)
  assert.ok(DETAIL.includes('expenseBadges(row).map((b) =>'), 'badges só via expenseBadges (status + flag overdue)')
  assert.ok(!/'OVERDUE'.*label|status === 'OVERDUE'/.test(EXP_TAB + DETAIL), 'OVERDUE nunca vira status')
  assert.ok(EXP_TAB.includes('<button type="button" onClick={(e) => onOpen(it.expense_id, e.currentTarget)}'))
  assert.ok(EXP_TAB.includes('md:grid md:grid-cols-[') && EXP_TAB.includes('flex min-h-11 w-full flex-col'), 'grade no desktop, card no mobile')
  for (const [f, code] of UI) assert.ok(!/<div[^>]*onClick/.test(code), `${f}: div clicável`)
})
await check('D06 vazio / carregando / erro: skeleton com role=status, vazio por status, erro com retry; atualizando sinalizado', () => {
  assert.ok(EXP_TAB.includes('role="status" aria-label="Carregando despesas"') && EXP_TAB.includes('role="status" aria-label="Carregando resumo"'))
  assert.ok(EXP_TAB.includes('title="Nenhuma despesa neste filtro" description={EMPTY_BY_STATUS[status] || EMPTY_BY_STATUS.ACTIVE}'))
  assert.ok(EXP_TAB.includes('Tentar novamente') && CASH_TAB.includes('Tentar novamente') && DETAIL.includes('Tentar novamente'))
  assert.ok(EXP_TAB.includes('role="status" aria-live="polite"') && EXP_TAB.includes('aria-busy={list.refreshing}'))
})

// ---------------------------------------------------------------- Detalhe
await check('S01 Sheet: Title + Description, largura total no mobile, rolagem, foco devolvido ao item, sem ação de escrita', () => {
  assert.ok(DETAIL.includes('<SheetTitle>') && DETAIL.includes('<SheetDescription>Dados, situação e histórico de lançamentos da despesa selecionada.</SheetDescription>'))
  assert.ok(DETAIL.includes('className="w-full overflow-y-auto sm:max-w-lg motion-reduce:animate-none motion-reduce:transition-none"'))
  assert.ok(DETAIL.includes('onCloseAutoFocus={(e) => { const el = returnFocusTo?.current; if (el && el.isConnected) { e.preventDefault(); el.focus() } }}'))
  for (const f of ['d.category_name', "d.arena_id ? d.arena_name : 'Geral'", 'formatCents(d.amount)', 'fmtDueDate(d.due_date)', 'd.notes', 'formatCents(d.paid_gross)', 'formatCents(d.reversed)', 'formatCents(d.net_paid)', 'formatCents(d.amount_due)'])
    assert.ok(DETAIL.includes(f), f)
  for (const f of ["reversal ? 'Devolução' : 'Pagamento'", 'PAYMENT_METHOD_LABELS[e.method]', 'fmtDateTimeLong(e.paid_at)', 'e.void_reason', 'byId[e.reversal_of]', 'Devolução do pagamento']) assert.ok(DETAIL.includes(f), f)
  // B-2B: ações só pelo estado real devolvido pelo banco (deriveExpenseActions)
  assert.ok(DETAIL.includes('const a = d ? deriveExpenseActions(d) : null'))
  for (const g of ['{a.canPay && <Button', '{a.canEdit && <Button', '{a.canCancel && <Button', '{e.canReverse && <Button']) assert.ok(DETAIL.includes(g), g)
})

// ---------------------------------------------------------------- Caixa
await check('C10 Caixa: 3 cards (in_net / out_net / result), resultado negativo em atenção, sem Saldo/Lucro', () => {
  const card = (label) => { const i = CASH_TAB.indexOf(`<CashCard label="${label}"`); return CASH_TAB.slice(i, CASH_TAB.indexOf('/>', i)) }
  assert.ok(card('Entradas').includes('formatCents(t?.in_net)') && card('Saídas').includes('formatCents(t?.out_net)') && card('Resultado de caixa').includes('formatCents(t?.result)'))
  assert.ok(card('Resultado de caixa').includes("tone={result !== null && result < 0 ? 'warn' : undefined}"))
  assert.ok(CASH_TAB.includes('Entradas − Saídas registradas no período'))
})
await check('C11 gráfico: escala única (|entradas|, |saídas|, |resultado|), zeros => vazio, barras não negativas, sem biblioteca', () => {
  const chart = /function CashChart\([^)]*\) \{([\s\S]*?)\n\}/.exec(CASH_TAB)[1]
  assert.ok(chart.includes('Math.abs(v(b.in_net)), Math.abs(v(b.out_net)), Math.abs(v(b.result))'))
  assert.ok(chart.includes("if (max === 0) return") && chart.includes('Nenhum movimento registrado no período.'))
  assert.ok(chart.includes('const pct = (x) => (x > 0 ? Math.max(1, Math.floor((x * 100) / max)) : 0)'), 'valor <= 0 não desenha barra; escala inteira')
  assert.ok(chart.includes("r > 0 ? 'bg-foreground' : 'bg-amber-400'") && chart.includes('role="img"'))
  assert.ok(!/recharts|chart\.js|from 'd3|@\/components\/ui\/chart/.test(CASH_TAB))
  // a mesma escala aplicada a cenários extremos (espelho da fórmula do componente)
  const scale = (buckets) => { const max = buckets.reduce((m, b) => Math.max(m, Math.abs(b.in_net), Math.abs(b.out_net), Math.abs(b.result)), 0); return (x) => (max === 0 ? 0 : x > 0 ? Math.max(1, Math.floor((x * 100) / max)) : 0) }
  let s = scale([{ in_net: 0, out_net: 0, result: 0 }]); assert.equal(s(0), 0)
  s = scale([{ in_net: 5000, out_net: 0, result: 5000 }]); assert.equal(s(5000), 100)
  s = scale([{ in_net: 0, out_net: 7000, result: -7000 }]); assert.equal(s(7000), 100); assert.equal(s(-7000), 0)
  s = scale([{ in_net: 100000000, out_net: 1, result: 99999999 }]); assert.equal(s(1), 1, 'valor mínimo visível'); assert.equal(s(100000000), 100)
})
await check('C12 movimentos: movementView do banco, contraparte (reserva ou despesa), método, chave composta, "mais" invalidado', () => {
  assert.ok(CASH_TAB.includes("const who = m.source === 'EXPENSE'"), 'só escolhe a CONTRAPARTE exibida pela origem')
  assert.ok(CASH_TAB.includes('key={`${m.source_kind}:${m.id}`}') && CASH_TAB.includes('PAYMENT_METHOD_LABELS[m.method]') && CASH_TAB.includes('fmtDateTimeLong(m.occurred_at)'))
  assert.ok(!/m\.source === '(RESERVATION|EXPENSE)' \? '(\+|-|in|out)/.test(CASH_TAB) && !/direction/.test(CASH_TAB.replace(/movementView/g, '')), 'sinal/direção nunca derivados da origem no componente')
  const eff = CASH_TAB.slice(CASH_TAB.indexOf('useEffect(() => {'))
  assert.ok(eff.indexOf('seqs.more.invalidate()') < eff.indexOf('runLatest(seqs.result'))
})

// ---------------------------------------------------------------- mobile / acessibilidade
await check('A01 mobile 390×844: abas roláveis com 44 px; chips/select/botões novos h-11 sm:h-9|8; dinheiro sem quebra', () => {
  assert.ok(PAGE_SRC.includes('<div className="-mx-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">') && PAGE_SRC.includes('<TabsList className="inline-flex h-auto w-max">'))
  assert.ok(PAGE_SRC.includes('className="h-11 px-4 motion-reduce:transition-none sm:h-7 sm:px-3"'))
  assert.ok(EXP_TAB.includes('className="h-11 shrink-0 px-4 sm:h-8 sm:px-3"') && EXP_TAB.includes('className="h-11 w-full sm:h-9 sm:w-64"'))
  for (const [f, code] of [['expenses-tab', EXP_TAB], ['cash-tab', CASH_TAB], ['detail', DETAIL]]) {
    for (const b of code.match(/<Button[^>]*>/g) || []) assert.ok(/h-11/.test(b) || /aria-pressed/.test(b), `${f}: botão sem alvo de 44 px: ${b}`)
  }
  for (const code of [EXP_TAB, CASH_TAB, DETAIL]) {
    for (const m of code.matchAll(/<(span|p)[^>]*>\{formatCents\(/g)) assert.ok(/whitespace-nowrap/.test(m[0]), `valor monetário pode quebrar: ${m[0]}`)
  }
  assert.ok(!/<table|overflow-x-scroll/.test(EXP_TAB + CASH_TAB + DETAIL), 'sem tabela horizontal')
})
await check('A02 acessibilidade: spinners/transições com reduced motion; carregamentos com role=status; erros com role=alert', () => {
  for (const [f, code] of [['expenses-tab', EXP_TAB], ['cash-tab', CASH_TAB]]) {
    for (const m of code.matchAll(/animate-spin[^"]*/g)) assert.ok(m[0].includes('motion-reduce:animate-none'), `${f}: ${m[0]}`)
    assert.ok(code.includes('role="alert"'), `${f}: erro do "carregar mais" anunciado`)
  }
  assert.ok(CASH_TAB.includes('role="status" aria-label="Carregando caixa"') && DETAIL.includes('role="status" aria-label="Carregando despesa"'))
})
await check('A03 termos proibidos nas telas novas: faturamento / saldo / lucro', () => {
  for (const [f, code] of UI) for (const bad of ['faturamento', 'saldo', 'lucro']) assert.ok(!code.toLowerCase().includes(bad), `${f}: ${bad}`)
})

// ---------------------------------------------------------------- corridas (modelos com runLatest + client reais)
// Mesma ligação dos componentes: sequências da página, invalidação síncrona na troca de filtro, carga
// principal invalida o "mais"; fetch controlado por URL (deferred) para forçar ordens adversariais.
function controlledFetch() {
  const pending = []
  const fn = (url) => { const d = deferred(); pending.push({ url, d }); return d.p }
  const answer = (pred, body) => { const i = pending.findIndex((x) => pred(x.url)); const [x] = pending.splice(i, 1); x.d.resolve(resp(200, body)) }
  return { fn, pending, answer }
}
function expensesModel(fetchImpl) {
  const api = createExpensesApi(fetchImpl)
  const seqs = { list: createRequestSequence(), more: createRequestSequence() }
  const st = { categoryId: null, status: 'ACTIVE', list: { loading: true, refreshing: false, items: [], cursor: null }, more: { loading: false } }
  const scope = { orgId: ORG, arenaId: null, period: P10 }
  const loadMain = () => {
    seqs.more.invalidate(); st.more = { loading: false }
    return runLatest(seqs.list, () => api.list(scope, { categoryId: st.categoryId, status: st.status, limit: 50 }), {
      onStart: () => { st.list = { ...st.list, loading: st.list.items.length === 0, refreshing: st.list.items.length > 0, cursor: null } },
      onResult: (d) => { st.list = { loading: false, refreshing: false, items: d.items, cursor: d.next_cursor || null } },
    })
  }
  const loadMore = () => runLatest(seqs.more, () => api.list(scope, { categoryId: st.categoryId, status: st.status, limit: 50, cursor: st.list.cursor }), {
    onStart: () => { st.more = { loading: true } },
    onResult: (d) => { st.list = { ...st.list, items: [...st.list.items, ...d.items], cursor: d.next_cursor || null } },
    onSettled: () => { st.more = { loading: false } },
  })
  const changeStatus = (s) => { seqs.list.invalidate(); seqs.more.invalidate(); st.status = s; return loadMain() }
  const changeCategory = (c) => { seqs.list.invalidate(); seqs.more.invalidate(); st.categoryId = c; return loadMain() }
  return { st, loadMain, loadMore, changeStatus, changeCategory }
}
const ids = (s) => s.list.items.map((x) => x.expense_id)

await check('K10 filtro trocado com carga pendente: resposta antiga nunca sobrescreve o filtro novo', async () => {
  const f = controlledFetch(); const m = expensesModel(f.fn)
  const p1 = m.loadMain(); await tick()
  const p2 = m.changeStatus('PAID'); await tick()
  f.answer((u) => u.includes('status=PAID'), { items: [{ expense_id: 'paid-1' }], next_cursor: null }); await p2
  f.answer((u) => u.includes('status=ACTIVE'), { items: [{ expense_id: 'active-OLD' }], next_cursor: { due_date: '2026-10-02', id: EXP } }); await p1
  assert.deepEqual(ids(m.st), ['paid-1']); assert.equal(m.st.list.cursor, null)
})
await check('K11 período/categoria trocados fora de ordem: só a última intenção aplica', async () => {
  const f = controlledFetch(); const m = expensesModel(f.fn)
  const a = m.changeCategory(CAT); await tick()
  const b = m.changeCategory(null); await tick()
  const c = m.changeCategory('9a3c7e10-2b4d-4f6a-8c9e-1d2f3a4b5c6d'); await tick()
  f.answer((u) => u.includes('category_id=9a3c'), { items: [{ expense_id: 'C' }] }); await c
  f.answer((u) => u.includes(`category_id=${CAT}`), { items: [{ expense_id: 'A' }] }); await a
  f.answer(() => true, { items: [{ expense_id: 'B' }] }); await b
  assert.deepEqual(ids(m.st), ['C'])
})
await check('K12 "carregar mais" pendente é descartado por nova carga principal; refresh mantém conteúdo marcado', async () => {
  const f = controlledFetch(); const m = expensesModel(f.fn)
  const p0 = m.loadMain(); await tick()
  f.answer(() => true, { items: [{ expense_id: 'e1' }], next_cursor: { due_date: '2026-10-05', id: EXP } }); await p0
  const pm = m.loadMore(); await tick()
  assert.ok(f.pending[0].url.includes(`after_due=2026-10-05&after_id=${EXP}`), 'cursor (due_date, id) da RPC')
  const pr = m.changeStatus('OPEN'); await tick()
  assert.equal(m.st.list.refreshing, true); assert.deepEqual(ids(m.st), ['e1'], 'conteúdo anterior visível enquanto atualiza')
  assert.equal(m.st.list.cursor, null, 'paginação zerada')
  f.answer((u) => u.includes('after_due'), { items: [{ expense_id: 'MORE-OLD' }], next_cursor: null }); await pm
  assert.ok(!ids(m.st).includes('MORE-OLD'), 'mais antigo descartado')
  f.answer(() => true, { items: [{ expense_id: 'o1' }], next_cursor: null }); await pr
  assert.deepEqual(ids(m.st), ['o1']); assert.equal(m.st.list.refreshing, false)
})
await check('K13 detalhe: abre A, abre B, B responde, A responde depois => fica B; fechar invalida a pendente', async () => {
  const f = controlledFetch(); const api = createExpensesApi(f.fn)
  const seq = createRequestSequence()
  const st = { data: null, loading: false }
  const open = (id) => runLatest(seq, () => api.detail(id), { onStart: () => { st.loading = true; st.data = null }, onResult: (d) => { st.loading = false; st.data = d } })
  const A = 'aaaaaaaa-1d3b-4c55-9a77-0b8e2d4c6f10', B = 'bbbbbbbb-1d3b-4c55-9a77-0b8e2d4c6f10'
  const pa = open(A); await tick()
  seq.invalidate() // cleanup do efeito ao trocar expenseId
  const pb = open(B); await tick()
  f.answer((u) => u.endsWith(B), { expense_id: B }); await pb
  f.answer((u) => u.endsWith(A), { expense_id: A }); await pa
  assert.equal(st.data.expense_id, B)
  // fechar o Sheet com C pendente: nada é aplicado depois
  const C = 'cccccccc-1d3b-4c55-9a77-0b8e2d4c6f10'
  const pc = open(C); await tick()
  seq.invalidate() // closeDetail + cleanup do componente
  f.answer((u) => u.endsWith(C), { expense_id: C }); await pc
  assert.equal(st.data, null, 'resposta depois de fechar não altera estado')
  assert.ok(EXP_TAB.includes('const closeDetail = () => { seqs.detail.invalidate(); setOpenId(null) }'))
})
await check('K14 Caixa: cursor composto (occurred_at, source_kind, id) e "mais" descartado por nova carga', async () => {
  const f = controlledFetch(); const api = createExpensesApi(f.fn)
  const seqs = { moves: createRequestSequence(), more: createRequestSequence() }
  const st = { items: [], cursor: null }
  const scope = { orgId: ORG, arenaId: null, period: P10 }
  const loadMain = () => { seqs.more.invalidate(); return runLatest(seqs.moves, () => api.cashMovements(scope, { limit: 50 }), { onStart: () => { st.items = []; st.cursor = null }, onResult: (d) => { st.items = d.items; st.cursor = d.next_cursor } }) }
  const loadMore = () => runLatest(seqs.more, () => api.cashMovements(scope, { limit: 50, cursor: st.cursor }), { onResult: (d) => { st.items = [...st.items, ...d.items]; st.cursor = d.next_cursor } })
  const p0 = loadMain(); await tick()
  f.answer(() => true, { items: [{ id: 'm1' }], next_cursor: { occurred_at: '2026-10-03T15:00:00+00:00', source_kind: 2, id: PAY } }); await p0
  const pm = loadMore(); await tick()
  assert.ok(f.pending[0].url.includes(`after_at=2026-10-03T15%3A00%3A00%2B00%3A00&after_source=2&after_id=${PAY}`))
  const p1 = loadMain(); await tick()
  f.answer((u) => u.includes('after_at'), { items: [{ id: 'OLD-MORE' }], next_cursor: null }); await pm
  f.answer(() => true, { items: [{ id: 'n1' }], next_cursor: null }); await p1
  assert.deepEqual(st.items.map((x) => x.id), ['n1'])
})

// ---------------------------------------------------------------- 03B.2B-2A.1 — comparação do resumo
// Identidade de carga = valores das dependências REAIS do efeito (lidas do componente), com baseKey pela
// fórmula da página e compareKey pela expressão do próprio componente (avaliada, não comparada como texto).
await check('K15 mesmo from/to + comparação diferente => nova identidade de carga do resumo; base e lista inalteradas', async () => {
  const pA = resolvePeriod('this_month', '2026-10-15')
  const pB = resolvePeriod('custom', '2026-10-15', { from: '2026-10-01', to: '2026-10-15' })
  assert.deepEqual([pA.from, pA.to], [pB.from, pB.to], 'mesmo período principal')
  assert.notDeepEqual([pA.compare.from, pA.compare.to], [pB.compare.from, pB.compare.to], 'comparação diferente')
  assert.ok(PAGE_SRC.includes("const baseKey = base ? `${base.organization_id}|${base.arena_id || ''}|${base.from}|${base.to}` : ''"), 'fórmula da baseKey da página')
  const baseKeyOf = (p) => { const b = periodParams(ORG, null, p); return `${b.organization_id}|${b.arena_id || ''}|${b.from}|${b.to}` }
  const m = /const compareKey = (`[^`\n]*`)/.exec(EXP_TAB)
  assert.ok(m, 'compareKey derivada no componente')
  const compareKeyOf = new Function('scope', `return ${m[1]}`)
  const depsOf = (anchor) => {
    const i = EXP_TAB.indexOf(anchor); assert.ok(i > 0, anchor)
    const j = EXP_TAB.indexOf('}, [', i)
    return EXP_TAB.slice(j + 4, EXP_TAB.indexOf('])', j)).split(',').map((s) => s.trim())
  }
  const ovDeps = depsOf('runLatest(seqs.overview'), listDeps = depsOf('runLatest(seqs.list')
  assert.ok(!ovDeps.includes('scope'), 'sem o objeto scope inteiro como dependência (recarga por identidade)')
  const identity = (deps, p) => {
    const v = { baseKey: baseKeyOf(p), compareKey: compareKeyOf({ orgId: ORG, arenaId: null, period: p }), categoryId: null, status: 'ACTIVE', reload: 0 }
    return deps.map((d) => { assert.ok(Object.prototype.hasOwnProperty.call(v, d), `dependência desconhecida: ${d}`); return v[d] }).join('§')
  }
  assert.equal(baseKeyOf(pA), baseKeyOf(pB), 'chave principal (base) igual')
  assert.notEqual(identity(ovDeps, pA), identity(ovDeps, pB), 'resumo de despesas recarrega quando só a comparação muda')
  assert.equal(identity(listDeps, pA), identity(listDeps, pB), 'lista não recarrega (rg_expenses só usa o período principal)')
  assert.equal(identity(ovDeps, pA), identity(ovDeps, resolvePeriod('this_month', '2026-10-15')), 'mesma intenção => mesma identidade (sem recarga à toa)')
  // cada limite da comparação conta sozinho: só compare.to muda / só compare.from muda (mesmo from/to)
  const onlyTo = { ...pA, compare: { ...pA.compare, to: '2026-09-14' } }
  const onlyFrom = { ...pA, compare: { ...pA.compare, from: '2026-09-02' } }
  for (const [name, p] of [['só compare.to', onlyTo], ['só compare.from', onlyFrom]]) {
    assert.equal(baseKeyOf(p), baseKeyOf(pA), `${name}: base igual`)
    assert.notEqual(identity(ovDeps, p), identity(ovDeps, pA), `${name}: resumo recarrega`)
    assert.equal(identity(listDeps, p), identity(listDeps, pA), `${name}: lista não recarrega`)
  }
  // a carga do resumo de fato envia a comparação de cada período (client real)
  const urls = []
  const api = createExpensesApi(async (u) => { urls.push(u); return resp(200, {}) })
  await api.overview({ orgId: ORG, arenaId: null, period: pA }); await api.overview({ orgId: ORG, arenaId: null, period: pB })
  assert.ok(urls[0].includes(`compare_from=${pA.compare.from}&compare_to=${pA.compare.to}`) && urls[1].includes(`compare_from=${pB.compare.from}&compare_to=${pB.compare.to}`))
  assert.notEqual(urls[0], urls[1])
})

// ------------------------------------------------------------------ resultado
const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3B2B_JS_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
