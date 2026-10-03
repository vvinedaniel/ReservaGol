-- =============================================================================
-- RESERVA GOL — FASE 03B.1 — ROLLBACK
-- Remove exatamente o que migration_phase3b1_finance_overview.sql criou: 4 RPCs públicas,
-- 2 funções privadas e 2 índices. Não toca objetos da 03A. Não há dados a desfazer
-- (a 03B.1 é somente leitura).
-- =============================================================================
begin;

drop function if exists public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid);
drop function if exists public.rg_fin_cashflow(uuid, uuid, date, date, text);
drop function if exists public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid);
drop function if exists public.rg_fin_overview(uuid, uuid, date, date, date, date);
drop function if exists private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz);
drop function if exists private.rg_fin_scope(uuid, uuid, date, date, integer);
drop index if exists public.idx_reservations_arena_start;
drop index if exists public.idx_reservations_org_start;

-- Conferência: nada da 03B.1 sobrou e a 03A continua intacta.
do $$ begin
  if to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is not null
     or to_regprocedure('public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid)') is not null
     or to_regprocedure('public.rg_fin_cashflow(uuid, uuid, date, date, text)') is not null
     or to_regprocedure('public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid)') is not null
     or to_regprocedure('private.rg_fin_scope(uuid, uuid, date, date, integer)') is not null
     or to_regprocedure('private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz)') is not null
     or to_regclass('public.idx_reservations_org_start') is not null
     or to_regclass('public.idx_reservations_arena_start') is not null then
    raise exception '03B.1 rollback: objeto da 03B.1 ainda presente';
  end if;
  if to_regprocedure('private.rg_financials(uuid[])') is null
     or to_regprocedure('public.rg_reservation_financial_detail(uuid)') is null
     or to_regprocedure('public.rg_reservation_financial_summaries(uuid[])') is null then
    raise exception '03B.1 rollback: objeto da 03A ausente — não deveria ter sido tocado';
  end if;
end $$;

commit;
