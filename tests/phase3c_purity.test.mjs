// Reserva Gol — FASE 03C — PUREZA REAL dos GETs (não é inspeção estática).
// Uso: node tests/phase3c_purity.test.mjs
// Executa os handlers GET REAIS de app/api/[[...path]]/route.js com um cliente Supabase GRAVADOR (hooks em
// tests/support/route-hooks.mjs). Falha se qualquer GET chamar insert/update/upsert/delete ou uma RPC fora da
// lista de leitura. Cobre: Agenda (dia e as 7 chamadas da semana), Visão Geral (as mesmas chamadas da página),
// Mensalistas (mês: lista/busca/detalhe), Séries (lista/detalhe/lacunas), disponibilidade pública, /me.
// Autoteste: um POST conhecido (bloquear horário) PRECISA ser detectado como escrita — prova que o gravador vê.
import { register } from 'node:module'
import assert from 'node:assert/strict'

register('./support/route-hooks.mjs', import.meta.url)

const U = '11111111-1111-4111-8111-111111111111'
const O = '22222222-2222-4222-8222-222222222222'
const A = '33333333-3333-4333-8333-333333333333'
const C = '44444444-4444-4444-8444-444444444444'
const S = '55555555-5555-4555-8555-555555555555'
const D = '2026-10-20'
const CANNED = {
  arenas: { id: A, organization_id: O, name: 'Arena', slug: 'arena-x', published: true, timezone: 'America/Sao_Paulo' },
  organizations: { id: O, name: 'Org', default_reservation_minutes: 60, onboarding_completed: true },
  courts: { id: C, arena_id: A, organization_id: O, name: 'Q1', active: true },
  business_hours: { id: 'bh', arena_id: A, weekday: 2, open_time: '08:00', close_time: '22:00', closed: false },
  recurring_reservations: { id: S, organization_id: O, arena_id: A, court_id: C, customer_id: null, frequency: 'WEEKLY', weekday: 2,
    day_of_month: null, start_time: '19:00', end_time: '20:00', start_date: '2026-09-01', end_date: null, has_no_end_date: true,
    status: 'ACTIVE', default_price: 10000, notes: null, is_demo: true },
  profiles: { id: U, full_name: 'Teste', is_platform_admin: false },
  organization_members: { id: 'm', role: 'OWNER', status: 'ACTIVE', organization: { id: O, name: 'Org' } },
}
const READ_RPCS = new Set(['rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail', 'rg_recurring_gaps',
  'rg_fin_overview', 'rg_fin_receivables', 'rg_fin_cashflow', 'rg_fin_cash_entries'])

const calls = []
function builder(kind, table) {
  const st = { table, single: false, write: null }
  const proxy = new Proxy(function () {}, {
    get(_, prop) {
      if (prop === 'then') {
        const data = st.write ? null : (st.single ? (CANNED[table] ?? null) : (CANNED[table] ? [CANNED[table]] : []))
        return (res, rej) => Promise.resolve({ data, error: null, count: 0 }).then(res, rej)
      }
      if (['insert', 'update', 'upsert', 'delete'].includes(prop)) {
        return () => { st.write = prop; calls.push({ type: 'write', kind, table, op: prop }); return proxy }
      }
      if (prop === 'maybeSingle' || prop === 'single') return () => { st.single = true; return proxy }
      return () => proxy
    },
  })
  return proxy
}
globalThis.__p3cRecorder = {
  client(kind) {
    return {
      from: (table) => { calls.push({ type: 'from', kind, table }); return builder(kind, table) },
      rpc: (name, args) => {
        calls.push({ type: 'rpc', kind, name })
        return Promise.resolve({ data: name === 'rg_recurring_gaps' ? { items: [] } : (name.startsWith('rg_recurring_month') ? { items: [] } : {}), error: null })
      },
      auth: { getUser: async () => ({ data: { user: { id: U } } }) },
    }
  },
}

const route = await import('../app/api/[[...path]]/route.js')

async function call(method, pathname, body) {
  const url = new URL(`http://localhost${pathname}`)
  const segs = url.pathname.replace(/^\/api\/?/, '').split('/').filter(Boolean)
  const init = { method, headers: { 'content-type': 'application/json' } }
  if (body) init.body = JSON.stringify(body)
  const res = await route[method](new Request(url, init), { params: Promise.resolve({ path: segs }) })
  return res
}
function writesIn(from) { return calls.slice(from).filter((c) => c.type === 'write' || (c.type === 'rpc' && !READ_RPCS.has(c.name))) }

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
async function pureGet(name, pathname, { expectOk = false } = {}) {
  await check(name, async () => {
    const from = calls.length
    const res = await call('GET', pathname)
    const w = writesIn(from)
    assert.equal(w.length, 0, `GET escreveu: ${JSON.stringify(w)}`)
    assert.ok(res && res.status < 500, `status ${res?.status}`)
    if (expectOk) assert.equal(res.status, 200, `status ${res.status} ${JSON.stringify(res.body).slice(0, 120)}`)
    assert.ok(calls.slice(from).some((c) => c.type === 'from' || c.type === 'rpc'), 'handler não executou leitura (teste vazio)')
  })
}

// ---------------------------------------------------------------- autoteste do gravador
await check('P00 autoteste: POST /reservations/block É detectado como escrita (o gravador enxerga mutações)', async () => {
  const from = calls.length
  await call('POST', '/api/reservations/block', { organization_id: O, arena_id: A, court_id: C, date: D, start_time: '10:00', end_time: '11:00' })
  assert.ok(writesIn(from).some((c) => c.type === 'write' && c.table === 'reservations' && c.op === 'insert'))
})
await check('P00b autoteste: POST /recurring-reservations/:id/generate é detectado como RPC mutável', async () => {
  const from = calls.length
  await call('POST', `/api/recurring-reservations/${S}/generate`, {})
  assert.ok(writesIn(from).some((c) => c.type === 'rpc' && c.name === 'rg_recurring_topup'))
})

// ---------------------------------------------------------------- Agenda
await pureGet('P01 Agenda (dia): GET /api/agenda não escreve e não chama RPC', `/api/agenda?arena_id=${A}&date=${D}`, { expectOk: true })
await check('P02 Agenda (semana): as 7 chamadas GET /api/agenda são puras', async () => {
  const from = calls.length
  for (let i = 0; i < 7; i++) {
    const d = new Date(Date.UTC(2026, 9, 19 + i)).toISOString().slice(0, 10)
    const res = await call('GET', `/api/agenda?arena_id=${A}&date=${d}`)
    assert.equal(res.status, 200)
  }
  assert.equal(writesIn(from).length, 0)
  assert.equal(calls.slice(from).filter((c) => c.type === 'rpc').length, 0, 'Agenda chamou RPC')
})
// ---------------------------------------------------------------- Visão Geral (mesmas chamadas da página)
await pureGet('P03 Visão Geral: GET /api/arenas', `/api/arenas?organization_id=${O}`)
await pureGet('P04 Visão Geral: GET /api/arenas/:id/publish-check', `/api/arenas/${A}/publish-check`)
await pureGet('P05 Visão Geral: GET /api/agenda (hoje)', `/api/agenda?arena_id=${A}&date=${D}`, { expectOk: true })
await pureGet('P06 Visão Geral: GET /api/finance/overview', `/api/finance/overview?organization_id=${O}&from=2026-10-01&to=2026-10-31`)
// ---------------------------------------------------------------- Mensalistas (mês)
await pureGet('P07 Mensalistas: GET /api/recurring-month (lista)', `/api/recurring-month?organization_id=${O}&month=2026-10`, { expectOk: true })
await pureGet('P08 Mensalistas: GET /api/recurring-month/search', `/api/recurring-month/search?organization_id=${O}&month=2026-10&q=jo`, { expectOk: true })
await pureGet('P09 Mensalistas: GET /api/recurring-month/:id (detalhe)', `/api/recurring-month/${S}?month=2026-10`, { expectOk: true })
// ---------------------------------------------------------------- Séries
await pureGet('P10 Séries: GET /api/recurring-reservations (lista)', `/api/recurring-reservations?organization_id=${O}`, { expectOk: true })
await pureGet('P11 Séries: GET /api/recurring-reservations/:id (detalhe)', `/api/recurring-reservations/${S}`, { expectOk: true })
await pureGet('P12 Séries: GET /api/recurring-reservations/:id/gaps (lacunas; só RPC de leitura)', `/api/recurring-reservations/${S}/gaps`, { expectOk: true })
// ---------------------------------------------------------------- pública e outros GETs da operação
await pureGet('P13 Pública: GET /api/public/availability', `/api/public/availability?slug=arena-x&court_id=${C}&date=${D}`)
await pureGet('P14 Pública: GET /api/public/arenas', '/api/public/arenas')
await pureGet('P15 GET /api/me', '/api/me', { expectOk: true })
await pureGet('P16 GET /api/reservations (lista)', `/api/reservations?organization_id=${O}`)
await pureGet('P17 GET /api/customers', `/api/customers?organization_id=${O}`, { expectOk: true })

await check('P18 em TODO o percurso GET, nenhuma chamada de rg_recurring_generate / rg_recurring_topup / rg_materialize', async () => {
  const getCalls = calls.filter((c) => c.type === 'rpc' && ['rg_recurring_generate', 'rg_materialize', 'rg_recurring_topup_batch'].includes(c.name))
  assert.equal(getCalls.length, 0, JSON.stringify(getCalls))
})

const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3C_PURITY_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
