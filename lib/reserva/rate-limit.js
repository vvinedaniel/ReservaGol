// Rate limit PERSISTENTE e compartilhado (A6). SOMENTE servidor: usa node:crypto e a secret.
// O estado vive no PostgreSQL (public.rate_limit_buckets), incrementado de forma atômica pela
// RPC public.consume_rate_limit (executável apenas por service_role). Nenhum telefone ou IP é
// enviado ao banco: só um HMAC-SHA256 (64 hex) com subchave derivada da SUPABASE_SECRET_KEY.
import crypto from 'node:crypto'
import net from 'node:net'

// Limites do produto (janela FIXA). Centralizados aqui — nada de números mágicos no route.js.
export const RATE_LIMITS = Object.freeze({
  // Proteção PRIMÁRIA da reserva pública: arena + telefone normalizado (cleanBrPhone do A4).
  RESERVE_PHONE: Object.freeze({ scope: 'public_reserve_phone', limit: 5, windowSeconds: 600 }),
  // Sinal SECUNDÁRIO: arena + IP (X-Forwarded-For não é prova forte de identidade).
  RESERVE_IP: Object.freeze({ scope: 'public_reserve_ip', limit: 20, windowSeconds: 600 }),
  // Consulta por public_code: único identificador disponível é o IP (temporário até o B3).
  LOOKUP_IP: Object.freeze({ scope: 'public_reservation_lookup_ip', limit: 30, windowSeconds: 600 }),
})

// Separação de domínio: a secret raiz nunca é usada diretamente como chave do hash.
const HMAC_CONTEXT = 'reservagol-rate-limit-v1'
const MAX_IP_HEADER = 512

export class RateLimitUnavailable extends Error {
  constructor(reason) { super(`rate limiter indisponível: ${reason}`); this.name = 'RateLimitUnavailable' }
}

let derived = null // { root, key } — recalcula se a secret mudar (ex.: testes)
function subkey() {
  const root = process.env.SUPABASE_SECRET_KEY
  if (!root) throw new RateLimitUnavailable('secret ausente')
  if (!derived || derived.root !== root) derived = { root, key: crypto.createHmac('sha256', root).update(HMAC_CONTEXT).digest() }
  return derived.key
}

// Serialização sem ambiguidade: "<bytes>:<valor>|<bytes>:<valor>".
export function encodeParts(parts) {
  return parts.map((p) => { const s = String(p); return `${Buffer.byteLength(s, 'utf8')}:${s}` }).join('|')
}

// HMAC-SHA256 (hex minúsculo, 64 chars) de scope + partes. O scope entra no material para que
// o mesmo identificador gere hashes diferentes em buckets diferentes.
export function rateLimitKeyHash(scope, parts) {
  return crypto.createHmac('sha256', subkey()).update(encodeParts([scope, ...parts])).digest('hex')
}

// Ordem de preferência: header da Vercel (definido pela plataforma) e depois os genéricos.
const IP_HEADERS = ['x-vercel-forwarded-for', 'x-forwarded-for', 'x-real-ip']

// Normaliza UMA entrada: remove espaços, porta e prefixo ::ffff:; v6 em minúsculas. null se inválida.
function normalizeIp(entry) {
  let ip = String(entry || '').trim()
  if (!ip) return null
  const bracketed = /^\[([^\]]+)\](?::\d+)?$/.exec(ip) // [v6]:porta
  if (bracketed) ip = bracketed[1]
  else if (/^\d{1,3}(?:\.\d{1,3}){3}:\d+$/.test(ip)) ip = ip.slice(0, ip.lastIndexOf(':')) // v4:porta
  ip = ip.toLowerCase()
  if (ip.startsWith('::ffff:') && net.isIPv4(ip.slice(7))) ip = ip.slice(7)
  return net.isIP(ip) ? ip : null
}

// IP do cliente como SINAL SECUNDÁRIO. Para cada header, na ordem de IP_HEADERS, usa APENAS a
// primeira entrada da lista; header ausente, grande demais ou com primeira entrada inválida é
// ignorado e o próximo header é tentado. Retorna o IP normalizado ou null (inutilizável).
// Limitação documentada: sem um proxy confiável que sobrescreva estes headers, o cliente pode
// forjá-los. O IP bruto nunca é logado nem enviado ao banco (só o HMAC).
export function clientIp(headers) {
  for (const name of IP_HEADERS) {
    const v = headers?.get?.(name)
    if (typeof v !== 'string' || !v || v.length > MAX_IP_HEADER) continue
    const ip = normalizeIp(v.split(',')[0])
    if (ip) return ip
  }
  return null
}

// Consome 1 unidade do bucket. Retorna { allowed, retryAfter }. Qualquer falha (secret ausente,
// erro da RPC, resposta inválida) lança RateLimitUnavailable: o chamador NUNCA faz fail-open.
export async function consumeRateLimit(admin, cfg, parts) {
  const keyHash = rateLimitKeyHash(cfg.scope, parts)
  let data, error
  try {
    ({ data, error } = await admin.rpc('consume_rate_limit', {
      p_scope: cfg.scope, p_key_hash: keyHash, p_limit: cfg.limit, p_window_seconds: cfg.windowSeconds,
    }))
  } catch {
    throw new RateLimitUnavailable('falha de rede na RPC')
  }
  if (error) throw new RateLimitUnavailable(`RPC ${error.code || 'erro'}`)
  const row = Array.isArray(data) ? data[0] : data
  if (!row || typeof row.allowed !== 'boolean' || !Number.isInteger(row.retry_after_seconds)) {
    throw new RateLimitUnavailable('resposta inválida da RPC')
  }
  return { allowed: row.allowed, retryAfter: Math.max(1, row.retry_after_seconds) }
}
