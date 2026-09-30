// B3 — chave de idempotência por INTENÇÃO na UI (contrato congelado):
//   mesma intenção / retry (inclusive após falha de rede) => MESMO operation_id;
//   intenção alterada (qualquer campo do formulário muda de valor) => NOVO operation_id.
// Este helper só DESCARTA a chave quando o valor do campo realmente muda; quem gera a próxima
// continua sendo newOperationId(), uma única vez, no próximo envio. Devolve true quando a intenção
// mudou (o chamador descarta também o que pertencia à intenção anterior, ex.: conflitos exibidos).
export function invalidateIntentOnChange(form, key, value, keyRef) {
  if (form && Object.is(form[key], value)) return false
  keyRef.current = null
  return true
}
