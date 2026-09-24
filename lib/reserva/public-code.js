// Código público da reserva (B2). SOMENTE servidor: usa node:crypto (CSPRNG). Sem Supabase,
// sem env, sem estado global. O código é um token opaco usado em /reserva/[codigo]; a consulta
// continua por igualdade exata e aceita também os códigos legados RG-XXXXXX (6 caracteres).
import crypto from 'node:crypto'

export const PUBLIC_CODE_PREFIX = 'RG-'
// Mesmo alfabeto legível do formato legado: sem I, O, 0 e 1. 24 letras + 8 dígitos = 32 símbolos.
export const PUBLIC_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
// 16 símbolos de 32 => 32^16 = 2^80 (80 bits).
export const PUBLIC_CODE_LENGTH = 16
// Tentativas de INSERT quando o código gerado colide com um existente (índice UNIQUE).
export const PUBLIC_CODE_MAX_ATTEMPTS = 3

const PUBLIC_CODE_UNIQUE_INDEX = 'idx_reservations_public_code_unique'

// Cada símbolo vem de crypto.randomInt, que é uniforme (sem modulo bias).
export function generatePublicReservationCode() {
  let out = ''
  for (let i = 0; i < PUBLIC_CODE_LENGTH; i++) out += PUBLIC_CODE_ALPHABET[crypto.randomInt(PUBLIC_CODE_ALPHABET.length)]
  return PUBLIC_CODE_PREFIX + out
}

// UNIQUE violation causada ESPECIFICAMENTE pelo índice do public_code. O PostgreSQL/PostgREST
// informa o nome do índice em `message` ("... violates unique constraint "<índice>""). Outras
// UNIQUE (ex.: idempotência por arena) não são tratadas como colisão de código.
export function isPublicCodeCollision(error) {
  if (!error || error.code !== '23505') return false
  return `${error.message || ''} ${error.details || ''}`.includes(PUBLIC_CODE_UNIQUE_INDEX)
}

// Repete SOMENTE o INSERT com um código novo quando o código colide. Não recria cliente, não
// consome rate limit e não grava audit log (tudo isso fica com o chamador, uma vez por request).
//   insert(code)        -> Promise<{ data, error }>  (o INSERT da reserva com esse public_code)
//   resolveExisting()   -> Promise<string|null>      (opcional; em qualquer 23505 ou 23P01, procura
//                          a reserva da mesma idempotency_key ANTES de decidir regenerar ou
//                          devolver erro — numa corrida com a MESMA chave o perdedor pode bater
//                          primeiro no overlap (23P01) em vez do índice de idempotência (23505))
//   generateCode        -> injetável apenas para testes internos (não exposto via HTTP)
// Retorna { status: 'created', code } | { status: 'existing', code } | { status: 'error', error }
//       | { status: 'exhausted' } (todas as tentativas colidiram; sem loop infinito).
export async function insertWithPublicCode({ insert, resolveExisting = null, generateCode = generatePublicReservationCode, maxAttempts = PUBLIC_CODE_MAX_ATTEMPTS }) {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const code = generateCode()
    const { error } = await insert(code)
    if (!error) return { status: 'created', code }
    if (error.code !== '23505' && error.code !== '23P01') return { status: 'error', error }
    if (resolveExisting) {
      const existing = await resolveExisting()
      if (existing) return { status: 'existing', code: existing }
    }
    if (!isPublicCodeCollision(error)) return { status: 'error', error }
  }
  return { status: 'exhausted' }
}
