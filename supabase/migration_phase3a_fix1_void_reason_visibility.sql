-- =============================================================================
-- RESERVA GOL — FASE 03A — FIX1: visibilidade dos dados internos de anulação
-- Migration INCREMENTAL (FOUNDATION e GUARDS já aplicadas; nenhuma delas é alterada).
--
-- Problema (revisão final do PR #12, MEDIUM-1): rg_reservation_financial_detail — chamável por
-- qualquer membro, inclusive RECEPTIONIST — devolvia void_reason e voided_by, contrariando a regra
-- documentada de rg_payment_void ("motivo visível só a OWNER/MANAGER").
--
-- Correção (somente esta função; mesma assinatura, mesmo retorno, mesmas permissões):
--   OWNER / MANAGER / platform admin (private.is_org_manager) => recebem void_reason e voided_by;
--   RECEPTIONIST => recebe voided_at (sabe que o lançamento foi anulado), SEM void_reason/voided_by;
--   não membro / outro tenant => P0002 (inalterado). O restante do detalhe é idêntico.
-- SECURITY DEFINER, owner postgres, search_path = '', EXECUTE só para authenticated.
-- IDEMPOTENTE. Não altera dados. Rollback: supabase/rollback_phase3a_fix1_void_reason_visibility.sql
-- =============================================================================
begin;

do $$ begin
  if to_regprocedure('public.rg_reservation_financial_detail(uuid)') is null then
    raise exception '03A FIX1: FOUNDATION 03A ausente';
  end if;
end $$;

create or replace function public.rg_reservation_financial_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_manager boolean;
  v_fin record;
  v_entries jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select r.organization_id into v_org from public.reservations r where r.id = p_reservation_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: reserva não encontrada' using errcode = 'P0002';
  end if;
  -- Dados internos da anulação (motivo e autor) só para OWNER/MANAGER; a recepção vê apenas voided_at.
  v_manager := private.is_org_manager(v_org, v_uid);
  select f.* into v_fin from private.rg_financials(array[p_reservation_id]) f;
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', p.id, 'kind', p.kind, 'refund_of', p.refund_of, 'method', p.method, 'amount', p.amount,
             'received_at', p.received_at, 'notes', p.notes, 'source', p.source, 'created_by', p.created_by,
             'created_at', p.created_at, 'voided_at', p.voided_at)
           || case when v_manager then jsonb_build_object('voided_by', p.voided_by, 'void_reason', p.void_reason)
                   else '{}'::jsonb end
           order by p.received_at, p.created_at, p.id), '[]'::jsonb)
    into v_entries
    from public.reservation_payments p where p.reservation_id = p_reservation_id;
  return jsonb_build_object(
    'reservation_id', v_fin.reservation_id, 'status', v_fin.status,
    'amount_due', v_fin.amount_due, 'amount_received', v_fin.amount_received, 'amount_refunded', v_fin.amount_refunded,
    'net_received', v_fin.net_received, 'balance', v_fin.balance, 'collectible', v_fin.collectible,
    'collectible_balance', v_fin.collectible_balance, 'payment_status', v_fin.payment_status,
    'entries', v_entries);
end $$;

alter function public.rg_reservation_financial_detail(uuid) owner to postgres;
revoke all on function public.rg_reservation_financial_detail(uuid) from public, anon, service_role;
grant execute on function public.rg_reservation_financial_detail(uuid) to authenticated;

commit;
