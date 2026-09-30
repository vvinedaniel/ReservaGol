// Dinheiro no Reserva Gol = INTEGER em CENTAVOS (D5). Nunca float.
// Conversão texto -> centavos é determinística e feita só com operações de string/inteiro:
// nenhuma função de ponto flutuante participa do valor. Entrada inválida => null (nunca aproxima).
//
// Formatos aceitos (prefixo "R$" e espaços nas pontas são ignorados):
//   "150"        -> 15000        inteiro
//   "150,5"      -> 15050        vírgula = separador decimal (1 ou 2 casas)
//   "150,00"     -> 15000
//   "150.00"     -> 15000        ponto seguido de 1 ou 2 dígitos = decimal
//   "1.500"      -> 150000       ponto seguido de grupos de 3 dígitos = milhar (padrão BR)
//   "1.500,00"   -> 150000       ambos: o ÚLTIMO separador é o decimal; o outro, milhar em grupos de 3
//   "1,500.00"   -> 150000
// Recusados: vazio, negativo, letras, "12,345" (3 casas decimais), "1.50.0", milhar malformado,
// acima de MAX_CENTS.
export const MAX_CENTS = 10000000 // R$ 100.000,00 (mesmo teto das constraints do banco)

const DIGITS = /^\d+$/
const FRACTION = /^\d{1,2}$/
const GROUPED_DOT = /^\d{1,3}(\.\d{3})+$/
const GROUPED_COMMA = /^\d{1,3}(,\d{3})+$/

export function parseMoneyToCents(input) {
  if (typeof input !== 'string') return null
  const s = input.trim().replace(/^R\$\s*/i, '').trim()
  if (!s || !/^[0-9.,]+$/.test(s)) return null

  let intPart
  let frac = ''
  const lastComma = s.lastIndexOf(',')
  const lastDot = s.lastIndexOf('.')

  if (lastComma >= 0 && lastDot >= 0) {
    const decSep = lastComma > lastDot ? ',' : '.'
    const idx = decSep === ',' ? lastComma : lastDot
    const whole = s.slice(0, idx)
    frac = s.slice(idx + 1)
    if (!FRACTION.test(frac)) return null
    const grouped = decSep === ',' ? GROUPED_DOT : GROUPED_COMMA
    if (!grouped.test(whole)) return null
    intPart = whole.replace(/[.,]/g, '')
  } else if (lastComma >= 0) {
    const parts = s.split(',')
    if (parts.length !== 2 || !DIGITS.test(parts[0]) || !FRACTION.test(parts[1])) return null
    intPart = parts[0]
    frac = parts[1]
  } else if (lastDot >= 0) {
    const parts = s.split('.')
    if (parts.length === 2 && DIGITS.test(parts[0]) && FRACTION.test(parts[1])) {
      intPart = parts[0]
      frac = parts[1]
    } else if (GROUPED_DOT.test(s)) {
      intPart = parts.join('')
    } else {
      return null
    }
  } else {
    if (!DIGITS.test(s)) return null
    intPart = s
  }

  intPart = intPart.replace(/^0+(?=\d)/, '')
  if (intPart.length > 7) return null
  const cents = Number.parseInt(intPart + frac.padEnd(2, '0'), 10)
  if (!Number.isSafeInteger(cents) || cents < 0 || cents > MAX_CENTS) return null
  return cents
}

// Inteiro de centavos vindo da API (JSON number ou string de dígitos). Qualquer outra coisa => null.
export function toCents(v) {
  if (typeof v === 'number') return Number.isSafeInteger(v) ? v : null
  if (typeof v === 'string' && /^-?\d+$/.test(v)) { const n = Number.parseInt(v, 10); return Number.isSafeInteger(n) ? n : null }
  return null
}

function splitCents(cents) {
  const abs = Math.abs(cents)
  const cc = abs % 100
  return { neg: cents < 0, reais: (abs - cc) / 100, cc }
}

// "R$ 1.500,00" — exibição; só aritmética inteira.
export function formatCents(v) {
  const cents = toCents(v)
  if (cents === null) return null
  const { neg, reais, cc } = splitCents(cents)
  return `${neg ? '-' : ''}R$ ${new Intl.NumberFormat('pt-BR').format(reais)},${String(cc).padStart(2, '0')}`
}

// "1500,00" — para preencher campos de formulário (aceito de volta por parseMoneyToCents).
export function centsToInput(v) {
  const cents = toCents(v)
  if (cents === null || cents < 0) return ''
  const { reais, cc } = splitCents(cents)
  return `${reais},${String(cc).padStart(2, '0')}`
}
