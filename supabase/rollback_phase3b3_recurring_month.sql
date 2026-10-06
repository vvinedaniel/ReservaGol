-- =============================================================================
-- RESERVA GOL — ROLLBACK DA FASE 03B.3A — MENSALISTAS (visão mensal + recebimento do mês)
--
-- Remove SOMENTE os objetos criados por supabase/migration_phase3b3_recurring_month.sql e restaura
-- private.protect_structural_links ao corpo A2 original (md5 conferido).
--
-- Nunca destrói histórico financeiro: ABORTA se existir qualquer recebimento mensal (batch) registrado.
-- Dados gravados pelas RPCs permanecem (por desenho): lançamentos 03A dos batches já removidos antes,
-- vínculos de cliente (W1) e valores aplicados às ocorrências (W2) continuam válidos no modelo 03A/B3.
-- audit_logs não são tocados.
--
-- Uma transação. Qualquer divergência => exceção, nada é alterado.
-- =============================================================================
begin;

do $$
begin
  if to_regclass('public.reservation_payment_batches') is null or to_regclass('public.reservation_payment_batch_items') is null then
    raise exception '03B.3 rollback: migration 03B.3 não está aplicada';
  end if;
  if exists (select 1 from public.reservation_payment_batch_items) or exists (select 1 from public.reservation_payment_batches) then
    raise exception '03B.3 rollback: existem recebimentos mensais registrados; rollback abortado para preservar o histórico';
  end if;
  if (select md5(p.prosrc) from pg_proc p where p.oid = 'private.protect_structural_links()'::regprocedure)
     <> 'c50be816b59dcf74bfb2d17d85435496' then
    raise exception '03B.3 rollback: private.protect_structural_links difere da versão 03B.3 esperada (md5)';
  end if;
end $$;

-- RPCs públicas
drop function public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb);
drop function public.rg_recurring_month_search(uuid, date, text, integer);
drop function public.rg_recurring_month_detail(uuid, date);
drop function public.rg_recurring_month_payment_record(uuid, uuid, date, integer, text, timestamptz, text, bigint);
drop function public.rg_recurring_link_customer(uuid, uuid, jsonb);
drop function public.rg_recurring_month_apply_series_price(uuid, date);

-- tabelas (triggers e índices próprios saem junto); itens antes de batches
drop table public.reservation_payment_batch_items;
drop table public.reservation_payment_batches;

-- funções privadas
drop function private.enforce_payment_batch_integrity();
drop function private.enforce_payment_batch_item_integrity();
drop function private.protect_payment_batch_record();
drop function private.rg_rm_batch_result(uuid, boolean);
drop function private.rg_rm_lock_lineage(uuid, boolean);
drop function private.rg_rm_month_status(numeric, numeric, numeric, numeric, numeric);
drop function private.rg_rm_rows(uuid[], date, date);
drop function private.rg_rm_fingerprint(uuid, date, integer, text, timestamptz, text);
drop function private.rg_rm_validate_payment(uuid, text, integer, timestamptz);
drop function private.rg_rm_month(date);
drop function private.rg_rm_lineage_map(uuid);
drop function private.rg_rm_lineage(uuid);
drop function private.rg_rm_root(uuid);
drop function private.rg_rm_is_member(uuid, uuid);

-- corpo A2 original de private.protect_structural_links (sem CR, independente do fim de linha do arquivo)
do $do$
begin
  execute replace($fn$create or replace function private.protect_structural_links()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'structural_link_immutable: organization_id não pode ser alterado' using errcode = 'RGT02';
  end if;
  if tg_table_name in ('courts', 'business_hours', 'reservations', 'recurring_reservations') then
    if new.arena_id is distinct from old.arena_id then
      raise exception 'structural_link_immutable: arena_id não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  if tg_table_name = 'recurring_reservations' then
    if new.court_id is distinct from old.court_id then
      raise exception 'structural_link_immutable: court_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
    if new.customer_id is distinct from old.customer_id then
      raise exception 'structural_link_immutable: customer_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  return new;
end $$$fn$, chr(13), '');
end $do$;

do $$
begin
  if (select md5(p.prosrc) from pg_proc p where p.oid = 'private.protect_structural_links()'::regprocedure)
     <> '82b84c5d95d11123949ead4928896743' then
    raise exception '03B.3 rollback: corpo restaurado de protect_structural_links não confere com o A2 (md5)';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where (n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search',
                       'rg_recurring_month_detail', 'rg_recurring_month_payment_record', 'rg_recurring_link_customer',
                       'rg_recurring_month_apply_series_price'))
                 or (n.nspname = 'private' and (p.proname like 'rg_rm_%' or p.proname in ('enforce_payment_batch_integrity',
                       'enforce_payment_batch_item_integrity', 'protect_payment_batch_record')))) then
    raise exception '03B.3 rollback: restaram funções da 03B.3';
  end if;
end $$;

commit;
