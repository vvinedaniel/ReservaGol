// Reserva Gol — FASE 03B.1B — API + frontend do Financeiro (puro/estático, sem rede e sem banco).
// Uso: node tests/phase3b1_finance_overview.test.mjs
// Cobre: períodos (presets, viradas, fevereiro/bissexto, limites), validação da API, mapeamento de
// erros, no-store, permissões/menu, ausência de chamadas para RECEPTIONIST, termos proibidos,
// runLatest e corridas adversariais (respostas fora de ordem, paginação invalidada).
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createHash } from 'node:crypto'
import { PRESETS, MAX_PERIOD_DAYS, resolvePeriod, periodDays, isValidCustomPeriod, periodFromSearch, periodToSearch, pctChange, fmtPeriodShort, daysInMonth } from '../lib/reserva/finance-period.js'
import { parseFinanceQuery, mapFinanceError, runFinanceEndpoint, FINANCE_ENDPOINTS, FINANCE_ERRORS, RECEIVABLE_FILTERS } from '../lib/reserva/finance-api.js'
import { financeUrl, fetchFinance, FinanceRequestError, periodParams, cashflowGranularity } from '../lib/reserva/finance-client.js'
import { canViewFinance, can, FEATURES, ROLES } from '../lib/auth/permissions.js'
import { createRequestSequence, runLatest } from '../lib/reserva/latest-request.js'
import { addDaysStr, isValidDateStr } from '../lib/reserva/time.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripJsComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ROUTE = read('app/api/[[...path]]/route.js')
const PAGE = stripJsComments(read('app/dashboard/financeiro/page.js'))
const PICKER = stripJsComments(read('components/reserva/finance/period-picker.jsx'))
const DASH = stripJsComments(read('app/dashboard/page.js'))
const SHELL = stripJsComments(read('components/reserva/dashboard-shell.jsx'))

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
const P = (preset, today, custom) => resolvePeriod(preset, today, custom)
const span = (p) => p && [p.from, p.to, p.compare.from, p.compare.to]
function deferred() { let resolve, reject; const p = new Promise((res, rej) => { resolve = res; reject = rej }); return { p, resolve, reject } }
const tick = () => new Promise((r) => setImmediate(r))
const sp = (o) => { const q = new URLSearchParams(); for (const [k, v] of Object.entries(o)) (Array.isArray(v) ? v : [v]).forEach((x) => q.append(k, x)); return q }
const ORG = '1b728e0e-cc5f-4d3f-9e10-2864238754fc'
const ARENA = '0df00495-9f3f-4b8b-b14c-1392f6b99b83'
const RID = '6f1c2a8e-1d3b-4c55-9a77-0b8e2d4c6f10'

// ------------------------------------------------------------------ períodos
await check('F01 PRESETS exatos', () => assert.deepEqual(PRESETS, ['today', 'last7', 'this_month', 'last_month', 'custom']))
await check('F02 today: hoje / comparação ontem', () => {
  assert.deepEqual(span(P('today', '2026-10-15')), ['2026-10-15', '2026-10-15', '2026-10-14', '2026-10-14'])
  assert.equal(P('today', '2026-10-15').days, 1)
})
await check('F03 last7: hoje-6..hoje / hoje-13..hoje-7', () => {
  const p = P('last7', '2026-10-15')
  assert.deepEqual(span(p), ['2026-10-09', '2026-10-15', '2026-10-02', '2026-10-08'])
  assert.equal(p.days, 7); assert.equal(p.compare.days, 7)
})
await check('F04 this_month: dia 1..hoje / mês anterior até o mesmo dia', () => {
  assert.deepEqual(span(P('this_month', '2026-10-15')), ['2026-10-01', '2026-10-15', '2026-09-01', '2026-09-15'])
})
await check('F05 last_month: mês anterior inteiro / mês imediatamente anterior', () => {
  assert.deepEqual(span(P('last_month', '2026-10-15')), ['2026-09-01', '2026-09-30', '2026-08-01', '2026-08-31'])
})
await check('F06 custom: período informado / mesma duração imediatamente antes', () => {
  const p = P('custom', '2026-10-15', { from: '2026-10-01', to: '2026-10-10' })
  assert.deepEqual(span(p), ['2026-10-01', '2026-10-10', '2026-09-21', '2026-09-30'])
  assert.equal(p.days, 10); assert.equal(p.compare.days, 10)
})
await check('F07 virada de mês', () => {
  assert.deepEqual(span(P('today', '2026-11-01')), ['2026-11-01', '2026-11-01', '2026-10-31', '2026-10-31'])
  assert.deepEqual(span(P('last7', '2026-11-02')), ['2026-10-27', '2026-11-02', '2026-10-20', '2026-10-26'])
  assert.deepEqual(span(P('this_month', '2026-11-01')), ['2026-11-01', '2026-11-01', '2026-10-01', '2026-10-01'])
})
await check('F08 virada de ano', () => {
  assert.deepEqual(span(P('today', '2027-01-01')), ['2027-01-01', '2027-01-01', '2026-12-31', '2026-12-31'])
  assert.deepEqual(span(P('last7', '2027-01-01')), ['2026-12-26', '2027-01-01', '2026-12-19', '2026-12-25'])
  assert.deepEqual(span(P('this_month', '2027-01-03')), ['2027-01-01', '2027-01-03', '2026-12-01', '2026-12-03'])
  assert.deepEqual(span(P('last_month', '2027-01-15')), ['2026-12-01', '2026-12-31', '2026-11-01', '2026-11-30'])
  assert.deepEqual(span(P('last_month', '2027-02-10')), ['2027-01-01', '2027-01-31', '2026-12-01', '2026-12-31'])
  assert.deepEqual(span(P('custom', '2027-01-20', { from: '2027-01-01', to: '2027-01-10' })), ['2027-01-01', '2027-01-10', '2026-12-22', '2026-12-31'])
})
await check('F09 fevereiro (não bissexto)', () => {
  assert.deepEqual(span(P('last_month', '2026-03-05')), ['2026-02-01', '2026-02-28', '2026-01-01', '2026-01-31'])
  assert.deepEqual(span(P('last_month', '2026-04-05')), ['2026-03-01', '2026-03-31', '2026-02-01', '2026-02-28'])
  assert.deepEqual(span(P('this_month', '2026-02-28')), ['2026-02-01', '2026-02-28', '2026-01-01', '2026-01-28'])
})
await check('F10 ano bissexto', () => {
  assert.equal(daysInMonth(2028, 2), 29)
  assert.deepEqual(span(P('last_month', '2028-03-10')), ['2028-02-01', '2028-02-29', '2028-01-01', '2028-01-31'])
  assert.deepEqual(span(P('this_month', '2028-03-30')), ['2028-03-01', '2028-03-30', '2028-02-01', '2028-02-29'])
  assert.deepEqual(span(P('today', '2028-03-01')), ['2028-03-01', '2028-03-01', '2028-02-29', '2028-02-29'])
  assert.deepEqual(span(P('this_month', '2028-02-29')), ['2028-02-01', '2028-02-29', '2028-01-01', '2028-01-29'])
  assert.deepEqual(span(P('custom', '2028-03-10', { from: '2028-02-01', to: '2028-02-29' })), ['2028-02-01', '2028-02-29', '2028-01-03', '2028-01-31'])
})
await check('F11 this_month com mês anterior mais curto (limita ao último dia)', () => {
  assert.deepEqual(span(P('this_month', '2026-03-31')), ['2026-03-01', '2026-03-31', '2026-02-01', '2026-02-28'])
  assert.deepEqual(span(P('this_month', '2026-03-29')), ['2026-03-01', '2026-03-29', '2026-02-01', '2026-02-28'])
  assert.deepEqual(span(P('this_month', '2026-05-31')), ['2026-05-01', '2026-05-31', '2026-04-01', '2026-04-30'])
  assert.deepEqual(span(P('this_month', '2028-03-31')), ['2028-03-01', '2028-03-31', '2028-02-01', '2028-02-29'])
})
await check('F12 personalizado de 1 dia', () => {
  const p = P('custom', '2026-10-15', { from: '2026-10-10', to: '2026-10-10' })
  assert.deepEqual(span(p), ['2026-10-10', '2026-10-10', '2026-10-09', '2026-10-09'])
  assert.equal(p.days, 1)
})
await check('F13 personalizado de 366 dias aceito (comparação também com 366)', () => {
  const p = P('custom', '2028-06-01', { from: '2027-01-01', to: '2028-01-01' })
  assert.equal(p.days, 366); assert.equal(p.compare.days, 366)
  assert.deepEqual(span(p), ['2027-01-01', '2028-01-01', '2025-12-31', '2026-12-31'])
  assert.equal(MAX_PERIOD_DAYS, 366)
})
await check('F14 personalizado de 367 dias rejeitado (resolver, validador e API)', () => {
  assert.equal(periodDays('2027-01-01', '2028-01-02'), 367)
  assert.equal(P('custom', '2028-06-01', { from: '2027-01-01', to: '2028-01-02' }), null)
  assert.equal(isValidCustomPeriod('2027-01-01', '2028-01-02'), false)
  const q = parseFinanceQuery('overview', sp({ organization_id: ORG, from: '2027-01-01', to: '2028-01-02' }))
  assert.equal(q.ok, false); assert.equal(q.status, 400)
})
await check('F15 entradas inválidas => null (nunca lança)', () => {
  for (const t of ['', '2026-02-30', '0002-10-01', '15/10/2026', null, undefined, 20261015]) assert.equal(P('today', t), null, String(t))
  assert.equal(P('week', '2026-10-15'), null)
  assert.equal(P('custom', '2026-10-15', { from: '2026-10-10', to: '2026-10-09' }), null)
  assert.equal(P('custom', '2026-10-15', { from: '2026-10-1', to: '2026-10-09' }), null)
  assert.equal(P('custom', '2026-10-15'), null)
})
await check('F16 comparação SEMPRE termina antes do período atual (todos os dias 2026–2029, todos os presets)', () => {
  let d = '2026-01-01', n = 0
  while (d <= '2029-12-31') {
    for (const pr of ['today', 'last7', 'this_month', 'last_month']) {
      const p = P(pr, d)
      assert.ok(p, `${pr} ${d}`)
      for (const x of span(p)) assert.ok(isValidDateStr(x), `${pr} ${d} ${x}`)
      assert.ok(p.from <= p.to && p.compare.from <= p.compare.to, `${pr} ${d}`)
      assert.ok(p.compare.to < p.from, `${pr} ${d}: ${p.compare.to} >= ${p.from}`)
      assert.ok(p.to <= d, `${pr} ${d}: período no futuro`)
      assert.ok(p.days <= MAX_PERIOD_DAYS && p.compare.days <= MAX_PERIOD_DAYS)
      if (pr !== 'this_month') assert.equal(p.compare.to, addDaysStr(p.from, -1), `${pr} ${d}: buraco entre comparação e período`)
      n++
    }
    d = addDaysStr(d, 1)
  }
  assert.ok(n > 5000)
})
await check('F17 custom aleatório: mesma duração, contíguo e anterior (2.000 casos)', () => {
  let seed = 7
  const rnd = (m) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % m }
  for (let i = 0; i < 2000; i++) {
    const from = addDaysStr('2024-01-01', rnd(1800))
    const to = addDaysStr(from, rnd(366))
    const p = P('custom', '2030-01-01', { from, to })
    assert.ok(p, `${from}..${to}`)
    assert.equal(p.days, p.compare.days)
    assert.equal(p.compare.to, addDaysStr(from, -1))
    assert.ok(p.compare.to < p.from)
  }
})
await check('F18 URL: periodToSearch/periodFromSearch ida e volta + fallback seguro', () => {
  const today = '2026-10-15'
  for (const pr of ['today', 'last7', 'this_month', 'last_month']) {
    const p = P(pr, today)
    assert.equal(periodToSearch(p, null), `preset=${pr}`)
    assert.deepEqual(periodFromSearch(new URLSearchParams(periodToSearch(p, ARENA)), today), p)
  }
  const c = P('custom', today, { from: '2026-09-01', to: '2026-09-20' })
  assert.equal(periodToSearch(c, ARENA), `from=2026-09-01&to=2026-09-20&arena=${ARENA}`)
  assert.deepEqual(periodFromSearch(new URLSearchParams('from=2026-09-01&to=2026-09-20'), today), c)
  const def = P('this_month', today)
  for (const bad of ['', 'preset=xx', 'preset=custom', 'from=2026-02-30&to=2026-03-01', 'from=2026-10-10', 'from=2025-01-01&to=2026-10-01', 'from=0002-01-01&to=2026-01-01']) {
    assert.deepEqual(periodFromSearch(new URLSearchParams(bad), today), def, bad)
  }
})
await check('F19 sem new Date(\'YYYY-MM-DD\') nos módulos de período/API', () => {
  for (const f of ['lib/reserva/finance-period.js', 'lib/reserva/finance-api.js', 'lib/reserva/finance-client.js', 'components/reserva/finance/period-picker.jsx', 'app/dashboard/financeiro/page.js']) {
    const code = stripJsComments(read(f))
    assert.ok(!/new Date\(\s*['"`]\d{4}-/.test(code) && !/new Date\(\s*(from|to|today|todayStr|dateStr|s)\s*\)/.test(code) && !/Date\.parse\(\s*(from|to)\b/.test(code), f)
  }
  assert.ok(read('lib/reserva/finance-period.js').includes("import { isValidDateStr, addDaysStr } from './time.js'"))
})
await check('F20 pctChange inteiro, sem base => null', () => {
  assert.equal(pctChange(100, 80), 25)
  assert.equal(pctChange(50, 100), -50)
  assert.equal(pctChange(1, 3), -67)
  assert.equal(pctChange(2, 3), -33)
  assert.equal(pctChange(100, 100), 0)
  assert.equal(pctChange(100, 0), null)
  assert.equal(pctChange(100, null), null)
  assert.equal(pctChange(null, 100), null)
  assert.equal(fmtPeriodShort('2026-10-01', '2026-10-15'), '01/10/2026 – 15/10/2026')
  assert.equal(fmtPeriodShort('2026-10-01', '2026-10-01'), '01/10/2026')
})

// ------------------------------------------------------------------ API: validação
const BASE = { organization_id: ORG, from: '2026-10-01', to: '2026-10-15' }
await check('A01 overview válido (com e sem comparação, arena opcional)', () => {
  const a = parseFinanceQuery('overview', sp(BASE))
  assert.deepEqual(a, { ok: true, rpc: 'rg_fin_overview', args: { p_org: ORG, p_arena: null, p_from: '2026-10-01', p_to: '2026-10-15' } })
  const b = parseFinanceQuery('overview', sp({ ...BASE, arena_id: ARENA, compare_from: '2026-09-01', compare_to: '2026-09-15' }))
  assert.equal(b.ok, true)
  assert.deepEqual(b.args, { p_org: ORG, p_arena: ARENA, p_from: '2026-10-01', p_to: '2026-10-15', p_compare_from: '2026-09-01', p_compare_to: '2026-09-15' })
})
await check('A02 query inválida => 400 (UUID, datas, período, comparação, repetição)', () => {
  const bad = [
    {}, { ...BASE, organization_id: 'x' }, { ...BASE, organization_id: `${ORG}'--` }, { ...BASE, arena_id: 'abc' },
    { ...BASE, from: '2026-02-30' }, { ...BASE, to: '2026-10-1' }, { ...BASE, from: '0002-10-01' }, { ...BASE, from: '2026-10-16' },
    { ...BASE, from: '2025-01-01', to: '2026-10-15' },
    { ...BASE, compare_from: '2026-09-01' }, { ...BASE, compare_to: '2026-09-15' },
    { ...BASE, compare_from: '2026-09-20', compare_to: '2026-10-01' }, { ...BASE, compare_from: '2026-09-20', compare_to: '2026-09-10' },
    { ...BASE, compare_from: '2024-01-01', compare_to: '2025-09-30' },
    { ...BASE, organization_id: [ORG, ORG] }, { ...BASE, from: ['2026-10-01', '2026-09-01'] },
    { ...BASE, filter: 'OPEN' }, { ...BASE, granularity: 'day' }, { ...BASE, limit: '10' },
  ]
  for (const q of bad) { const r = parseFinanceQuery('overview', sp(q)); assert.equal(r.ok, false, JSON.stringify(q)); assert.equal(r.status, 400, JSON.stringify(q)) }
})
await check('A03 receivables: filtros, limite e cursor (start_at, id)', () => {
  const ok = parseFinanceQuery('receivables', sp(BASE))
  assert.deepEqual(ok.args, { p_org: ORG, p_arena: null, p_from: '2026-10-01', p_to: '2026-10-15', p_filter: 'OPEN', p_limit: 50, p_after_start: null, p_after_id: null })
  for (const f of RECEIVABLE_FILTERS) assert.equal(parseFinanceQuery('receivables', sp({ ...BASE, filter: f })).args.p_filter, f)
  const cur = parseFinanceQuery('receivables', sp({ ...BASE, filter: 'UNPRICED', limit: '200', after_start: '2026-10-05T21:00:00+00:00', after_id: RID }))
  assert.equal(cur.ok, true); assert.equal(cur.args.p_limit, 200); assert.equal(cur.args.p_after_start, '2026-10-05T21:00:00+00:00')
  assert.equal(parseFinanceQuery('receivables', sp({ ...BASE, after_start: '2026-10-05T21:00:00.123456Z', after_id: RID })).ok, true)
  const bad = [{ filter: 'ALL' }, { filter: 'open' }, { limit: '0' }, { limit: '201' }, { limit: 'abc' }, { limit: '1.5' }, { limit: '-1' }, { limit: '050' },
    { after_start: '2026-10-05T21:00:00+00:00' }, { after_id: RID }, { after_start: '2026-10-05', after_id: RID }, { after_start: 'ontem', after_id: RID },
    { after_start: '2026-10-05T21:00:00+00:00', after_id: 'x' }, { after_at: '2026-10-05T21:00:00+00:00', after_id: RID }, { compare_from: '2026-09-01', compare_to: '2026-09-15' }]
  for (const b of bad) assert.equal(parseFinanceQuery('receivables', sp({ ...BASE, ...b })).status, 400, JSON.stringify(b))
})
await check('A04 cashflow: granularidade day|month|year (padrão day)', () => {
  assert.equal(parseFinanceQuery('cashflow', sp(BASE)).args.p_granularity, 'day')
  for (const g of ['day', 'month', 'year']) assert.equal(parseFinanceQuery('cashflow', sp({ ...BASE, granularity: g })).args.p_granularity, g)
  for (const g of ['week', 'DAY', 'hour', ' day']) assert.equal(parseFinanceQuery('cashflow', sp({ ...BASE, granularity: g })).status, 400, g)
  assert.equal(parseFinanceQuery('cashflow', sp({ ...BASE, filter: 'OPEN' })).status, 400)
})
await check('A05 cash-entries: limite e cursor (received_at, id)', () => {
  const ok = parseFinanceQuery('cash-entries', sp({ ...BASE, after_at: '2026-10-05T21:00:00+00:00', after_id: RID, limit: '25' }))
  assert.deepEqual(ok.args, { p_org: ORG, p_arena: null, p_from: '2026-10-01', p_to: '2026-10-15', p_limit: 25, p_after_at: '2026-10-05T21:00:00+00:00', p_after_id: RID })
  for (const b of [{ after_at: '2026-10-05T21:00:00+00:00' }, { after_start: '2026-10-05T21:00:00+00:00', after_id: RID }, { limit: '500' }, { filter: 'OPEN' }])
    assert.equal(parseFinanceQuery('cash-entries', sp({ ...BASE, ...b })).status, 400, JSON.stringify(b))
})
await check('A06 endpoint desconhecido => 404 (inclusive nomes de protótipo)', () => {
  for (const e of ['summary', 'constructor', '__proto__', 'toString', '', 'overview/x']) assert.equal(parseFinanceQuery(e, sp(BASE)).status, 404, e)
  assert.deepEqual(Object.keys(FINANCE_ENDPOINTS), ['overview', 'receivables', 'cashflow', 'cash-entries'])
})

// ------------------------------------------------------------------ API: execução e erros
const fakeRpc = (impl) => { const calls = []; return { calls, fn: async (name, args) => { calls.push([name, args]); return impl(name, args) } } }
const silent = () => {}
await check('E01 42501 => HTTP 403 (mensagem genérica)', async () => {
  const r = fakeRpc(() => ({ data: null, error: { code: '42501', message: 'rg: sem permissão financeira', details: 'x', hint: 'y' } }))
  const out = await runFinanceEndpoint({ endpoint: 'overview', searchParams: sp(BASE), user: { id: 'u' }, callRpc: r.fn, log: silent })
  assert.equal(out.status, 403); assert.deepEqual(out.body, { error: FINANCE_ERRORS.forbidden })
})
await check('E02 22023 => HTTP 400 (mensagem genérica)', async () => {
  const r = fakeRpc(() => ({ data: null, error: { code: '22023', message: 'rg: arena inválida' } }))
  const out = await runFinanceEndpoint({ endpoint: 'receivables', searchParams: sp(BASE), user: { id: 'u' }, callRpc: r.fn, log: silent })
  assert.equal(out.status, 400); assert.deepEqual(out.body, { error: FINANCE_ERRORS.invalid })
})
await check('E03 erro interno => 500 genérico, sem SQL/mensagem/stack do banco', async () => {
  const leaks = ['relation "private.rg_fin_scope" does not exist', 'XX000', 'stack', 'select', 'rg_fin']
  for (const error of [{ code: 'XX000', message: leaks[0], details: 'select * from x', hint: 'stack' }, { code: '42P01', message: 'boom' }, { message: 'sem código' }, { code: '23505' }]) {
    const r = fakeRpc(() => ({ data: null, error }))
    const logs = []
    const out = await runFinanceEndpoint({ endpoint: 'cashflow', searchParams: sp(BASE), user: { id: 'u' }, callRpc: r.fn, log: (...a) => logs.push(a.join(' ')) })
    assert.equal(out.status, 500); assert.deepEqual(out.body, { error: FINANCE_ERRORS.internal })
    const txt = JSON.stringify(out.body)
    for (const l of leaks) assert.ok(!txt.includes(l), l)
    assert.ok(logs.every((l) => !l.includes('select') && !l.includes('does not exist')), 'log não carrega mensagem do banco')
  }
  const thrown = await runFinanceEndpoint({ endpoint: 'overview', searchParams: sp(BASE), user: { id: 'u' }, callRpc: async () => { throw new Error('socket hang up at db.internal:5432') }, log: silent })
  assert.deepEqual(thrown, { status: 500, body: { error: FINANCE_ERRORS.internal } })
  const empty = await runFinanceEndpoint({ endpoint: 'overview', searchParams: sp(BASE), user: { id: 'u' }, callRpc: async () => ({ data: null, error: null }), log: silent })
  assert.equal(empty.status, 500)
  assert.deepEqual(mapFinanceError(undefined), { status: 500, body: { error: FINANCE_ERRORS.internal } })
})
await check('E04 sem usuário => 401 sem chamar RPC; query inválida => sem RPC', async () => {
  const r = fakeRpc(() => ({ data: {}, error: null }))
  const out = await runFinanceEndpoint({ endpoint: 'overview', searchParams: sp(BASE), user: null, callRpc: r.fn, log: silent })
  assert.equal(out.status, 401)
  const bad = await runFinanceEndpoint({ endpoint: 'overview', searchParams: sp({ ...BASE, from: '2026-13-01' }), user: { id: 'u' }, callRpc: r.fn, log: silent })
  assert.equal(bad.status, 400)
  assert.equal(r.calls.length, 0)
})
await check('E05 sucesso => 200 com o JSON da RPC; argumentos exatos', async () => {
  const data = { items: [], next_cursor: null }
  const r = fakeRpc(() => ({ data, error: null }))
  const out = await runFinanceEndpoint({ endpoint: 'cash-entries', searchParams: sp({ ...BASE, arena_id: ARENA }), user: { id: 'u' }, callRpc: r.fn, log: silent })
  assert.equal(out.status, 200); assert.equal(out.body, data)
  assert.deepEqual(r.calls, [['rg_fin_cash_entries', { p_org: ORG, p_arena: ARENA, p_from: '2026-10-01', p_to: '2026-10-15', p_limit: 50, p_after_at: null, p_after_id: null }]])
})
await check('E06 route: /api/finance com sessão do usuário, Cache-Control no-store em toda resposta, sem service-role', () => {
  const m = /async function handleFinance\([^)]*\) \{([\s\S]*?)\n\}\n/.exec(ROUTE)
  assert.ok(m, 'handleFinance')
  const body = m[1]
  const returns = body.match(/return [^\n]+/g)
  assert.ok(returns.length >= 3)
  for (const r of returns) assert.ok(r.startsWith('return jsonNoStore('), r)
  assert.ok(body.includes('getContext(request)') && body.includes('supabase.rpc(name, args)') && body.includes('runFinanceEndpoint('))
  assert.ok(!/createAdminClient|admin\.|service_role|SERVICE_ROLE/.test(body), 'sem service-role')
  assert.ok(!/error\.message|\.stack/.test(body), 'sem vazar erro')
  assert.ok(/function jsonNoStore\(data, status = 200\) \{\n  const res = json\(data, status\)\n  res\.headers\.set\('Cache-Control', 'no-store'\)/.test(ROUTE))
  assert.ok(body.includes("method !== 'GET'"), 'somente GET')
  const iFin = ROUTE.indexOf("if (resource === 'finance') return await handleFinance(request, id, sub, method)")
  assert.ok(iFin > 0 && iFin < ROUTE.indexOf("const { supabase, user } = await getContext(request)\n    if (!user)"))
  assert.ok(ROUTE.includes("import { runFinanceEndpoint } from '@/lib/reserva/finance-api'"))
})
await check('E07 finance-api sem import de Supabase/Next/service-role', () => {
  const code = stripJsComments(read('lib/reserva/finance-api.js'))
  assert.ok(!/supabase|next\/|createAdminClient|SERVICE_ROLE/i.test(code))
})

// ------------------------------------------------------------------ cliente
await check('C01 financeUrl omite vazios; fetchFinance lança FinanceRequestError com status', async () => {
  assert.equal(financeUrl('overview', { organization_id: ORG, arena_id: null, from: '2026-10-01', to: '', x: undefined }), `/api/finance/overview?organization_id=${ORG}&from=2026-10-01`)
  const calls = []
  const f403 = async (u, o) => { calls.push([u, o]); return { ok: false, status: 403, json: async () => ({}) } }
  await assert.rejects(fetchFinance('overview', { organization_id: ORG }, f403), (e) => e instanceof FinanceRequestError && e.status === 403)
  assert.equal(calls[0][1].cache, 'no-store')
  const fOk = async () => ({ ok: true, status: 200, json: async () => ({ a: 1 }) })
  assert.deepEqual(await fetchFinance('cashflow', {}, fOk), { a: 1 })
  assert.deepEqual(periodParams(ORG, null, { from: 'a', to: 'b' }), { organization_id: ORG, arena_id: null, from: 'a', to: 'b' })
  assert.equal(cashflowGranularity({ days: 31 }), 'day'); assert.equal(cashflowGranularity({ days: 62 }), 'day'); assert.equal(cashflowGranularity({ days: 92 }), 'month')
})

// ------------------------------------------------------------------ permissões / menu / RECEPTIONIST
await check('R01 canViewFinance: somente OWNER e MANAGER', () => {
  assert.equal(canViewFinance(ROLES.OWNER), true)
  assert.equal(canViewFinance(ROLES.MANAGER), true)
  for (const r of [ROLES.RECEPTIONIST, ROLES.PLATFORM_SUPER_ADMIN, undefined, null, '', 'owner', 'ADMIN']) assert.equal(canViewFinance(r), false, String(r))
  assert.equal(can(ROLES.RECEPTIONIST, FEATURES.FINANCE), false)
})
await check('R02 menu: Financeiro pronto e filtrado por canViewFinance (oculto para RECEPTIONIST)', () => {
  assert.ok(SHELL.includes("{ label: 'Financeiro', href: '/dashboard/financeiro', icon: DollarSign, feature: FEATURES.FINANCE, allow: canViewFinance, ready: true }"))
  assert.ok(SHELL.includes('NAV.filter((i) => (i.allow ? i.allow(role) : can(role, i.feature) || i.feature === FEATURES.SETTINGS_USER))'))
  // mesma regra de filtro do componente, aplicada aos três papéis
  const NAV = [{ feature: FEATURES.FINANCE, allow: canViewFinance }, { feature: FEATURES.AGENDA }, { feature: FEATURES.SETTINGS_USER }]
  const visible = (role) => NAV.filter((i) => (i.allow ? i.allow(role) : can(role, i.feature) || i.feature === FEATURES.SETTINGS_USER)).map((i) => i.feature)
  assert.ok(!visible(ROLES.RECEPTIONIST).includes(FEATURES.FINANCE))
  assert.ok(visible(ROLES.RECEPTIONIST).includes(FEATURES.AGENDA))
  assert.ok(visible(ROLES.OWNER).includes(FEATURES.FINANCE) && visible(ROLES.MANAGER).includes(FEATURES.FINANCE))
})
await check('R03 tela Financeiro: sem permissão => acesso negado ANTES de montar qualquer carga', () => {
  const m = /export default function FinanceiroPage\(\) \{([\s\S]*?)\n\}/.exec(PAGE)
  assert.ok(m)
  const body = m[1]
  const iGuard = body.indexOf('if (!canViewFinance(me?.role)) return <FinanceAccessDenied />')
  assert.ok(iGuard >= 0 && iGuard < body.indexOf('<FinanceView'))
  assert.ok(!/fetch|runLatest|useEffect/.test(body.slice(0, iGuard)), 'nenhuma carga antes do guard')
  assert.ok(PAGE.includes('if (forbidden) return <FinanceAccessDenied />') && /status === 403\) onForbidden\(\)/.test(PAGE), '403 do banco => acesso negado')
})
await check('R04 dashboard: cards financeiros e carga só com canViewFinance (RECEPTIONIST: zero chamadas)', () => {
  assert.ok(DASH.includes('const showFinance = canViewFinance(me?.role)'))
  assert.ok(/if \(!orgId \|\| !showFinance\) return\n/.test(DASH))
  assert.equal((DASH.match(/fetchFinance\(/g) || []).length, 1)
  assert.ok(DASH.indexOf('if (!orgId || !showFinance) return') < DASH.indexOf("fetchFinance('overview'"))
  assert.ok(DASH.includes("resolvePeriod('this_month', todayStr())"))
  for (const label of ['Valor das reservas (mês)', 'Ticket médio (mês)']) {
    const i = DASH.indexOf(`label="${label}"`)
    assert.ok(i > 0, label)
    assert.ok(DASH.lastIndexOf('{showFinance && (', i) > DASH.lastIndexOf(')}', i), `${label} fora do guard`)
  }
  assert.ok(!DASH.includes('Em breve'), 'placeholders removidos')
})
await check('R05 modelo RECEPTIONIST: dashboard e Financeiro não chamam /api/finance', async () => {
  // Mesma decisão dos componentes: canViewFinance(role) é o portão de toda carga financeira.
  for (const role of [ROLES.RECEPTIONIST, undefined]) {
    const calls = []
    const fetchImpl = async (u) => { calls.push(u); return { ok: true, status: 200, json: async () => ({}) } }
    if (canViewFinance(role)) await fetchFinance('overview', {}, fetchImpl)
    assert.equal(calls.length, 0)
  }
})
await check('R06 permissões financeiras individuais da reserva (03A) intactas', () => {
  const panel = read('components/reserva/finance-panel.jsx')
  assert.ok(panel.includes('const canManage = isManagerOrAbove(role)'))
  assert.ok(read('lib/auth/permissions.js').includes('export function isManagerOrAbove(role) {\n  return [ROLES.PLATFORM_SUPER_ADMIN, ROLES.OWNER, ROLES.MANAGER].includes(role)\n}'))
})

// ------------------------------------------------------------------ conteúdo da tela
// Props de um <MetricCard label="..."> até o fechamento "/>" (índice 1, como num match de regex).
function cardProps(label) {
  const i = PAGE.indexOf(`<MetricCard label="${label}"`)
  if (i < 0) return null
  return [null, PAGE.slice(i, PAGE.indexOf('/>', i))]
}
await check('U01 A receber e Inadimplência: "Situação atual" e sem comparação', () => {
  for (const label of ['A receber', 'Inadimplência']) {
    const m = cardProps(label)
    assert.ok(m, label)
    assert.ok(m[1].includes('current_situation'), `${label}: selo`)
    assert.ok(!/compare=|cmpLabel=/.test(m[1]), `${label}: sem comparação`)
  }
  assert.ok(PAGE.includes('const pct = current_situation ? null : pctChange(current, compare)'))
  assert.ok(PAGE.includes('const hasCompare = !current_situation && cmpLabel'))
  assert.ok(PAGE.includes('Situação atual'))
  for (const label of ['Valor das reservas', 'Recebido no período', 'Ticket médio', 'Reservas com valor']) {
    const m = cardProps(label)
    assert.ok(m &&m[1].includes('cmpLabel={cmpLabel}'), `${label}: comparação`)
  }
})
await check('U02 sem Despesas/Resultado/Faturamento/Saldo/Lucro nas telas da 03B.1', () => {
  for (const [f, code] of [['financeiro', PAGE], ['period-picker', PICKER], ['dashboard', DASH]]) {
    for (const bad of ['faturamento', 'saldo', 'lucro', 'resultado', 'despesa', 'saída']) assert.ok(!code.toLowerCase().includes(bad), `${f}: ${bad}`)
  }
})
await check('U03 aviso de reservas sem valor + ação para A receber filtrado em UNPRICED', () => {
  assert.ok(PAGE.includes('reservas sem valor no período não entram na receita prevista.'))
  assert.ok(PAGE.includes("const openUnpriced = () => { invalidateFinance(); setRecFilter('UNPRICED'); setTab('receivables') }"))
  assert.ok(/\{unpriced > 0 && \(/.test(PAGE))
  assert.ok(/\{d\.credits\?\.count > 0 && \(/.test(PAGE), 'créditos só com count > 0')
})
await check('U04 Caixa: "Entradas de reservas no período", pagamentos/estornos/líquido, estorno negativo', () => {
  assert.ok(PAGE.includes('Entradas de reservas no período'))
  for (const t of ['label="Pagamentos"', 'label="Estornos"', 'label="Líquido"']) assert.ok(PAGE.includes(t), t)
  assert.ok(PAGE.includes("{refund ? '-' : '+'}{formatCents(e.amount)}") && PAGE.includes("refund ? 'text-red-400'"))
  assert.ok(PAGE.includes('`-${formatCents(t.refunds)}`'))
})
await check('U05 linha de A receber abre o FinancePanel existente (sem segundo fluxo de pagamento)', () => {
  assert.ok(PAGE.includes("import { FinancePanel, PaymentStatusBadge } from '@/components/reserva/finance-panel'"))
  assert.ok(PAGE.includes('<FinancePanel reservationId={item.reservation_id} role={role} onChanged={onChanged} />'))
  assert.ok(!/payments|rg_payment|operation_id|newOperationId|method: 'POST'/.test(PAGE), 'sem escrita financeira na tela')
})
await check('U06 seletor: atalhos, arena só com mais de uma, URL ?preset / ?from&to + arena, padrão 03A.1', () => {
  assert.ok(PICKER.includes('{arenas.length > 1 && ('))
  assert.ok(PICKER.includes('applyDateInput(s.date, e.target.value)') && PICKER.includes('onBlur={() => setFrom((s) => ({ dateInput: s.date, date: s.date }))}'))
  assert.ok(PICKER.includes('disabled={!!err}') && PICKER.includes('if (!isValidCustomPeriod(from.date, to.date)) return'))
  assert.ok(PAGE.includes('const period = useMemo(() => periodFromSearch(searchParams, today), [searchParams, today])'))
  assert.ok(PAGE.includes('replaceQuery(periodToSearch(p, arenaId))') && PAGE.includes('replaceQuery(periodToSearch(period, a))'))
  assert.ok(PAGE.includes('isUuid(arenaParam) && arenas.list.some((a) => a.id === arenaParam)'), 'arena da URL validada contra a lista da organização')
})

await check('U07 mobile 390 px: totais do Caixa nunca truncados; rótulos do gráfico fora da coluna estreita', () => {
  const total = /function Total\([^)]*\) \{([\s\S]*?)\n\}/.exec(PAGE)[1]
  assert.ok(!total.includes('truncate'), 'valor do total não pode ser truncado')
  assert.ok(total.includes('whitespace-nowrap') && total.includes('sm:block'))
  assert.ok(PAGE.includes('<div className="grid gap-2 sm:grid-cols-3 sm:gap-4">'), 'totais empilhados no mobile')
  const chart = /function CashChart\([^)]*\) \{([\s\S]*?)\n\}/.exec(PAGE)[1]
  assert.ok(chart.includes("'absolute top-0 whitespace-nowrap'"), 'rótulos posicionados de forma absoluta')
  assert.ok(!/flex-1 truncate text-center/.test(chart), 'rótulos não ficam na largura da coluna')
})

// ------------------------------------------------------------------ corridas (runLatest)
await check('K01 toda carga financeira passa por runLatest; invalidação síncrona e no unmount', () => {
  const total = (PAGE.match(/fetchFinance\(/g) || []).length
  const wrapped = (PAGE.match(/runLatest\(seq\w*, \(\) => fetchFinance\(/g) || []).length
  assert.equal(total, 6); assert.equal(wrapped, total)
  assert.ok(PAGE.includes("import { createRequestSequence, runLatest } from '@/lib/reserva/latest-request'"))
  assert.ok(PAGE.includes('useEffect(() => () => { for (const s of Object.values(seqs.current)) s.invalidate() }, [])'), 'unmount')
  for (const h of ['const changePeriod = (p) => { invalidateFinance();', 'const changeArena = (a) => { invalidateFinance();', "const changeTab = (t) => { if (!TABS.includes(t) || t === tab) return; invalidateFinance();",
    'const changeFilter = (f) => { if (f === recFilter) return; seqs.current.rec.invalidate(); seqs.current.recMore.invalidate();']) assert.ok(PAGE.includes(h), h)
  assert.ok(PAGE.includes('return () => { seqMain.invalidate(); seqMore.invalidate() }'))
  assert.ok(PAGE.includes('return () => { seqFlow.invalidate(); seqEntries.invalidate(); seqMore.invalidate() }'))
  assert.ok(DASH.includes('runLatest(seq, () => fetchFinance(') && DASH.includes('return () => seq.invalidate()'))
})
await check('K02 Carregar mais com sequência própria, invalidada por toda carga principal', () => {
  assert.ok(PAGE.includes("recMore: createRequestSequence()") && PAGE.includes("entriesMore: createRequestSequence()"))
  const rec = /function ReceivablesTab[\s\S]*?\n\}\n/.exec(PAGE)[0]
  const iEff = rec.indexOf('useEffect(() => {')
  assert.ok(rec.indexOf('seqMore.invalidate()', iEff) < rec.indexOf('runLatest(seqMain', iEff), 'invalida paginação antes da nova carga')
  assert.ok(rec.includes('runLatest(seqMore, () => fetchFinance(\'receivables\', { ...base, filter, limit: PAGE_SIZE, after_start: cursor.start_at, after_id: cursor.id })'))
  assert.ok(rec.includes('}, [baseKey, filter, reload])'))
})

// Modelo da aba A receber: MESMA ligação do componente (seqMain/seqMore, invalidação síncrona
// no filtro/período, paginação invalidada a cada carga principal). As respostas são controladas.
function receivablesModel() {
  const seqMain = createRequestSequence(), seqMore = createRequestSequence()
  const s = { key: 'P1', filter: 'OPEN', items: [], cursor: null, loading: false, error: false, moreLoading: false, moreError: false, pending: [] }
  const req = (tag) => { const d = deferred(); s.pending.push({ tag, d }); return d.p }
  const loadMain = () => {
    seqMore.invalidate(); s.moreLoading = false; s.moreError = false
    const tag = `${s.key}|${s.filter}|main`
    return runLatest(seqMain, () => req(tag), {
      onStart: () => { s.items = []; s.cursor = null; s.loading = true; s.error = false },
      onResult: (d) => { s.items = d.items; s.cursor = d.next_cursor; s.loading = false },
      onError: () => { s.items = []; s.cursor = null; s.loading = false; s.error = true },
    })
  }
  const loadMore = () => {
    if (!s.cursor || s.moreLoading) return Promise.resolve()
    const tag = `${s.key}|${s.filter}|more:${s.cursor.id}`
    return runLatest(seqMore, () => req(tag), {
      onStart: () => { s.moreLoading = true; s.moreError = false },
      onResult: (d) => { s.items = [...s.items, ...d.items]; s.cursor = d.next_cursor },
      onError: () => { s.moreError = true },
      onSettled: () => { s.moreLoading = false },
    })
  }
  // Effect: cleanup (invalida as duas) e nova carga quando key/filtro mudam.
  const effect = () => { seqMain.invalidate(); seqMore.invalidate(); return loadMain() }
  const changeFilter = (f) => { if (f === s.filter) return; seqMain.invalidate(); seqMore.invalidate(); s.filter = f; return effect() }
  const changePeriod = (k) => { seqMain.invalidate(); seqMore.invalidate(); s.key = k; return effect() }
  const unmount = () => { seqMain.invalidate(); seqMore.invalidate() }
  const find = (tag) => s.pending.find((p) => p.tag === tag)
  return { s, loadMain, loadMore, changeFilter, changePeriod, unmount, find }
}
const page = (ids, next) => ({ items: ids.map((id) => ({ reservation_id: id })), next_cursor: next ? { start_at: '2026-10-05T21:00:00+00:00', id: next } : null })
const ids = (s) => s.items.map((i) => i.reservation_id)

await check('K03 troca de filtro invalida a paginação: "Carregar mais" atrasado do filtro antigo é descartado', async () => {
  const m = receivablesModel()
  m.loadMain(); m.find('P1|OPEN|main').d.resolve(page(['a1', 'a2'], 'a2')); await tick()
  assert.deepEqual(ids(m.s), ['a1', 'a2'])
  m.loadMore(); await tick(); assert.equal(m.s.moreLoading, true)
  m.changeFilter('UNPRICED'); await tick()
  assert.equal(m.s.moreLoading, false, 'loading do "mais" antigo não fica preso')
  assert.deepEqual(ids(m.s), [], 'lista antiga sai da tela')
  m.find('P1|OPEN|more:a2').d.resolve(page(['a3'], null)); await tick()
  assert.deepEqual(ids(m.s), [], 'página do filtro antigo NÃO é anexada')
  m.find('P1|UNPRICED|main').d.resolve(page(['u1'], null)); await tick()
  assert.deepEqual(ids(m.s), ['u1']); assert.equal(m.s.cursor, null)
})
await check('K04 respostas principais fora de ordem: a mais nova vence', async () => {
  const m = receivablesModel()
  m.loadMain()
  m.changePeriod('P2')
  m.changePeriod('P3')
  m.find('P3|OPEN|main').d.resolve(page(['c1'], null)); await tick()
  m.find('P1|OPEN|main').d.resolve(page(['x1'], 'x1')); await tick()
  m.find('P2|OPEN|main').d.reject(new FinanceRequestError(500)); await tick()
  assert.deepEqual(ids(m.s), ['c1']); assert.equal(m.s.error, false); assert.equal(m.s.loading, false); assert.equal(m.s.cursor, null)
})
await check('K05 "Carregar mais" atrasado após troca de período é descartado; o da página atual anexa uma vez', async () => {
  const m = receivablesModel()
  m.loadMain(); m.find('P1|OPEN|main').d.resolve(page(['a1'], 'a1')); await tick()
  m.loadMore(); m.loadMore()
  assert.equal(m.s.pending.filter((p) => p.tag.includes('more')).length, 1, 'duplo clique não duplica')
  m.changePeriod('P2'); m.find('P2|OPEN|main').d.resolve(page(['b1'], 'b1')); await tick()
  m.find('P1|OPEN|more:a1').d.resolve(page(['a2'], null)); await tick()
  assert.deepEqual(ids(m.s), ['b1'])
  m.loadMore(); m.find('P2|OPEN|more:b1').d.resolve(page(['b2'], null)); await tick()
  assert.deepEqual(ids(m.s), ['b1', 'b2']); assert.equal(m.s.cursor, null)
})
await check('K06 erro atrasado de requisição antiga não mostra erro; "mais" antigo não marca erro', async () => {
  const m = receivablesModel()
  m.loadMain(); m.find('P1|OPEN|main').d.resolve(page(['a1'], 'a1')); await tick()
  m.loadMore()
  m.changeFilter('OVERDUE'); m.find('P1|OVERDUE|main').d.resolve(page(['o1'], null)); await tick()
  m.find('P1|OPEN|more:a1').d.reject(new FinanceRequestError(500)); await tick()
  assert.equal(m.s.moreError, false); assert.equal(m.s.error, false); assert.deepEqual(ids(m.s), ['o1'])
})
await check('K07 unmount: nenhuma resposta tardia altera estado', async () => {
  const m = receivablesModel()
  m.loadMain(); m.unmount()
  m.find('P1|OPEN|main').d.resolve(page(['late'], 'late')); await tick()
  assert.deepEqual(ids(m.s), []); assert.equal(m.s.loading, true, 'estado congelado (componente desmontado)')
})
await check('K08 visão geral: troca de período/arena com respostas invertidas mantém o pedido mais novo', async () => {
  const seq = createRequestSequence()
  const st = { data: null, loading: false, error: false }
  const pend = {}
  const load = (key) => runLatest(seq, () => { const d = deferred(); pend[key] = d; return d.p }, {
    onStart: () => { st.loading = true; st.data = null }, onResult: (v) => { st.data = v; st.loading = false }, onError: () => { st.error = true; st.loading = false },
  })
  load('this_month|all'); seq.invalidate(); load('this_month|arenaB'); seq.invalidate(); load('last7|arenaB')
  pend['last7|arenaB'].resolve({ k: 'last7|arenaB' }); await tick()
  pend['this_month|all'].resolve({ k: 'this_month|all' }); pend['this_month|arenaB'].reject(new FinanceRequestError(403)); await tick()
  assert.deepEqual(st.data, { k: 'last7|arenaB' }); assert.equal(st.error, false); assert.equal(st.loading, false)
})

// ------------------------------------------------------------------ 03B.1A congelada
await check('Z01 arquivos congelados da 03B.1A intactos (SHA-256)', () => {
  const sha = (f) => createHash('sha256').update(fs.readFileSync(new URL(`../${f}`, import.meta.url))).digest('hex')
  const norm = (f) => createHash('sha256').update(read(f)).digest('hex')
  const want = {
    'supabase/migration_phase3b1_finance_overview.sql': 'fdb746907262434ec7775eddf50c37f37856664a8dab00b9e05fd69299bcb563',
    'supabase/rollback_phase3b1_finance_overview.sql': 'bb9faef4b04fefddf3dcc0510d75f4edefa95254797576621366268a024ca38a',
    'tests/phase3b1_finance_overview.sql': '32988853b9bc2d72ec8c9a0b2b6cba1f7ea09a761145ade12035dd8b98b07e32',
  }
  for (const [f, h] of Object.entries(want)) assert.ok(sha(f) === h || norm(f) === h, f)
})

const pass = results.filter((r) => r[1] === 'PASS').length
const fail = results.filter((r) => r[1] === 'FAIL').length
console.log(`\nP3B1_JS_RESULTS ${pass} PASS / ${fail} FAIL (total ${results.length})`)
process.exit(fail ? 1 : 0)
