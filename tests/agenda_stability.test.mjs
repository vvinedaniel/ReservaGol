// 03A.1 — Agenda Stability Hardening (puro/estático, sem rede e sem banco).
// Uso: node tests/agenda_stability.test.mjs
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { isValidDateStr, applyDateInput, fmtDateLong, addDaysStr, todayStr, firstSeriesDate, MIN_OPERATIONAL_YEAR, MAX_OPERATIONAL_YEAR } from '../lib/reserva/time.js'
import { createRequestSequence, runLatest } from '../lib/reserva/latest-request.js'

const read = (f) => fs.readFileSync(new URL(`../${f}`, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const stripJsComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const AGENDA = stripJsComments(read('app/dashboard/agenda/page.js'))
const PUBLIC = stripJsComments(read('app/jogar/[slug]/page.js'))
const MENSAL = stripJsComments(read('app/dashboard/mensalistas/page.js'))

const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS  ${name}`) }
  catch (e) { results.push([name, 'FAIL']); console.log(`FAIL  ${name}: ${e.message}`) }
}

// Promessa controlável: a ordem de chegada das respostas é decidida pelo teste.
function deferred() { let resolve, reject; const p = new Promise((res, rej) => { resolve = res; reject = rej }); return { p, resolve, reject } }
const tick = () => new Promise((r) => setImmediate(r))

// Modelo da Agenda: mesma ligação do componente (applyDateInput/changeDate/changeArena/blur,
// invalidação síncrona na mudança de intenção e runLatest em load). `deferEffects` separa a
// mudança de estado do effect que inicia a nova busca, para exercitar a janela entre os dois.
function agendaModel(initialDate, { deferEffects = false, arenaId = 'arena-1' } = {}) {
  const s = { date: initialDate, dateInput: initialDate, arenaId, data: null, loading: false, errors: 0, toasts: 0, fetches: [], runs: [] }
  const seq = createRequestSequence()
  const pending = new Map()
  let effectQueued = false
  const fetchDay = (key) => { s.fetches.push(key); const d = deferred(); pending.set(s.fetches.length - 1, d); return d.p }
  const load = () => {
    if (!s.arenaId || !isValidDateStr(s.date)) return Promise.resolve()
    const key = s.arenaId === arenaId ? s.date : `${s.arenaId}|${s.date}`
    return runLatest(seq, () => fetchDay(key), {
      onStart: () => { s.loading = true },
      onResult: (v) => { s.data = v },
      onError: () => { s.data = null; s.errors++; s.toasts++ },
      onSettled: () => { s.loading = false },
    })
  }
  const runEffects = () => { if (effectQueued) { effectQueued = false; s.runs.push(load()) } }
  const scheduleEffect = () => { effectQueued = true; if (!deferEffects) runEffects() }
  return {
    s, pending, seq, runEffects,
    type(raw) { const n = applyDateInput(s.date, raw); s.dateInput = n.dateInput; this.changeDate(n.date) },
    blur() { s.dateInput = s.date },
    changeDate(d) {
      if (!isValidDateStr(d) || d === s.date) return
      seq.invalidate()
      s.date = d; s.dateInput = d
      scheduleEffect()
    },
    changeArena(id) {
      if (!id || id === s.arenaId) return
      seq.invalidate()
      s.arenaId = id
      scheduleEffect()
    },
    arrow(n) { this.changeDate(addDaysStr(s.date, n)) },
    today() { this.changeDate(todayStr()) },
    reload() { s.runs.push(load()) },
    unmount() { seq.invalidate() },
  }
}

await check('D01 data: vazio, parcial, inexistente e anos fora do intervalo são rejeitados', () => {
  for (const v of ['', '2026-10-', '2026-1-01', '2026-10-1', '20261-10-01', '0002-10-01', '1999-12-31', '2101-01-01', '2026-13-01', '2026-00-10', '2026-10-00', '2026-02-30', '2026-04-31', '2026-02-29', ' 2026-10-01', '2026-10-01T00:00', null, undefined, 20261001])
    assert.equal(isValidDateStr(v), false, `aceitou ${JSON.stringify(v)}`)
  assert.equal(MIN_OPERATIONAL_YEAR, 2000)
  assert.equal(MAX_OPERATIONAL_YEAR, 2100)
})
await check('D02 data: válidas aceitas, incluindo bissexto (2028-02-29) e limites do intervalo', () => {
  for (const v of ['2026-10-01', '2028-02-29', '2000-02-29', '2026-12-31', '2000-01-01', '2100-12-31']) assert.equal(isValidDateStr(v), true, v)
  assert.equal(isValidDateStr('2100-02-29'), false, '2100 não é bissexto')
})
await check('D03 fmtDateLong nunca lança e devolve vazio para entrada inválida', () => {
  for (const v of ['', '2026-10-', '2026-02-30', '20261-10-01', '0002-10-01', null, undefined]) assert.equal(fmtDateLong(v), '', String(v))
  assert.match(fmtDateLong('2026-10-01'), /01 de outubro/)
})
await check('D04 addDaysStr nunca lança: inválida devolve vazio; válida continua igual', () => {
  for (const v of ['', '2026-10-', '20261-10-01', null]) assert.equal(addDaysStr(v, 1), '', String(v))
  assert.equal(addDaysStr('2026-10-01', 1), '2026-10-02')
  assert.equal(addDaysStr('2026-03-01', -1), '2026-02-28')
  assert.equal(addDaysStr('2028-02-28', 1), '2028-02-29')
  assert.equal(addDaysStr('2026-12-31', 1), '2027-01-01')
})
await check('D05 applyDateInput: parcial muda só o campo; válida muda campo e data', () => {
  assert.deepEqual(applyDateInput('2026-10-01', ''), { dateInput: '', date: '2026-10-01' })
  assert.deepEqual(applyDateInput('2026-10-01', '0002-10-05'), { dateInput: '0002-10-05', date: '2026-10-01' })
  assert.deepEqual(applyDateInput('2026-10-01', '2026-10-05'), { dateInput: '2026-10-05', date: '2026-10-05' })
})

await check('A01 agenda: digitação parcial (apagar dia, ano sendo digitado) não busca nem muda a data', async () => {
  const m = agendaModel('2026-10-01')
  for (const raw of ['', '0002-10-01', '0020-10-01', '0202-10-01', '20261-10-01', '2026-02-30']) m.type(raw)
  assert.equal(m.s.date, '2026-10-01')
  assert.equal(m.s.dateInput, '2026-02-30', 'o campo mantém o que foi digitado')
  assert.deepEqual(m.s.fetches, [], 'busca disparada com data inválida')
  assert.equal(fmtDateLong(m.s.date), fmtDateLong('2026-10-01'))
})
await check('A02 agenda: blur com valor inválido restaura a última data válida', () => {
  const m = agendaModel('2026-10-01')
  m.type('')
  assert.equal(m.s.dateInput, '')
  m.blur()
  assert.equal(m.s.dateInput, '2026-10-01')
  assert.deepEqual(m.s.fetches, [])
})
await check('A03 agenda: data válida digitada atualiza campo e data e busca uma vez', () => {
  const m = agendaModel('2026-10-01')
  m.type(''); m.type('2026-10-07')
  assert.equal(m.s.date, '2026-10-07'); assert.equal(m.s.dateInput, '2026-10-07')
  assert.deepEqual(m.s.fetches, ['2026-10-07'])
})
await check('A04 agenda: setas e Hoje atualizam campo e data; nenhuma busca inválida', () => {
  const m = agendaModel('2026-10-01')
  m.type('2026-10-')
  m.arrow(-1)
  assert.equal(m.s.date, '2026-09-30'); assert.equal(m.s.dateInput, '2026-09-30', 'seta não sincronizou o campo')
  m.arrow(2)
  assert.equal(m.s.date, '2026-10-02')
  m.today()
  assert.equal(m.s.date, todayStr()); assert.equal(m.s.dateInput, todayStr())
  assert.ok(m.s.fetches.every(isValidDateStr), `busca inválida: ${m.s.fetches}`)
})

await check('R01 concorrência A→B→C respondendo C→B→A: só C atualiza dados e loading', async () => {
  const m = agendaModel('2026-10-01')
  m.changeDate('2026-10-02'); m.changeDate('2026-10-03'); m.changeDate('2026-10-04')
  const [a, b, c] = [0, 1, 2].map((i) => m.pending.get(i))
  assert.equal(m.s.loading, true)
  c.resolve({ day: 'C' }); await tick()
  assert.deepEqual(m.s.data, { day: 'C' }); assert.equal(m.s.loading, false)
  b.resolve({ day: 'B' }); await tick()
  a.resolve({ day: 'A' }); await tick()
  assert.deepEqual(m.s.data, { day: 'C' }, 'resposta antiga sobrescreveu')
  assert.equal(m.s.loading, false); assert.equal(m.s.date, '2026-10-04'); assert.equal(m.s.dateInput, '2026-10-04')
})
await check('R02 resposta antiga não encerra o loading da atual; erro antigo é ignorado', async () => {
  const m = agendaModel('2026-10-01')
  m.changeDate('2026-10-02'); m.changeDate('2026-10-03')
  const [old, cur] = [m.pending.get(0), m.pending.get(1)]
  old.reject(new Error('rede')); await tick()
  assert.equal(m.s.loading, true, 'loading encerrado pela resposta antiga')
  assert.equal(m.s.errors, 0, 'erro antigo exibido')
  cur.resolve({ day: '03' }); await tick()
  assert.deepEqual(m.s.data, { day: '03' }); assert.equal(m.s.loading, false)
})
await check('R03 erro da requisição atual encerra o loading (sem skeleton infinito) e limpa os dados', async () => {
  const m = agendaModel('2026-10-01')
  m.changeDate('2026-10-02')
  m.pending.get(0).reject(new TypeError('Failed to fetch')); await tick()
  assert.equal(m.s.loading, false); assert.equal(m.s.errors, 1); assert.equal(m.s.data, null)
  await Promise.all(m.s.runs) // runLatest nunca rejeita
})
await check('R04 navegação lenta: cada resposta chega antes do próximo clique e é aplicada', async () => {
  const m = agendaModel('2026-10-01')
  for (const [i, d] of ['2026-10-02', '2026-10-03', '2026-10-04'].entries()) {
    m.changeDate(d); m.pending.get(i).resolve({ day: d }); await tick()
    assert.deepEqual(m.s.data, { day: d }); assert.equal(m.s.loading, false)
  }
})
await check('R05 recarga do Realtime vira a requisição mais nova da data atual', async () => {
  const m = agendaModel('2026-10-01')
  m.changeDate('2026-10-02'); m.reload()
  assert.deepEqual(m.s.fetches, ['2026-10-02', '2026-10-02'])
  m.pending.get(1).resolve({ v: 'realtime' }); await tick()
  m.pending.get(0).resolve({ v: 'antiga' }); await tick()
  assert.deepEqual(m.s.data, { v: 'realtime' })
})
await check('R06 visão semanal: sequência própria; semana antiga não sobrescreve a nova', async () => {
  const seq = createRequestSequence()
  const st = { week: null, loading: false }
  const run = (task) => runLatest(seq, task, { onStart: () => { st.loading = true }, onResult: (w) => { st.week = w }, onError: () => { st.week = null }, onSettled: () => { st.loading = false } })
  const w1 = deferred(), w2 = deferred()
  run(() => w1.p); run(() => w2.p)
  w2.resolve('semana-2'); await tick()
  w1.resolve('semana-1'); await tick()
  assert.equal(st.week, 'semana-2'); assert.equal(st.loading, false)
  const day = createRequestSequence(); day.next(); day.next()
  assert.equal(seq.isCurrent(2), true, 'DIA e SEMANA não podem compartilhar contador')
})

await check('R07 janela intenção→effect: A responde depois da mudança para B e antes de B começar', async () => {
  const m = agendaModel('2026-10-01', { deferEffects: true })
  m.reload()                           // A em andamento
  const a = m.pending.get(0)
  m.changeDate('2026-10-02')           // intenção B: invalida na hora; effect de B ainda não rodou
  assert.equal(m.s.fetches.length, 1, 'B começou antes do effect')
  a.resolve({ day: 'A' }); await tick()
  assert.equal(m.s.data, null, 'A aplicou dados depois da mudança de intenção')
  assert.equal(m.s.loading, true, 'A encerrou o loading da próxima intenção')
  m.runEffects()                       // effect de B
  m.pending.get(1).resolve({ day: 'B' }); await tick()
  assert.deepEqual(m.s.data, { day: 'B' }); assert.equal(m.s.loading, false)
  // mesma janela com troca de arena
  const m2 = agendaModel('2026-10-01', { deferEffects: true })
  m2.reload(); m2.changeArena('arena-2')
  m2.pending.get(0).resolve({ arena: 1 }); await tick()
  assert.equal(m2.s.data, null, 'arena antiga aplicou dados')
  m2.runEffects(); m2.pending.get(1).resolve({ arena: 2 }); await tick()
  assert.deepEqual(m2.s.data, { arena: 2 }); assert.deepEqual(m2.s.fetches, ['2026-10-01', 'arena-2|2026-10-01'])
})
await check('R08 mesmo valor (Hoje já em hoje, mesma arena) não invalida nem prende o loading', async () => {
  const m = agendaModel(todayStr(), { deferEffects: true })
  m.reload()
  m.today()                            // já está em hoje
  m.changeArena('arena-1')             // mesma arena
  m.changeDate('2026-10-')             // inválida
  m.runEffects()
  assert.equal(m.s.fetches.length, 1, 'mesmo valor disparou nova busca')
  m.pending.get(0).resolve({ v: 'atual' }); await tick()
  assert.deepEqual(m.s.data, { v: 'atual' }, 'requisição atual foi invalidada')
  assert.equal(m.s.loading, false, 'loading preso')
})
await check('R09 cleanup/unmount: erro ou resposta tardia não rodam onError/onResult/onSettled nem toast', async () => {
  const m = agendaModel('2026-10-01')
  m.reload(); m.reload()
  m.unmount()
  const before = JSON.stringify(m.s)
  m.pending.get(0).reject(new TypeError('Failed to fetch'))
  m.pending.get(1).resolve({ v: 'tardia' }); await tick()
  assert.equal(m.s.toasts, 0, 'toast depois do unmount'); assert.equal(m.s.errors, 0)
  assert.equal(JSON.stringify(m.s), before, 'estado alterado depois do unmount')
  // runLatest direto: nenhum callback roda após invalidate()
  const seq = createRequestSequence(); const calls = []; const d = deferred()
  const p = runLatest(seq, () => d.p, { onResult: () => calls.push('result'), onError: () => calls.push('error'), onSettled: () => calls.push('settled') })
  seq.invalidate(); d.reject(new Error('tarde')); await p
  assert.deepEqual(calls, [])
})
await check('R10 callbacks que lançam: nenhuma rejeição sem tratamento; loading da atual termina', async () => {
  const unhandled = []; const onUnhandled = (e) => unhandled.push(e)
  process.on('unhandledRejection', onUnhandled)
  const logged = []; const origErr = console.error; console.error = (...a) => logged.push(a)
  try {
    const seq = createRequestSequence()
    const run = (opts, task = async () => 'ok') => { const calls = []; const wrap = {}; for (const k of ['onStart', 'onResult', 'onError', 'onSettled']) wrap[k] = (...x) => { calls.push(k); if (opts[k]) return opts[k](...x) }; return runLatest(seq, task, wrap).then((v) => ({ v, calls })) }
    const boom = () => { throw new Error('bug') }
    let r = await run({ onStart: boom })
    assert.deepEqual(r.calls, ['onStart', 'onError', 'onSettled'], 'onStart lançando não encerrou o loading'); assert.equal(r.v, undefined)
    r = await run({}, async () => { throw new Error('rede') })
    assert.deepEqual(r.calls, ['onStart', 'onError', 'onSettled'])
    r = await run({ onResult: boom })
    assert.deepEqual(r.calls, ['onStart', 'onResult', 'onError', 'onSettled'], 'erro em onResult não virou falha da requisição')
    r = await run({ onError: boom }, async () => { throw new Error('rede') })
    assert.deepEqual(r.calls, ['onStart', 'onError', 'onSettled'], 'erro em onError impediu onSettled')
    r = await run({ onSettled: boom })
    assert.deepEqual(r.calls, ['onStart', 'onResult', 'onSettled'])
    assert.equal(logged.length, 2, 'erro de onError/onSettled não foi reportado no console')
    assert.ok(logged.every((a) => String(a[0]).includes('runLatest: callback lançou erro')))
    await new Promise((res) => setTimeout(res, 20))
    assert.deepEqual(unhandled, [], 'Promise rejection não tratada')
  } finally { console.error = origErr; process.off('unhandledRejection', onUnhandled) }
})

await check('P01 página pública: data parcial e polling antigo após nova seleção', async () => {
  const seq = createRequestSequence()
  let date = '2026-10-01', dateInput = date, avail = null; const fetches = [], pend = []
  const loadAvail = () => { if (!isValidDateStr(date)) return; const d = date; fetches.push(d); const x = deferred(); pend.push(x); runLatest(seq, () => x.p, { onResult: (v) => { avail = v }, onError: () => { avail = { error: 'x' } } }) }
  const type = (raw) => { const n = applyDateInput(date, raw); dateInput = n.dateInput; if (isValidDateStr(n.date) && n.date !== date) { seq.invalidate(); date = n.date; avail = null; loadAvail() } }
  loadAvail()           // carga inicial (01)
  loadAvail()           // polling de 10 s ainda para 01
  type('')              // apagou o dia: nada busca, nada quebra
  assert.equal(fmtDateLong(date) !== '', true); assert.equal(fetches.length, 2)
  type('2026-10-05')    // nova seleção
  pend[2].resolve({ d: '05' }); await tick()
  pend[1].resolve({ d: '01-polling' }); await tick()
  pend[0].resolve({ d: '01' }); await tick()
  assert.deepEqual(avail, { d: '05' }, 'polling antigo sobrescreveu a data nova')
  assert.equal(dateInput, '2026-10-05')
})

await check('M01 mensalistas: start_date inválida não calcula; válida calcula como antes', () => {
  for (const v of ['', '2026-10-', '2026-02-30']) assert.equal(firstSeriesDate({ start_date: v, frequency: 'WEEKLY', weekday: '3' }), null, v)
  assert.equal(firstSeriesDate({ start_date: '2026-10-01', frequency: 'WEEKLY', weekday: '3' }), '2026-10-07') // 01/10/2026 é quinta; próxima quarta
  assert.equal(firstSeriesDate({ start_date: '2026-10-07', frequency: 'WEEKLY', weekday: '3' }), '2026-10-07')
  assert.equal(firstSeriesDate({ start_date: '2026-10-01', frequency: 'MONTHLY', day_of_month: '10' }), '2026-10-10')
  assert.equal(firstSeriesDate({ start_date: '2026-10-15', frequency: 'MONTHLY', day_of_month: '10' }), '2026-11-10')
})

await check('S01 agenda (estático): campo separado, setas/Hoje validadas, load/loadWeek com sequências próprias', () => {
  assert.ok(AGENDA.includes('<Input type="date" value={dateInput}'), 'campo ainda ligado direto a date')
  assert.ok(AGENDA.includes('applyDateInput(date, e.target.value)') && AGENDA.includes('onBlur={() => setDateInput(date)}'))
  assert.ok(!/setDate\(e\.target\.value\)/.test(AGENDA), 'setDate com valor bruto do campo')
  assert.ok(!/onClick=\{\(\) => setDate\(/.test(AGENDA), 'seta/Hoje sem validação')
  for (const g of ['changeDate(addDaysStr(date, -1))', 'changeDate(todayStr())', 'changeDate(addDaysStr(date, 1))', 'setDateInput(next.dateInput); changeDate(next.date)']) assert.ok(AGENDA.includes(g), g)
  assert.ok(!/goToDate|setDate\(next\.date\)/.test(AGENDA), 'caminho de data fora do changeDate')
  assert.ok(AGENDA.includes('useEffect(() => { setDateInput(date) }, [date])'), 'campo não acompanha setas/Hoje')
  const cd = AGENDA.slice(AGENDA.indexOf('const changeDate = (d) => {'), AGENDA.indexOf('const changeArena = (id) => {'))
  assert.ok(cd.includes('if (!isValidDateStr(d) || d === date) return'), 'changeDate sem guarda de valor inválido/igual')
  assert.ok(cd.indexOf('invalidateLoads()') > 0 && cd.indexOf('invalidateLoads()') < cd.indexOf('setDate(d)'), 'changeDate não invalida antes de mudar a data')
  const ca = AGENDA.slice(AGENDA.indexOf('const changeArena = (id) => {'), AGENDA.indexOf('const [data, setData]'))
  assert.ok(ca.includes('if (!id || id === arenaId) return') && ca.indexOf('invalidateLoads()') < ca.indexOf('setArenaId(id)'), 'changeArena sem guarda/invalidação')
  assert.ok(AGENDA.includes('onValueChange={changeArena}'), 'Select de arena fora do changeArena')
  assert.ok(AGENDA.includes('const invalidateLoads = () => { daySeq.current.invalidate(); weekSeq.current.invalidate() }'))
  assert.ok(AGENDA.includes('useEffect(() => () => invalidateLoads(), [])'), 'unmount não invalida as sequências')
  const load = AGENDA.slice(AGENDA.indexOf('const load = useCallback('), AGENDA.indexOf('loadRef.current = load'))
  const week = AGENDA.slice(AGENDA.indexOf('const loadWeek = useCallback('), AGENDA.indexOf("useEffect(() => { if (view === 'week') loadWeek() }"))
  assert.ok(load.includes('!isValidDateStr(date)') && load.includes('runLatest(daySeq.current') && load.includes('onSettled: () => setLoading(false)'), 'load sem guarda/sequência')
  assert.ok(week.includes('!isValidDateStr(date)') && week.includes('runLatest(weekSeq.current') && week.includes('onSettled: () => setWeekLoading(false)'), 'loadWeek sem guarda/sequência')
  assert.ok(!/setData\(|setLoading\(false\)/.test(load.replace(/onResult: setData|onError: \(\) => \{ setData\(null\)|onSettled: \(\) => setLoading\(false\)/g, '')), 'load grava fora do runLatest')
  assert.ok(!/AbortController/.test(AGENDA))
  assert.ok(AGENDA.includes('reloadRef.current = () => { if (view === \'week\') loadWeek(); else load() }'), 'Realtime deixou de recarregar')
})
await check('S02 página pública (estático): mesmo modelo de campo e polling na sequência', () => {
  assert.ok(PUBLIC.includes('value={dateInput}') && PUBLIC.includes('applyDateInput(date, e.target.value)') && PUBLIC.includes('onBlur={() => setDateInput(date)}'))
  assert.ok(!/setDate\(e\.target\.value\)/.test(PUBLIC))
  const la = PUBLIC.slice(PUBLIC.indexOf('const loadAvail = () => {'), PUBLIC.indexOf('useEffect(() => { setAvail(null); loadAvail()'))
  assert.ok(la.includes('!isValidDateStr(date)') && la.includes('runLatest(availSeq.current'), 'loadAvail sem guarda/sequência')
  assert.ok(PUBLIC.includes('const iv = setInterval(loadAvail, 10000)'), 'polling removido')
  assert.ok(PUBLIC.includes('return () => { clearInterval(iv); availSeq.current.invalidate() }'), 'cleanup não invalida a sequência')
  const cd = PUBLIC.slice(PUBLIC.indexOf('const changeDate = (d) => {'), PUBLIC.indexOf('const changeCourt = (id) => {'))
  assert.ok(cd.includes('if (!isValidDateStr(d) || d === date) return') && cd.indexOf('availSeq.current.invalidate()') < cd.indexOf('setDate(d)'), 'changeDate público sem guarda/invalidação')
  const cc = PUBLIC.slice(PUBLIC.indexOf('const changeCourt = (id) => {'), PUBLIC.indexOf('const loadAvail = () => {'))
  assert.ok(cc.includes('if (!id || id === courtId) return') && cc.indexOf('availSeq.current.invalidate()') < cc.indexOf('setCourtId(id)'), 'changeCourt sem guarda/invalidação')
  assert.ok(PUBLIC.includes('onValueChange={changeCourt}') && PUBLIC.includes('setDateInput(next.dateInput); changeDate(next.date)'))
  assert.ok(PUBLIC.includes("r.status === 409") && PUBLIC.includes("fetch('/api/public/reserve'"), 'fluxo de reserva/409 alterado')
})
await check('S03 mensalistas (estático): "Sugerir valor" valida start_date antes de calcular', () => {
  const q = MENSAL.slice(MENSAL.indexOf('async function quotePrice()'), MENSAL.indexOf('async function doPreview()'))
  assert.ok(q.indexOf('!isValidDateStr(f.start_date)') >= 0 && q.indexOf('!isValidDateStr(f.start_date)') < q.indexOf('firstSeriesDate(f)'))
  assert.ok(!/function firstSeriesDate/.test(MENSAL), 'cópia local de firstSeriesDate')
  assert.ok(q.includes('/api/pricing/quote') && q.includes("set('price', centsToInput(d.price))"), 'regra de cotação alterada')
})

const passed = results.filter(([, s]) => s === 'PASS').length
const failed = results.filter(([, s]) => s === 'FAIL').length
console.log(`\n== ${passed} PASS, ${failed} FAIL (03A.1 agenda stability) ==`)
process.exit(failed ? 1 : 0)
