// Reserva Gol — FASE 03A — testes puros/estáticos do financeiro (sem rede, sem banco).
// Uso: node tests/phase3a_finance.test.mjs
// Cobre: money.js (centavos sem float), prévia de períodos (só visual), contrato route <-> RPCs,
// ausência de escrita financeira direta, grants/owners/search_path das migrations, ordem dos
// triggers, B3 inalterada, UI com UM POST por faixa (split atômico no banco) e harnesses.
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { parseMoneyToCents, formatCents, centsToInput, toCents, MAX_CENTS } from '../lib/reserva/money.js'
import { previewRulePeriods, localInputToISO, nowLocalInput, PAYMENT_METHODS, PRICE_REASONS, normalizeFinanceNotes, NOTES_MAX_CHARS } from '../lib/reserva/finance.js'
import { invalidateIntentOnChange } from '../lib/reserva/intent.js'
import { RESERVATION_STATUSES, CREATE_STATUSES, EDIT_STATUSES } from '../lib/reserva/status.js'

const read = (p) => fs.readFileSync(new URL(`../${p}`, import.meta.url), 'utf8')
const exists = (p) => fs.existsSync(new URL(`../${p}`, import.meta.url))
const stripSqlComments = (s) => s.replace(/--.*$/gm, '')
const stripJsComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
const ROUTE = read('app/api/[[...path]]/route.js')
const FOUNDATION_RAW = read('supabase/migration_phase3a_foundation.sql')
const FOUNDATION = stripSqlComments(FOUNDATION_RAW)
const GUARDS = stripSqlComments(read('supabase/migration_phase3a_guards.sql'))
const results = []
async function check(name, fn) {
  try { const r = await fn(); results.push([name, r === 'SKIP' ? 'SKIP' : 'PASS']); console.log(`${r === 'SKIP' ? 'SKIP' : 'PASS'}  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}

// ------------------------------------------------------------------ money.js
await check('P3A-1 parseMoneyToCents: formatos definidos (150 / 150,00 / 150.00 / 1.500,00 ...)', () => {
  const ok = { '150': 15000, '150,00': 15000, '150.00': 15000, '1.500,00': 150000, '1.500': 150000, '1,500.00': 150000, '150,5': 15050,
    '150.5': 15050, '0': 0, '0,01': 1, 'R$ 99,90': 9990, '  220,00  ': 22000, '1.234.567': null, '100.000,00': MAX_CENTS, '007': 700 }
  for (const [input, want] of Object.entries(ok)) assert.equal(parseMoneyToCents(input), want, input)
})
await check('P3A-2 parseMoneyToCents: inválidos falham (nunca aproxima)', () => {
  for (const bad of ['', ' ', 'abc', '-10', '12,345', '1.50.0', '1.5000', '1,50,00', '10,', ',50', '1e3', '100.000,01', '150,0,0', '1.500.00,00', 'R$', '15 0'])
    assert.equal(parseMoneyToCents(bad), null, JSON.stringify(bad))
  for (const bad of [null, undefined, 150, 150.5, {}, []]) assert.equal(parseMoneyToCents(bad), null, String(bad))
})
await check('P3A-3 formatCents / centsToInput só com inteiros e ida-e-volta exata', () => {
  assert.equal(formatCents(22000), 'R$ 220,00')
  assert.equal(formatCents(150000), 'R$ 1.500,00')
  assert.equal(formatCents(5), 'R$ 0,05')
  assert.equal(formatCents(-1234), '-R$ 12,34')
  assert.equal(formatCents(null), null)
  assert.equal(formatCents(1.5), null)
  assert.equal(centsToInput(15050), '150,50')
  assert.equal(toCents('22000'), 22000)
  for (let c = 0; c <= 200000; c += 37) assert.equal(parseMoneyToCents(centsToInput(c)), c, String(c))
})
await check('P3A-4 money.js sem parseFloat / toFixed / * 100 / Math.round', () => {
  const code = stripJsComments(read('lib/reserva/money.js'))
  for (const bad of ['parseFloat', 'toFixed', '* 100', '*100', 'Math.round', 'Number(input']) assert.ok(!code.includes(bad), bad)
})
await check('P3A-5 código monetário da UI sem parseFloat / toFixed / * 100', () => {
  for (const f of ['components/reserva/finance-panel.jsx', 'components/reserva/pricing-rules-sheet.jsx', 'app/dashboard/mensalistas/page.js', 'lib/reserva/finance.js']) {
    const code = stripJsComments(read(f))
    for (const bad of ['parseFloat', 'toFixed(', '* 100', 'Math.round(']) assert.ok(!code.includes(bad), `${f}: ${bad}`)
  }
})

// ------------------------------------------------------------------ finance.js (prévia visual)
await check('P3A-6 previewRulePeriods: 22->02 = 2 períodos consecutivos; 22->00 e 00->02 = 1', () => {
  assert.deepEqual(previewRulePeriods({ weekday: 5, start_time: '22:00', end_time: '02:00' }),
    [{ weekday: 5, start_time: '22:00', end_time: '00:00' }, { weekday: 6, start_time: '00:00', end_time: '02:00' }])
  assert.deepEqual(previewRulePeriods({ weekday: 6, start_time: '23:00', end_time: '01:00' })[1].weekday, 0)
  assert.equal(previewRulePeriods({ weekday: 3, start_time: '22:00', end_time: '00:00' }).length, 1)
  assert.equal(previewRulePeriods({ weekday: 4, start_time: '00:00', end_time: '02:00' }).length, 1)
  assert.equal(previewRulePeriods({ weekday: 4, start_time: '00:00', end_time: '00:00' }).length, 1)
  assert.equal(previewRulePeriods({ weekday: 1, start_time: '10:00', end_time: '10:00' }), null)
  assert.equal(previewRulePeriods({ weekday: 7, start_time: '10:00', end_time: '11:00' }), null)
})
await check('P3A-7 datas locais: nowLocalInput / localInputToISO (offset fixo -03:00)', () => {
  assert.match(nowLocalInput(), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/)
  assert.equal(nowLocalInput(new Date('2026-09-26T13:05:00Z')), '2026-09-26T10:05')
  assert.equal(localInputToISO('2026-10-02T18:30'), '2026-10-02T18:30:00-03:00')
  assert.equal(localInputToISO('2026-10-02 18:30'), null)
})
await check('P3A-8 status: PAID fora de todas as listas selecionáveis (D15)', () => {
  for (const list of [RESERVATION_STATUSES, CREATE_STATUSES, EDIT_STATUSES]) assert.ok(!list.includes('PAID'))
  assert.deepEqual(CREATE_STATUSES, ['PENDING', 'CONFIRMED'])
})

// ------------------------------------------------------------------ route
function sqlParams(sql, fn) {
  const m = sql.match(new RegExp(`create or replace function public\\.${fn}\\(([\\s\\S]*?)\\)\\s*returns`, 'i'))
  if (!m) return null
  return m[1].split(',').map((p) => p.trim().split(/\s+/)[0]).filter(Boolean).sort()
}
const P3A_RPCS = ['rg_price_quote', 'rg_pricing_rule_create', 'rg_pricing_rule_update', 'rg_pricing_rule_deactivate', 'rg_payment_register',
  'rg_payment_refund', 'rg_payment_void', 'rg_reservation_set_price', 'rg_reservation_financial_detail', 'rg_reservation_financial_summaries']
await check('P3A-9 cada .rpc() 03A do route usa EXATAMENTE os parâmetros da RPC na FOUNDATION', () => {
  const calls = [...ROUTE.matchAll(/\.rpc\('(rg_(?:price|pricing|payment|reservation)_\w+)',\s*\{([\s\S]*?)\}\)/g)]
  assert.ok(calls.length >= 10, `chamadas: ${calls.length}`)
  for (const [, fn, body] of calls) {
    const want = sqlParams(FOUNDATION, fn)
    assert.ok(want, `RPC inexistente na migration: ${fn}`)
    const got = [...body.matchAll(/\b(p_\w+)\s*:/g)].map((m) => m[1]).sort()
    assert.deepEqual(got, want, fn)
  }
  for (const fn of P3A_RPCS) assert.ok(calls.some((c) => c[1] === fn), `route não usa ${fn}`)
})
await check('P3A-10 nenhuma RPC financeira recebe organization_id do cliente', () => {
  for (const [, , body] of ROUTE.matchAll(/\.rpc\('(rg_(?:price|pricing|payment|reservation)_\w+)',\s*\{([\s\S]*?)\}\)/g)) assert.ok(!/organization/.test(body), body)
  for (const fn of P3A_RPCS) assert.ok(!(sqlParams(FOUNDATION, fn) || []).some((p) => /organization/.test(p)), fn)
})
await check('P3A-11 sem escrita direta em reservation_payments / court_pricing_rules (app/lib/components)', () => {
  const offenders = []
  const walk = (dir) => {
    for (const e of fs.readdirSync(new URL(`../${dir}`, import.meta.url), { withFileTypes: true })) {
      const p = `${dir}/${e.name}`
      if (e.isDirectory()) walk(p)
      else if (/\.(m?js|jsx|ts|tsx)$/.test(e.name) && /from\(\s*['"](reservation_payments|court_pricing_rules)['"]\s*\)\s*\.\s*(insert|update|upsert|delete)\(/.test(read(p))) offenders.push(p)
    }
  }
  for (const d of ['app', 'lib', 'components', 'hooks']) if (exists(d)) walk(d)
  assert.deepEqual(offenders, [])
})
await check('P3A-12 route: price nunca vem do cliente; status com allowlist sem PAID', () => {
  assert.ok(!/patch\.price\s*=/.test(ROUTE), 'PUT ainda grava price')
  assert.ok(/if \(body\.price !== undefined\) return json\(\{ error: 'O valor da reserva é alterado/.test(ROUTE), 'PUT não recusa price')
  assert.ok(/if \(body\.price !== undefined\) return json\(\{ error: 'O valor da reserva é definido/.test(ROUTE), 'POST não recusa price')
  assert.ok(/CREATE_STATUSES\.includes\(status\)/.test(ROUTE) && /EDIT_STATUSES\.includes\(body\.status\)/.test(ROUTE))
  assert.ok(!/status: body\.status \|\| 'CONFIRMED'/.test(ROUTE), 'status livre no INSERT')
})
await check('P3A-13 route: handlers financeiros antes dos genéricos PUT/POST de /reservations', () => {
  const generic = ROUTE.indexOf("if (id && method === 'PUT') {")
  for (const marker of ["id === 'financial-summaries' && method === 'POST'", "sub === 'financials' && method === 'GET'", "sub === 'payments' && method === 'POST'", "sub === 'price' && method === 'PUT'"])
    assert.ok(ROUTE.indexOf(marker) > 0 && ROUTE.indexOf(marker) < generic, marker)
})
await check('P3A-14 erros financeiros mapeados sem vazar texto interno (code + hint)', () => {
  const fn = ROUTE.slice(ROUTE.indexOf('function financeErrorResponse'), ROUTE.indexOf('function validCents'))
  assert.ok(fn.length > 100 && !/error\.message|error\.details/.test(fn), 'mensagem interna repassada')
  for (const code of ['RGP01', 'RGP02', 'RGP03', '23P01', '42501', 'P0002']) assert.ok(fn.includes(`'${code}'`), code)
  const hints = [...FOUNDATION.matchAll(/hint = '(\w+)'/g)].map((m) => m[1])
  for (const h of new Set(hints)) assert.ok(new RegExp(`\\b${h}:`).test(ROUTE), `hint sem mensagem: ${h}`)
  assert.deepEqual(PAYMENT_METHODS, ['PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER'])
  assert.ok(PRICE_REASONS.every((r) => FOUNDATION.includes(`'${r}'`)), 'motivos divergentes do banco')
})

// ------------------------------------------------------------------ migrations
const fnBlocks = (sql, schema) => [...sql.matchAll(new RegExp(`create or replace function ${schema}\\.(\\w+)\\(([\\s\\S]*?)\\)\\s*returns[\\s\\S]*?\\$\\$`, 'gi'))]
await check('P3A-15 RPCs públicas: SECURITY DEFINER + search_path vazio + owner postgres + REVOKE/GRANT corretos', () => {
  const blocks = fnBlocks(FOUNDATION, 'public')
  assert.deepEqual(blocks.map((b) => b[1]).sort(), [...P3A_RPCS].sort())
  for (const [header, name] of blocks) {
    assert.ok(/security definer set search_path = ''/.test(header), `${name}: definer/search_path`)
    assert.ok(new RegExp(`alter function public\\.${name}\\([^)]*\\) owner to postgres;`).test(FOUNDATION), `${name}: owner`)
    assert.ok(new RegExp(`revoke all on function public\\.${name}\\([^)]*\\) from public, anon, service_role;`).test(FOUNDATION), `${name}: revoke`)
    assert.ok(new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated;`).test(FOUNDATION), `${name}: grant`)
    assert.ok(FOUNDATION.indexOf(`revoke all on function public.${name}(`) < FOUNDATION.indexOf(`grant execute on function public.${name}(`), `${name}: REVOKE antes do GRANT`)
  }
})
await check('P3A-16 funções private.*: search_path vazio, owner postgres, sem EXECUTE para anon/authenticated/service_role', () => {
  const blocks = fnBlocks(FOUNDATION, 'private')
  assert.ok(blocks.length >= 12, `funções: ${blocks.length}`)
  for (const [header, name] of blocks) {
    assert.ok(/set search_path = ''/.test(header), `${name}: search_path`)
    assert.ok(new RegExp(`alter function private\\.${name}\\([^)]*\\) owner to postgres;`).test(FOUNDATION), `${name}: owner`)
    assert.ok(new RegExp(`revoke all on function private\\.${name}\\([^)]*\\) from public, anon, authenticated, service_role;`).test(FOUNDATION), `${name}: revoke`)
    assert.ok(!new RegExp(`grant execute on function private\\.${name}`).test(FOUNDATION), `${name}: grant indevido`)
  }
})
await check('P3A-17 snapshot SECURITY DEFINER; guard SECURITY INVOKER com default-deny de price', () => {
  assert.ok(/function private\.enforce_reservation_price_snapshot\(\)\s*returns trigger language plpgsql security definer set search_path = ''/.test(FOUNDATION))
  assert.ok(/function private\.enforce_reservation_price_guard\(\)\s*returns trigger language plpgsql set search_path = ''/.test(GUARDS), 'guard não é INVOKER')
  assert.ok(!/enforce_reservation_price_guard\(\)\s*returns trigger language plpgsql security definer/.test(GUARDS))
  assert.ok(GUARDS.includes("new.price is distinct from old.price and current_user <> 'postgres'"), 'UPDATE de price não é default-deny')
  assert.ok(GUARDS.includes("current_user in ('authenticated', 'anon') and new.price is not null"), 'INSERT comum com price')
  assert.ok(GUARDS.includes("new.status = 'PAID' and old.status is distinct from 'PAID'"), 'transição para PAID')
  assert.ok(/alter function private\.enforce_reservation_price_guard\(\) owner to postgres;/.test(GUARDS))
  assert.ok(/revoke all on function private\.enforce_reservation_price_guard\(\) from public, anon, authenticated, service_role;/.test(GUARDS))
  assert.ok(!/enforce_reservation_price_guard/.test(FOUNDATION), 'guard não pode estar na FOUNDATION')
})
await check('P3A-18 guard: INSERT recorrente retorna ANTES de qualquer checagem (D7 continua autoridade)', () => {
  const body = GUARDS.slice(GUARDS.indexOf('create or replace function private.enforce_reservation_price_guard'))
  const ins = body.indexOf("if tg_op = 'INSERT' then")
  const rec = body.indexOf('if new.recurring_reservation_id is not null then', ins)
  const ret = body.indexOf('return new;', rec)
  assert.ok(ins > 0 && rec > ins && ret > rec && ret < body.indexOf('new.price is not null', ins) && ret < body.indexOf("new.status = 'PAID'", ins))
  const snap = FOUNDATION.slice(FOUNDATION.indexOf('function private.enforce_reservation_price_snapshot'))
  assert.ok(/if new\.recurring_reservation_id is not null or new\.status = 'BLOCKED' or new\.price is not null then\s*return new;/.test(snap))
})
await check('P3A-19 ordem dos BEFORE triggers: tenant < guard < snapshot < validate_* (D7 por último)', () => {
  const names = ['enforce_reservation_tenant', 'enforce_reservation_zz_price_guard', 'enforce_reservation_zz_price_snapshot', 'validate_reservation_recurring', 'validate_reservation_zz_series_occurrence']
  assert.deepEqual([...names].sort(), names)
  assert.ok(FOUNDATION.includes('create trigger enforce_reservation_zz_price_snapshot before insert on public.reservations'))
  assert.ok(GUARDS.includes('create trigger enforce_reservation_zz_price_guard before insert or update on public.reservations'))
})
await check('P3A-20 tabelas: RLS, REVOKE ALL (anon/authenticated/service_role) e fingerprint fora do SELECT', () => {
  for (const t of ['court_pricing_rules', 'reservation_payments']) {
    assert.ok(FOUNDATION.includes(`alter table public.${t} enable row level security;`), `${t}: RLS`)
    assert.ok(FOUNDATION.includes(`revoke all on table public.${t} from public, anon, authenticated, service_role;`), `${t}: revoke`)
    assert.ok(!new RegExp(`grant (insert|update|delete|all)[^;]*on (table )?public\\.${t} to authenticated`).test(FOUNDATION), `${t}: escrita para authenticated`)
    assert.ok(!new RegExp(`to anon`).test(FOUNDATION.slice(FOUNDATION.indexOf(`revoke all on table public.${t}`))), `${t}: grant para anon`)
  }
  const sel = FOUNDATION.match(/grant select \(([^)]*)\)\s*on public\.reservation_payments to authenticated;/)
  assert.ok(sel && !sel[1].includes('operation_fingerprint') && sel[1].includes('amount'), 'SELECT por coluna do ledger')
  assert.ok(/for select to authenticated\s*using \(\(select private\.is_org_manager\(organization_id/.test(FOUNDATION), 'ledger não é só OWNER/MANAGER')
  assert.ok(!/create (or replace )?view/i.test(FOUNDATION), 'view financeira pública')
})
await check('P3A-21 ledger: amount > 0, sinal pelo kind, refund_of só em REFUND, DELETE só em org demo', () => {
  assert.ok(FOUNDATION.includes('check (amount between 1 and 10000000)'))
  assert.ok(FOUNDATION.includes("check ((kind = 'REFUND') = (refund_of is not null))"))
  assert.ok(FOUNDATION.includes("v_parent.kind <> 'PAYMENT'") && FOUNDATION.includes("hint = 'OVER_REFUNDABLE'"))
  assert.ok(/guard_finance_delete[\s\S]*?not o\.is_demo/.test(FOUNDATION))
  assert.ok(FOUNDATION.includes("new.received_at > now() + interval '5 minutes'") && !/received_at\s*<\s*now\(\)\s*-/.test(FOUNDATION), 'sem limite inferior')
})
await check('P3A-22 idempotência: ordem D9 (trava -> replay/RGP02 -> estado mutável) e fingerprint SHA-256', () => {
  for (const fn of ['rg_payment_register', 'rg_payment_refund']) {
    const body = FOUNDATION.slice(FOUNDATION.indexOf(`create or replace function public.${fn}(`))
    const end = body.indexOf('end $$;')
    const b = body.slice(0, end)
    const lock = b.indexOf('private.rg_fin_lock_reservation(')
    const replay = b.indexOf('operation_fingerprint = v_fp')
    const state = Math.min(...['v_res.status not in', 'v_pay.kind <>'].map((s) => (b.indexOf(s) < 0 ? Infinity : b.indexOf(s))))
    const insert = b.indexOf('insert into public.reservation_payments')
    assert.ok(lock > 0 && replay > lock && state > replay && insert > state, `${fn}: ordem ${lock} ${replay} ${state} ${insert}`)
  }
  assert.ok(FOUNDATION.includes('pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object('))
  for (const k of ["'kind'", "'reservation_id'", "'refund_of'", "'amount'", "'method'", "'received_at'", "'notes'"]) assert.ok(FOUNDATION.includes(k), k)
})
await check('P3A-23 criação MULTI-DAY ATÔMICA: vários dias + split na MESMA RPC; UM audit; 4 pontos de falha', () => {
  const body = FOUNDATION.slice(FOUNDATION.indexOf('create or replace function public.rg_pricing_rule_create('))
  const b = body.slice(0, body.indexOf('end $$;'))
  assert.ok(/p_weekdays smallint\[\]/.test(b) && !/p_weekday smallint,/.test(b), 'assinatura sem smallint[]')
  assert.ok(b.includes('foreach v_wd in array v_days loop'), 'sem laço dos dias dentro da transação')
  assert.equal((b.match(/insert into public\.court_pricing_rules/g) || []).length, 2, 'linha do dia + metade do dia seguinte')
  assert.equal((b.match(/insert into public\.audit_logs/g) || []).length, 1, 'um audit por intenção')
  for (const f of ['after_first_insert', 'midway', 'after_all_inserts', 'after_audit']) assert.ok(b.includes(`private.rg_fault('pricing_create:${f}')`), f)
  assert.ok(b.indexOf("pricing_create:after_all_inserts") > b.indexOf('end loop;'), 'after_all_inserts fora do fim do laço')
  assert.ok(b.includes('((v_wd + 1) % 7)::smallint') && /v_split := v_e <> 0 and v_e < v_s;/.test(b))
  assert.ok(b.includes("'rule_ids', to_jsonb(v_ids), 'weekdays', to_jsonb(v_days), 'split', v_split") && b.includes("'rules_created', cardinality(v_ids)"))
  for (const k of ["'arena_id'", "'court_id'", "'weekdays'", "'start_time'", "'end_time'", "'price_per_hour'", "'valid_from'", "'valid_until'", "'split'", "'rule_ids'", "'rules_created'"])
    assert.ok(b.slice(b.indexOf('insert into public.audit_logs')).includes(k), `audit sem ${k}`)
  const upd = FOUNDATION.slice(FOUNDATION.indexOf('create or replace function public.rg_pricing_rule_update('))
  const u = upd.slice(0, upd.indexOf('end $$;'))
  assert.ok(u.includes('private.rg_pricing_validate(') && !/p_weekdays/.test(u), 'UPDATE deve continuar editando UMA linha')
  assert.ok(FOUNDATION_RAW.includes('drop function if exists public.rg_pricing_rule_create(uuid, uuid, smallint, time, time, integer, date, date);'), 'overload antigo')
})
await check('P3A-23b weekdays validados no banco: 1..7, sem NULL, 0..6, SEM duplicados (22023), ordem determinística', () => {
  const b = FOUNDATION.slice(FOUNDATION.indexOf('create or replace function public.rg_pricing_rule_create('))
  assert.ok(b.includes('coalesce(cardinality(p_weekdays), 0) < 1 or cardinality(p_weekdays) > 7'))
  assert.ok(b.includes('array_position(p_weekdays, null) is not null'))
  assert.ok(b.includes('where d < 0 or d > 6'))
  assert.ok(b.includes('(select count(distinct d) from unnest(p_weekdays) as d) <> cardinality(p_weekdays)'), 'duplicados não rejeitados')
  assert.ok(b.includes('select array_agg(d order by d) into v_days'), 'ordem não normalizada')
  const route = ROUTE.slice(ROUTE.indexOf("if (resource === 'pricing-rules')"))
  assert.ok(route.includes('new Set(wds).size !== wds.length') && route.includes('wds.length > 7') && route.includes('p_weekdays: wds'), 'route sem validação/repasse de weekdays')
})
await check('P3A-24 UI de preços: EXATAMENTE UM POST por criação (todos os dias), sem laço de requisições', () => {
  const ui = stripJsComments(read('components/reserva/pricing-rules-sheet.jsx'))
  assert.equal((ui.match(/jsonReq\('\/api\/pricing-rules',/g) || []).length, 1)
  const submit = ui.slice(ui.indexOf('async function submit()'), ui.indexOf('return (', ui.indexOf('async function submit()')))
  const post = submit.slice(submit.indexOf("jsonReq('/api/pricing-rules',"))
  assert.ok(post.includes('weekdays: days') && post.includes('start_time: f.start') && post.includes('end_time: f.end'), 'POST não envia a intenção original')
  assert.ok(!/\bfor\s*\(|\.forEach\(|\.map\(\s*async|Promise\.all/.test(submit), 'submit com laço de requisições')
  assert.ok(!/expandRuleDrafts/.test(ui + read('lib/reserva/finance.js')), 'helper antigo de split ainda existe')
})
await check('P3A-25 SQL sem SQL dinâmico e sem tipo float/numeric para dinheiro', () => {
  const fixes = ['migration_phase3a_fix1_void_reason_visibility', 'migration_phase3a_fix2_price_origin', 'rollback_phase3a_fix1_void_reason_visibility', 'rollback_phase3a_fix2_price_origin']
    .map((f) => [f, stripSqlComments(read(`supabase/${f}.sql`))])
  for (const [name, sql] of [['foundation', FOUNDATION], ['guards', GUARDS], ...fixes]) {
    assert.ok(!/\bexecute\s+(format|'|\w+\s*\|\|)/i.test(sql), `${name}: SQL dinâmico`)
    assert.ok(!/\b(float4|float8|double precision|real|money)\b/i.test(sql) && !/::numeric\b/.test(sql), `${name}: float`)
  }
})
await check('P3A-26 B3 intocada (migrations B3 idênticas à base)', () => {
  try {
    execFileSync('git', ['diff', '--quiet', '3b4d4ca7aec83556d3509fd294e78562a9ffc8ca', '--', 'supabase/migration_security_b3.sql', 'supabase/migration_security_b3_lockdown.sql'],
      { cwd: fileURLToPath(new URL('..', import.meta.url)), stdio: 'ignore' })
  } catch (e) {
    if (e.status === 1) throw new Error('migrations B3 alteradas')
    return 'SKIP'
  }
  assert.ok(!/rg_recurring_|recurring_reservations/.test(FOUNDATION.replace(/recurring_reservation_id/g, '')), 'FOUNDATION toca objetos B3')
})

// ------------------------------------------------------------------ harnesses
await check('P3A-27 harness_cleanup: tabelas novas, ordem das FKs e tolerância antes da FOUNDATION', () => {
  const h = read('tests/harness_cleanup.py')
  assert.ok(/ORG_TABLES = \['reservation_payments', 'court_pricing_rules'/.test(h))
  assert.ok(h.includes("OPTIONAL_TABLES = {'reservation_payments', 'court_pricing_rules'}") && h.includes('if s == 404 and table in OPTIONAL_TABLES'))
  const refund = h.indexOf('reservation_payments?organization_id={flt}&kind=eq.REFUND')
  const pays = h.indexOf("reservation_payments?organization_id={flt}', 'return=minimal'")
  const rules = h.indexOf('court_pricing_rules?organization_id={flt}')
  const res = h.indexOf("/rest/v1/reservations?organization_id={flt}'")
  assert.ok(refund > 0 && pays > refund && rules > pays && res > rules, 'ordem de limpeza')
})
await check('P3A-28 harness de integração 03A: modo obrigatório, escrita explícita e residual no exit code', () => {
  const h = read('tests/phase3a_finance_integration.py')
  assert.ok(/from harness_cleanup import FixtureTracker/.test(h) && h.includes('atexit.register(FX.cleanup)') && h.includes('FX.cleanup() != 0'))
  assert.ok(h.includes("os.environ.get('P3A_ALLOW_WRITE') != '1'") && h.includes("os.environ.get('P3A_EXPECT_GUARDS') not in ('0', '1')"))
  assert.ok(h.includes("'X-Forwarded-For': ip") && h.includes('FX.public_reserve('), 'reserva pública sem IP rastreado')
  const sql = read('tests/phase3a_finance_rollback.sql')
  assert.ok(sql.includes('P3A_ROLLBACK_RESULTS') && /\nrollback;\s*$/.test(sql), 'rollback SQL sem desfazer tudo')
  // cenários multi-day obrigatórios presentes no rollback SQL (executado só na fase controlada)
  for (const t of ["'Y01 weekdays [1,2,3,4] 18:00–22:00'", "'Y02 weekdays [1,2,3,4] 22:00 -> 02:00'", "'Y07 conflito só na 2ª metade do ÚLTIMO dia cross-midnight => 23P01'",
    "'pricing_create:after_first_insert'", "'pricing_create:midway'", "'pricing_create:after_all_inserts'", "'pricing_create:after_audit'",
    "'Y11 exatamente UM audit", "'Y13 weekdays duplicados => 22023'", "'Y14 weekdays vazio => 22023'", "'Y15 weekday 7 => 22023'"])
    assert.ok(sql.includes(t), `rollback SQL sem ${t}`)
  assert.ok(/INTERMEDIÁRIO/.test(sql) && /PRIMEIRO/.test(sql) && /ÚLTIMO/.test(sql), 'conflitos primeiro/intermediário/último')
  assert.ok(!/p3_rule_sql\('[^']*', (null|'[^']*'), \d+,/.test(sql), 'chamada de regra com weekday escalar')
  assert.ok(h.includes("'weekdays': wds") && h.includes('def t02b_multiday_atomic'), 'harness sem multi-day')
})

// ------------------------------------------------------------------ notes (PAYMENT/REFUND) — nunca truncada
await check('P3A-29 normalizeFinanceNotes espelha private.rg_fin_notes: trim, vazio => NULL, máx. 500, sem truncar', () => {
  assert.equal(NOTES_MAX_CHARS, 500)
  const x500 = 'x'.repeat(500)
  assert.deepEqual(normalizeFinanceNotes(x500), { ok: true, value: x500 }, '500 caracteres')
  assert.deepEqual(normalizeFinanceNotes(`   ${x500}   `), { ok: true, value: x500 }, '500 após trim')
  assert.equal(normalizeFinanceNotes('x'.repeat(501)).ok, false, '501 caracteres')
  assert.equal(normalizeFinanceNotes('😀'.repeat(500)).ok, true, '500 code points (char_length), não unidades UTF-16')
  assert.equal(normalizeFinanceNotes('😀'.repeat(501)).ok, false)
  for (const blank of ['', ' ', '     ']) assert.deepEqual(normalizeFinanceNotes(blank), { ok: true, value: null }, JSON.stringify(blank))
  for (const none of [undefined, null]) assert.deepEqual(normalizeFinanceNotes(none), { ok: true, value: null })
  assert.deepEqual(normalizeFinanceNotes('  nota  '), { ok: true, value: 'nota' })
  for (const bad of [0, 123, 1.5, true, false, {}, { a: 1 }, [], ['a']]) assert.equal(normalizeFinanceNotes(bad).ok, false, `tipo ${JSON.stringify(bad)}`)
  // mesmos 500 primeiros caracteres, sufixos diferentes: AMBAS inválidas (nunca a mesma intenção normalizada)
  const a = normalizeFinanceNotes(`${'y'.repeat(500)}A`)
  const b = normalizeFinanceNotes(`${'y'.repeat(500)}B`)
  assert.ok(!a.ok && !b.ok && a.value === null && b.value === null, 'prefixo de 500 aceito')
  const db = FOUNDATION.slice(FOUNDATION.indexOf('create or replace function private.rg_fin_notes'))
  assert.ok(db.includes("nullif(btrim(p_notes), '')") && db.includes('char_length(v) > 500'), 'regra do banco mudou: realinhar a API')
})
await check('P3A-30 route: PAYMENT e REFUND validam notes (400) e enviam o valor normalizado; sem slice/cleanNotes', () => {
  assert.ok(!/cleanNotes|\.slice\(0,\s*500\)/.test(ROUTE), 'truncamento silencioso ainda existe')
  for (const [marker, fn] of [["sub === 'payments' && method === 'POST'", 'rg_payment_register'], ["sub === 'refund' && method === 'POST'", 'rg_payment_refund']]) {
    const block = ROUTE.slice(ROUTE.indexOf(marker), ROUTE.indexOf(`.rpc('${fn}'`, ROUTE.indexOf(marker)) + 400)
    assert.ok(block.includes('const notes = normalizeFinanceNotes(body.notes)'), `${fn}: sem normalização`)
    assert.ok(/if \(!notes\.ok\) return json\(\{ error: `[^`]*` \}, 400\)/.test(block), `${fn}: inválida não vira 400`)
    assert.ok(block.indexOf('if (!notes.ok)') < block.indexOf(`.rpc('${fn}'`), `${fn}: validação depois da RPC`)
    assert.ok(block.includes('p_notes: notes.value') && !/p_notes: body\.notes/.test(block), `${fn}: RPC não recebe o valor normalizado`)
  }
})

// ------------------------------------------------------------------ B3 na UI: operation_id muda quando a intenção muda
await check('P3A-31 invalidateIntentOnChange: campo alterado descarta a chave; retry/valor igual mantém', () => {
  const ref = { current: 'op-A' }
  const form = { court_id: 'c1', start_time: '20:00', price: '180,00' }
  assert.equal(invalidateIntentOnChange(form, 'start_time', '20:00', ref), false, 'mesmo valor não é outra intenção')
  assert.equal(ref.current, 'op-A', 'retry sem edição mantém a chave')
  assert.equal(invalidateIntentOnChange(form, 'price', '150,00', ref), true)
  assert.equal(ref.current, null, 'edição não descartou a chave')
  ref.current = 'op-B'
  assert.equal(invalidateIntentOnChange(form, 'court_id', 'c2', ref), true)
  assert.equal(ref.current, null)
  // modelo do RescheduleDialog: needs_decision da intenção A, depois edição => nem chave nem conflitos de A
  const dialog = { key: { current: 'op-A' }, conflicts: [{ date: '2026-10-09' }], form: { start_time: '20:00' } }
  const set = (k, v) => { if (invalidateIntentOnChange(dialog.form, k, v, dialog.key)) dialog.conflicts = null; dialog.form = { ...dialog.form, [k]: v } }
  set('start_time', '20:00')
  assert.ok(dialog.key.current === 'op-A' && dialog.conflicts?.length === 1, 'retry sem alteração perdeu chave/decisão')
  set('start_time', '21:00')
  assert.ok(dialog.key.current === null && dialog.conflicts === null, 'intenção B herdou chave/conflitos de A')
  const button = dialog.conflicts ? 'apply(true)' : 'apply(false)'
  assert.equal(button, 'apply(false)', 'intenção B não volta pelo caminho normal')
})
await check('P3A-32 CreateDialog e RescheduleDialog: set() invalida a chave (e conflitos); catch de rede mantém a chave', () => {
  const lf = (p) => read(p).replace(/\r\n/g, '\n')
  const blockOf = (src, header) => { const i = src.indexOf(header); assert.ok(i >= 0, header); return src.slice(i, src.indexOf('\n  }\n', i) + 4) }
  const men = stripJsComments(lf('app/dashboard/mensalistas/page.js'))
  const create = men.slice(men.indexOf('function CreateDialog('), men.indexOf('function DetailSheet('))
  const cSet = blockOf(create, 'const set = (k, v) => {')
  assert.ok(cSet.indexOf('invalidateIntentOnChange(f, k, v, operationIdRef)') >= 0 && cSet.indexOf('invalidateIntentOnChange') < cSet.indexOf('setF('), 'CreateDialog: set não invalida antes de atualizar')
  assert.ok(/set\('price', centsToInput\(d\.price\)\)/.test(create), '"Usar tabela" não passa pelo mesmo helper')
  assert.ok(!/setF\(\(s\) => \(\{ \.\.\.s, \[k\]: v \}\)\)/.test(create.replace(cSet, '')), 'CreateDialog: outro caminho altera o formulário sem invalidar')
  const ag = stripJsComments(lf('app/dashboard/agenda/page.js'))
  const resch = ag.slice(ag.indexOf('function RescheduleDialog('))
  const rSet = blockOf(resch, 'const set = (k, v) => {')
  assert.ok(rSet.includes('if (invalidateIntentOnChange(f, k, v, operationIdRef)) setConflicts(null)'), 'RescheduleDialog: set não limpa chave/conflitos')
  assert.ok(rSet.indexOf('setConflicts(null)') < rSet.indexOf('setF('), 'RescheduleDialog: conflitos limpos depois')
  assert.ok(/\{conflicts \? \([\s\S]*?apply\(true\)[\s\S]*?\) : \([\s\S]*?apply\(false\)/.test(resch), 'botão não depende de conflicts')
  for (const [src, header] of [[create, 'async function create(skip_conflicts)'], [resch, 'async function apply(skip)']]) {
    const body = src.slice(src.indexOf(header), src.indexOf('} finally {', src.indexOf(header)))
    const catchBlock = body.slice(body.indexOf('} catch {'))
    assert.ok(!/operationIdRef\.current\s*=|invalidateIntentOnChange/.test(catchBlock), `${header}: falha de rede descarta a chave`)
    assert.ok(body.includes('if (!operationIdRef.current)'), `${header}: chave não é reaproveitada no retry`)
  }
  for (const f of ['app/dashboard/mensalistas/page.js', 'app/dashboard/agenda/page.js']) assert.ok(read(f).includes("import { invalidateIntentOnChange } from '@/lib/reserva/intent'"), f)
})
await check('P3A-33 regras de preço: desativar pede confirmação e trata falha de rede', () => {
  const ui = stripJsComments(read('components/reserva/pricing-rules-sheet.jsx').replace(/\r\n/g, '\n'))
  assert.ok(ui.includes('onClick={() => setConfirming(r)}') && !ui.includes('onClick={() => deactivate(r)}'), 'ícone desativa direto')
  assert.ok(ui.includes('Desativar esta regra de preço?') && ui.includes('Ela não poderá ser reativada'), 'texto de confirmação')
  const fn = ui.slice(ui.indexOf('async function deactivate(rule)'), ui.indexOf('const byDay'))
  assert.ok(/try \{[\s\S]*await jsonReq[\s\S]*\} catch \{\s*toast\.error\(/.test(fn) && fn.includes('} finally { setDeactivating(false) }'), 'falha de rede sem toast')
})

// ------------------------------------------------------------------ FIX1 / FIX2 (revisão final do PR #12)
const lfRead = (p) => read(p).replace(/\r\n/g, '\n')
const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest('hex')
const FIX1 = stripSqlComments(lfRead('supabase/migration_phase3a_fix1_void_reason_visibility.sql'))
const FIX2 = stripSqlComments(lfRead('supabase/migration_phase3a_fix2_price_origin.sql'))
const origBlock = (name) => { const s = FOUNDATION_RAW.replace(/\r\n/g, '\n'); const i = s.indexOf(`create or replace function ${name}(`); return s.slice(i, s.indexOf('end $$;', i) + 'end $$;'.length) }
await check('P3A-34 FIX1: motivo/autor da anulação só para OWNER/MANAGER, no banco; rollback restaura a FOUNDATION', () => {
  assert.equal((FIX1.match(/create or replace function/g) || []).length, 1, 'FIX1 deve redefinir só o detalhe')
  assert.ok(/create or replace function public\.rg_reservation_financial_detail\(p_reservation_id uuid\)\s*returns jsonb language plpgsql security definer set search_path = ''/.test(FIX1))
  assert.ok(FIX1.includes('v_manager := private.is_org_manager(v_org, v_uid);'), 'sem checagem de gerente')
  assert.ok(FIX1.includes("if v_org is null or not private.is_org_member(v_org, v_uid) then"), 'tenant isolation')
  const base = FIX1.slice(FIX1.indexOf('jsonb_build_object(\n             \'id\''), FIX1.indexOf('|| case when v_manager'))
  assert.ok(base.includes("'voided_at', p.voided_at") && !/void_reason|voided_by/.test(base), 'objeto base expõe dados internos')
  assert.ok(FIX1.includes("|| case when v_manager then jsonb_build_object('voided_by', p.voided_by, 'void_reason', p.void_reason)\n                   else '{}'::jsonb end"))
  assert.ok(FIX1.includes('alter function public.rg_reservation_financial_detail(uuid) owner to postgres;'))
  assert.ok(FIX1.includes('revoke all on function public.rg_reservation_financial_detail(uuid) from public, anon, service_role;'))
  assert.ok(FIX1.includes('grant execute on function public.rg_reservation_financial_detail(uuid) to authenticated;'))
  assert.ok(/^\s*begin;[\s\S]*commit;\s*$/.test(FIX1), 'sem transação')
  const rb = lfRead('supabase/rollback_phase3a_fix1_void_reason_visibility.sql')
  assert.ok(rb.includes(origBlock('public.rg_reservation_financial_detail')), 'rollback não restaura o corpo original')
})
await check('P3A-35 FIX2: price_source definido só pelo banco; recálculo com guards antes; FOUNDATION/GUARDS intactas', () => {
  assert.ok(FIX2.includes('alter table public.reservations add column if not exists price_source text;'))
  assert.ok(FIX2.includes("check (price_source is null or (price_source in ('RULE', 'MANUAL', 'SERIES') and price is not null))"))
  assert.ok(!/update public\.reservations\s+set[^;]*price_source[^;]*;/i.test(FIX2.slice(0, FIX2.indexOf('create or replace function'))), 'backfill em linhas existentes')
  const snap = FIX2.slice(FIX2.indexOf('create or replace function private.enforce_reservation_price_snapshot'))
  for (const s of ["new.price_source := case when new.price is null then null else 'SERIES' end;", "new.price_source := case when new.price is null then null else 'MANUAL' end;",
    "new.price_source := case when v_price is null then null else 'RULE' end;"]) assert.ok(snap.slice(0, snap.indexOf('end $$;')).includes(s), `snapshot sem: ${s}`)
  assert.ok(/function private\.enforce_reservation_price_snapshot\(\)\s*returns trigger language plpgsql security definer set search_path = ''/.test(FIX2))
  const sp = FIX2.slice(FIX2.indexOf('create or replace function public.rg_reservation_set_price'))
  const spb = sp.slice(0, sp.indexOf('end $$;'))
  assert.ok(spb.includes("v_src := case when v_new is null then null when p_mode = 'RULE' then 'RULE' else 'MANUAL' end;"))
  assert.ok(spb.includes('update public.reservations r set price = v_new, price_source = v_src where r.id = v_res.id;'))
  assert.ok(spb.includes("'old_source', v_res.price_source, 'new_source', v_src") && spb.includes('private.rg_fin_lock_reservation(p_reservation_id, true)'))
  const og = FIX2.slice(FIX2.indexOf('create or replace function private.enforce_reservation_price_origin_guard'))
  assert.ok(/returns trigger language plpgsql set search_path = ''/.test(og.slice(0, 200)) && !/security definer/.test(og.slice(0, og.indexOf('end $$;'))), 'guard da origem deve ser INVOKER')
  assert.ok(og.includes("if new.price_source is distinct from old.price_source and current_user <> 'postgres' then") && og.includes("errcode = '42501'"))
  const rp = FIX2.slice(FIX2.indexOf('create or replace function private.enforce_reservation_price_reprice'))
  const rpb = rp.slice(0, rp.indexOf('end $$;'))
  assert.ok(/returns trigger language plpgsql security definer set search_path = ''/.test(rp.slice(0, 200)), 'recálculo deve ser DEFINER')
  const order = ['if new.recurring_reservation_id is not null then', "if new.status not in ('PENDING', 'CONFIRMED', 'NO_SHOW') then",
    'if new.price is distinct from old.price or new.price_source is distinct from old.price_source then',
    "if not (old.price_source is not distinct from 'RULE' or (old.price is null and old.price_source is null)) then",
    'p.reservation_id = old.id and p.voided_at is null', 'private.rg_price_quote(new.court_id, new.start_at, new.end_at)',
    "'RESERVATION_PRICE_REPRICED'", "private.rg_fault('reprice:after_audit')"]
  let last = -1
  for (const s of order) { const i = rpb.indexOf(s); assert.ok(i > last, `recálculo fora de ordem/ausente: ${s}`); last = i }
  assert.ok(!/'notes'|customer|phone|email/.test(rpb.slice(rpb.indexOf("'RESERVATION_PRICE_REPRICED'"))), 'audit com PII')
  const names = ['enforce_reservation_tenant', 'enforce_reservation_zz_price_guard', 'enforce_reservation_zz_price_origin_guard', 'enforce_reservation_zz_price_reprice', 'protect_occurrence_anchor']
  assert.deepEqual([...names].sort(), names, 'ordem alfabética dos BEFORE UPDATE')
  assert.ok(FIX2.includes('create trigger enforce_reservation_zz_price_origin_guard before update on public.reservations') && FIX2.includes('create trigger enforce_reservation_zz_price_reprice before update on public.reservations'))
  for (const fn of ['enforce_reservation_price_snapshot()', 'enforce_reservation_price_origin_guard()', 'enforce_reservation_price_reprice()']) {
    assert.ok(FIX2.includes(`alter function private.${fn} owner to postgres;`) && FIX2.includes(`revoke all on function private.${fn} from public, anon, authenticated, service_role;`), fn)
    assert.ok(!FIX2.includes(`grant execute on function private.${fn}`), `${fn}: grant indevido`)
  }
  assert.ok(!/enforce_reservation_price_guard\(\)/.test(FIX2.replace(/-- .*$/gm, '')), 'FIX2 não pode tocar o guard dos GUARDS')
  const rb = lfRead('supabase/rollback_phase3a_fix2_price_origin.sql')
  for (const n of ['private.enforce_reservation_price_snapshot', 'public.rg_reservation_set_price']) assert.ok(rb.includes(origBlock(n)), `rollback não restaura ${n}`)
  for (const s of ['drop trigger if exists enforce_reservation_zz_price_reprice on public.reservations;', 'drop trigger if exists enforce_reservation_zz_price_origin_guard on public.reservations;',
    'alter table public.reservations drop column if exists price_source;']) assert.ok(rb.includes(s), s)
  // FOUNDATION e GUARDS aplicadas: byte a byte iguais aos hashes aprovados
  assert.equal(sha256(FOUNDATION_RAW.replace(/\r\n/g, '\n')), '638c61a9b72b6db7e410258b13e4940f4c7030a97555171ce4015321a2f20696', 'FOUNDATION alterada')
  assert.equal(sha256(lfRead('supabase/migration_phase3a_guards.sql')), '4f4baa84c2c21792165f77abde9e0193e34f767eddf3d59167a6ab0027ddace4', 'GUARDS alterada')
})
await check('P3A-36 route/UI FIX2: cliente nunca envia price_source; aviso de revisão só com lançamento ativo', () => {
  assert.ok(/if \(body\.price_source !== undefined\) return json\(\{ error: 'A origem do valor é definida pelo sistema\.' \}, 400\)/.test(ROUTE), 'PUT/POST aceitam price_source')
  assert.equal((ROUTE.match(/body\.price_source !== undefined/g) || []).length, 2, 'PUT e POST')
  assert.ok(!/price_source\s*:/.test(ROUTE), 'route grava price_source')
  const put = ROUTE.slice(ROUTE.indexOf("if (id && method === 'PUT') {"), ROUTE.indexOf("if (method === 'POST') {", ROUTE.indexOf("if (id && method === 'PUT') {")))
  assert.ok(put.includes(".from('reservations').select('*').eq('id', id).maybeSingle()"), 'estado anterior incompleto')
  assert.ok(put.includes("supabase.rpc('rg_reservation_financial_detail', { p_reservation_id: id })") && put.includes('fin.entries.some((e) => !e.voided_at)'), 'lançamento ativo não verificado')
  assert.ok(put.includes("(before.price_source === 'RULE' || (before.price == null && before.price_source == null))") && put.includes('!data.recurring_reservation_id'))
  assert.ok(put.includes('return json({ ...data, price_recalculated, price_review_required })'))
  const dbStatuses = FIX2.match(/if new\.status not in \(([^)]*)\) then/)[1].split(',').map((s) => s.trim().replace(/'/g, ''))
  const routeStatuses = ROUTE.match(/const PRICEABLE_STATUSES = \[([^\]]*)\]/)[1].split(',').map((s) => s.trim().replace(/'/g, ''))
  assert.deepEqual(routeStatuses, dbStatuses, 'status precificáveis divergentes entre route e banco')
  const ag = lfRead('app/dashboard/agenda/page.js')
  assert.ok(ag.includes("if (edit && saved.price_review_required) toast.warning('Reserva atualizada. O valor foi mantido porque existem lançamentos financeiros. Revise o valor da reserva.')"), 'aviso ausente')
  assert.ok(!/price_source/.test(ag), 'UI não pode enviar/decidir price_source')
})
await check('P3A-37 rollback SQL dos fixes: casos obrigatórios presentes e tudo desfeito', () => {
  const sql = lfRead('tests/phase3a_fix_rollback.sql')
  assert.ok(sql.includes('P3A_FIX_RESULTS') && /\nrollback;\s*$/.test(sql))
  for (const t of ["'V01b OWNER recebe void_reason e voided_by'", "'V02b MANAGER recebe void_reason e voided_by'", "'V03b RECEPTIONIST recebe voided_at, SEM void_reason e SEM voided_by'",
    "'V05 outro tenant => P0002'", "'R01 horário", "'R02 duração", "'R03 data", "'R04 quadra", "'R05 faixa sem regra", "'R06 sem valor volta para faixa com regra",
    "'R09 cross-midnight", "'R10b MANUAL preservado", "'R11b legado preservado", "'R12b valor preservado", "'R13b estorno não anulado impede", "'R14b recalcula",
    "'R15b SERIES preservado", "'S01 ordem EXATA dos BEFORE UPDATE", "'S03 RECEPTIONIST altera price_source direto => 42501'", "'S06 OWNER altera price direto continua 42501'",
    "'S07 cliente muda horário + price na mesma instrução", "'S09 PAID continua bloqueado", "'F01 falha após o audit do recálculo"])
    assert.ok(sql.includes(t), `caso ausente: ${t}`)
})

const fail = results.filter((r) => r[1] === 'FAIL').length
const skip = results.filter((r) => r[1] === 'SKIP').length
console.log(`\n== ${results.length - fail - skip} PASS, ${skip} SKIP, ${fail} FAIL (03A puro/estático) ==`)
process.exit(fail ? 1 : 0)
