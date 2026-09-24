// Reserva Gol — SECURITY HARDENING B1 — testes puros de safeInternalRedirect (sem rede, sem banco).
// Uso: node tests/security_b1_safe_redirect.test.mjs
import assert from 'node:assert/strict'
import { safeInternalRedirect } from '../lib/auth/safe-redirect.js'

const FALLBACK = '/dashboard'
const ORIGIN = 'https://app.reservagol.test'
const results = []
function check(name, fn) {
  try { fn(); results.push([name, true]); console.log(`PASS  ${name}`) } catch (e) { results.push([name, false]); console.log(`FAIL  ${name}: ${e.message}`) }
}
const rejected = (v) => assert.equal(safeInternalRedirect(v), FALLBACK, `deveria cair no fallback: ${JSON.stringify(v)}`)
// Simula exatamente o caminho do app: valor lido por URLSearchParams (que decodifica %XX).
const fromQuery = (encoded) => new URL(`${ORIGIN}/auth/confirm?next=${encoded}`).searchParams.get('next')

const ACCEPTED = ['/dashboard', '/dashboard/', '/dashboard?tab=agenda', '/dashboard?tab=agenda#hoje', '/onboarding', '/jogar', '/reserva/ABC123', '/reset-password']
const REJECTED = [
  '', null, undefined, 42, {}, 'dashboard', 'https://evil.example', 'http://evil.example', 'HTTPS://evil.example',
  '//evil.example', '///evil.example', '////evil.example', '\\\\evil.example', '\\evil.example', '/\\evil.example', '/\\/evil.example',
  'javascript:alert(1)', 'JavaScript:alert(1)', 'data:text/html,<script>alert(1)</script>', 'vbscript:msgbox(1)',
  '/\t/evil.example', '/\n/evil.example', '/\r\n/evil.example', '/dashboard\r\nSet-Cookie: x=1', '\u0000/dashboard', '/dash\u007Fboard',
  ' //evil.example', '/.//evil.example', '/..//evil.example', '/./..//evil.example', '/' + 'a'.repeat(2048),
]

check('B1-1 aceita /dashboard (e demais rotas internas)', () => {
  for (const v of ACCEPTED) assert.equal(safeInternalRedirect(v), v, v)
})
check('B1-2 preserva query e hash internos', () => {
  assert.equal(safeInternalRedirect('/dashboard?tab=agenda#hoje'), '/dashboard?tab=agenda#hoje')
  assert.equal(safeInternalRedirect('/reserva/ABC123?x=1&y=2'), '/reserva/ABC123?x=1&y=2')
})
check('B1-3 //evil.example rejeitado', () => rejected('//evil.example'))
check('B1-4 ///evil.example rejeitado', () => { rejected('///evil.example'); rejected('////evil.example') })
check('B1-5 URL absoluta https rejeitada', () => { rejected('https://evil.example'); rejected('HTTPS://evil.example/dashboard') })
check('B1-6 URL absoluta http rejeitada', () => rejected('http://evil.example'))
check('B1-7 javascript:/data:/vbscript: rejeitados', () => {
  for (const v of ['javascript:alert(1)', 'JavaScript:alert(1)', 'data:text/html,<script>alert(1)</script>', 'vbscript:msgbox(1)']) rejected(v)
})
check('B1-8 backslash e /\\evil.example rejeitados', () => {
  for (const v of ['\\evil.example', '\\\\evil.example', '/\\evil.example', '/\\/evil.example', '/dashboard\\..\\x']) rejected(v)
})
check('B1-9 percent-encoded após URLSearchParams não vira redirect externo', () => {
  const encoded = ['%2F%2Fevil.example', '%2F%2F%2Fevil.example', '%5C%5Cevil.example', '%2F%5Cevil.example', '%2F%09%2Fevil.example',
    '%2F%0D%0A%2Fevil.example', 'https%3A%2F%2Fevil.example', 'javascript%3Aalert(1)', '%2F.%2F%2Fevil.example', '%20%2F%2Fevil.example']
  for (const e of encoded) rejected(fromQuery(e))
  assert.equal(safeInternalRedirect(fromQuery('%2Freset-password')), '/reset-password') // uso real do forgot-password
  assert.equal(safeInternalRedirect(fromQuery('')), FALLBACK)
})
check('B1-10 nenhum resultado muda a origin (inclui controle, espaços e normalização)', () => {
  for (const v of [...ACCEPTED, ...REJECTED]) {
    const out = safeInternalRedirect(v)
    assert.ok(typeof out === 'string' && out.startsWith('/') && !out.startsWith('//'), `resultado inválido para ${JSON.stringify(v)}: ${out}`)
    assert.equal(new URL(out, ORIGIN).origin, ORIGIN, `origin mudou para ${JSON.stringify(v)}`)
  }
  for (const v of REJECTED) rejected(v)
})
check('B1-11 fallback customizado é respeitado', () => {
  assert.equal(safeInternalRedirect('//evil.example', '/login'), '/login')
})
check('B1-12 fallback também é validado (seguro por construção)', () => {
  assert.equal(safeInternalRedirect('//evil.example', '/login'), '/login')                   // fallback válido
  assert.equal(safeInternalRedirect('//evil.example', '//evil2.example'), '/dashboard')      // protocol-relative
  assert.equal(safeInternalRedirect('javascript:alert(1)', 'https://evil.example'), '/dashboard') // absoluta
  assert.equal(safeInternalRedirect(null, '/\\evil.example'), '/dashboard')                  // backslash
  for (const bad of ['/\t/evil.example', '/\r\n/evil.example', '/\n/evil.example', '/dash\tboard'])
    assert.equal(safeInternalRedirect('//evil.example', bad), '/dashboard', JSON.stringify(bad)) // TAB/CR/LF
  for (const bad of ['', null, undefined, 42, 'dashboard', '/.//evil.example', 'data:text/html,x'])
    assert.equal(safeInternalRedirect('//evil.example', bad), '/dashboard', JSON.stringify(bad))
  assert.equal(safeInternalRedirect(undefined), '/dashboard')                               // fallback padrão
})
check('B1-13 value válido tem prioridade sobre qualquer fallback', () => {
  assert.equal(safeInternalRedirect('/jogar?x=1#teste', '//evil.example'), '/jogar?x=1#teste')
  assert.equal(safeInternalRedirect('/reserva/ABC123', '/login'), '/reserva/ABC123')
})
check('B1-14 nenhum par (value, fallback) muda a origin', () => {
  const values = [...ACCEPTED, ...REJECTED]
  const fallbacks = ['/login', '//evil2.example', 'https://evil.example', '/\\evil.example', '/\t/evil.example', null, '']
  for (const v of values) for (const f of fallbacks) {
    const out = safeInternalRedirect(v, f)
    assert.ok(typeof out === 'string' && out.startsWith('/') && !out.startsWith('//'), `${JSON.stringify(v)} / ${JSON.stringify(f)} -> ${out}`)
    assert.equal(new URL(out, ORIGIN).origin, ORIGIN)
  }
})

const ok = results.filter(([, p]) => p).length
console.log(`\n== ${ok}/${results.length} PASS (safe-redirect) ==`)
process.exit(ok === results.length ? 0 : 1)
