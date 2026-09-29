-- =============================================================================
-- RESERVA GOL — FASE 03A — FIX2: origem do valor (price_source) e recálculo ao editar
-- Migration INCREMENTAL (FOUNDATION e GUARDS já aplicadas; os ARQUIVOS delas não mudam).
-- Redefine, via CREATE OR REPLACE, duas funções da FOUNDATION (snapshot e set_price) e cria dois
-- triggers novos. O guard dos GUARDS (enforce_reservation_zz_price_guard) NÃO é alterado.
--
-- Problema (revisão final do PR #12, MEDIUM-2): editar data/horário/duração/quadra mantinha o
-- snapshot de preço antigo (o snapshot só existia no INSERT) => cobrança incorreta.
--
-- Modelo: reservations.price_source (NULL | 'RULE' | 'MANUAL' | 'SERIES'), SEMPRE definido pelo banco.
--   price NULL  + price_source NULL => reserva sem valor;
--   price !NULL + price_source NULL => valor LEGADO de origem desconhecida (nunca recalculado sozinho);
--   RULE   => snapshot da tabela de preços (INSERT) ou "Recalcular pela tabela";
--   MANUAL => valor informado por OWNER/MANAGER (rg_reservation_set_price) ou preço explícito em
--             INSERT por caminho interno autorizado (authenticated/anon não enviam price: GUARDS);
--   SERIES => ocorrência recorrente (default_price da série; D7/B3 é a autoridade).
-- SEM backfill: nenhuma linha existente é alterada (as antigas ficam com price_source NULL).
--
-- Recálculo ao editar (trigger enforce_reservation_zz_price_reprice, BEFORE UPDATE, DEFINER):
-- quando start_at/end_at/court_id mudam, recalcula pela tabela SOMENTE se: não for ocorrência
-- recorrente; status PENDING/CONFIRMED/NO_SHOW; origem RULE ou reserva sem valor; nenhum lançamento
-- NÃO anulado (pagamento/estorno) na reserva; e a própria instrução não tiver definido o valor.
-- Sem regra => sem valor (price/price_source NULL). Mesma transação do UPDATE; audit
-- RESERVATION_PRICE_REPRICED (sem PII). Com lançamento ativo o valor é PRESERVADO (a API avisa).
--
-- Ordem dos BEFORE UPDATE (alfabética; testada): enforce_reservation_tenant ->
--   enforce_reservation_zz_price_guard (GUARDS: cliente não muda price/PAID) ->
--   enforce_reservation_zz_price_origin_guard (cliente não muda price_source) ->
--   enforce_reservation_zz_price_reprice (sistema recalcula) -> protect_* -> trg_* -> validate_*.
-- Os guards INVOKER veem só o que o CLIENTE enviou; o recálculo roda depois, como postgres.
-- IDEMPOTENTE. Rollback: supabase/rollback_phase3a_fix2_price_origin.sql
-- =============================================================================
begin;

do $$ begin
  if to_regprocedure('private.enforce_reservation_price_snapshot()') is null
     or to_regprocedure('public.rg_reservation_set_price(uuid,text,integer,text)') is null then
    raise exception '03A FIX2: FOUNDATION 03A ausente';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'enforce_reservation_zz_price_guard'
                   and tgrelid = 'public.reservations'::regclass) then
    raise exception '03A FIX2: GUARDS 03A ausentes';
  end if;
end $$;

-- 1) Coluna de origem (nula, sem default: só metadados; nenhuma linha reescrita)
alter table public.reservations add column if not exists price_source text;
alter table public.reservations drop constraint if exists reservations_price_source_chk;
alter table public.reservations add constraint reservations_price_source_chk
  check (price_source is null or (price_source in ('RULE', 'MANUAL', 'SERIES') and price is not null));

-- 2) Snapshot no INSERT: a origem é SEMPRE decidida aqui (qualquer valor enviado pelo cliente é
--    sobrescrito). Mesmo comportamento de preço da FOUNDATION.
create or replace function private.enforce_reservation_price_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_price integer;
begin
  if new.recurring_reservation_id is not null then
    new.price_source := case when new.price is null then null else 'SERIES' end;
    return new;
  end if;
  if new.status = 'BLOCKED' or new.price is not null then
    new.price_source := case when new.price is null then null else 'MANUAL' end;
    return new;
  end if;
  select q.price into v_price from private.rg_price_quote(new.court_id, new.start_at, new.end_at) q;
  new.price := v_price;
  new.price_source := case when v_price is null then null else 'RULE' end;
  return new;
end $$;

-- 3) Alteração de valor (OWNER/MANAGER): igual à FOUNDATION + grava a origem.
--    MANUAL com valor => 'MANUAL'; MANUAL sem valor => NULL/NULL; RULE => 'RULE' (sem regra => RGP01 NO_RULE).
--    Mudar só a origem (ex.: mesmo valor, MANUAL -> RULE) também é uma alteração (changed = true).
create or replace function public.rg_reservation_set_price(p_reservation_id uuid, p_mode text, p_price integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_res public.reservations;
  v_new integer;
  v_src text;
  v_rules uuid[] := '{}'::uuid[];
  v_fin record;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('MANUAL', 'RULE') then
    raise exception 'rg: modo inválido' using errcode = '22023';
  end if;
  if p_reason is null or p_reason not in ('CORRECTION', 'DISCOUNT', 'COURTESY', 'RULE_RECALC', 'OTHER') then
    raise exception 'rg: motivo inválido' using errcode = '22023';
  end if;
  if p_mode = 'MANUAL' and p_price is not null and (p_price < 0 or p_price > 10000000) then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  v_res := private.rg_fin_lock_reservation(p_reservation_id, true);
  if v_res.status = 'BLOCKED' then
    raise exception 'rg: bloqueio de horário não tem valor' using errcode = 'RGP01', hint = 'BLOCKED';
  end if;
  if p_mode = 'RULE' then
    select q.price, q.rule_ids into v_new, v_rules from private.rg_price_quote(v_res.court_id, v_res.start_at, v_res.end_at) q;
    if v_new is null then
      raise exception 'rg: nenhuma regra de preço cobre este horário' using errcode = 'RGP01', hint = 'NO_RULE';
    end if;
  else
    v_new := p_price;
  end if;
  v_src := case when v_new is null then null when p_mode = 'RULE' then 'RULE' else 'MANUAL' end;
  if v_new is not distinct from v_res.price and v_src is not distinct from v_res.price_source then
    return jsonb_build_object('reservation_id', v_res.id, 'price', v_res.price, 'changed', false);
  end if;
  if v_new is null then
    select f.* into v_fin from private.rg_financials(array[v_res.id]) f;
    if v_fin.net_received > 0 then
      raise exception 'rg: reserva com valor recebido não pode ficar sem preço' using errcode = 'RGP01', hint = 'PRICE_REQUIRED';
    end if;
  end if;
  update public.reservations r set price = v_new, price_source = v_src where r.id = v_res.id;
  perform private.rg_fault('set_price:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'RESERVATION_PRICE_SET', 'reservation', v_res.id, jsonb_build_object(
    'old_price', v_res.price, 'new_price', v_new, 'old_source', v_res.price_source, 'new_source', v_src,
    'mode', p_mode, 'reason', p_reason, 'rule_ids', to_jsonb(v_rules)));
  perform private.rg_fault('set_price:after_audit');
  return jsonb_build_object('reservation_id', v_res.id, 'price', v_new, 'changed', true);
end $$;

-- 4) Guard da origem (SECURITY INVOKER de propósito, como o guard dos GUARDS): current_user reflete
--    QUEM executa; só quem roda como postgres (RPC/trigger do sistema) muda price_source.
create or replace function private.enforce_reservation_price_origin_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.price_source is distinct from old.price_source and current_user <> 'postgres' then
    raise exception 'price_protected: a origem do valor da reserva é definida pelo sistema' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists enforce_reservation_zz_price_origin_guard on public.reservations;
create trigger enforce_reservation_zz_price_origin_guard before update on public.reservations
  for each row execute function private.enforce_reservation_price_origin_guard();

-- 5) Recálculo ao editar (SECURITY DEFINER: usa private.rg_price_quote, sem EXECUTE para a API).
--    Roda DEPOIS dos guards: o que ele altera não é intenção do cliente.
create or replace function private.enforce_reservation_price_reprice()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_price integer;
begin
  if new.start_at is not distinct from old.start_at and new.end_at is not distinct from old.end_at
     and new.court_id is not distinct from old.court_id then
    return new;
  end if;
  -- ocorrência recorrente: valor da série (contrato do mensalista), nunca pela tabela avulsa
  if new.recurring_reservation_id is not null then
    return new;
  end if;
  if new.status not in ('PENDING', 'CONFIRMED', 'NO_SHOW') then
    return new;
  end if;
  -- a própria instrução definiu o valor/origem (caminho autorizado): respeitar
  if new.price is distinct from old.price or new.price_source is distinct from old.price_source then
    return new;
  end if;
  -- só valor automático (RULE) ou reserva sem valor; MANUAL e legado (valor sem origem) nunca.
  -- (IS NOT DISTINCT FROM: com price_source NULL a comparação precisa dar false, nunca NULL)
  if not (old.price_source is not distinct from 'RULE' or (old.price is null and old.price_source is null)) then
    return new;
  end if;
  -- com movimentação financeira ativa o snapshot é preservado (revisão manual)
  if exists (select 1 from public.reservation_payments p where p.reservation_id = old.id and p.voided_at is null) then
    return new;
  end if;
  select q.price into v_price from private.rg_price_quote(new.court_id, new.start_at, new.end_at) q;
  new.price := v_price;
  new.price_source := case when v_price is null then null else 'RULE' end;
  if new.price is not distinct from old.price and new.price_source is not distinct from old.price_source then
    return new;
  end if;
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (new.organization_id, auth.uid(), 'RESERVATION_PRICE_REPRICED', 'reservation', new.id, jsonb_build_object(
    'old_price', old.price, 'new_price', new.price, 'old_source', old.price_source, 'new_source', new.price_source,
    'changed', to_jsonb(array_remove(array[
      case when new.start_at is distinct from old.start_at then 'start_at' end,
      case when new.end_at is distinct from old.end_at then 'end_at' end,
      case when new.court_id is distinct from old.court_id then 'court_id' end], null))));
  perform private.rg_fault('reprice:after_audit');
  return new;
end $$;

drop trigger if exists enforce_reservation_zz_price_reprice on public.reservations;
create trigger enforce_reservation_zz_price_reprice before update on public.reservations
  for each row execute function private.enforce_reservation_price_reprice();

-- 6) Owner e permissões (triggers não exigem EXECUTE do chamador)
alter function private.enforce_reservation_price_snapshot() owner to postgres;
alter function public.rg_reservation_set_price(uuid, text, integer, text) owner to postgres;
alter function private.enforce_reservation_price_origin_guard() owner to postgres;
alter function private.enforce_reservation_price_reprice() owner to postgres;
revoke all on function private.enforce_reservation_price_snapshot() from public, anon, authenticated, service_role;
revoke all on function private.enforce_reservation_price_origin_guard() from public, anon, authenticated, service_role;
revoke all on function private.enforce_reservation_price_reprice() from public, anon, authenticated, service_role;
revoke all on function public.rg_reservation_set_price(uuid, text, integer, text) from public, anon, service_role;
grant execute on function public.rg_reservation_set_price(uuid, text, integer, text) to authenticated;

commit;
