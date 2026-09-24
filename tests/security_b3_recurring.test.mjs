// Reserva Gol — SECURITY HARDENING B3 — testes puros/estáticos (sem rede, sem banco).
// Uso: node tests/security_b3_recurring.test.mjs
// Cobre: gerador de operation_id, contrato route <-> RPCs (nomes de parâmetros), ausência de
// escrita direta em recurring_reservations (prontidão para o LOCKDOWN), projeção sem
// operation_request, preview fail-closed e o contrato de idempotência no frontend.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { newOperationId } from '../lib/reserva/operation-id.js'

const read = (p) => fs.readFileSync(new URL(`../${p}`, import.meta.url), 'utf8')
const exists = (p) => fs.existsSync(new URL(`../${p}`, import.meta.url))
const ROUTE = read('app/api/[[...path]]/route.js')
const LIB = read('lib/reserva/operation-id.js')
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const results = []
async function check(name, fn) {
  try { const r = await fn(); results.push([name, r === 'SKIP' ? 'SKIP' : 'PASS']); console.log(`${r === 'SKIP' ? 'SKIP' : 'PASS'}  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}

// ------------------------------------------------------------------ operation_id
await check('B3-1 newOperationId usa crypto.randomUUID quando disponível', () => {
  const fake = { randomUUID: () => '11111111-2222-4333-8444-555555555555', getRandomValues: () => { throw new Error('não deveria') } }
  assert.equal(newOperationId(fake), '11111111-2222-4333-8444-555555555555')
})
await check('B3-2 fallback getRandomValues gera UUID v4 válido (versão/variante)', () => {
  const fake = { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = 0xff; return a } }
  const id = newOperationId(fake)
  assert.match(id, UUID_V4)
  assert.equal(id, 'ffffffff-ffff-4fff-bfff-ffffffffffff')
})
await check('B3-3 sem gerador criptográfico: lança (nunca cai em Math.random)', () => {
  assert.throws(() => newOperationId({}), /criptográfico/)
  assert.throws(() => newOperationId(null), /criptográfico/) // (undefined aciona o default globalThis.crypto)
})
await check('B3-4 1000 ids reais: UUID v4 e únicos', () => {
  const s = new Set()
  for (let i = 0; i < 1000; i++) { const id = newOperationId(); assert.match(id, UUID_V4); s.add(id) }
  assert.equal(s.size, 1000)
})
await check('B3-5 helper não usa Math.random / Date.now', () => {
  const code = LIB.replace(/\/\/.*$/gm, '')
  for (const bad of ['Math.random', 'Date.now', 'performance.now']) assert.ok(!code.includes(bad), bad)
})

// ------------------------------------------------------------------ route: prontidão para o LOCKDOWN
function recurringAccesses(src) {
  const out = []
  const re = /from\(\s*['"]recurring_reservations['"]\s*\)\s*\.\s*(\w+)\(/g
  let m
  while ((m = re.exec(src))) out.push({ op: m[1], line: src.slice(0, m.index).split('\n').length })
  return out
}
await check('B3-6 route: zero INSERT/UPDATE/UPSERT/DELETE direto em recurring_reservations', () => {
  const acc = recurringAccesses(ROUTE)
  assert.ok(acc.length > 0, 'nenhum acesso encontrado (regex quebrada?)')
  const writes = acc.filter((a) => ['insert', 'update', 'upsert', 'delete'].includes(a.op))
  assert.deepEqual(writes, [], `escritas diretas: ${JSON.stringify(writes)}`)
})
await check('B3-7 app/lib/components/hooks: nenhum outro arquivo acessa recurring_reservations', () => {
  const offenders = []
  const walk = (dir) => {
    for (const e of fs.readdirSync(new URL(`../${dir}`, import.meta.url), { withFileTypes: true })) {
      const p = `${dir}/${e.name}`
      if (e.isDirectory()) walk(p)
      else if (/\.(m?js|jsx|ts|tsx)$/.test(e.name) && read(p).includes('recurring_reservations') && p !== 'app/api/[[...path]]/route.js') offenders.push(p)
    }
  }
  for (const d of ['app', 'lib', 'components', 'hooks']) if (exists(d)) walk(d)
  assert.deepEqual(offenders, [])
})
await check('B3-8 route: sem audit RECURRING_* no JS e sem materialize/cancelFutureOccurrences', () => {
  assert.ok(!/RECURRING_RESERVATION_/.test(ROUTE), 'audit de série no JS')
  assert.ok(!/function materialize\(|function cancelFutureOccurrences\(/.test(ROUTE), 'helpers de escrita antigos ainda existem')
})

// ------------------------------------------------------------------ route: projeção
const PUBLIC_20 = 'id,organization_id,arena_id,court_id,customer_id,frequency,weekday,day_of_month,start_time,end_time,start_date,end_date,has_no_end_date,status,default_price,notes,is_demo,created_by,created_at,updated_at'
await check('B3-9 projeção PÚBLICA = exatamente as 20 colunas da ETAPA 0 (sem metadados B3)', () => {
  const m = ROUTE.match(/const RECURRING_SERIES_COLUMNS = '([^']+)'/)
  assert.ok(m, 'constante ausente')
  assert.equal(m[1], PUBLIC_20)
  assert.ok(ROUTE.includes('const RECURRING_SERIES_WITH_RELATIONS = `${RECURRING_SERIES_COLUMNS}, customer:customers(id,name,phone), court:courts(id,name), arena:arenas(id,name)`'))
  assert.ok(!/operation_request/.test(ROUTE.replace(/\/\/.*$/gm, '')), 'operation_request referenciado no código')
  assert.ok(ROUTE.includes('ROUTE B3 REQUIRES FOUNDATION'))
})
await check('B3-9b projeção INTERNA B3 separada, usada só no preflight (nunca em resposta)', () => {
  const m = ROUTE.match(/const RECURRING_SERIES_B3_INTERNAL = '([^']+)'/)
  assert.ok(m, 'constante interna ausente')
  assert.deepEqual(m[1].split(','), ['id', 'operation_kind', 'previous_series_id'])
  const uses = ROUTE.split('RECURRING_SERIES_B3_INTERNAL').length - 1
  assert.equal(uses, 2, 'deve aparecer só na definição e no preflight')
  const pre = ROUTE.slice(ROUTE.indexOf('async function operationAlreadyRecorded'), ROUTE.indexOf('async function loadSeries'))
  assert.ok(pre.includes('.select(RECURRING_SERIES_B3_INTERNAL)'))
  const code = ROUTE.replace(/\/\/.*$/gm, '').replace(/const RECURRING_SERIES_B3_INTERNAL = '[^']+'/, '')
  // metadados de saída: nunca fora da projeção interna
  for (const k of ['operation_kind', 'previous_series_id']) assert.ok(!code.includes(k), `${k} aparece fora da projeção interna`)
  // nenhuma resposta json({...}) carrega metadados B3 (operation_id só existe como campo de ENTRADA)
  for (const m of code.matchAll(/json\(\{[^\n]*\}/g)) assert.ok(!/operation_(id|kind|request)|previous_series_id/.test(m[0]), `resposta com metadado B3: ${m[0].slice(0, 100)}`)
})
await check('B3-9c preflight escopado por organization_id + operation_id', () => {
  const pre = ROUTE.slice(ROUTE.indexOf('async function operationAlreadyRecorded'), ROUTE.indexOf('async function loadSeries'))
  assert.ok(/async function operationAlreadyRecorded\(db, organizationId, operationId\)/.test(pre))
  assert.ok(pre.includes(".eq('organization_id', organizationId).eq('operation_id', operationId)"))
  const calls = [...ROUTE.matchAll(/operationAlreadyRecorded\(supabase, ([^,]+), operationId\)/g)].map((m) => m[1])
  assert.ok(calls.length >= 4, `chamadas: ${calls.length}`)
  for (const org of calls) assert.ok(['opOrg', 'old.organization_id'].includes(org), `org do preflight vinda de ${org}`)
  assert.ok(!/operationAlreadyRecorded\(supabase, body\./.test(ROUTE), 'organização do preflight nunca vem do body')
})
await check('B3-10 route: nenhum select(*) / .select() implícito em recurring_reservations', () => {
  for (const a of recurringAccesses(ROUTE)) assert.equal(a.op, 'select', `linha ${a.line}: ${a.op}`)
  assert.ok(!/from\(\s*['"]recurring_reservations['"]\s*\)\s*\.select\(\s*['"`]\*/.test(ROUTE))
  assert.ok(!/from\(\s*['"]recurring_reservations['"]\s*\)\s*\.select\(\s*\)/.test(ROUTE))
})
await check('B3-11 preview é FAIL-CLOSED (erros de leitura lançam PreviewUnavailableError)', () => {
  const body = ROUTE.slice(ROUTE.indexOf('async function previewOccurrences'), ROUTE.indexOf('// ---- B3: mutações de série'))
  for (const what of ['business_hours', 'anchors', 'reservations']) assert.ok(body.includes(`throw new PreviewUnavailableError('${what}')`), what)
  assert.ok(ROUTE.includes("throw new PreviewUnavailableError('latest anchor')"))
})

// ------------------------------------------------------------------ contrato route <-> SQL (RPCs)
const FOUNDATION = 'supabase/migration_security_b3.sql'
function sqlSignatures(sql) {
  const sigs = {}
  const re = /create or replace function public\.(rg_recurring_\w+)\(([\s\S]*?)\)\s*returns/gi
  let m
  while ((m = re.exec(sql))) sigs[m[1]] = [...m[2].matchAll(/\b(p_\w+)\s+\w/g)].map((x) => x[1]).sort()
  return sigs
}
function routeRpcCalls(src) {
  const calls = []
  const builders = {}
  for (const b of src.matchAll(/const (\w+Args) = \(dates\) => \(\{([\s\S]*?)\}\)/g)) builders[b[1]] = [...new Set([...b[2].matchAll(/\b(p_\w+):/g)].map((x) => x[1]))].sort()
  for (const c of src.matchAll(/\.rpc\('(rg_recurring_\w+)',\s*(\{[^}]*\}|\w+Args\([^)]*\))/g)) {
    const keys = c[2].startsWith('{') ? [...new Set([...c[2].matchAll(/\b(p_\w+):/g)].map((x) => x[1]))].sort() : builders[c[2].split('(')[0]]
    calls.push({ fn: c[1], keys })
  }
  return calls
}
await check('B3-12 cada .rpc() do route usa EXATAMENTE os parâmetros da RPC no draft FOUNDATION', () => {
  if (!exists(FOUNDATION)) { console.log('      (draft FOUNDATION ausente neste checkout)'); return 'SKIP' }
  const sigs = sqlSignatures(read(FOUNDATION))
  assert.deepEqual(Object.keys(sigs).sort(), ['rg_recurring_cancel', 'rg_recurring_create', 'rg_recurring_generate', 'rg_recurring_pause', 'rg_recurring_reactivate', 'rg_recurring_reschedule', 'rg_recurring_update'])
  const calls = routeRpcCalls(ROUTE)
  assert.ok(calls.length >= 10, `chamadas encontradas: ${calls.length}`)
  for (const c of calls) {
    assert.ok(sigs[c.fn], `RPC inexistente: ${c.fn}`)
    assert.deepEqual(c.keys, sigs[c.fn], `${c.fn}: route ${JSON.stringify(c.keys)} x SQL ${JSON.stringify(sigs[c.fn])}`)
  }
  for (const fn of Object.keys(sigs)) assert.ok(calls.some((c) => c.fn === fn), `route não usa ${fn}`)
})
await check('B3-13 create/reschedule exigem operation_id UUID e fazem preflight ANTES do preview', () => {
  for (const [start, end] of [["if (method === 'POST' && !id) {", '// GET /recurring-reservations?'], ["sub === 'reschedule') {", 'return json({ error: `Rota']]) {
    const body = ROUTE.slice(ROUTE.indexOf(start), ROUTE.indexOf(end))
    assert.ok(body.includes('validOperationId(operationId)'), `${start}: sem validação`)
    const pre = body.indexOf('operationAlreadyRecorded(')
    const preview = body.indexOf('previewOccurrences(')
    assert.ok(pre > 0 && preview > 0 && pre < preview, `${start}: preflight deve vir antes do preview`)
    // double-click: rechecagem da chave antes de devolver needs_decision
    const nd = body.indexOf('needs_decision: true')
    assert.ok(body.lastIndexOf('operationAlreadyRecorded(', nd) > preview, `${start}: sem rechecagem antes do needs_decision`)
  }
  // reschedule: carrega e autoriza a série ANTES do preflight
  const rs = ROUTE.slice(ROUTE.indexOf("sub === 'reschedule') {"))
  assert.ok(rs.indexOf('loadSeries(supabase, id)') < rs.indexOf('operationAlreadyRecorded(') && rs.indexOf('canManageOrg(') < rs.indexOf('operationAlreadyRecorded('))
})
await check('B3-13b nenhum resolveCustomerId no fluxo de mensalista (cliente só dentro da RPC)', () => {
  const rec = ROUTE.slice(ROUTE.indexOf("if (resource === 'recurring-reservations') {"), ROUTE.indexOf('return json({ error: `Rota'))
  assert.ok(!rec.includes('resolveCustomerId('), 'resolveCustomerId no bloco recurring')
})
await check('B3-14 erros das RPCs mapeados sem vazar SQL (RGR02 = mensagem genérica 409)', () => {
  const fn = ROUTE.slice(ROUTE.indexOf('function rpcErrorResponse'), ROUTE.indexOf('function validOperationId'))
  for (const code of ['42501', 'P0002', 'RGR02', 'RGR01', '23P01', '23505', '22023', '23514', '40P01']) assert.ok(fn.includes(`'${code}'`), code)
  assert.ok(fn.includes('isTenantViolation(error)'))
  assert.ok(!/error\.message|error\.details|error\.hint/.test(fn.replace(/console\.error\([^)]*\)/g, '')), 'mensagem SQL exposta')
  assert.ok(ROUTE.includes("'Esta operação já foi utilizada com dados diferentes. Atualize e tente novamente.'"))
})

// ------------------------------------------------------------------ frontend mínimo
await check('B3-15 UI: operation_id por intenção, needs_decision explícito e replay sem contadores', () => {
  for (const [file, msg] of [['app/dashboard/mensalistas/page.js', 'Mensalista já criado'], ['app/dashboard/agenda/page.js', 'Reagendamento já aplicado']]) {
    const src = read(file)
    assert.ok(src.includes("import { newOperationId } from '@/lib/reserva/operation-id'"), `${file}: import`)
    assert.ok(/if \(!operationIdRef\.current\)[\s\S]{0,120}newOperationId\(\)/.test(src), `${file}: gera uma vez`)
    assert.ok(src.includes('operation_id: operationIdRef.current'), `${file}: envia`)
    assert.ok(src.includes('r.status === 409 && d.needs_decision'), `${file}: 409 só é decisão com needs_decision`)
    assert.ok(src.includes(`if (d.idempotent) { toast.success('${msg}')`), `${file}: replay`)
    assert.ok(!/Math\.random|Date\.now\(\)/.test(src.slice(src.indexOf('operationIdRef'))), `${file}: chave não criptográfica`)
  }
})

// ------------------------------------------------------------------ harnesses oficiais
await check('B3-16 harnesses: operation_id em todo create/reschedule + limpeza com residual no exit code', () => {
  const H = {
    'tests/phase2c_closeout.py': read('tests/phase2c_closeout.py'),
    'tests/security_a2_tenant_integrity.py': read('tests/security_a2_tenant_integrity.py'),
    'tests/security_a3_delete_history.py': read('tests/security_a3_delete_history.py'),
    'tests/security_b3_recurring_integration.py': read('tests/security_b3_recurring_integration.py'),
    'p2c_func.py': read('p2c_func.py'),
  }
  for (const [f, src] of Object.entries(H)) {
    assert.ok(/from harness_cleanup import FixtureTracker/.test(src), `${f}: sem FixtureTracker`)
    assert.ok(src.includes('atexit.register(FX.cleanup)'), `${f}: sem limpeza no atexit`)
    assert.ok(/residual == 0|FX\.cleanup\(\) != 0/.test(src), `${f}: residual fora do exit code`)
  }
  // create/reschedule via API sempre com operation_id
  // Corpo da chamada = do api('POST', ... até a próxima linha "assert" (chamadas podem ter várias linhas).
  const noOp = []
  for (const f of ['tests/phase2c_closeout.py', 'tests/security_a2_tenant_integrity.py', 'tests/security_a3_delete_history.py']) {
    const src = H[f]
    for (const m of src.matchAll(/api\('POST', f?'\/recurring-reservations(?:'|\/\{[^}]+\}\/reschedule')/g)) {
      const call = src.slice(m.index, src.indexOf('\n    assert', m.index) > 0 ? src.indexOf('\n    assert', m.index) : m.index + 600)
      const viaHelper = src.slice(Math.max(0, m.index - 250), m.index).includes("kw.setdefault('operation_id'") // 02C series()
      if (!call.includes('operation_id') && !viaHelper) noOp.push(`${f}: ${call.slice(0, 90)}`)
    }
  }
  assert.deepEqual(noOp, [])
  assert.ok(H['tests/phase2c_closeout.py'].includes("kw.setdefault('operation_id', str(uuid.uuid4()))"), '02C series() sem operation_id')
  assert.ok(/endpoint == '\/recurring-reservations' or endpoint\.endswith\('\/reschedule'\)/.test(H['p2c_func.py']), 'p2c_func sem injeção de operation_id')
  assert.ok(!/os\.environ\['TEST_ACCOUNT_EMAIL'\]/.test(H['p2c_func.py']), 'p2c_func ainda usa a conta real')
  // A2: dois modos explícitos, sem casos "falhando de propósito"
  const a2 = H['tests/security_a2_tenant_integrity.py']
  assert.ok(a2.includes("os.environ.get('B3_EXPECT_LOCKDOWN') not in ('0', '1')"), 'A2 sem modo obrigatório')
  assert.ok(a2.includes('def direct_transitional(') && !/falham de\s+propósito/.test(a2.replace('Nenhum caso "falha de propósito"', '')), 'A2 com caso falhando de propósito')
  // chamadas públicas com IP rastreável
  for (const f of ['tests/phase2c_closeout.py', 'tests/security_a2_tenant_integrity.py']) {
    for (const m of H[f].matchAll(/api\('POST', '\/public\/reserve'[^\n]*/g)) assert.ok(m[0].includes("'X-Forwarded-For': ip"), `${f}: reserva pública sem X-Forwarded-For rastreado: ${m[0]}`)
    assert.ok(H[f].includes('FX.public_reserve('), `${f}: bucket público não rastreado`)
  }
})

const passed = results.filter(([, s]) => s === 'PASS').length
const skipped = results.filter(([, s]) => s === 'SKIP').length
const failed = results.filter(([, s]) => s === 'FAIL').length
console.log(`\n== ${passed} PASS, ${skipped} SKIP, ${failed} FAIL (B3 puro/estático) ==`)
process.exit(failed ? 1 : 0)
