// Chave de idempotência (operation_id) de uma AÇÃO do usuário que cria/reagenda mensalista (B3).
// Regra: gerada UMA vez quando a ação começa e reutilizada em todo retry da MESMA intenção
// (needs_decision -> "ignorar conflitos", falha de rede, clique repetido). Ao fechar o
// formulário a chave é descartada; uma nova ação recebe uma nova chave.
// Sempre criptográfica: nunca Math.random() nem Date.now().
export function newOperationId(cryptoImpl = globalThis.crypto) {
  if (cryptoImpl && typeof cryptoImpl.randomUUID === 'function') return cryptoImpl.randomUUID()
  if (!cryptoImpl || typeof cryptoImpl.getRandomValues !== 'function') throw new Error('Gerador criptográfico indisponível')
  // UUID v4 (RFC 9562) a partir de 16 bytes criptográficos.
  const b = cryptoImpl.getRandomValues(new Uint8Array(16))
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}
