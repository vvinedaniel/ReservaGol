// Sequência de requisições: só a mais recente aplica resultado. Respostas que chegam
// fora de ordem (navegação rápida, polling, Realtime) são descartadas sem AbortController.
export function createRequestSequence() {
  let current = 0
  return {
    next() { current += 1; return current },
    isCurrent(id) { return id === current },
    // Descarta tudo o que está em andamento (mudança de intenção, unmount): nenhuma
    // requisição anterior roda mais callbacks. A próxima chamada de next() começa limpa.
    invalidate() { current += 1 },
  }
}

// Executa `task` como a requisição mais recente de `seq`. Garantias:
// - onResult/onError/onSettled só rodam enquanto esta requisição for a atual (nenhum
//   next()/invalidate() depois dela): resposta ou erro antigo não altera estado nem loading.
// - erro em onStart, em task ou em onResult conta como falha da requisição: onError e
//   onSettled rodam (se ainda for a atual), então o loading da atual sempre termina.
// - erro lançado pelo próprio onError/onSettled é um bug de programação: vai para
//   console.error e não é engolido em silêncio.
// - a Promise devolvida sempre resolve (nunca rejeita), mesmo sem await de quem chama.
export async function runLatest(seq, task, { onStart, onResult, onError, onSettled } = {}) {
  const id = seq.next()
  const isCurrent = () => seq.isCurrent(id)
  try {
    if (onStart) onStart()
    const value = await task()
    if (isCurrent() && onResult) onResult(value)
  } catch (err) {
    if (isCurrent() && onError) callGuarded(onError, err)
  } finally {
    if (isCurrent() && onSettled) callGuarded(onSettled)
  }
}

function callGuarded(fn, arg) {
  try { fn(arg) } catch (err) { console.error('runLatest: callback lançou erro', err) }
}
