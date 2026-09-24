// Redirect INTERNO seguro (B1). Função pura: aceita apenas destinos root-relative da própria
// aplicação e devolve pathname + search + hash, nunca uma URL absoluta.
// Seguro por construção: o `value` E o `fallback` passam pela MESMA validação; se nenhum dos dois
// for válido, o resultado é o destino fixo '/dashboard'. Nada fornecido pelo chamador é devolvido
// sem validação.
//
// Duas barreiras (toSafeInternal):
//  1) formato: string curta, começa com exatamente uma "/", sem "\" e sem caracteres de controle
//     (o parser de URL remove TAB/CR/LF e trata "\" como "/", o que transformaria "/\t/evil" ou
//     "/\\evil" em "//evil");
//  2) parsing: resolve contra uma origin sentinela fixa e exige que a origin continue a mesma; o
//     resultado normalizado também não pode começar com "//" (ex.: "/.//evil" normaliza para "//evil").
const SENTINEL = 'https://reservagol.invalid'
const MAX_LENGTH = 2048
const TERMINAL_FALLBACK = '/dashboard'

// Caminho interno normalizado se válido; null se inválido.
function toSafeInternal(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_LENGTH) return null
  if (/[\u0000-\u001F\u007F]/.test(value)) return null // controle, inclusive TAB/CR/LF
  if (value.includes('\\')) return null
  if (value[0] !== '/' || value[1] === '/') return null // root-relative, não protocol-relative
  let parsed
  try {
    parsed = new URL(value, SENTINEL)
  } catch {
    return null
  }
  if (parsed.origin !== SENTINEL) return null
  const out = `${parsed.pathname}${parsed.search}${parsed.hash}`
  if (!out.startsWith('/') || out.startsWith('//')) return null
  return out
}

export function safeInternalRedirect(value, fallback = TERMINAL_FALLBACK) {
  const safeValue = toSafeInternal(value)
  if (safeValue) return safeValue
  const safeFallback = toSafeInternal(fallback)
  if (safeFallback) return safeFallback
  return TERMINAL_FALLBACK
}
