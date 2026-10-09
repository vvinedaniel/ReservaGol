// Reserva Gol — CLIENTES C2B — API + interface sobre as RPCs do C2A (sem rede; banco só na paridade de telefone).
// Uso: node tests/customers_c2b.test.mjs   (paridade JS×SQL usa o container local RG_TEST_CONTAINER/rg-p3a-testdb)
// Cobre: telefone canônico (espelho JS × private.rg_phone_canonical), parsers/allowlists, mapeamento de erro sem
// vazar o banco, client, runCustomersRoute/runChangeReservationCustomer com RPC falsa, e o route.js REAL com um
// cliente GRAVADOR: qual RPC cada operação usa, PUT de reserva nunca mexe no cliente, troca explícita, criação
// interna/pública pelas autoridades C2A, busca de Reservas/Séries NO BANCO, recepção sem financeiro, duplo envio,
// W1 com a regra canônica e guardas estáticas da UI (sem excluir/mesclar, finanças só gestor, sem "pago pelo cliente").
import { register } from 'node:module'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { execFileSync } from 'node:child_process'

register('./support/route-hooks.mjs', import.meta.url)
// segredo FALSO só para o HMAC do rate limiter (A6) funcionar no teste; nenhuma chamada real
process.env.SUPABASE_SECRET_KEY = process.env.SUPABASE_SECRET_KEY || 'c2b-test-only-not-a-real-key'

const { canonicalBrPhone, isCanonicalBrPhone, formatBrPhone, whatsappUrl } = await import('../lib/reserva/phone.js')
const api = await import('../lib/reserva/customers-api.js')
const { createCustomersApi, customersUrl, CustomerRequestError, CustomerNetworkError, customerErrorMessage } = await import('../lib/reserva/customers-client.js')
const { createSubmitGuard, submitWithBusy } = await import('../lib/reserva/expense-mutation.js')
const { validateNewCustomer } = await import('../lib/reserva/recurring-month.js')
const { parseLinkCustomer } = await import('../lib/reserva/recurring-month-api.js')

const U = '11111111-1111-4111-8111-111111111111'
const O = '22222222-2222-4222-8222-222222222222'
const A = '33333333-3333-4333-8333-333333333333'
const C = '44444444-4444-4444-8444-444444444444'
const K = '55555555-5555-4555-8555-555555555555' // cliente
const K2 = '66666666-6666-4666-8666-666666666666'
const R = '77777777-7777-4777-8777-777777777777' // reserva
const O2 = '88888888-8888-4888-8888-888888888888'

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}
const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8')
const sp = (o = {}) => new URLSearchParams(o)

// ================================================================ telefone
const PHONE_CASES = [
  '41999991111', '(41) 99999-1111', '+55 41 99999-1111', '5541999991111', '554133334444', '4133334444', '041999991111',
  '04133334444', '55999991111', '5533334444', ' 41 99999 1111 ', '', '   ', '123', '41899991111', '4163334444', '20999991111',
  '+1 202 555 0100', '+5541999991111', '41.99999.1111', '41-3333-4444', '419999911112', 'abc41999991111', '41 9999a1111',
  '0041999991111', '+055 41 99999-1111', '(11) 90000-0001', '11900000001', '1190000000', '99999991111', '10999991111',
  '1199999111', '٤١٩٩٩٩٩١١١١', '41\t999991111', '+', '55', '5555999991111', '555533334444', `${'4'.repeat(41)}`,
]
await check('T01 canonicalBrPhone: canônico, vazio => null, inválidos recusados (exemplos do contrato)', () => {
  assert.deepEqual(canonicalBrPhone('(41) 99999-1111'), { ok: true, value: '41999991111' })
  assert.deepEqual(canonicalBrPhone('+55 41 99999-1111'), { ok: true, value: '41999991111' })
  assert.deepEqual(canonicalBrPhone('554133334444'), { ok: true, value: '4133334444' })
  assert.deepEqual(canonicalBrPhone('55999991111'), { ok: true, value: '55999991111' }) // DDD 55 legítimo fica
  assert.deepEqual(canonicalBrPhone('041999991111'), { ok: true, value: '41999991111' })
  assert.deepEqual(canonicalBrPhone(''), { ok: true, value: null })
  assert.deepEqual(canonicalBrPhone(null), { ok: true, value: null })
  for (const bad of ['123', '41899991111', '4163334444', '20999991111', '+1 202 555 0100', 'abc41999991111', 12345]) assert.equal(canonicalBrPhone(bad).ok, false, String(bad))
})
await check('T02 formatBrPhone / whatsappUrl: só canônico vira link; legado exibido como está e sem WhatsApp', () => {
  assert.equal(formatBrPhone('41999991111'), '(41) 99999-1111')
  assert.equal(formatBrPhone('4133334444'), '(41) 3333-4444')
  assert.equal(formatBrPhone('9999'), '9999')
  assert.equal(whatsappUrl('41999991111'), 'https://wa.me/5541999991111')
  assert.equal(whatsappUrl('9999'), null)
  assert.equal(whatsappUrl(null), null)
  assert.ok(isCanonicalBrPhone('11900000001') && !isCanonicalBrPhone('1190000000'))
})
await check('T03 PARIDADE JS × SQL: canonicalBrPhone == private.rg_phone_canonical (mesmo aceito/recusado e mesmo valor)', () => {
  const lit = (s) => `'${s.replace(/'/g, "''")}'`
  const values = PHONE_CASES.map((p, i) => `(${i}, ${lit(p)})`).join(',')
  const sql = `do $$ begin perform 1; end $$;
create or replace function pg_temp.c2b_try(p text) returns text language plpgsql as $f$
begin return coalesce(private.rg_phone_canonical(p), '<null>'); exception when sqlstate '22023' then return '<invalid>'; end $f$;
select c.i || '|' || pg_temp.c2b_try(c.p) from (values ${values}) c(i, p) order by c.i;`
  const out = execFileSync('docker', ['exec', '-i', process.env.RG_TEST_CONTAINER || 'rg-p3a-testdb', 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'],
    { input: sql, encoding: 'utf8' })
  const sqlRes = Object.fromEntries(out.split(/\r?\n/).filter((l) => /^\d+\|/.test(l)).map((l) => { const [i, v] = l.split('|'); return [Number(i), v] }))
  assert.equal(Object.keys(sqlRes).length, PHONE_CASES.length, `SQL devolveu ${Object.keys(sqlRes).length}/${PHONE_CASES.length}`)
  const js = (p) => { const r = canonicalBrPhone(p); return r.ok ? (r.value ?? '<null>') : '<invalid>' }
  const diverge = PHONE_CASES.map((p, i) => ({ p, js: js(p), sql: sqlRes[i] })).filter((x) => x.js !== x.sql)
  assert.equal(diverge.length, 0, JSON.stringify(diverge))
})

// ================================================================ parsers
await check('T04 parseCustomerList: allowlist, limite 1..50 (padrão 25), filtro, cursor em par, alias legado phone', () => {
  const ok = api.parseCustomerList(sp({ organization_id: O, q: ' jo ', filter: 'MENSALISTA', limit: '10' }))
  assert.deepEqual(ok, { ok: true, rpc: 'rg_customer_list', args: { p_org: O, p_q: 'jo', p_filter: 'MENSALISTA', p_limit: 10, p_after_name: null, p_after_id: null } })
  assert.equal(api.parseCustomerList(sp({ organization_id: O })).args.p_limit, 25)
  assert.equal(api.parseCustomerList(sp({ organization_id: O, phone: '4199' })).args.p_q, '4199')
  for (const bad of [{ organization_id: 'x' }, { organization_id: O, limit: '51' }, { organization_id: O, limit: '0' }, { organization_id: O, limit: '1e1' },
    { organization_id: O, filter: 'VIP' }, { organization_id: O, after_name: 'a' }, { organization_id: O, after_name: 'a', after_id: 'x' },
    { organization_id: O, extra: '1' }, { organization_id: O, q: 'a', phone: '1' }, { organization_id: O, q: 'x'.repeat(101) }]) {
    assert.equal(api.parseCustomerList(sp(bad)).ok, false, JSON.stringify(bad))
  }
  assert.equal(api.parseCustomerList(new URLSearchParams(`organization_id=${O}&q=a&q=b`)).ok, false)
})
await check('T05 parseCustomerCreate: telefone canônico no JS, vazio => NULL, origem CUSTOMERS|RESERVATION, chaves extras recusadas', () => {
  const r = api.parseCustomerCreate({ organization_id: O, name: '  Ana   Maria ', phone: '(41) 99999-1111', email: ' A@B.CO ' })
  assert.deepEqual(r.args, { p_org: O, p_name: 'Ana Maria', p_phone: '41999991111', p_email: 'a@b.co', p_arena: null, p_origin: 'CUSTOMERS' })
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', phone: '' }).args.p_phone, null)
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', origin: 'RESERVATION' }).args.p_origin, 'RESERVATION')
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', phone: '123' }).code, 'INVALID_PHONE')
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: '' }).code, 'INVALID_NAME')
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', email: 'x' }).code, 'INVALID_EMAIL')
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', origin: 'PUBLIC' }).code, 'INVALID_ORIGIN')
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', id: K }).ok, false)
  assert.equal(api.parseCustomerCreate({ organization_id: O, name: 'Ana', finance: 1 }).ok, false)
})
await check('T06 parseCustomerUpdate: só name/phone/email/arena_id; versão obrigatória; telefone vazio => NULL', () => {
  const r = api.parseCustomerUpdate(K, { changes: { phone: '' }, expected_updated_at: '2026-10-08T10:00:00.123456+00:00' })
  assert.deepEqual(r.args, { p_customer_id: K, p_changes: { phone: null }, p_expected_updated_at: '2026-10-08T10:00:00.123456+00:00' })
  assert.equal(api.parseCustomerUpdate(K, { changes: { name: 'B' } }).ok, false)
  assert.equal(api.parseCustomerUpdate(K, { changes: {}, expected_updated_at: '2026-10-08T10:00:00Z' }).code, 'INVALID_FIELD')
  assert.equal(api.parseCustomerUpdate(K, { changes: { organization_id: O2 }, expected_updated_at: '2026-10-08T10:00:00Z' }).code, 'INVALID_FIELD')
  assert.equal(api.parseCustomerUpdate(K, { changes: { phone: '20999991111' }, expected_updated_at: '2026-10-08T10:00:00Z' }).code, 'INVALID_PHONE')
  assert.equal(api.parseCustomerUpdate(K, { changes: { name: 'B' }, expected_updated_at: 'ontem' }).code, 'STALE_UPDATE')
})
await check('T07 parseChangeCustomer: customer_id e expected_customer_id obrigatórios (expected pode ser null)', () => {
  assert.deepEqual(api.parseChangeCustomer(R, { customer_id: K, expected_customer_id: null }).args, { p_reservation_id: R, p_customer_id: K, p_expected_customer_id: null })
  assert.equal(api.parseChangeCustomer(R, { customer_id: K }).ok, false)
  assert.equal(api.parseChangeCustomer(R, { customer_id: null, expected_customer_id: null }).code, 'CUSTOMER_REQUIRED')
  assert.equal(api.parseChangeCustomer(R, { customer_id: K, expected_customer_id: 'x' }).ok, false)
  assert.equal(api.parseChangeCustomer(R, { customer_id: K, expected_customer_id: null, notes: 'x' }).ok, false)
})
await check('T08 mapCustomerError: códigos C2A => HTTP + code estável; nunca mensagem/detalhe do banco', () => {
  const leak = { message: 'SQL secreto tabela customers', details: 'detalhe interno' }
  const m = (e) => api.mapCustomerError({ ...leak, ...e })
  assert.deepEqual(m({ code: 'RGC01', details: K2 }), { status: 409, body: { error: api.CUSTOMER_REASON_MSG.PHONE_IN_USE, code: 'PHONE_IN_USE', conflict_customer_id: K2 } })
  assert.equal(m({ code: 'RGC01' }).body.conflict_customer_id, undefined)
  assert.equal(m({ code: 'RGC02' }).body.code, 'STALE_UPDATE')
  assert.equal(m({ code: 'RGC03' }).body.code, 'RECURRING_OCCURRENCE')
  assert.equal(m({ code: 'RGC04' }).body.code, 'BLOCKED_SLOT')
  assert.equal(m({ code: 'RGC05' }).body.code, 'CANCELLED_RESERVATION')
  assert.deepEqual(m({ code: '22023', hint: 'INVALID_PHONE' }).status, 400)
  assert.equal(m({ code: '22023', hint: 'INVALID_PHONE' }).body.code, 'INVALID_PHONE')
  assert.equal(m({ code: '22023', hint: 'QUALQUER' }).body.code, undefined)
  assert.equal(m({ code: '42501' }).status, 403)
  assert.equal(m({ code: 'P0002', hint: 'CUSTOMER_NOT_FOUND' }).body.code, 'CUSTOMER_NOT_FOUND')
  assert.equal(m({ code: 'P0002' }).status, 404)
  assert.equal(m({ code: '40P01' }).status, 503)
  assert.equal(m({ code: 'XX000' }).status, 500)
  for (const code of ['RGC01', 'RGC02', '22023', '42501', 'P0002', 'XX000', 'RGT02']) {
    const s = JSON.stringify(m({ code, hint: 'INVALID_PHONE' }).body)
    assert.ok(!s.includes('SQL') && !s.includes('detalhe'), s)
  }
})

// ================================================================ runCustomersRoute (RPC falsa)
function fakeRpc(impl) {
  const calls = []
  const fn = async (name, args) => { calls.push({ name, args }); return impl ? impl(name, args) : { data: {}, error: null } }
  fn.calls = calls
  return fn
}
const run = (o) => api.runCustomersRoute({ searchParams: sp(), rawBody: null, user: { id: U }, log: () => {}, ...o })
await check('T09 rotas: sem sessão 401 sem RPC; rota/ID inválidos 404; métodos fora do contrato 404 (sem DELETE/merge)', async () => {
  const rpc = fakeRpc()
  assert.equal((await run({ method: 'GET', segments: [], user: null, callRpc: rpc })).status, 401)
  assert.equal((await run({ method: 'GET', segments: ['nao-uuid'], callRpc: rpc })).status, 404)
  for (const [m, s] of [['DELETE', [K]], ['PUT', [K]], ['POST', [K]], ['POST', [K, 'merge']], ['GET', [K, 'x']], ['DELETE', []]]) {
    assert.equal((await run({ method: m, segments: s, callRpc: rpc })).status, 404, `${m} ${s}`)
  }
  assert.equal(rpc.calls.length, 0)
})
await check('T10 listagem/paginação: cursor vai para o banco (busca além de 20 = próxima página no servidor), sem filtro em JS', async () => {
  const page1 = { items: Array.from({ length: 25 }, (_, i) => ({ id: `id${i}`, name: `Cliente ${i}` })), next_cursor: { after_name: 'cliente 24', after_id: K } }
  const rpc = fakeRpc(() => ({ data: page1, error: null }))
  const r1 = await run({ method: 'GET', segments: [], searchParams: sp({ organization_id: O, q: 'cliente' }), callRpc: rpc })
  assert.equal(r1.status, 200)
  assert.equal(r1.body.items.length, 25) // devolvido como veio do banco
  await run({ method: 'GET', segments: [], searchParams: sp({ organization_id: O, q: 'cliente', after_name: 'cliente 24', after_id: K }), callRpc: rpc })
  assert.deepEqual(rpc.calls.map((c) => c.name), ['rg_customer_list', 'rg_customer_list'])
  assert.equal(rpc.calls[1].args.p_after_name, 'cliente 24')
  assert.equal(rpc.calls[1].args.p_after_id, K)
  assert.equal(rpc.calls[1].args.p_q, 'cliente')
})
await check('T11 criar: rg_customer_resolve; created=true => 201; existente (created=false, name_differs) => 200 sem renomear', async () => {
  const rpc = fakeRpc((n, a) => ({ data: a.p_phone === '41999991111' ? { customer_id: K, created: false, name_differs: true, existing: { name: 'Ana' } } : { customer_id: K2, created: true, name_differs: false, existing: null }, error: null }))
  const ex = await run({ method: 'POST', segments: [], rawBody: JSON.stringify({ organization_id: O, name: 'Outro Nome', phone: '41 99999-1111' }), callRpc: rpc })
  assert.equal(ex.status, 200)
  assert.deepEqual(ex.body, { customer_id: K, created: false, name_differs: true, existing: { name: 'Ana' } })
  const nw = await run({ method: 'POST', segments: [], rawBody: JSON.stringify({ organization_id: O, name: 'Bia', phone: '4133334444' }), callRpc: rpc })
  assert.equal(nw.status, 201)
  assert.deepEqual(rpc.calls.map((c) => c.name), ['rg_customer_resolve', 'rg_customer_resolve'])
  assert.ok(rpc.calls.every((c) => !('p_customer_id' in c.args)), 'criar nunca aponta para um cliente existente para renomear')
})
await check('T12 editar: rg_customer_update com versão; PHONE_IN_USE => 409 + id do outro; STALE => 409; inválido não chama RPC', async () => {
  const rpc = fakeRpc((n, a) => ({ data: null, error: a.p_changes.phone ? { code: 'RGC01', details: K2, message: 'x' } : { code: 'RGC02', message: 'x' } }))
  const body = (changes) => JSON.stringify({ changes, expected_updated_at: '2026-10-08T10:00:00Z' })
  const c1 = await run({ method: 'PATCH', segments: [K], rawBody: body({ phone: '41999992222' }), callRpc: rpc })
  assert.deepEqual([c1.status, c1.body.code, c1.body.conflict_customer_id], [409, 'PHONE_IN_USE', K2])
  const c2 = await run({ method: 'PATCH', segments: [K], rawBody: body({ name: 'Novo' }), callRpc: rpc })
  assert.deepEqual([c2.status, c2.body.code], [409, 'STALE_UPDATE'])
  const c3 = await run({ method: 'PATCH', segments: [K], rawBody: body({ phone: '999' }), callRpc: rpc })
  assert.deepEqual([c3.status, c3.body.code], [400, 'INVALID_PHONE'])
  assert.equal(rpc.calls.length, 2)
  assert.deepEqual(rpc.calls[0].args.p_expected_updated_at, '2026-10-08T10:00:00Z')
})
await check('T13 ficha: recepção sem financeiro — a API repassa finance:null do banco e nunca calcula/injeta valores', async () => {
  const detail = { customer: { id: K, name: 'Ana' }, upcoming: [], history: [], history_next_before: null, series: [], finance: null }
  const rpc = fakeRpc(() => ({ data: detail, error: null }))
  const r = await run({ method: 'GET', segments: [K], searchParams: sp({ history_limit: '10' }), callRpc: rpc })
  assert.equal(r.status, 200)
  assert.equal(r.body.finance, null)
  assert.deepEqual(rpc.calls[0], { name: 'rg_customer_detail', args: { p_customer_id: K, p_history_before: null, p_history_limit: 10 } })
  const src = read('lib/reserva/customers-api.js')
  assert.ok(!/rg_fin_|amount_due|net_received|fin_flag\s*=/.test(src), 'camada da API não calcula finanças')
  // lista: fin_flag vem do banco (null p/ recepção); a página só mostra a coluna para gestor
  const page = read('app/dashboard/clientes/page.js')
  assert.ok(/const manager = canViewFinance\(me\?\.role\)/.test(page) && /\{manager && <th/.test(page) && /\{manager && <td/.test(page))
})
await check('T14 isolamento de organização: org da query vai como p_org; 42501/P0002 do banco => 403/404 sem vazar', async () => {
  const rpc = fakeRpc((n, a) => ({ data: null, error: a.p_org === O2 ? { code: '42501', message: 'não membro' } : { code: 'P0002', hint: 'CUSTOMER_NOT_FOUND', message: 'x' } }))
  const r1 = await run({ method: 'GET', segments: [], searchParams: sp({ organization_id: O2 }), callRpc: rpc })
  assert.equal(r1.status, 403)
  assert.equal(rpc.calls[0].args.p_org, O2)
  const r2 = await run({ method: 'GET', segments: [K2], callRpc: rpc })
  assert.equal(r2.status, 404)
  assert.ok(!JSON.stringify([r1.body, r2.body]).includes('membro'))
})
await check('T15 troca explícita: rg_reservation_change_customer; erros C2A mapeados; idempotente (changed:false) => 200', async () => {
  const errs = { [K]: null, [K2]: { code: 'RGC03' } }
  const rpc = fakeRpc((n, a) => (errs[a.p_customer_id] ? { data: null, error: errs[a.p_customer_id] } : { data: { reservation_id: R, customer_id: a.p_customer_id, changed: false }, error: null }))
  const go = (body, extra = {}) => api.runChangeReservationCustomer({ reservationId: R, searchParams: sp(), rawBody: JSON.stringify(body), user: { id: U }, callRpc: rpc, log: () => {}, ...extra })
  const ok = await go({ customer_id: K, expected_customer_id: K })
  assert.deepEqual([ok.status, ok.body.changed], [200, false])
  const rec = await go({ customer_id: K2, expected_customer_id: K })
  assert.deepEqual([rec.status, rec.body.code], [409, 'RECURRING_OCCURRENCE'])
  assert.equal((await go({ customer_id: K })).status, 400)
  assert.equal((await go({ customer_id: K, expected_customer_id: null }, { user: null })).status, 401)
  assert.equal((await go({ customer_id: K, expected_customer_id: null }, { reservationId: 'x' })).status, 404)
  assert.deepEqual(rpc.calls.map((c) => c.name), ['rg_reservation_change_customer', 'rg_reservation_change_customer'])
})

// ================================================================ client
await check('T16 client: URLs, no-store, erros HTTP => CustomerRequestError(code, conflictCustomerId), rede => CustomerNetworkError', async () => {
  assert.equal(customersUrl(null, { organization_id: O, q: 'a', filter: null }), `/api/customers?organization_id=${O}&q=a`)
  assert.throws(() => customersUrl('../x'))
  const seen = []
  const f = async (url, init) => { seen.push([url, init]); return { ok: false, status: 409, json: async () => ({ error: 'Telefone em uso', code: 'PHONE_IN_USE', conflict_customer_id: K2 }) } }
  const c = createCustomersApi(f)
  await assert.rejects(c.update(K, { changes: { phone: '41999991111' }, expectedUpdatedAt: 'v' }), (e) => e instanceof CustomerRequestError && e.code === 'PHONE_IN_USE' && e.conflictCustomerId === K2)
  assert.equal(seen[0][1].cache, 'no-store')
  assert.equal(seen[0][1].method, 'PATCH')
  await c.list({ orgId: O, q: 'jo', cursor: { after_name: 'a', after_id: K } }).catch(() => {})
  assert.ok(seen[1][0].includes('after_name=a') && seen[1][0].includes(`after_id=${K}`) && !seen[1][0].includes('filter='))
  await c.changeReservationCustomer(R, { customerId: K, expectedCustomerId: null }).catch(() => {})
  assert.equal(seen[2][0], `/api/reservations/${R}/customer`)
  assert.deepEqual(JSON.parse(seen[2][1].body), { customer_id: K, expected_customer_id: null })
  const net = createCustomersApi(async () => { throw new Error('offline') })
  await assert.rejects(net.detail(K), (e) => e instanceof CustomerNetworkError)
  assert.equal(customerErrorMessage(new CustomerRequestError(500, null)), 'Não foi possível concluir. Tente novamente.')
})
await check('T17 chamadas duplicadas: duplo clique em "Cadastrar" com o guard => 1 única chamada; sem atualização otimista', async () => {
  let n = 0
  let release
  const c = createCustomersApi(async () => { n += 1; await new Promise((r) => { release = r }); return { ok: true, status: 201, json: async () => ({ customer_id: K, created: true }) } })
  const guard = createSubmitGuard()
  const busy = []
  const send = () => c.create({ orgId: O, name: 'Ana' })
  const p1 = submitWithBusy({ guard, setBusy: (b) => busy.push(b), send, onSuccess: () => {}, onError: () => {} })
  const p2 = await submitWithBusy({ guard, setBusy: (b) => busy.push(b), send, onSuccess: () => {}, onError: () => {} })
  assert.equal(p2, 'busy')
  release()
  assert.equal(await p1, 'ok')
  assert.equal(n, 1)
  for (const f of ['components/reserva/customers/customer-form-dialog.jsx', 'components/reserva/customers/change-customer-dialog.jsx']) {
    const s = read(f)
    assert.ok(s.includes('createSubmitGuard()') && s.includes('submitWithBusy('), f)
  }
})

// ================================================================ busca de Reservas/Séries (filtro no banco)
await check('T18 customerSearchFilter: telefone (>=4 dígitos, também sem 55) ou nome; sem curingas/sintaxe PostgREST', () => {
  assert.deepEqual(api.customerSearchFilter(null), { kind: 'none' })
  assert.deepEqual(api.customerSearchFilter('  '), { kind: 'none' })
  assert.deepEqual(api.customerSearchFilter('(41) 9999'), { kind: 'or', value: 'phone.like.*419999*' })
  assert.deepEqual(api.customerSearchFilter('+55 41 99999-1111'), { kind: 'or', value: 'phone.like.*5541999991111*,phone.like.*41999991111*' })
  assert.deepEqual(api.customerSearchFilter('João'), { kind: 'or', value: 'name.ilike.*João*' })
  assert.deepEqual(api.customerSearchFilter('a,b),phone.eq.1'), { kind: 'or', value: 'name.ilike.*a b phone.eq.1*' })
  assert.deepEqual(api.customerSearchFilter('%_*(),'), { kind: 'empty' })
  const v = api.customerSearchFilter('x*%,()"\\:').value
  assert.ok(!/[*%,()"\\:]/.test(v.slice('name.ilike.*'.length, -1)), v)
})

// ================================================================ route.js REAL com cliente gravador
const log = []
const cfg = { rpc: null, single: {}, list: {}, insertResult: {} }
function builder(kind, table) {
  const st = { kind, table, ops: [], single: false, write: null }
  log.push({ type: 'from', ...st, st })
  const proxy = new Proxy(function () {}, {
    get(_, prop) {
      if (prop === 'then') {
        let data
        if (st.write === 'insert') data = st.single ? (cfg.insertResult[table] ?? { id: 'new' }) : null
        else if (st.write) data = st.single ? (cfg.single[table] ?? null) : null
        else data = st.single ? (typeof cfg.single[table] === 'function' ? cfg.single[table](st) : (cfg.single[table] ?? null)) : (cfg.list[table] ?? [])
        return (res, rej) => Promise.resolve({ data, error: null, count: 0 }).then(res, rej)
      }
      return (...args) => {
        st.ops.push([prop, args])
        if (['insert', 'update', 'upsert', 'delete'].includes(prop)) st.write = prop
        if (prop === 'maybeSingle' || prop === 'single') st.single = true
        return proxy
      }
    },
  })
  return proxy
}
globalThis.__p3cRecorder = {
  client(kind) {
    return {
      from: (table) => builder(kind, table),
      rpc: async (name, args) => {
        log.push({ type: 'rpc', kind, name, args })
        if (name === 'consume_rate_limit') return { data: [{ allowed: true, retry_after_seconds: 0 }], error: null }
        return cfg.rpc ? cfg.rpc(kind, name, args) : { data: {}, error: null }
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
  if (body !== undefined) init.body = typeof body === 'string' ? body : JSON.stringify(body)
  return route[method](new Request(url, init), { params: Promise.resolve({ path: segs }) })
}
function reset(o = {}) { log.length = 0; cfg.rpc = o.rpc ?? null; cfg.single = o.single ?? {}; cfg.list = o.list ?? {}; cfg.insertResult = o.insertResult ?? {} }
const rpcs = () => log.filter((l) => l.type === 'rpc' && l.name !== 'consume_rate_limit')
const froms = (table) => log.filter((l) => l.type === 'from' && (!table || l.table === table))

await check('T19 route GET/POST/PATCH /api/customers: só RPCs C2A pelo client da SESSÃO (nunca service-role, nunca tabela direta)', async () => {
  reset({ rpc: (kind, name) => ({ data: name === 'rg_customer_resolve' ? { customer_id: K, created: true } : name === 'rg_customer_update' ? { changed: true, customer: {} } : { items: [], next_cursor: null }, error: null }) })
  assert.equal((await call('GET', `/api/customers?organization_id=${O}&q=ana&limit=5`)).status, 200)
  assert.equal((await call('POST', '/api/customers', { organization_id: O, name: 'Ana', phone: '41999991111' })).status, 201)
  assert.equal((await call('PATCH', `/api/customers/${K}`, { changes: { name: 'Ana B' }, expected_updated_at: '2026-10-08T10:00:00Z' })).status, 200)
  assert.deepEqual(rpcs().map((r) => `${r.kind}:${r.name}`), ['session:rg_customer_list', 'session:rg_customer_resolve', 'session:rg_customer_update'])
  assert.equal(froms('customers').length, 0)
  const res = await call('DELETE', `/api/customers/${K}`)
  assert.equal(res.status, 404)
})
await check('T20 PUT /reservations/:id com cliente => 400 USE_CHANGE_CUSTOMER e NENHUMA escrita; sem cliente => patch nunca contém customer_id', async () => {
  reset({ single: { reservations: { id: R, organization_id: O, customer_id: K, status: 'CONFIRMED', start_at: '2026-10-20T13:00:00Z', end_at: '2026-10-20T14:00:00Z', price_source: 'MANUAL' } } })
  for (const body of [{ customer: { name: 'X', phone: '41999991111' } }, { customer_id: K2 }, { customer_id: null }]) {
    log.length = 0
    const r = await call('PUT', `/api/reservations/${R}`, { notes: 'n', ...body })
    assert.equal(r.status, 400)
    assert.equal(r.body.code, 'USE_CHANGE_CUSTOMER')
    assert.equal(froms().filter((f) => f.st.write).length, 0)
    assert.equal(rpcs().length, 0)
  }
  log.length = 0
  const ok = await call('PUT', `/api/reservations/${R}`, { notes: 'nova obs', status: 'CONFIRMED', court_id: C, date: '2026-10-21', start_time: '10:00', end_time: '11:00' })
  assert.ok(ok.status < 400, `status ${ok.status}`)
  const upd = froms('reservations').find((f) => f.st.write === 'update')
  assert.ok(upd, 'update feito')
  const patch = upd.st.ops.find(([p]) => p === 'update')[1][0]
  assert.ok(!('customer_id' in patch) && !('customer' in patch), JSON.stringify(patch))
  assert.equal(froms('customers').length, 0)
})
await check('T21 POST /reservations/:id/customer: rg_reservation_change_customer (sessão); CANCELLED/BLOCKED mapeados', async () => {
  reset({ rpc: (kind, name, a) => (a.p_customer_id === K2 ? { data: null, error: { code: 'RGC05' } } : { data: { reservation_id: R, customer_id: K, changed: true }, error: null }) })
  const ok = await call('POST', `/api/reservations/${R}/customer`, { customer_id: K, expected_customer_id: null })
  assert.deepEqual([ok.status, ok.body.changed], [200, true])
  const bad = await call('POST', `/api/reservations/${R}/customer`, { customer_id: K2, expected_customer_id: K })
  assert.deepEqual([bad.status, bad.body.code], [409, 'CANCELLED_RESERVATION'])
  assert.equal((await call('GET', `/api/reservations/${R}/customer`)).status, 404)
  assert.deepEqual(rpcs().map((r) => `${r.kind}:${r.name}`), ['session:rg_reservation_change_customer', 'session:rg_reservation_change_customer'])
  assert.deepEqual(rpcs()[0].args, { p_reservation_id: R, p_customer_id: K, p_expected_customer_id: null })
})
const resBody = (extra) => ({ organization_id: O, arena_id: A, court_id: C, date: '2026-10-21', start_time: '10:00', end_time: '11:00', ...extra })
await check('T22 POST /reservations (reserva interna): dados => rg_customer_resolve origem RESERVATION; existente => aviso, nunca renomeia', async () => {
  reset({ rpc: () => ({ data: { customer_id: K, created: false, name_differs: true, existing: { name: 'Ana Original' } }, error: null }), insertResult: { reservations: { id: R, customer_id: K } } })
  const r = await call('POST', '/api/reservations', resBody({ customer: { name: 'Outro Nome', phone: '(41) 99999-1111', email: '' } }))
  assert.equal(r.status, 201)
  assert.deepEqual(r.body.customer_notice, { code: 'EXISTING_CUSTOMER', existing_name: 'Ana Original' })
  assert.deepEqual(rpcs()[0], { type: 'rpc', kind: 'session', name: 'rg_customer_resolve', args: { p_org: O, p_name: 'Outro Nome', p_phone: '41999991111', p_email: null, p_arena: A, p_origin: 'RESERVATION' } })
  const ins = froms('reservations').find((f) => f.st.write === 'insert').st.ops.find(([p]) => p === 'insert')[1][0]
  assert.equal(ins.customer_id, K)
  assert.equal(froms('customers').length, 0, 'nada de insert/update direto em customers')
})
await check('T23 POST /reservations: customer_id escolhido => sem RPC; telefone inválido => 400 sem RPC e sem reserva; ambos => 400', async () => {
  reset({ insertResult: { reservations: { id: R } } })
  assert.equal((await call('POST', '/api/reservations', resBody({ customer_id: K }))).status, 201)
  assert.equal(rpcs().length, 0)
  assert.equal(froms('reservations').find((f) => f.st.write === 'insert').st.ops.find(([p]) => p === 'insert')[1][0].customer_id, K)
  reset()
  const bad = await call('POST', '/api/reservations', resBody({ customer: { name: 'Ana', phone: '20 99999-1111' } }))
  assert.deepEqual([bad.status, bad.body.code], [400, 'INVALID_PHONE'])
  assert.equal(rpcs().length + froms('reservations').length, 0)
  assert.equal((await call('POST', '/api/reservations', resBody({ customer_id: K, customer: { name: 'A' } }))).status, 400)
  reset({ rpc: () => ({ data: null, error: { code: '22023', hint: 'INVALID_PHONE', message: 'segredo' } }) })
  const dbBad = await call('POST', '/api/reservations', resBody({ customer: { name: 'Ana', phone: '41999991111' } }))
  assert.deepEqual([dbBad.status, dbBad.body.code], [400, 'INVALID_PHONE'])
  assert.equal(froms('reservations').length, 0)
  assert.ok(!JSON.stringify(dbBad.body).includes('segredo'))
})
await check('T24 busca de Reservas: filtro no BANCO antes do limit (embed !inner + .or em customer); termo inútil => [] sem consulta', async () => {
  reset({ list: { reservations: [{ id: R }] } })
  const r = await call('GET', `/api/reservations?organization_id=${O}&q=${encodeURIComponent('Ana Maria')}`)
  assert.equal(r.status, 200)
  const q = froms('reservations')[0].st.ops
  assert.ok(q.find(([p, a]) => p === 'select' && a[0].includes('customer:customers!inner(')), 'embed !inner')
  assert.deepEqual(q.find(([p]) => p === 'or')[1], ['name.ilike.*Ana Maria*', { referencedTable: 'customer' }])
  reset()
  const p = await call('GET', `/api/reservations?organization_id=${O}&q=4199`)
  assert.equal(p.status, 200)
  assert.deepEqual(froms('reservations')[0].st.ops.find(([op]) => op === 'or')[1][0], 'phone.like.*4199*')
  reset()
  const e = await call('GET', `/api/reservations?organization_id=${O}&q=${encodeURIComponent('%*,')}`)
  assert.deepEqual([e.status, e.body], [200, []])
  assert.equal(froms('reservations').length, 0)
  reset()
  await call('GET', `/api/reservations?organization_id=${O}`)
  const plain = froms('reservations')[0].st.ops
  assert.ok(!plain.some(([op]) => op === 'or') && plain.find(([op]) => op === 'select')[1][0].includes('customer:customers(id'), 'sem busca: embed normal (reservas sem cliente continuam)')
  const src = read('app/api/[[...path]]/route.js')
  assert.ok(!/\.filter\(\s*\(?r\)?\s*=>[^\n]*customer\?\.name/.test(src), 'sem filtro de nome em JS sobre a amostra')
})
await check('T25 busca de Séries: filtro no BANCO (customers!inner + .or em customer) para nome e telefone', async () => {
  reset({ list: { recurring_reservations: [] } })
  assert.equal((await call('GET', `/api/recurring-reservations?organization_id=${O}&q=joao`)).status, 200)
  const q = froms('recurring_reservations')[0].st.ops
  assert.ok(q.find(([p, a]) => p === 'select' && a[0].includes('customer:customers!inner(')))
  assert.deepEqual(q.find(([p]) => p === 'or')[1], ['name.ilike.*joao*', { referencedTable: 'customer' }])
})
function todayPlus(n) {
  const d = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
  const t = new Date(`${d}T12:00:00Z`); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10)
}
const PUB_ARENA = { id: A, organization_id: O, slug: 'arena-x', name: 'Arena', active: true, public_booking_enabled: true }
const pubBody = (extra) => ({ slug: 'arena-x', court_id: C, date: todayPlus(2), start_time: '10:00', end_time: '11:00', name: 'Cliente Web', phone: '(41) 99999-1111', email: '', accept_terms: true, ...extra })
const pubSingles = () => ({ arenas: PUB_ARENA, courts: { id: C }, business_hours: { open_time: '08:00', close_time: '22:00', closed: false }, organizations: { default_reservation_minutes: 60 } })
await check('T26 reserva pública: rg_customer_resolve_public SÓ pelo admin (server-only), telefone canônico, sem tocar customers direto', async () => {
  reset({ single: pubSingles(), rpc: (kind, name) => ({ data: name === 'rg_customer_resolve_public' ? { customer_id: K, created: false, name_differs: true } : {}, error: null }), insertResult: { reservations: { public_code: 'ok' } } })
  const r = await call('POST', '/api/public/reserve', pubBody())
  assert.equal(r.status, 201, JSON.stringify(r.body))
  const res = rpcs()
  assert.deepEqual(res.map((x) => `${x.kind}:${x.name}`), ['admin:rg_customer_resolve_public'])
  assert.deepEqual(res[0].args, { p_org: O, p_arena: A, p_name: 'Cliente Web', p_phone: '41999991111', p_email: null })
  assert.equal(froms('customers').length, 0)
  assert.ok(!('name_differs' in r.body) && !('customer_id' in r.body), 'resposta pública não revela cadastro existente')
  assert.equal(froms('reservations').find((f) => f.st.write === 'insert').st.ops.find(([p]) => p === 'insert')[1][0].customer_id, K)
  // nenhuma chave de serviço chega ao browser: só o route (servidor) importa o admin client
  for (const f of ['lib/reserva/customers-client.js', 'components/reserva/customers/customer-form-dialog.jsx', 'app/dashboard/clientes/page.js']) assert.ok(!/supabase\/admin|SERVICE_ROLE|SECRET_KEY/.test(read(f)), f)
})
await check('T27 reserva pública: telefone fora da regra => 400 ANTES de rate limit/RPC; erro do resolve => sem reserva', async () => {
  reset({ single: pubSingles() })
  const bad = await call('POST', '/api/public/reserve', pubBody({ phone: '(20) 99999-1111' }))
  assert.equal(bad.status, 400)
  assert.equal(log.filter((l) => l.type === 'rpc').length, 0, 'nem rate limit nem resolve')
  reset({ single: pubSingles(), rpc: () => ({ data: null, error: { code: '22023', hint: 'INVALID_NAME', message: 'x' } }) })
  assert.equal((await call('POST', '/api/public/reserve', pubBody())).status, 400)
  assert.equal(froms('reservations').filter((f) => f.st.write === 'insert').length, 0)
  reset({ single: pubSingles(), rpc: () => ({ data: null, error: { code: '42501', message: 'segredo' } }) })
  const down = await call('POST', '/api/public/reserve', pubBody())
  assert.equal(down.status, 503)
  assert.ok(!JSON.stringify(down.body).includes('segredo'))
  assert.equal(froms('reservations').filter((f) => f.st.write === 'insert').length, 0)
  assert.ok(log.some((l) => l.type === 'rpc' && l.name === 'consume_rate_limit'), 'rate limit (A6) continua antes do cliente')
})

// ================================================================ W1 / mensalistas
await check('T28 W1: formulário usa a regra canônica; parser congelado (03B.3) segue repassando ao banco, que canonicaliza (decisão A)', () => {
  assert.deepEqual(validateNewCustomer({ name: 'Ana', phone: '(11) 99000-0001' }), { ok: true, value: { name: 'Ana', phone: '11990000001' } })
  assert.deepEqual(validateNewCustomer({ name: 'Ana', phone: '' }), { ok: true, value: { name: 'Ana', phone: null } })
  assert.equal(validateNewCustomer({ name: 'Ana', phone: '20999991111' }).ok, false)
  const p = parseLinkCustomer(K, { customer: { name: 'Ana', phone: '+55 (41) 99999-1111' }, month: '2026-10' })
  if (p.ok) assert.equal(p.rpc, 'rg_recurring_link_customer')
  const dialog = read('components/reserva/mensalistas/link-customer-dialog.jsx')
  assert.ok(dialog.includes('&q=${encodeURIComponent(digits)}&limit=10') && dialog.includes('d?.items'), 'busca do W1 usa a API nova (servidor)')
})

// ================================================================ UI (guardas estáticas)
await check('T29 UI: Clientes ativo no menu; sem excluir/mesclar/inativar/tags; estados de carregamento, vazio e erro', () => {
  assert.ok(/label: 'Clientes'[^\n]*ready: true/.test(read('components/reserva/dashboard-shell.jsx')))
  const files = ['app/dashboard/clientes/page.js', 'components/reserva/customers/customer-detail-sheet.jsx', 'components/reserva/customers/customer-form-dialog.jsx', 'components/reserva/customers/change-customer-dialog.jsx']
  for (const f of files) {
    const s = read(f)
    assert.ok(!/Excluir|Mesclar|Inativar|method: 'DELETE'|\btags?\b/i.test(s.replace(/\/\/[^\n]*/g, '')), f)
    assert.ok(!/pago pelo cliente/i.test(s.replace(/\/\/[^\n]*/g, '')), `${f}: nunca "pago pelo cliente"`)
  }
  const page = read(files[0])
  assert.ok(page.includes('aria-busy') && page.includes('EmptyState') && page.includes('Tentar novamente') && page.includes('Carregar mais'))
})
await check('T30 UI ficha: financeiro só quando o banco devolve (gestor); rótulos de reservas vinculadas; série linka Mensalistas', () => {
  const s = read('components/reserva/customers/customer-detail-sheet.jsx')
  assert.ok(/\{fin && \(/.test(s))
  for (const l of ['Esperado nas reservas', 'Recebido nas reservas', 'Em aberto', 'Vencido', 'não identificam quem pagou']) assert.ok(s.includes(l), l)
  assert.ok(s.includes('/dashboard/mensalistas?l='))
  assert.ok(s.includes('history_next_before') && s.includes('Carregar mais'))
  assert.ok(s.includes('whatsappUrl(') && s.includes('rel="noopener noreferrer"'))
})
await check('T31 UI Agenda: editar reserva nunca envia cliente; "Trocar cliente" só em avulsa ativa; sugestão via API nova', () => {
  const s = read('app/dashboard/agenda/page.js')
  assert.ok(s.includes('...(edit ? {} : pickedId ? { customer_id: pickedId } : { customer: {'))
  assert.ok(/res\.status !== 'BLOCKED' && !isRecurring && <Button[^\n]*setChangeCustomer\(true\)/.test(s))
  assert.ok(/\{res\.status !== 'CANCELLED' && \(/.test(s), 'ações (inclui Trocar cliente) só fora de canceladas')
  assert.ok(s.includes('customersApi.current.list({ orgId, q: digits, limit: 5 })') && !s.includes('/api/customers?'))
  assert.ok(s.includes("saved.customer_notice?.code === 'EXISTING_CUSTOMER'"))
  const form = read('components/reserva/customers/customer-form-dialog.jsx')
  assert.ok(form.includes('expectedUpdatedAt: customer.updated_at') && form.includes("'PHONE_IN_USE'") && form.includes("'STALE_UPDATE'"))
  assert.ok(form.includes('res?.created === false') && !/api\.update\([^)]*\)[^\n]*created === false/.test(form), 'existente abre o cadastro, sem update')
})

const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nC2B_JS_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
