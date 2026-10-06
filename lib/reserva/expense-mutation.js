// FASE 03B.2B-2B — envio de mutações de Despesas pela UI (puro, sem React). Regras do contrato:
// - um envio por vez (guarda SÍNCRONA contra duplo clique, antes de qualquer re-render);
// - operation_id por intenção: gerado no 1º envio, REUTILIZADO em retry (falha de rede, 5xx, 409 de
//   estado), descartado só no sucesso, quando o banco acusa reuso com dados diferentes (RGP02) ou
//   quando o formulário muda/fecha (quem chama faz reset);
// - nenhuma atualização otimista: quem chama recarrega as fontes depois do sucesso.
import { ExpenseNetworkError, ExpenseRequestError } from './expenses-client.js'

export function createSubmitGuard() {
  let busy = false
  return {
    begin() { if (busy) return false; busy = true; return true },
    end() { busy = false },
    get busy() { return busy },
  }
}

// Executa UMA mutação. `send(operationId)` faz a chamada (operationId = undefined sem intenção).
// Resolve 'busy' (já havia envio em andamento), 'ok' ou 'error' — nunca rejeita.
export async function submitIntent({ guard, intent = null, send, onSuccess, onError }) {
  if (!guard.begin()) return 'busy'
  try {
    const key = intent ? intent.get() : undefined
    const res = await send(key)
    if (intent) intent.reset()
    if (onSuccess) await onSuccess(res)
    return 'ok'
  } catch (e) {
    if (intent && e instanceof ExpenseRequestError && e.code === 'IDEMPOTENCY_MISMATCH') intent.reset()
    if (onError) onError(e)
    return 'error'
  } finally {
    guard.end()
  }
}

const FALLBACK = 'Não foi possível concluir. Tente novamente.'
// Mensagem para o usuário: rede => "confirmar resposta"; HTTP => mensagem já saneada pela API.
export function mutationErrorMessage(e, fallback = FALLBACK) {
  if (e instanceof ExpenseNetworkError) return e.message
  if (e instanceof ExpenseRequestError && typeof e.message === 'string' && e.message && !/^finance \d+$/.test(e.message)) return e.message
  return fallback
}
// O estado no servidor mudou (registro sumiu ou regra de negócio recusou): recarregar o detalhe.
export function shouldReloadAfterError(e) {
  return e instanceof ExpenseRequestError && (e.status === 404 || e.status === 409)
}

// Toast de sucesso por operação, distinguindo replay idempotente / "nada mudou".
export function successMessage(kind, data) {
  switch (kind) {
    case 'create': return data?.idempotent ? 'Despesa já registrada' : 'Despesa registrada'
    case 'update': return data?.changed === false ? 'Nada a alterar' : 'Despesa atualizada'
    case 'payment': return data?.idempotent ? 'Pagamento já registrado' : 'Pagamento registrado'
    case 'reverse': return data?.idempotent ? 'Devolução já registrada' : 'Devolução registrada'
    case 'void': return data?.changed === false ? 'Lançamento já estava anulado' : 'Lançamento anulado'
    case 'cancel': return data?.changed === false ? 'Despesa já estava cancelada' : 'Despesa cancelada'
    case 'category-create': return data?.created === false ? 'Categoria já existia' : 'Categoria criada'
    case 'category-update': return data?.changed === false ? 'Nada a alterar' : 'Categoria atualizada'
    default: return 'Concluído'
  }
}
