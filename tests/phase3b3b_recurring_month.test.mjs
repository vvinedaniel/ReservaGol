// Reserva Gol — FASE 03B.3B — Mensalistas: aplicação e UI (puro/estático, sem rede e sem banco).
// Uso: node tests/phase3b3b_recurring_month.test.mjs
// Cobre: helpers puros (mês, rótulos, status, formulário, prévia visual), API REAL (runRecurringMonthRoute com
// RPC falsa: allowlist, expected_open obrigatório, mapeamento de erro sem vazar o banco, 201/200), client,
// fluxo de mutação (STATE_CHANGED => intent novo; rede => mesmo intent; duplo clique => 1 chamada), gates de
// papel e UI (RECEPTIONIST sem agregados, W1/W2/estorno só gestor, 44 px, a11y), GETs recorrentes puros,
// Agenda preservada e migration 03B.3A intacta.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import crypto from 'node:crypto'
import {
  isMonthParam, monthToDate, dateToMonth, monthOf, shiftMonth, prevMonth, nextMonth, monthLabel, monthName, slotLabel, dayMonth,
  MONTH_STATUSES, MONTH_STATUS_META, MONTH_FILTERS, MONTH_REASON_MSG, validateMonthPaymentDraft, previewMonthSplit, unpricedSeries,
  monthErrorMessage, monthErrorReason, keepsIntent, validateNewCustomer, validateSeriesPrice, RM_PREFIX, capitalizeFirst,
} from '../lib/reserva/recurring-month.js'
import {
  runRecurringMonthRoute, recurringMonthPathSegments, mapRecurringMonthError, resolveRecurringMonthRoute, RM_ERRORS,
} from '../lib/reserva/recurring-month-api.js'
import { createRecurringMonthApi, recurringMonthUrl, RecurringMonthRequestError, RecurringMonthNetworkError } from '../lib/reserva/recurring-month-client.js'
import { createSubmitGuard, submitWithBusy } from '../lib/reserva/expense-mutation.js'
import { createOperationIntent } from '../lib/reserva/expenses.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripJs = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const VIEW = stripJs(read('components/reserva/mensalistas/month-view.jsx'))
const LIST = stripJs(read('components/reserva/mensalistas/month-list.jsx'))
const SEARCH = stripJs(read('components/reserva/mensalistas/month-search.jsx'))
const DETAIL = stripJs(read('components/reserva/mensalistas/month-detail-sheet.jsx'))
const RECEIVE = stripJs(read('components/reserva/mensalistas/receive-month-dialog.jsx'))
const LINK = stripJs(read('components/reserva/mensalistas/link-customer-dialog.jsx'))
const PRICE = stripJs(read('components/reserva/mensalistas/apply-series-price-dialog.jsx'))
const UI = stripJs(read('components/reserva/mensalistas/month-ui.jsx'))
const PAGE = stripJs(read('app/dashboard/mensalistas/page.js'))
const ROUTE = read('app/api/[[...path]]/route.js')
const COMPONENTS = [['view', VIEW], ['list', LIST], ['search', SEARCH], ['detail', DETAIL], ['receive', RECEIVE], ['link', LINK], ['price', PRICE], ['ui', UI]]

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
const ORG = '1b728e0e-cc5f-4d3f-9e10-2864238754fc'
const LIN = '3c1d2e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f'
const ARENA = '0df00495-9f3f-4b8b-b14c-1392f6b99b83'
const CUST = '9a3c7e10-2b4d-4f6a-8c9e-1d2f3a4b5c6d'
const OP = '7e2d3b9f-2e4c-4d66-8b88-1c9f3e5d7a21'
const user = { id: 'u' }

// Rota REAL com RPC falsa; registra chamadas.
async function route(method, path, { query = '', body = null, rpc = () => ({ data: { ok: true }, error: null }), u = user } = {}) {
  const calls = []
  const url = new URL(`http://x${path}${query ? `?${query}` : ''}`)
  const logs = []
  const out = await runRecurringMonthRoute({
    method, segments: recurringMonthPathSegments(url.pathname), searchParams: url.searchParams,
    rawBody: body === null ? null : (typeof body === 'string' ? body : JSON.stringify(body)), user: u,
    callRpc: async (name, args) => { calls.push([name, args]); return rpc(name, args) }, log: (...a) => logs.push(a),
  })
  return { ...out, calls, logs }
}
const payBody = (over = {}) => ({ operation_id: OP, month: '2026-10', amount: 25000, method: 'PIX', received_at: '2026-10-05T10:00:00-03:00', notes: null, expected_open: 40000, ...over })

// ------------------------------------------------------------------ helpers puros
await check('H01 mês: formato YYYY-MM, limites, navegação (dez->jan, jan->dez), rótulos', () => {
  assert.equal(isMonthParam('2026-10'), true)
  for (const bad of ['2026-13', '2026-00', '1999-12', '2101-01', '2026-1', '2026-10-01', null, 202610]) assert.equal(isMonthParam(bad), false, String(bad))
  assert.equal(monthToDate('2026-10'), '2026-10-01'); assert.equal(monthToDate('x'), null)
  assert.equal(dateToMonth('2026-10-01'), '2026-10'); assert.equal(dateToMonth('2026-10-02'), null)
  assert.equal(monthOf('2026-10-06'), '2026-10')
  assert.equal(nextMonth('2026-12'), '2027-01'); assert.equal(prevMonth('2026-01'), '2025-12'); assert.equal(shiftMonth('2026-10', 14), '2027-12')
  assert.equal(prevMonth('2000-01'), null, 'limite inferior'); assert.equal(nextMonth('2100-12'), null, 'limite superior')
  assert.equal(monthLabel('2026-10'), 'outubro de 2026'); assert.equal(monthName('2026-03'), 'março')
  assert.equal(slotLabel({ frequency: 'WEEKLY', weekday: 2, start_time: '20:00', end_time: '21:00' }), 'Terça · 20:00–21:00')
  assert.equal(slotLabel({ frequency: 'MONTHLY', day_of_month: 10, start_time: '20:00:00', end_time: '21:00:00' }), 'Dia 10 · 20:00–21:00')
  assert.equal(dayMonth('2026-10-03'), '03/10')
  // bugs do smoke 03B.3B: series[] sem weekday não vira "· 07:00"; rótulo do mês não vira "Outubro De 2026"
  assert.equal(slotLabel({ frequency: 'WEEKLY', start_time: '07:00:00', end_time: '08:00:00' }), '07:00–08:00')
  assert.equal(slotLabel({ frequency: 'MONTHLY', start_time: '07:00', end_time: '08:00' }), '07:00–08:00')
  assert.equal(capitalizeFirst(monthLabel('2026-10')), 'Outubro de 2026')
  assert.ok(!/font-semibold capitalize/.test(UI) && UI.includes('{capitalizeFirst(monthLabel(month))}'))
  assert.ok(PRICE.includes('slotLabel(s.series_id === detail.current?.series_id ? { ...detail.current, ...s } : s)'))
})
await check('H02 status do mês: os 6 com rótulo + ícone (nunca só cor); filtros incluem Sem cliente', () => {
  assert.deepEqual(MONTH_STATUSES, ['UNPRICED', 'OVERDUE', 'PARTIAL', 'OPEN', 'PAID', 'NO_CHARGE'])
  const labels = { UNPRICED: 'Sem valor', OVERDUE: 'Vencido', PARTIAL: 'Parcial', OPEN: 'Em aberto', PAID: 'Pago', NO_CHARGE: 'Sem cobrança' }
  for (const s of MONTH_STATUSES) { assert.equal(MONTH_STATUS_META[s].label, labels[s], s); assert.ok(MONTH_STATUS_META[s].icon && MONTH_STATUS_META[s].badge, s) }
  assert.ok(MONTH_FILTERS.includes('NO_CUSTOMER') && MONTH_FILTERS.includes('ALL'))
  assert.ok(UI.includes('<Icon className="h-3 w-3" aria-hidden="true" />{meta.label}'), 'badge com ícone e texto')
})
await check('H03 formulário "Receber mês": teto = saldo do servidor, meio, data não futura (5 min), observação', () => {
  const now = Date.parse('2026-10-06T12:00:00-03:00')
  const ok = validateMonthPaymentDraft({ amount: '250,00', method: 'PIX', at: '2026-10-06T11:00', notes: ' x ' }, { openCents: 40000, nowMs: now })
  assert.deepEqual(ok, { ok: true, value: { amount: 25000, method: 'PIX', at: '2026-10-06T11:00:00-03:00', notes: 'x' } })
  assert.equal(validateMonthPaymentDraft({ amount: '400,01', method: 'PIX', at: '2026-10-06T11:00' }, { openCents: 40000, nowMs: now }).ok, false, 'acima do saldo')
  assert.equal(validateMonthPaymentDraft({ amount: '0', method: 'PIX', at: '2026-10-06T11:00' }, { openCents: 40000, nowMs: now }).ok, false)
  assert.equal(validateMonthPaymentDraft({ amount: '10,00', method: 'BOLETO', at: '2026-10-06T11:00' }, { openCents: 40000, nowMs: now }).ok, false)
  assert.equal(validateMonthPaymentDraft({ amount: '10,00', method: 'PIX', at: '2026-10-06T12:30' }, { openCents: 40000, nowMs: now }).ok, false, 'futuro')
  assert.equal(validateMonthPaymentDraft({ amount: '10,00', method: 'PIX', at: '2026-10-06T12:04' }, { openCents: 40000, nowMs: now }).ok, true, 'tolerância de 5 min')
  assert.equal(validateMonthPaymentDraft({ amount: '10,00', method: 'PIX', at: '2026-10-06T11:00', notes: 'x'.repeat(501) }, { openCents: 40000, nowMs: now }).ok, false)
  assert.equal(validateMonthPaymentDraft({ amount: '10,00', method: 'PIX', at: '2026-10-06T11:00' }, { openCents: null, nowMs: now }).ok, false, 'sem saldo do servidor')
})
await check('H04 prévia visual: mais antigo primeiro, último parcial, ignora cancelado/sem valor/quitado, independe da ordem de entrada', () => {
  const occ = [
    { reservation_id: 'c', occurrence_date: '2026-10-17', start_at: '2026-10-17T23:00:00Z', collectible: true, price: 10000, open: 10000 },
    { reservation_id: 'a', occurrence_date: '2026-10-03', start_at: '2026-10-03T23:00:00Z', collectible: true, price: 10000, open: 10000 },
    { reservation_id: 'x', occurrence_date: '2026-10-01', start_at: '2026-10-01T23:00:00Z', collectible: false, price: 10000, open: 0 },
    { reservation_id: 'b', occurrence_date: '2026-10-10', start_at: '2026-10-10T23:00:00Z', collectible: true, price: 10000, open: 10000 },
    { reservation_id: 'u', occurrence_date: '2026-10-02', start_at: '2026-10-02T23:00:00Z', collectible: true, price: null, open: 0 },
    { reservation_id: 'p', occurrence_date: '2026-10-04', start_at: '2026-10-04T23:00:00Z', collectible: true, price: 10000, open: 0 },
  ]
  const exp = [{ reservation_id: 'a', occurrence_date: '2026-10-03', amount: 10000 }, { reservation_id: 'b', occurrence_date: '2026-10-10', amount: 10000 }, { reservation_id: 'c', occurrence_date: '2026-10-17', amount: 5000 }]
  assert.deepEqual(previewMonthSplit(occ, 25000), exp)
  assert.deepEqual(previewMonthSplit([...occ].reverse(), 25000), exp, 'ordem de entrada não importa')
  assert.deepEqual(previewMonthSplit(occ, 0), [])
  assert.ok(RECEIVE.includes('Previsão visual. O sistema confirma a distribuição real ao registrar.'), 'rotulada como previsão')
  assert.ok(!/preview[^\n]*recordPayment|recordPayment\([^)]*preview/.test(RECEIVE), 'prévia nunca é enviada')
})
await check('H05 W2: séries com jogo sem valor separadas por ter/não ter default_price (dados do servidor)', () => {
  const d = { occurrences: [{ series_id: 's1', collectible: true, price: null }, { series_id: 's2', collectible: true, price: null }, { series_id: 's3', collectible: true, price: 100 }, { series_id: 's4', collectible: false, price: null }],
    series: [{ series_id: 's1', default_price: null }, { series_id: 's2', default_price: 7000 }, { series_id: 's3', default_price: null }, { series_id: 's4', default_price: null }] }
  const r = unpricedSeries(d)
  assert.deepEqual(r.withoutPrice.map((s) => s.series_id), ['s1']); assert.deepEqual(r.withPrice.map((s) => s.series_id), ['s2'])
  assert.deepEqual(validateSeriesPrice('150,00'), { ok: true, value: 15000 }); assert.equal(validateSeriesPrice('abc').ok, false)
  assert.deepEqual(validateNewCustomer({ name: '  João  Silva ', phone: '(11) 99000-0001' }), { ok: true, value: { name: 'João Silva', phone: '11990000001' } })
  assert.equal(validateNewCustomer({ name: '', phone: '' }).ok, false); assert.equal(validateNewCustomer({ name: 'A', phone: '123' }).ok, false)
})
await check('H06 erros no client: mensagem saneada; rede/503 mantêm intent; reason estável', () => {
  const net = new RecurringMonthNetworkError(); const st = new RecurringMonthRequestError(409, { error: 'x', code: 'FINANCE_STATE', reason: 'STATE_CHANGED' })
  assert.equal(keepsIntent(net), true); assert.equal(keepsIntent(new RecurringMonthRequestError(503, {})), true); assert.equal(keepsIntent(st), false)
  assert.equal(monthErrorReason(st), 'STATE_CHANGED'); assert.equal(monthErrorMessage(st), 'x')
  assert.equal(monthErrorMessage(new RecurringMonthRequestError(500, null)), 'Não foi possível concluir. Tente novamente.')
  assert.equal(monthErrorMessage(new TypeError('stack')), 'Não foi possível concluir. Tente novamente.')
  assert.match(monthErrorMessage(net), /não há cobrança em dobro/)
})

// ------------------------------------------------------------------ API (rota real + RPC falsa)
await check('A01 sem sessão => 401; rota desconhecida => 404; id não-UUID => 404; sem chamada de RPC', async () => {
  let r = await route('GET', RM_PREFIX, { query: `organization_id=${ORG}&month=2026-10`, u: null }); assert.equal(r.status, 401); assert.equal(r.calls.length, 0)
  r = await route('GET', `${RM_PREFIX}/x/y`); assert.equal(r.status, 404)
  r = await route('DELETE', `${RM_PREFIX}/${LIN}`); assert.equal(r.status, 404)
  r = await route('GET', `${RM_PREFIX}/not-a-uuid`, { query: 'month=2026-10' }); assert.equal(r.status, 404); assert.equal(r.calls.length, 0)
  r = await route('POST', `${RM_PREFIX}/${LIN}/delete`, { body: {} }); assert.equal(r.status, 404)
  assert.equal(recurringMonthPathSegments('/api/recurring-month-x'), null); assert.deepEqual(recurringMonthPathSegments(RM_PREFIX), [])
})
await check('A02 lista: argumentos da RPC (mês -> 1º dia, filtro, cursor); allowlist e limites => 400 sem RPC', async () => {
  let r = await route('GET', RM_PREFIX, { query: `organization_id=${ORG}&month=2026-10&arena_id=${ARENA}&status=OVERDUE&q=%20jo%C3%A3o%20&limit=20&cursor_nc=false&cursor_name=jo%C3%A3o&cursor_lineage=${LIN}` })
  assert.equal(r.status, 200)
  assert.deepEqual(r.calls[0], ['rg_recurring_month_list', { p_org: ORG, p_arena: ARENA, p_month: '2026-10-01', p_status: 'OVERDUE', p_q: 'joão', p_limit: 20, p_cursor: { nc: false, name: 'joão', lineage: LIN } }])
  r = await route('GET', RM_PREFIX, { query: `organization_id=${ORG}&month=2026-10&cursor_nc=true&cursor_lineage=${LIN}` })
  assert.deepEqual(r.calls[0][1].p_cursor, { nc: true, name: '', lineage: LIN }, 'cursor de linhagem sem cliente (nome vazio)')
  for (const q of [`organization_id=${ORG}`, `organization_id=${ORG}&month=2026-13`, `month=2026-10`, `organization_id=x&month=2026-10`,
    `organization_id=${ORG}&month=2026-10&limit=101`, `organization_id=${ORG}&month=2026-10&status=FOO`, `organization_id=${ORG}&month=2026-10&q=${'x'.repeat(101)}`,
    `organization_id=${ORG}&month=2026-10&month=2026-11`, `organization_id=${ORG}&month=2026-10&evil=1`, `organization_id=${ORG}&month=2026-10&cursor_nc=true`]) {
    r = await route('GET', RM_PREFIX, { query: q }); assert.equal(r.status, 400, q); assert.equal(r.calls.length, 0, q)
  }
})
await check('A03 busca (limite 20) e detalhe (só ?month); POST de leitura => 404', async () => {
  let r = await route('GET', `${RM_PREFIX}/search`, { query: `organization_id=${ORG}&month=2026-10&q=ma` })
  assert.deepEqual(r.calls[0], ['rg_recurring_month_search', { p_org: ORG, p_month: '2026-10-01', p_q: 'ma', p_limit: 20 }])
  r = await route('GET', `${RM_PREFIX}/search`, { query: `organization_id=${ORG}&month=2026-10&limit=21` }); assert.equal(r.status, 400)
  r = await route('GET', `${RM_PREFIX}/${LIN}`, { query: 'month=2026-10' }); assert.deepEqual(r.calls[0], ['rg_recurring_month_detail', { p_lineage_id: LIN, p_month: '2026-10-01' }])
  r = await route('GET', `${RM_PREFIX}/${LIN}`, { query: 'month=2026-10&x=1' }); assert.equal(r.status, 400)
  r = await route('GET', `${RM_PREFIX}/${LIN}`); assert.equal(r.status, 400)
  r = await route('POST', `${RM_PREFIX}/search`, { body: {} }); assert.equal(r.status, 404)
})
await check('A04 "Receber mês": expected_open OBRIGATÓRIO; argumentos exatos; 201 novo / 200 replay', async () => {
  let r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { body: payBody({ notes: '  outubro  ' }), rpc: () => ({ data: { batch_id: 'b', idempotent: false }, error: null }) })
  assert.equal(r.status, 201)
  assert.deepEqual(r.calls[0], ['rg_recurring_month_payment_record', { p_operation_id: OP, p_lineage_id: LIN, p_month: '2026-10-01', p_amount: 25000, p_method: 'PIX',
    p_received_at: '2026-10-05T10:00:00-03:00', p_notes: 'outubro', p_expected_open: 40000 }])
  r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { body: payBody(), rpc: () => ({ data: { batch_id: 'b', idempotent: true }, error: null }) }); assert.equal(r.status, 200)
  const { expected_open, ...noExpected } = payBody()
  for (const b of [noExpected, payBody({ expected_open: null }), payBody({ expected_open: -1 }), payBody({ expected_open: 1.5 }), payBody({ expected_open: '40000' }),
    payBody({ amount: 0 }), payBody({ amount: 100000001 }), payBody({ method: 'BOLETO' }), payBody({ received_at: '2026-10-05' }), payBody({ month: '2026-13' }),
    payBody({ operation_id: 'x' }), payBody({ notes: 'x'.repeat(501) }), { ...payBody(), extra: 1 }]) {
    r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { body: b }); assert.equal(r.status, 400, JSON.stringify(b).slice(0, 80)); assert.equal(r.calls.length, 0)
  }
  r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { body: 'não-json' }); assert.equal(r.status, 400)
  r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { query: 'x=1', body: payBody() }); assert.equal(r.status, 400, 'query em escrita')
  assert.equal(r.calls.length, 0)
})
await check('A05 W1 (customer_id XOR dados) e W2 (só mês): argumentos exatos e validação', async () => {
  let r = await route('POST', `${RM_PREFIX}/${LIN}/customer`, { body: { customer_id: CUST } })
  assert.deepEqual(r.calls[0], ['rg_recurring_link_customer', { p_lineage_id: LIN, p_customer_id: CUST, p_customer: null }])
  r = await route('POST', `${RM_PREFIX}/${LIN}/customer`, { body: { customer: { name: ' João  Silva ', phone: '(11) 99000-0001' } } })
  assert.deepEqual(r.calls[0][1], { p_lineage_id: LIN, p_customer_id: null, p_customer: { name: 'João Silva', phone: '11990000001' } })
  for (const b of [{}, { customer_id: CUST, customer: { name: 'a' } }, { customer_id: 'x' }, { customer: { phone: '1199' } }, { customer: { name: '' } }, { customer: { name: 'a', phone: '12' } }, { customer: { name: 'a', email: 'x' } }]) {
    r = await route('POST', `${RM_PREFIX}/${LIN}/customer`, { body: b }); assert.equal(r.status, 400, JSON.stringify(b)); assert.equal(r.calls.length, 0)
  }
  r = await route('POST', `${RM_PREFIX}/${LIN}/apply-series-price`, { body: { month: '2026-10' } })
  assert.deepEqual(r.calls[0], ['rg_recurring_month_apply_series_price', { p_lineage_id: LIN, p_month: '2026-10-01' }])
  r = await route('POST', `${RM_PREFIX}/${LIN}/apply-series-price`, { body: { month: '2026-10', price: 1 } }); assert.equal(r.status, 400)
})
await check('A06 erro da RPC -> HTTP com reason estável; nunca devolve texto/SQL do banco; 500 só registra código', async () => {
  const cases = [
    [{ code: '42501', message: 'SQL' }, 403, null, null], [{ code: 'P0002' }, 404, null, null], [{ code: 'RGP02' }, 409, 'IDEMPOTENCY_MISMATCH', null],
    [{ code: 'RGP01', hint: 'STATE_CHANGED' }, 409, 'FINANCE_STATE', 'STATE_CHANGED'], [{ code: 'RGP01', hint: 'NOTHING_DUE' }, 409, 'FINANCE_STATE', 'NOTHING_DUE'],
    [{ code: 'RGP01', hint: 'UNPRICED' }, 409, 'FINANCE_STATE', 'UNPRICED'], [{ code: 'RGP01', hint: 'CUSTOMER_REQUIRED' }, 409, 'FINANCE_STATE', 'CUSTOMER_REQUIRED'],
    [{ code: 'RGP03', hint: 'OVER_BALANCE' }, 409, 'FINANCE_LIMIT', 'OVER_BALANCE'], [{ code: 'RGR01', hint: 'CUSTOMER_ALREADY_SET' }, 409, 'RECURRING_STATE', 'CUSTOMER_ALREADY_SET'],
    [{ code: 'RGP01', hint: 'SOMETHING_ELSE' }, 409, 'FINANCE_STATE', null], [{ code: 'RGT01' }, 400, null, null], [{ code: '22023' }, 400, null, null],
    [{ code: '23514' }, 400, null, null], [{ code: '40P01' }, 503, null, null], [{ code: 'XX000', message: 'boom interno' }, 500, null, null],
  ]
  for (const [err, status, code, reason] of cases) {
    const r = await route('POST', `${RM_PREFIX}/${LIN}/payments`, { body: payBody(), rpc: () => ({ data: null, error: { ...err, message: err.message || 'detalhe interno do banco' } }) })
    assert.equal(r.status, status, err.code); assert.equal(r.body.code ?? null, code, err.code); assert.equal(r.body.reason ?? null, reason, err.code)
    assert.ok(!/SQL|interno do banco|boom/.test(JSON.stringify(r.body)), `vazou texto do banco: ${err.code}`)
    if (status === 500) assert.equal(r.logs.length, 1)
  }
  assert.equal(mapRecurringMonthError({ code: 'RGP01', hint: 'STATE_CHANGED' }).body.error, MONTH_REASON_MSG.STATE_CHANGED)
  const r = await route('GET', RM_PREFIX, { query: `organization_id=${ORG}&month=2026-10`, rpc: () => ({ data: null, error: null }) })
  assert.equal(r.status, 500, 'resposta vazia da RPC')
})
await check('A07 route.js: dispatch com client da SESSÃO e no-store; nunca service-role', () => {
  const block = ROUTE.slice(ROUTE.indexOf('async function handleRecurringMonth('), ROUTE.indexOf('// ============================ PHASE 02B: PUBLIC API'))
  assert.ok(ROUTE.includes("if (resource === 'recurring-month') return await handleRecurringMonth(request, method)"))
  assert.ok(block.includes('const { supabase, user } = await getContext(request)') && block.includes('supabase.rpc(name, args)'))
  assert.ok(block.includes('return jsonNoStore(r.body, r.status)') && !/createAdminClient|service_role|SERVICE_ROLE/.test(block))
  assert.equal(resolveRecurringMonthRoute('GET', []).kind, 'list'); assert.equal(resolveRecurringMonthRoute('POST', []), null)
})

// ------------------------------------------------------------------ client
await check('C01 client: URLs (ALL omitido, cursor), no-store, expected_open sempre no corpo; erros tipados', async () => {
  const seen = []
  const ok = (body, status = 200) => async (url, init) => { seen.push([url, init]); return { ok: status < 300, status, json: async () => body } }
  let api = createRecurringMonthApi(ok({ items: [] }))
  await api.list({ orgId: ORG, month: '2026-10', status: 'ALL', q: '', cursor: { nc: false, name: 'ana', lineage: LIN } })
  assert.equal(seen[0][0], `${RM_PREFIX}?organization_id=${ORG}&month=2026-10&limit=50&cursor_nc=false&cursor_name=ana&cursor_lineage=${LIN}`)
  assert.equal(seen[0][1].cache, 'no-store')
  api = createRecurringMonthApi(ok({ batch_id: 'b' }, 201))
  await api.recordPayment(OP, LIN, { month: '2026-10', amount: 100, method: 'PIX', receivedAt: '2026-10-05T10:00:00-03:00', expectedOpen: 4000 })
  assert.deepEqual(JSON.parse(seen[1][1].body), { operation_id: OP, month: '2026-10', amount: 100, method: 'PIX', received_at: '2026-10-05T10:00:00-03:00', notes: null, expected_open: 4000 })
  assert.equal(seen[1][0], `${RM_PREFIX}/${LIN}/payments`)
  api = createRecurringMonthApi(ok({ error: 'm', code: 'FINANCE_STATE', reason: 'STATE_CHANGED' }, 409))
  const e = await api.detail(LIN, '2026-10').catch((x) => x)
  assert.ok(e instanceof RecurringMonthRequestError && e.status === 409 && e.reason === 'STATE_CHANGED')
  api = createRecurringMonthApi(async () => { throw new TypeError('offline') })
  assert.ok((await api.search({ orgId: ORG, month: '2026-10' }).catch((x) => x)) instanceof RecurringMonthNetworkError)
  assert.throws(() => recurringMonthUrl(['../x']))
})

// ------------------------------------------------------------------ fluxo de mutação (helpers reais)
await check('F01 STATE_CHANGED descarta o intent (nova tentativa = novo operation_id); rede/503 mantêm', async () => {
  let n = 0; const intent = createOperationIntent(() => `op-${++n}`); const guard = createSubmitGuard(); const keys = []
  const attempt = (err) => submitWithBusy({ guard, setBusy: () => {}, intent, send: async (k) => { keys.push(k); throw err },
    onError: (e) => { if (!keepsIntent(e)) intent.reset() } })
  await attempt(new RecurringMonthNetworkError()); await attempt(new RecurringMonthRequestError(503, {}))
  assert.deepEqual(keys, ['op-1', 'op-1'], 'rede/503 reaproveitam a chave (replay idempotente no servidor)')
  await attempt(new RecurringMonthRequestError(409, { reason: 'STATE_CHANGED' }))
  assert.equal(keys[2], 'op-1'); assert.equal(intent.peek(), null, 'STATE_CHANGED descartou')
  await attempt(new RecurringMonthRequestError(409, { code: 'IDEMPOTENCY_MISMATCH' }))
  assert.equal(keys[3], 'op-2'); assert.equal(intent.peek(), null)
  await submitWithBusy({ guard, setBusy: () => {}, intent, send: async (k) => { keys.push(k); return { data: {} } } })
  assert.equal(keys[4], 'op-3'); assert.equal(intent.peek(), null, 'sucesso descarta')
})
await check('F02 duplo clique => uma chamada; dialog: guarda síncrona + botão desabilitado + fechamento bloqueado', async () => {
  const guard = createSubmitGuard(); let calls = 0; let release
  const p = new Promise((r) => { release = r })
  const a = submitWithBusy({ guard, setBusy: () => {}, send: () => { calls += 1; return p } })
  assert.equal(await submitWithBusy({ guard, setBusy: () => {}, send: () => { calls += 1 } }), 'busy')
  release({ data: {} }); await a; assert.equal(calls, 1)
  for (const [f, code] of [['receive', RECEIVE], ['link', LINK], ['price', PRICE]]) {
    assert.ok(code.includes('if (!guard.current) guard.current = createSubmitGuard()') && code.includes('submitWithBusy({'), f)
    assert.ok(code.includes("onOpenChange={(o) => { if (!o && !busy) onClose() }}"), `${f}: fechar bloqueado durante envio`)
  }
  assert.ok(RECEIVE.includes('onClick={submit} disabled={busy}'), 'confirmar desabilitado durante envio')
})
await check('F03 "Receber mês": expected_open = saldo CONFIRMADO; STATE_CHANGED => refetch + nova confirmação; nada otimista', () => {
  assert.ok(RECEIVE.includes('setConfirmed({ value: r.value, expectedOpen: open, preview: previewMonthSplit(detail.occurrences, r.value.amount) })'))
  assert.ok(RECEIVE.includes('month, amount: value.amount, method: value.method, receivedAt: value.at, notes: value.notes, expectedOpen,'))
  const rr = RECEIVE.slice(RECEIVE.indexOf('if (RELOAD_AND_REVIEW.includes(reason)) {'), RECEIVE.indexOf('if (RELOAD_AND_CLOSE.includes(reason)) {'))
  for (const s of ['setConfirmed(null)', "setStep('form')", 'setNotice(MONTH_REASON_MSG[reason])', 'await onReload()']) assert.ok(rr.includes(s), s)
  assert.ok(RECEIVE.includes("const RELOAD_AND_REVIEW = ['STATE_CHANGED', 'OVER_BALANCE']") && RECEIVE.includes("const RELOAD_AND_CLOSE = ['NOTHING_DUE', 'UNPRICED', 'CUSTOMER_REQUIRED']"))
  assert.ok(RECEIVE.includes('if (!keepsIntent(err)) intent.current.reset()'), 'intent descartado fora de rede/503')
  assert.ok(RECEIVE.includes('const set = (k, v) => { intent.current.reset();'), 'campo alterado = nova intenção')
  // sucesso: split REAL exibido e refetch do detalhe + lista
  assert.ok(DETAIL.includes('onDone={async (r) => { setDlg(null); setResult(r); await afterMutation() }}'))
  assert.ok(DETAIL.includes('const afterMutation = async () => { await reloadDetail(); onChanged?.() }'))
  assert.ok(DETAIL.includes('Distribuição confirmada pelo sistema:') && DETAIL.includes('(result.items || []).map('))
  assert.ok(VIEW.includes('const onChanged = () => setListReload((n) => n + 1)') && VIEW.includes('reloadKey={listReload}'))
})

// ------------------------------------------------------------------ papéis e UI
await check('S01 papéis: gestor = canViewFinance (nunca isManagerOrAbove); RECEPTIONIST só busca (zero agregados)', () => {
  for (const [f, code] of COMPONENTS) assert.ok(!code.includes('isManagerOrAbove'), `${f}: isManagerOrAbove libera função financeira`)
  assert.ok(VIEW.includes('const manager = canViewFinance(role)') && VIEW.includes("const mode = manager && !forbidden ? 'manager' : 'operator'"))
  assert.ok(/\{mode === 'manager' \? \(\s*<MonthList /.test(VIEW) && VIEW.includes('<MonthSearch '), 'lista só no modo gestor')
  assert.ok(!/api\.list\(|expected|summary|\.open\b|\.net\b/.test(SEARCH), 'busca não lê agregados/valores')
  assert.ok(SEARCH.includes('api.search({ orgId, month, q: debouncedQ || null })'))
  assert.ok(VIEW.includes("if (!orgId || mode !== 'manager') return"), 'arenas só para gestor')
})
await check('S02 W1 / definir valor / W2 / estorno-anulação: só gestor no detalhe', () => {
  assert.ok(DETAIL.includes("{d && dlg === 'link' && manager && (") && DETAIL.includes("{d && dlg === 'price' && manager && (") && DETAIL.includes('{d && dlg?.finance && manager && ('))
  assert.ok(DETAIL.includes('{manager && (\n                  <Button variant="ghost" size="sm"'), 'botão Financeiro só gestor')
  const blocked = DETAIL.slice(DETAIL.indexOf('function Blocked('), DETAIL.indexOf('function Notice('))
  assert.equal((blocked.match(/\{manager\n\s+\?/g) || []).length, 2, 'CTAs de W1/W2 condicionados a manager')
  assert.ok(DETAIL.includes('<FinancePanel reservationId={dlg.finance.reservation_id} role={role} onChanged={afterMutation} />'), 'estorno/anulação => refetch')
  assert.ok(DETAIL.includes("manager={mode === 'manager'}") || VIEW.includes("manager={mode === 'manager'}"))
  assert.ok(PRICE.includes("method: 'PATCH'") && PRICE.includes('JSON.stringify({ default_price: cents })'), 'definir valor pelo PATCH existente')
  assert.ok(PRICE.includes('onSuccess: async () => { toast.success(\'Valor da série definido\'); await onReload() }'), 'refetch depois do PATCH')
  assert.ok(PRICE.includes('api.applySeriesPrice(detail.lineage_id, month)') && PRICE.includes('disabled={busy || withPrice.length === 0}'))
})
await check('S03 detalhe: valores e elegibilidade do servidor; carga por runLatest; mês/linhagem nova não herda o anterior', () => {
  assert.ok(DETAIL.includes('runLatest(seq, () => api.detail(lineageId, month), {'))
  assert.ok(DETAIL.includes('data: s.key === key ? s.data : null'), 'troca de mensalista/mês não mostra dado antigo')
  assert.ok(DETAIL.includes('{d.eligible && (') && DETAIL.includes("d.blocked_reason === 'CUSTOMER_REQUIRED'") && DETAIL.includes("d.blocked_reason === 'UNPRICED'"))
  for (const code of [DETAIL, LIST, SEARCH, RECEIVE]) assert.ok(!/reduce\(\(a, b\) => a \+|\.reduce\(\(s, o\) =>/.test(code), 'soma financeira no front')
  assert.ok(LIST.includes('runLatest(seqs.list, () => api.list({') && LIST.includes('runLatest(seqs.more,'))
  assert.ok(VIEW.includes('const invalidateLoads = () =>') && VIEW.includes('invalidateLoads(); navigate({ month: m })'), 'troca de mês invalida em curso')
  assert.ok(DETAIL.includes("fetch(`/api/recurring-reservations/${encodeURIComponent(id)}/generate`"), 'gerar = ação explícita')
})
await check('S04 mobile/a11y: alvos 44 px, Title+Description, foco de volta, aria-live, reduced motion', () => {
  for (const [f, code] of COMPONENTS) {
    for (const b of code.match(/<Button[^>]*>/g) || []) assert.ok(/h-11|h-12|aria-pressed/.test(b), `${f}: botão sem 44 px: ${b.slice(0, 80)}`)
    for (const m of code.matchAll(/animate-spin[^"]*/g)) assert.ok(m[0].includes('motion-reduce:animate-none'), `${f}: ${m[0]}`)
    for (const i of code.match(/<(?:Input|Textarea)\b[\s\S]*?\/>|<SelectTrigger\b[^>]*>/g) || []) assert.ok(/\bid=|aria-label=/.test(i), `${f}: controle sem rótulo: ${i.slice(0, 60)}`)
  }
  for (const [f, code] of [['receive', RECEIVE], ['link', LINK], ['price', PRICE]]) {
    assert.equal((code.match(/<DialogTitle>/g) || []).length, (code.match(/<DialogContent\b/g) || []).length, `${f}: Title`)
    assert.equal((code.match(/<DialogDescription>/g) || []).length, (code.match(/<DialogContent\b/g) || []).length, `${f}: Description`)
    assert.ok(code.includes('onCloseAutoFocus={focusReturn(returnFocusTo)}'), `${f}: foco de volta`)
    assert.ok(code.includes('max-h-[90dvh] overflow-y-auto'), `${f}: rola no mobile`)
  }
  assert.ok(UI.includes('aria-label={prev ? `Mês anterior: ${monthLabel(prev)}` : \'Mês anterior\'}') && UI.includes('aria-live="polite"'))
  assert.ok(LIST.includes('md:grid') && LIST.includes('md:hidden'), 'lista vira cards no mobile')
})
await check('S05 page.js: Mês é a view padrão; Séries preserva CreateDialog/DetailSheet; Suspense; "Ver mês"', () => {
  assert.ok(PAGE.includes("const view = sp.get('view') === 'series' ? 'series' : 'mes'"))
  assert.ok(PAGE.includes("{view === 'mes' ? <MonthView me={me} /> : <SeriesView me={me} onOpenMonth={openMonth} />}"))
  assert.ok(PAGE.includes('function CreateDialog(') && PAGE.includes('function DetailSheet(') && PAGE.includes('<Suspense fallback='))
  assert.ok(PAGE.includes('onClick={() => onOpenMonth(id)}'))
})

// ------------------------------------------------------------------ escopo e contratos congelados
await check('R01 GET /recurring-reservations e /:id são leitura PURA (sem top-up); PATCH/geração explícita preservados', () => {
  const list = ROUTE.slice(ROUTE.indexOf('// GET /recurring-reservations?organization_id=&status=&q='), ROUTE.indexOf('// GET /recurring-reservations/:id  -> detalhe'))
  const det = ROUTE.slice(ROUTE.indexOf('// GET /recurring-reservations/:id  -> detalhe'), ROUTE.indexOf('// PATCH /recurring-reservations/:id'))
  for (const [n, b] of [['lista', list], ['detalhe', det]]) {
    assert.ok(b.length > 100, n)
    assert.ok(!/topUpForRead|topUpSeries|rg_recurring_generate|\.rpc\(/.test(b), `${n}: GET escreve`)
  }
  assert.ok(ROUTE.includes("await topUpForRead(supabase, series, 'patch')"), 'PATCH inalterado')
  assert.ok(ROUTE.includes("const { data, error } = await supabase.rpc('rg_recurring_generate', { p_series_id: id, p_dates: prev.toCreate })"), 'geração explícita')
})
await check('R02 Agenda fora do escopo: GET /api/agenda e a tela da Agenda inalterados', () => {
  assert.ok(ROUTE.includes("for (const s of (aSeries || [])) { await topUpForRead(supabase, s, 'agenda') }"), 'Agenda mantém o comportamento (dívida conhecida)')
  assert.ok(!stripJs(read('app/dashboard/agenda/page.js')).includes('recurring-month'))
})
await check('R03 03B.3A congelada: migration/rollback com o hash do commit aplicado em Production', () => {
  const h = (f) => crypto.createHash('sha256').update(read(f), 'utf8').digest('hex')
  assert.equal(h('supabase/migration_phase3b3_recurring_month.sql'), '518b404830e889f71b632957590f67651421c26cc0960dfc1716f1e4bc181aa5')
  assert.equal(h('supabase/rollback_phase3b3_recurring_month.sql'), 'd8757bdbb4808e5ba3f56cc5b6d7484eb9c03f5ce1f952936e969b238635a741')
})

// ------------------------------------------------------------------ resultado
const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3B3B_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
