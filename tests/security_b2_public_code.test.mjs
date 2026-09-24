// Reserva Gol — SECURITY HARDENING B2 — testes puros do gerador de public_code (sem rede, sem banco).
// Sanity checks de formato/unicidade/implementação. NÃO são prova criptográfica: a segurança vem
// do CSPRNG do node:crypto (crypto.randomInt), não desta amostra.
// Uso: node tests/security_b2_public_code.test.mjs
import assert from 'node:assert/strict'
import fs from 'node:fs'
import {
  PUBLIC_CODE_PREFIX, PUBLIC_CODE_ALPHABET, PUBLIC_CODE_LENGTH, PUBLIC_CODE_MAX_ATTEMPTS,
  generatePublicReservationCode, isPublicCodeCollision, insertWithPublicCode,
} from '../lib/reserva/public-code.js'

const SRC = fs.readFileSync(new URL('../lib/reserva/public-code.js', import.meta.url), 'utf8')
const results = []
async function check(name, fn) {
  try { await fn(); results.push([name, true]); console.log(`PASS  ${name}`) } catch (e) { results.push([name, false]); console.log(`FAIL  ${name}: ${e.message}`) }
}
const ALPHA = new Set(PUBLIC_CODE_ALPHABET)
const FORMAT = new RegExp(`^RG-[${PUBLIC_CODE_ALPHABET}]{${PUBLIC_CODE_LENGTH}}$`)
const sample = (n) => Array.from({ length: n }, () => generatePublicReservationCode())
const collision = (code) => ({ code: '23505', message: 'duplicate key value violates unique constraint "idx_reservations_public_code_unique"', details: `Key (public_code)=(${code}) already exists.` })
const idemViolation = { code: '23505', message: 'duplicate key value violates unique constraint "idx_reservations_arena_idempotency_unique"', details: 'Key (arena_id, idempotency_key)=(...) already exists.' }
const overlap = { code: '23P01', message: 'conflicting key value violates exclusion constraint "reservations_no_overlap"' }

await check('B2-1 1000 códigos: string, prefixo RG-, tamanho e alfabeto corretos', () => {
  for (const c of sample(1000)) {
    assert.equal(typeof c, 'string')
    assert.ok(c.startsWith(PUBLIC_CODE_PREFIX))
    assert.equal(c.length, PUBLIC_CODE_PREFIX.length + PUBLIC_CODE_LENGTH)
    assert.match(c, FORMAT)
  }
})
await check('B2-2 nenhum caractere fora do alfabeto (sem I, O, 0, 1, minúsculas)', () => {
  for (const c of sample(1000)) for (const ch of c.slice(3)) assert.ok(ALPHA.has(ch), `símbolo fora do alfabeto: ${ch}`)
  for (const ch of 'IO01abcxyz-_ ') assert.ok(!ALPHA.has(ch))
})
await check('B2-3 nenhum dos 1000 códigos se repete (sanity check, não prova)', () => {
  const s = sample(1000)
  assert.equal(new Set(s).size, s.length)
})
await check('B2-4 o helper não usa Math.random nem fontes previsíveis', () => {
  const code = SRC.replace(/\/\/.*$/gm, '') // ignora comentários
  for (const bad of ['Math.random', 'Date.now', 'randomUUID', 'performance.now']) assert.ok(!code.includes(bad), `referência proibida: ${bad}`)
})
await check('B2-5 o helper usa node:crypto (crypto.randomInt)', () => {
  assert.ok(SRC.includes("from 'node:crypto'"))
  assert.ok(SRC.includes('crypto.randomInt('))
})
await check('B2-6 tamanho real do alfabeto e entropia', () => {
  assert.equal(new Set(PUBLIC_CODE_ALPHABET).size, PUBLIC_CODE_ALPHABET.length, 'alfabeto com símbolo repetido')
  assert.equal(PUBLIC_CODE_ALPHABET.length, 32)
  assert.equal(PUBLIC_CODE_LENGTH, 16)
  const bits = Math.log2(PUBLIC_CODE_ALPHABET.length) * PUBLIC_CODE_LENGTH
  const legacyBits = Math.log2(PUBLIC_CODE_ALPHABET.length) * 6
  assert.equal(bits, 80)
  console.log(`      alfabeto = ${PUBLIC_CODE_ALPHABET.length} símbolos; entropia = log2(${PUBLIC_CODE_ALPHABET.length}) x ${PUBLIC_CODE_LENGTH} = ${bits} bits (legado: ${legacyBits} bits)`)
})
await check('B2-7 distribuição grosseira (10.000): todos os símbolos aparecem, nenhuma posição fixa', () => {
  const s = sample(10000)
  const seen = new Set()
  const perPos = Array.from({ length: PUBLIC_CODE_LENGTH }, () => new Set())
  for (const c of s) [...c.slice(3)].forEach((ch, i) => { seen.add(ch); perPos[i].add(ch) })
  assert.equal(seen.size, PUBLIC_CODE_ALPHABET.length, 'algum símbolo nunca apareceu')
  perPos.forEach((set, i) => assert.equal(set.size, PUBLIC_CODE_ALPHABET.length, `posição ${i} não varia por todo o alfabeto`))
})
await check('B2-8 isPublicCodeCollision distingue o índice do código da idempotência e do overlap', () => {
  assert.equal(isPublicCodeCollision(collision('RG-X')), true)
  assert.equal(isPublicCodeCollision(idemViolation), false)
  assert.equal(isPublicCodeCollision(overlap), false)
  assert.equal(isPublicCodeCollision(null), false)
  assert.equal(isPublicCodeCollision({ code: '23505', message: 'duplicate key value violates unique constraint "arenas_slug_key"' }), false)
})
await check('B2-9 colisão controlada: 1ª tentativa colide, 2ª grava o SEGUNDO código', async () => {
  const codes = ['RG-OCUPADOAAAAAAAAA', 'RG-NOVOBBBBBBBBBBBB']
  const inserted = []
  const r = await insertWithPublicCode({
    generateCode: () => codes.shift(),
    insert: async (code) => { inserted.push(code); return inserted.length === 1 ? { data: null, error: collision(code) } : { data: { public_code: code }, error: null } },
  })
  assert.deepEqual(r, { status: 'created', code: 'RG-NOVOBBBBBBBBBBBB' })
  assert.deepEqual(inserted, ['RG-OCUPADOAAAAAAAAA', 'RG-NOVOBBBBBBBBBBBB'])
})
await check('B2-10 três colisões consecutivas: para após 3 tentativas (sem loop infinito)', async () => {
  let calls = 0
  const r = await insertWithPublicCode({ generateCode: () => `RG-C${++calls}`, insert: async (code) => ({ data: null, error: collision(code) }) })
  assert.deepEqual(r, { status: 'exhausted' })
  assert.equal(calls, PUBLIC_CODE_MAX_ATTEMPTS)
  assert.equal(PUBLIC_CODE_MAX_ATTEMPTS, 3)
})
await check('B2-11 corrida de idempotência NÃO é mascarada: devolve a reserva existente, sem regenerar', async () => {
  let gen = 0, lookups = 0
  const r = await insertWithPublicCode({
    generateCode: () => `RG-G${++gen}`,
    insert: async () => ({ data: null, error: idemViolation }),
    resolveExisting: async () => { lookups++; return 'RG-VENCEDORAXXXXXXX' },
  })
  assert.deepEqual(r, { status: 'existing', code: 'RG-VENCEDORAXXXXXXX' })
  assert.equal(gen, 1, 'não pode gerar outro código numa corrida de idempotência')
  assert.equal(lookups, 1)
})
await check('B2-12 colisão de código com idempotency_key: procura a existente ANTES de regenerar', async () => {
  const order = []
  const r = await insertWithPublicCode({
    generateCode: () => { order.push('gen'); return 'RG-X' },
    insert: async (code) => { order.push('insert'); return { data: null, error: collision(code) } },
    resolveExisting: async () => { order.push('lookup'); return order.filter((x) => x === 'lookup').length === 2 ? 'RG-EXISTENTEXXXXXXX' : null },
  })
  assert.deepEqual(order, ['gen', 'insert', 'lookup', 'gen', 'insert', 'lookup'])
  assert.deepEqual(r, { status: 'existing', code: 'RG-EXISTENTEXXXXXXX' })
})
await check('B2-13 outros erros (overlap, UNIQUE de outra constraint) voltam ao chamador sem retry', async () => {
  for (const err of [overlap, { code: '23505', message: 'duplicate key value violates unique constraint "arenas_slug_key"' }, { code: '42501', message: 'x' }]) {
    let gen = 0
    const r = await insertWithPublicCode({ generateCode: () => `RG-${++gen}`, insert: async () => ({ data: null, error: err }) })
    assert.equal(r.status, 'error')
    assert.equal(r.error, err)
    assert.equal(gen, 1, 'não pode repetir o INSERT para erro que não é colisão do código')
  }
})

await check('B2-14 corrida da MESMA chave que bate no overlap (23P01): devolve a reserva existente', async () => {
  let gen = 0
  const r = await insertWithPublicCode({ generateCode: () => `RG-${++gen}`, insert: async () => ({ data: null, error: overlap }), resolveExisting: async () => 'RG-VENCEDORAXXXXXXX' })
  assert.deepEqual(r, { status: 'existing', code: 'RG-VENCEDORAXXXXXXX' })
  assert.equal(gen, 1)
})
await check('B2-15 overlap causado por OUTRA reserva (sem reserva da mesma chave): erro original, sem retry', async () => {
  let gen = 0
  const r = await insertWithPublicCode({ generateCode: () => `RG-${++gen}`, insert: async () => ({ data: null, error: overlap }), resolveExisting: async () => null })
  assert.equal(r.status, 'error')
  assert.equal(r.error, overlap)
  assert.equal(gen, 1)
})

const ok = results.filter(([, p]) => p).length
console.log(`\n== ${ok}/${results.length} PASS (public-code) ==`)
process.exit(ok === results.length ? 0 : 1)
