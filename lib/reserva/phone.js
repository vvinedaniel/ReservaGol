// CLIENTES C2B — telefone brasileiro canônico (ESPELHO de private.rg_phone_canonical / rg_phone_valid do C2A).
// O banco é a autoridade: este módulo só pré-valida a entrada na UI/rotas, formata para exibição e monta o
// link do WhatsApp. Paridade JS × SQL provada em tests/customers_c2b.test.mjs.
//
// Canônico = DDD (lista Anatel) + número, só dígitos, SEM 55: 11 dígitos => celular (3º dígito 9);
// 10 dígitos => fixo (3º dígito 2–5). '+' só com 55 (estrangeiro rejeitado na V1); 55 removido apenas quando
// prova ser o código do país (12/13 dígitos) — DDD 55 (RS) com 10/11 dígitos fica; um '0' de longa distância
// removido (11/12 dígitos começando com 0); código de operadora => inválido.

const DDD = new Set([11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 24, 27, 28, 31, 32, 33, 34, 35, 37, 38, 41, 42, 43, 44, 45, 46, 47, 48, 49,
  51, 53, 54, 55, 61, 62, 63, 64, 65, 66, 67, 68, 69, 71, 73, 74, 75, 77, 79, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95, 96, 97, 98, 99])

/** Valor JÁ canônico? (espelho de private.rg_phone_valid) */
export function isCanonicalBrPhone(v) {
  if (typeof v !== 'string' || !/^[0-9]{10,11}$/.test(v)) return false
  if (!DDD.has(Number(v.slice(0, 2)))) return false
  return v.length === 11 ? v[2] === '9' : v[2] >= '2' && v[2] <= '5'
}

/**
 * Entrada livre -> { ok: true, value: canônico | null (vazio) } | { ok: false }.
 * Espelho exato de private.rg_phone_canonical (que lança 22023 INVALID_PHONE no caso inválido).
 */
export function canonicalBrPhone(raw) {
  if (raw === null || raw === undefined) return { ok: true, value: null }
  if (typeof raw !== 'string') return { ok: false }
  const v = raw.replace(/^ +| +$/g, '') // btrim do Postgres: só espaços
  if (v === '') return { ok: true, value: null }
  if (v.length > 40 || !/^\+?[0-9 ().-]+$/.test(v)) return { ok: false }
  let d = v.replace(/[^0-9]/g, '')
  if (v[0] === '+') {
    if (!d.startsWith('55')) return { ok: false }
    d = d.slice(2)
  } else if ((d.length === 12 || d.length === 13) && d.startsWith('55')) {
    d = d.slice(2)
  } else if ((d.length === 11 || d.length === 12) && d[0] === '0') {
    d = d.slice(1)
  }
  return isCanonicalBrPhone(d) ? { ok: true, value: d } : { ok: false }
}

/** "(41) 99999-1111" / "(41) 3333-4444"; valor não canônico (legado) é devolvido como está. */
export function formatBrPhone(v) {
  if (!isCanonicalBrPhone(v)) return v || ''
  const ddd = v.slice(0, 2)
  const rest = v.slice(2)
  return rest.length === 9 ? `(${ddd}) ${rest.slice(0, 5)}-${rest.slice(5)}` : `(${ddd}) ${rest.slice(0, 4)}-${rest.slice(4)}`
}

/** Link do WhatsApp só para telefone canônico (legado/inválido => null: não abre conversa errada). */
export function whatsappUrl(v) {
  return isCanonicalBrPhone(v) ? `https://wa.me/55${v}` : null
}

export const PHONE_INVALID_MSG = 'Telefone inválido. Use DDD + número brasileiro, ex.: (41) 99999-1111.'
