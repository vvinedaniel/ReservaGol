// Reserva Gol — FASE 03C — testes JS (rotas, mensagens, lacunas, gates de UI, paridade de horário JS × SQL,
// contratos congelados). Uso: node tests/phase3c_recurring.test.mjs
// A paridade de horário executa a função SQL REAL no banco Docker LOCAL (rg-p3a-testdb) dentro de uma
// transação com ROLLBACK (sem resíduo). Sem Docker => esse bloco FALHA (não é pulado em silêncio).
import assert from 'node:assert/strict'
import fs from 'node:fs'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { timeToMin, closeTimeToMin, intervalEndMin } from '../lib/reserva/time.js'
import { GAP_REASONS, GAP_REASON_LABELS, gapReasonLabel, gapReasonHint, gapDateLabel, gapConflictLabel, normalizeGaps } from '../lib/reserva/recurring-gaps.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const ROUTE = read('app/api/[[...path]]/route.js')
const PAGE = read('app/dashboard/mensalistas/page.js')
const SHEET = read('components/reserva/mensalistas/month-detail-sheet.jsx')
const GAPSUI = read('components/reserva/mensalistas/series-gaps.jsx')
const AGENDA = read('app/dashboard/agenda/page.js')
const MIG = read('supabase/migration_phase3c_recurring_deterministic.sql')
const RB = read('supabase/rollback_phase3c_recurring_deterministic.sql')
const block = (src, from, to) => { const i = src.indexOf(from); const j = src.indexOf(to, i + from.length); assert.ok(i >= 0 && j > i, `bloco não encontrado: ${from}`); return src.slice(i, j) }

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}

// ---------------------------------------------------------------- rotas
await check('C01 GET /api/agenda: sem reabastecimento, sem RPC, sem escrita (leitura pura)', () => {
  const b = block(ROUTE, "if (resource === 'agenda' && method === 'GET') {", "if (resource === 'reservations') {")
  assert.ok(!/topUp|\.rpc\(|\.insert\(|\.update\(|\.upsert\(|\.delete\(/.test(b), b.slice(0, 200))
})
await check('C02 reabastecimento implícito removido do route (topUpForRead/topUpSeries/rg_recurring_generate ausentes)', () => {
  assert.ok(!/topUpForRead|topUpSeries|rg_recurring_generate/.test(ROUTE))
})
await check('C03 PATCH da série não materializa (só rg_recurring_update)', () => {
  const b = block(ROUTE, "if (method === 'PATCH' && id) {", '// POST /recurring-reservations/:id/pause')
  assert.ok(b.includes("supabase.rpc('rg_recurring_update'") && !/topUp|rg_recurring_topup|rg_recurring_generate/.test(b))
})
await check('C04 "Gerar próximas" usa rg_recurring_topup (gestor; mesma regra do job) e devolve lacunas', () => {
  const b = block(ROUTE, "if (method === 'POST' && id && sub === 'generate') {", '// POST /recurring-reservations/:id/reschedule')
  assert.ok(b.includes("supabase.rpc('rg_recurring_topup', { p_series_id: id })") && b.includes('gaps') && b.includes("forbidden: 'Somente gestores podem gerar datas'"))
})
await check('C05 GET /:id/gaps é leitura pura (RPC de leitura) e vem ANTES do detalhe genérico', () => {
  const iG = ROUTE.indexOf("if (method === 'GET' && id && sub === 'gaps') {")
  const iD = ROUTE.indexOf("if (method === 'GET' && id) {")
  assert.ok(iG > 0 && iD > iG)
  const b = block(ROUTE, "if (method === 'GET' && id && sub === 'gaps') {", "if (method === 'GET' && id) {")
  assert.ok(b.includes("supabase.rpc('rg_recurring_gaps'") && !/\.insert\(|\.update\(|rg_recurring_topup/.test(b))
})
await check('C06 conflito de horário de mensalista (hint RECURRING_SLOT) tem mensagem própria em criar/editar/bloquear', () => {
  assert.equal((ROUTE.match(/isConflict\(error\) \? conflictMsg\(error\)/g) || []).length, 3)
  assert.ok(ROUTE.includes("function conflictMsg(error) { return error?.hint === 'RECURRING_SLOT' ? SLOT_MSG : CONFLICT_MSG }"))
})
await check('C07 mensagem do horário de mensalista não expõe dados (sem nome/telefone/cliente)', () => {
  const m = /const SLOT_MSG = '([^']+)'/.exec(ROUTE)[1]
  assert.ok(!/cliente|telefone|\$\{/.test(m) && m.includes('mensalista'))
})
await check('C08 reserva pública mantém mensagem genérica de conflito (23P01 via isConflict; não revela mensalista)', () => {
  assert.ok(ROUTE.includes("if (isConflict(ins.error)) return json({ error: 'Este horário acabou de ser reservado. Escolha outro horário.' }, 409)"))
  assert.ok(/error\.code === '23P01'/.test(block(ROUTE, 'function isConflict(error) {', '}')))
})
await check('C09 reativar continua materializando na própria ação (topUpDates + RPC B3), sem reabastecimento escondido', () => {
  const b = block(ROUTE, "if (method === 'POST' && id && sub === 'reactivate') {", "if (method === 'POST' && id && sub === 'generate') {")
  assert.ok(b.includes('topUpDates(supabase, current)') && b.includes("rg_recurring_reactivate"))
})

await check('C10 cada .rpc(\'rg_recurring_*\') do route usa EXATAMENTE os parâmetros da assinatura SQL (B3 ou 03C)', () => {
  const sigs = {}
  for (const f of ['supabase/migration_security_b3.sql', 'supabase/migration_phase3c_recurring_deterministic.sql']) {
    for (const m of read(f).matchAll(/create (?:or replace )?function public\.(rg_recurring_\w+)\(([\s\S]*?)\)\s*returns/gi)) {
      sigs[m[1]] = [...m[2].matchAll(/\b(p_\w+)\s+\w/g)].map((x) => x[1]).sort()
    }
  }
  const builders = {}
  for (const b of ROUTE.matchAll(/const (\w+Args) = \(dates\) => \(\{([\s\S]*?)\}\)/g)) builders[b[1]] = [...new Set([...b[2].matchAll(/\b(p_\w+):/g)].map((x) => x[1]))].sort()
  const calls = [...ROUTE.matchAll(/\.rpc\('(rg_recurring_\w+)',\s*(\{[^}]*\}|\w+Args\([^)]*\))/g)].map((c) => ({
    fn: c[1], keys: c[2].startsWith('{') ? [...new Set([...c[2].matchAll(/\b(p_\w+):/g)].map((x) => x[1]))].sort() : builders[c[2].split('(')[0]] }))
  assert.ok(calls.length >= 9, `chamadas: ${calls.length}`)
  for (const c of calls) { assert.ok(sigs[c.fn], `RPC inexistente: ${c.fn}`); assert.deepEqual(c.keys, sigs[c.fn], c.fn) }
  for (const fn of ['rg_recurring_topup', 'rg_recurring_gaps', 'rg_recurring_create', 'rg_recurring_reschedule', 'rg_recurring_pause',
                    'rg_recurring_cancel', 'rg_recurring_reactivate', 'rg_recurring_update']) assert.ok(calls.some((c) => c.fn === fn), `route não usa ${fn}`)
  assert.ok(!calls.some((c) => c.fn === 'rg_recurring_generate'), 'route não chama mais rg_recurring_generate (mantida no banco só por compatibilidade)')
  assert.ok(sigs.rg_recurring_generate, 'rg_recurring_generate continua existindo na B3 (compatibilidade do app anterior durante o rollout)')
})

// ---------------------------------------------------------------- lib de lacunas
await check('L01 motivos e rótulos (os 3 motivos congelados)', () => {
  assert.deepEqual(GAP_REASONS, ['CONFLICT', 'OUTSIDE_BUSINESS_HOURS', 'COURT_INACTIVE'])
  for (const r of GAP_REASONS) { assert.ok(GAP_REASON_LABELS[r] && gapReasonHint(r)) }
  assert.equal(gapReasonLabel('X'), 'Data não gerada'); assert.equal(gapReasonHint('X'), null)
})
await check('L02 normalizeGaps: filtra inválidos, ordena por data, não inventa campos', () => {
  const g = normalizeGaps({ items: [
    { id: 'b', series_id: 's', occurrence_date: '2026-11-10', reason: 'CONFLICT', conflict: { start_at: '2026-11-10T22:00:00Z', end_at: '2026-11-10T23:00:00Z', status: 'CONFIRMED', recurring: false } },
    { id: 'a', series_id: 's', occurrence_date: '2026-11-03', reason: 'OUTSIDE_BUSINESS_HOURS' },
    { id: 'x', occurrence_date: '2026-11-04', reason: 'OUTRA' }, { id: 'y', occurrence_date: 'lixo', reason: 'CONFLICT' }, null] })
  assert.deepEqual(g.map((x) => x.id), ['a', 'b'])
  assert.equal(normalizeGaps(null).length, 0)
})
await check('L03 rótulos de data e da reserva que ocupa (fuso America/Sao_Paulo; só horário e tipo)', () => {
  assert.equal(gapDateLabel('2026-11-03'), '03/11'); assert.equal(gapDateLabel('x'), '—')
  assert.equal(gapConflictLabel({ start_at: '2026-11-10T22:00:00Z', end_at: '2026-11-10T23:00:00Z', status: 'CONFIRMED', recurring: false }), 'reserva avulsa 19:00–20:00')
  assert.equal(gapConflictLabel({ start_at: '2026-11-10T22:00:00Z', end_at: '2026-11-10T23:00:00Z', status: 'BLOCKED' }), 'bloqueio 19:00–20:00')
  assert.equal(gapConflictLabel({ start_at: '2026-11-10T22:00:00Z', end_at: '2026-11-10T23:00:00Z', recurring: true }), 'outro mensalista 19:00–20:00')
  assert.equal(gapConflictLabel(null), null)
})

// ---------------------------------------------------------------- UI (gates iguais ao backend)
await check('U01 Séries: "Gerar próximas" e painel de lacunas só com canViewFinance (OWNER/MANAGER = regra da RPC)', () => {
  assert.ok(PAGE.includes('canGenerate={canViewFinance(me?.role)}'))
  assert.ok(PAGE.includes('{canGenerate && <Button size="sm" variant="outline" className="h-11 sm:h-9" onClick={generateNow}'))
  assert.ok(PAGE.includes("{canGenerate && s.status === 'ACTIVE' && <SeriesGaps seriesIds={[id]} reloadKey={gapsKey} />}"))
  assert.ok(!/act\('generate'/.test(PAGE), 'gerar não passa mais pelo act genérico')
})
await check('U02 Mês: lacunas só para o gestor (D7); recepção vê só o texto genérico, sem motivo/conflito', () => {
  const b = block(SHEET, '{d.missing_future_dates.length > 0 && (', '</div>\n            )}')
  assert.ok(b.includes('{manager && (\n                  <div className="mt-2">\n                    <SeriesGaps'))
  assert.ok(b.includes("{manager ? ' Se alguma não puder ser gerada, o motivo aparece abaixo.' : ''}"))
})
await check('U03 painel de lacunas é leitura pura (GET), descarta resposta antiga e é acessível', () => {
  assert.ok(!/method:\s*'(POST|PUT|PATCH|DELETE)'/.test(GAPSUI) && GAPSUI.includes('/gaps`, { cache: \'no-store\' }'))
  assert.ok(GAPSUI.includes('if (my === seq.current)') && GAPSUI.includes('aria-live="polite"') && GAPSUI.includes('aria-label={title}'))
  assert.ok(GAPSUI.includes('motion-reduce:animate-none'))
})
await check('U04 Agenda: 409 mostra a mensagem do servidor (horário de mensalista ≠ conflito comum)', () => {
  assert.equal((AGENDA.match(/if \(res\.status === 409\) \{ const e409 = await res\.json\(\)\.catch\(\(\) => \(\{\}\)\); toast\.error\('Horário indisponível', \{ description: e409\.error \|\|/g) || []).length, 2)
})

// ---------------------------------------------------------------- paridade de horário JS × SQL (função SQL REAL)
// Predicado JS idêntico a route.js previewOccurrences (as duas linhas são verificadas literalmente).
await check('H01 route.js mantém o predicado de horário que a SQL espelha', () => {
  assert.ok(ROUTE.includes("if (!bh || bh.closed || !bh.open_time || !bh.close_time) { result.conflicts.push({ date: a, reason: 'Fora do horário de funcionamento' }); continue }"))
  assert.ok(ROUTE.includes("if (sMin < timeToMin(bh.open_time) || eMin > closeTimeToMin(bh.close_time)) { result.conflicts.push({ date: a, reason: 'Fora do horário de funcionamento' }); continue }"))
})
const jsFits = (bh, st, et) => { if (!bh || bh.closed || !bh.open_time || !bh.close_time) return false; const s = timeToMin(st), e = intervalEndMin(st, et); return !(s < timeToMin(bh.open_time) || e > closeTimeToMin(bh.close_time)) }
await check('H02 paridade JS × SQL: sem linha, dia fechado, abertura nula, limites, 00:00, meia-noite, segundos (função SQL real)', () => {
  // weekday => linha de horário (0 sem linha)
  const BH = { 1: { closed: true, open_time: '08:00', close_time: '22:00' }, 2: { closed: false, open_time: null, close_time: '22:00' },
    3: { closed: false, open_time: '08:00', close_time: '22:00' }, 4: { closed: false, open_time: '08:00', close_time: '00:00' },
    5: { closed: false, open_time: '00:00', close_time: '00:00' }, 6: { closed: false, open_time: '10:00', close_time: '10:30' } }
  const TIMES = [['08:00', '09:00'], ['07:59', '09:00'], ['21:00', '22:00'], ['21:30', '22:01'], ['23:00', '00:00'], ['23:00', '00:30'],
    ['00:00', '01:00'], ['22:00', '23:59'], ['22:00', '01:00'], ['10:00', '10:30'], ['10:00', '10:31'], ['08:00:59', '09:00:30'], ['12:00', '12:00']]
  const cases = []
  for (let w = 0; w <= 6; w++) for (const [st, et] of TIMES) cases.push({ w, st, et })
  const values = cases.map((c, i) => `(${i}, ${c.w}, '${c.st}'::time, '${c.et}'::time)`).join(',')
  const sql = `begin;
do $$ declare o uuid; a uuid; begin
  insert into public.organizations (name, is_demo) values ('P3C-PARITY', true) returning id into o;
  insert into public.arenas (organization_id, name) values (o, 'P') returning id into a;
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed) values
    (o, a, 1, '08:00', '22:00', true), (o, a, 2, null, '22:00', false), (o, a, 3, '08:00', '22:00', false),
    (o, a, 4, '08:00', '00:00', false), (o, a, 5, '00:00', '00:00', false), (o, a, 6, '10:00', '10:30', false);
  create temp table p3c_parity_arena on commit drop as select a as id;
end $$;
select c.i || ':' || private.rg_fits_business_hours((select id from p3c_parity_arena), (current_date + ((c.w - extract(dow from current_date)::int + 7) % 7))::date, c.st, c.et)
  from (values ${values}) c(i, w, st, et) order by c.i;
rollback;`
  const out = execFileSync('docker', ['exec', '-i', process.env.RG_TEST_CONTAINER || 'rg-p3a-testdb', 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'],
    { input: sql, encoding: 'utf8' })
  const sqlRes = Object.fromEntries(out.split(/\r?\n/).filter((l) => /^\d+:(true|false)$/.test(l)).map((l) => { const [i, v] = l.split(':'); return [Number(i), v === 'true'] }))
  assert.equal(Object.keys(sqlRes).length, cases.length, `SQL devolveu ${Object.keys(sqlRes).length}/${cases.length}`)
  const diverge = cases.map((c, i) => ({ ...c, js: jsFits(BH[c.w], c.st, c.et), sql: sqlRes[i] })).filter((x) => x.js !== x.sql)
  assert.equal(diverge.length, 0, JSON.stringify(diverge.slice(0, 5)))
})

// ---------------------------------------------------------------- migration / contratos congelados
await check('M01 migration 03C não agenda nada no pg_cron (sem cron.schedule)', () => {
  assert.ok(!/cron\.schedule\s*\(/.test(MIG.replace(/--[^\n]*/g, '')))
  assert.ok(MIG.includes('create extension if not exists pg_cron;'))
})
await check('M02 procedure do job: SECURITY INVOKER, sem cláusula SET, COMMIT por série, lock_timeout reaplicado', () => {
  const b = block(MIG, 'create procedure private.rg_recurring_topup_job', '-- 12) RPCs públicas')
  assert.ok(!/security definer/i.test(b.split('$$')[0]) && !/\bset search_path\b/i.test(b.split('$$')[0]))
  assert.ok((b.match(/\bcommit;/g) || []).length >= 4 && (b.match(/set_config\('lock_timeout', '5s', true\)/g) || []).length >= 2)
})
await check('M03 rollback restaura corpos originais (md5 B3) e remove tudo da 03C', () => {
  assert.ok(RB.includes("<> '8df3f54e9b70d82a568e02bd5eeb7e9d'") && RB.includes("<> '66c035d0faca110ea05a87ac7ac39b92'"))
  assert.ok(RB.includes('drop trigger validate_reservation_zz_series_slot') && RB.includes('drop table public.recurring_occurrence_gaps'))
})
await check('M04 contratos congelados intactos vs baseline fe02a54 (03B.3A migration/rollback, B3, 03A, 03B.1/2)', () => {
  const frozen = ['supabase/migration_phase3b3_recurring_month.sql', 'supabase/rollback_phase3b3_recurring_month.sql',
    'supabase/migration_security_b3.sql', 'supabase/migration_security_b3_lockdown.sql', 'supabase/migration_phase3a_foundation.sql',
    'supabase/migration_phase3b1_finance_overview.sql', 'supabase/migration_phase3b2_expenses.sql', 'lib/reserva/recurring-month-api.js']
  const out = execFileSync('git', ['diff', '--name-only', 'fe02a54', '--', ...frozen], { encoding: 'utf8' }).trim()
  assert.equal(out, '', out)
  const h = (f) => crypto.createHash('sha256').update(read(f), 'utf8').digest('hex')
  assert.equal(h('supabase/migration_phase3b3_recurring_month.sql'), '518b404830e889f71b632957590f67651421c26cc0960dfc1716f1e4bc181aa5')
  assert.equal(h('supabase/rollback_phase3b3_recurring_month.sql'), 'd8757bdbb4808e5ba3f56cc5b6d7484eb9c03f5ce1f952936e969b238635a741')
})

const fails = results.filter(([, s]) => s === 'FAIL').length
console.log(`\nP3C_JS_RESULTS ${results.length - fails} PASS / ${fails} FAIL (total ${results.length})`)
process.exit(fails ? 1 : 0)
