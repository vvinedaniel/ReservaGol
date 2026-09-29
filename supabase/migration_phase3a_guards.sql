-- =============================================================================
-- RESERVA GOL — FASE 03A — FINANCEIRO DA ARENA — GUARDS
-- Normativo: ARCHITECTURE REVIEW Revision 2.1 (D15, D22).
-- DRAFT PARA REVISÃO. Aplicar SOMENTE depois de:
--   1) migration_phase3a_foundation.sql aplicada;
--   2) route/frontend 03A (sem escrita direta de price, sem PAID) e testes 03A verdes na FOUNDATION.
-- IDEMPOTENTE e segura para reaplicar. NÃO altera nem apaga dados. NÃO altera grants de
-- reservations nem nada da B3 (D7 continua a autoridade do INSERT recorrente).
--
-- enforce_reservation_zz_price_guard (BEFORE INSERT OR UPDATE em reservations):
--   INSERT recorrente (recurring_reservation_id NOT NULL): NÃO interfere em price/status — o D7
--     (validate_reservation_zz_series_occurrence) valida a ocorrência e responde com os SQLSTATEs
--     atuais (23514), inclusive para PAID (o D7 exige CONFIRMED).
--   INSERT comum: authenticated/anon não fornecem price (42501) — o snapshot vem da tabela de
--     preços (trigger da FOUNDATION) ou de rg_reservation_set_price; status PAID recusado (23514)
--     para qualquer papel. INSERT do service_role SEM price (reserva pública) segue normal.
--   UPDATE (TODAS as reservas, inclusive ocorrências recorrentes):
--     * price: DEFAULT-DENY — só quem executa legitimamente como postgres pode alterar, i.e. a
--       RPC SECURITY DEFINER rg_reservation_set_price (owner postgres). authenticated, anon e
--       service_role => 42501;
--     * status: qualquer transição NOVA para PAID => 23514, para qualquer papel.
--
-- SECURITY INVOKER de propósito: current_user precisa refletir QUEM executa o comando (dentro de
-- uma função SECURITY DEFINER owner postgres, current_user = postgres). Trigger não exige EXECUTE
-- do chamador; o EXECUTE é revogado de todos os papéis de API.
--
-- Ordem dos BEFORE INSERT triggers após os GUARDS (alfabética):
--   enforce_reservation_tenant -> enforce_reservation_zz_price_guard -> enforce_reservation_zz_price_snapshot
--   -> validate_reservation_recurring -> validate_reservation_zz_series_occurrence (D7)
--   (o guard vê o price enviado pelo cliente ANTES de o snapshot preenchê-lo)
-- =============================================================================
begin;

do $$ begin
  if to_regprocedure('private.enforce_reservation_price_snapshot()') is null then
    raise exception '03A GUARDS: FOUNDATION 03A ausente';
  end if;
end $$;

create or replace function private.enforce_reservation_price_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.recurring_reservation_id is not null then
      return new;
    end if;
    if current_user in ('authenticated', 'anon') and new.price is not null then
      raise exception 'price_protected: o valor da reserva vem da tabela de preços' using errcode = '42501';
    end if;
    if new.status = 'PAID' then
      raise exception 'status_paid_legacy: status PAID não pode mais ser gravado' using errcode = '23514';
    end if;
    return new;
  end if;

  if new.price is distinct from old.price and current_user <> 'postgres' then
    raise exception 'price_protected: o valor da reserva só muda pela ação de valor' using errcode = '42501';
  end if;
  if new.status = 'PAID' and old.status is distinct from 'PAID' then
    raise exception 'status_paid_legacy: status PAID não pode mais ser gravado' using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists enforce_reservation_zz_price_guard on public.reservations;
create trigger enforce_reservation_zz_price_guard before insert or update on public.reservations
  for each row execute function private.enforce_reservation_price_guard();

alter function private.enforce_reservation_price_guard() owner to postgres;
revoke all on function private.enforce_reservation_price_guard() from public, anon, authenticated, service_role;

commit;

-- =============================================================================
-- VERIFICAÇÃO (somente leitura; rodar após aplicar — NÃO faz parte da migration)
-- =============================================================================
-- 1) Trigger presente, SECURITY INVOKER, search_path vazio:
--   select p.prosecdef, p.proconfig from pg_proc p where p.oid = 'private.enforce_reservation_price_guard()'::regprocedure;
--     -> f | {search_path=""}
-- 2) Ordem dos BEFORE INSERT triggers de reservations:
--   select t.tgname from pg_trigger t where t.tgrelid = 'public.reservations'::regclass and not t.tgisinternal
--      and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 order by t.tgname;
--     -> enforce_reservation_tenant, enforce_reservation_zz_price_guard, enforce_reservation_zz_price_snapshot,
--        validate_reservation_recurring, validate_reservation_zz_series_occurrence
-- 3) Demonstração (transação descartada, como postgres):
--   begin; set local role service_role;
--   update public.reservations set price = 1 where id = '<reserva>';   -- esperado: ERROR 42501
--   rollback;
