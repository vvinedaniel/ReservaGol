-- =============================================================================
-- RESERVA GOL — FASE 03A — FINANCEIRO DA ARENA — FOUNDATION
-- Normativo: ARCHITECTURE REVIEW Revision 2 + Revision 2.1 (a 2.1 prevalece).
-- DRAFT PARA REVISÃO. Rodar no SQL Editor do Supabase SOMENTE após aprovação explícita.
-- IDEMPOTENTE e segura para reaplicar. NÃO altera nem apaga dados existentes (sem backfill).
--
-- ROLLOUT (D20):
--   1. FOUNDATION (este arquivo) — só ACRESCENTA objetos. Sem regras de preço cadastradas, o
--      trigger de snapshot não muda nenhuma reserva nova (a cotação devolve NULL).
--   2. Testes 03A contra a FOUNDATION (app local).
--   3. migration_phase3a_guards.sql — protege reservations.price e bloqueia novas escritas PAID.
--   4. Suíte final em modo GUARDS -> PR -> merge -> primeiro deploy.
--
-- PRÉ-REQUISITO: B3 FOUNDATION aplicada (reutiliza private.rg_fault para os testes de rollback).
--
-- Autoridade de cada informação (D1/D2):
--   reservations.status          = situação OPERACIONAL (PAID = legado congelado);
--   reservations.price           = SNAPSHOT histórico do valor contratado (centavos);
--   public.reservation_payments  = dinheiro efetivamente movimentado (ledger append-only);
--   payment_status / saldos      = CALCULADOS (private.rg_financials), nunca persistidos;
--   public.court_pricing_rules   = tabela de preços (usada só no momento do snapshot).
--
-- Fronteira (lockdown desde o início):
--   * authenticated: SELECT (RLS) nas tabelas novas; NENHUMA escrita direta; ledger só OWNER/MANAGER;
--   * toda escrita financeira = RPC SECURITY DEFINER (owner postgres, search_path = '') com
--     auth.uid() obrigatório, tenant derivado no banco e audit_logs na MESMA transação;
--   * anon: nada. service_role: sem EXECUTE nas RPCs; SELECT (+ DELETE só em org demo).
--   ATENÇÃO: os default privileges deste projeto concedem ALL/EXECUTE a anon/authenticated em
--   objetos novos do schema public — por isso cada objeto recebe REVOKE explícito.
--
-- SQLSTATEs novos:
--   RGP01 = estado financeiro inválido para a operação;
--   RGP02 = operation_id reutilizado com intenção diferente (idempotency mismatch);
--   RGP03 = limite de valor excedido (sobrepagamento / estorno acima do pago).
-- Padrão: 42501, P0002, 22023, 23514, 23P01, RGT01/RGT02 (A2), RGF01 (falha injetada, B3).
--
-- Ordem dos BEFORE INSERT triggers em reservations após a FOUNDATION (alfabética):
--   enforce_reservation_tenant (A2) -> enforce_reservation_zz_price_snapshot (03A) ->
--   validate_reservation_recurring (02C) -> validate_reservation_zz_series_occurrence (B3/D7).
--   (os GUARDS acrescentam enforce_reservation_zz_price_guard, que roda ANTES do snapshot)
-- =============================================================================
begin;

do $$ begin
  if to_regprocedure('private.rg_fault(text)') is null then
    raise exception '03A: B3 FOUNDATION ausente (private.rg_fault não existe)';
  end if;
end $$;

-- =============================================================================
-- 1) court_pricing_rules — tabela de preços por hora (centavos)
-- =============================================================================
-- Uma regra = (escopo, dia da semana, faixa [start, end) do MESMO dia, validade).
-- Escopo explícito (Revision 2.1): scope_kind ARENA (court_id NULL, vale para a arena inteira) ou
-- COURT; scope_key = arena_id ou court_id. Ambas GERADAS (ninguém grava).
-- Minutos: start_time 00:00 -> 0; end_time 00:00 -> 1440 (meia-noite do fim do dia). Uma regra
-- nunca atravessa a meia-noite (start_minute < end_minute); uma RESERVA pode atravessar.
create table if not exists public.court_pricing_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  arena_id uuid not null references public.arenas(id) on delete restrict,
  court_id uuid references public.courts(id) on delete restrict,
  scope_kind text generated always as (case when court_id is null then 'ARENA' else 'COURT' end) stored,
  scope_key uuid generated always as (coalesce(court_id, arena_id)) stored,
  weekday smallint not null,
  start_time time not null,
  end_time time not null,
  start_minute integer generated always as (
    (extract(hour from start_time) * 60 + extract(minute from start_time))::integer) stored,
  end_minute integer generated always as (
    case when end_time = time '00:00' then 1440
         else (extract(hour from end_time) * 60 + extract(minute from end_time))::integer end) stored,
  price_per_hour integer not null,
  valid_from date,
  valid_until date,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint court_pricing_rules_scope_kind_chk check (scope_kind in ('ARENA', 'COURT')),
  constraint court_pricing_rules_weekday_chk check (weekday between 0 and 6),
  constraint court_pricing_rules_seconds_chk check (extract(second from start_time) = 0 and extract(second from end_time) = 0),
  constraint court_pricing_rules_range_chk check (start_minute < end_minute),
  constraint court_pricing_rules_price_chk check (price_per_hour between 0 and 10000000),
  constraint court_pricing_rules_validity_chk check (valid_from is null or valid_until is null or valid_until >= valid_from),
  -- Antiambiguidade (D7): no MESMO escopo explícito, nenhuma sobreposição ativa de dia/faixa/validade.
  constraint court_pricing_rules_no_overlap exclude using gist (
    organization_id with =,
    arena_id with =,
    scope_kind with =,
    scope_key with =,
    weekday with =,
    int4range(start_minute, end_minute) with &&,
    daterange(valid_from, valid_until, '[]') with &&
  ) where (active)
);

create index if not exists idx_pricing_rules_arena_weekday on public.court_pricing_rules (arena_id, weekday) where active;
create index if not exists idx_pricing_rules_court on public.court_pricing_rules (court_id) where court_id is not null;

drop trigger if exists trg_court_pricing_rules_updated on public.court_pricing_rules;
create trigger trg_court_pricing_rules_updated before update on public.court_pricing_rules
  for each row execute function public.set_updated_at();

-- Integridade da regra, para QUALQUER escritor (inclusive service_role):
--   tenant (RGT01), vínculos/escopo/dia imutáveis (RGT02), desativação terminal (RGP01).
--   created_by pode apenas virar NULL (FK ON DELETE SET NULL da conta removida).
create or replace function private.enforce_pricing_rule_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.arenas a where a.id = new.arena_id and a.organization_id = new.organization_id) then
    raise exception 'tenant_mismatch: arena não pertence à organização da regra' using errcode = 'RGT01';
  end if;
  if new.court_id is not null and not exists (
    select 1 from public.courts c where c.id = new.court_id and c.organization_id = new.organization_id and c.arena_id = new.arena_id) then
    raise exception 'tenant_mismatch: quadra não pertence à organização/arena da regra' using errcode = 'RGT01';
  end if;
  if tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.arena_id is distinct from old.arena_id
       or new.court_id is distinct from old.court_id or new.weekday is distinct from old.weekday
       or new.created_at is distinct from old.created_at
       or (new.created_by is distinct from old.created_by and new.created_by is not null) then
      raise exception 'structural_link_immutable: escopo/dia da regra de preço não podem ser alterados' using errcode = 'RGT02';
    end if;
    if not old.active and row(new.start_time, new.end_time, new.price_per_hour, new.valid_from, new.valid_until, new.active)
                          is distinct from row(old.start_time, old.end_time, old.price_per_hour, old.valid_from, old.valid_until, old.active) then
      raise exception 'pricing_rule_inactive: regra desativada não pode ser alterada' using errcode = 'RGP01', hint = 'RULE_INACTIVE';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists enforce_pricing_rule_integrity on public.court_pricing_rules;
create trigger enforce_pricing_rule_integrity before insert or update on public.court_pricing_rules
  for each row execute function private.enforce_pricing_rule_integrity();

-- =============================================================================
-- 2) reservation_payments — ledger append-only (centavos)
-- =============================================================================
create table if not exists public.reservation_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  arena_id uuid not null references public.arenas(id) on delete restrict,
  reservation_id uuid not null references public.reservations(id) on delete restrict,
  kind text not null,
  refund_of uuid references public.reservation_payments(id) on delete restrict,
  method text not null,
  amount integer not null,
  received_at timestamptz not null,
  notes text,
  source text not null default 'MANUAL',
  external_provider text,
  external_reference text,
  operation_id uuid not null,
  operation_fingerprint bytea not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text,
  constraint reservation_payments_kind_chk check (kind in ('PAYMENT', 'REFUND')),
  constraint reservation_payments_refund_chk check ((kind = 'REFUND') = (refund_of is not null)),
  constraint reservation_payments_method_chk check (method in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER')),
  constraint reservation_payments_amount_chk check (amount between 1 and 10000000),
  constraint reservation_payments_source_chk check (source in ('MANUAL', 'GATEWAY')),
  constraint reservation_payments_external_chk check (
    (source = 'MANUAL' and external_provider is null and external_reference is null)
    or (source = 'GATEWAY' and external_provider is not null and external_reference is not null)),
  constraint reservation_payments_fingerprint_chk check (octet_length(operation_fingerprint) = 32),
  constraint reservation_payments_notes_chk check (notes is null or (notes = btrim(notes) and notes <> '' and char_length(notes) <= 500)),
  constraint reservation_payments_void_chk check (
    ((voided_at is null) = (void_reason is null)) and (voided_at is not null or voided_by is null)),
  constraint reservation_payments_void_reason_chk check (void_reason is null or (btrim(void_reason) <> '' and char_length(void_reason) <= 500))
);

-- Idempotência escopada por organização (D9) e referência externa única (03C).
create unique index if not exists idx_payments_org_operation on public.reservation_payments (organization_id, operation_id);
create unique index if not exists idx_payments_org_external on public.reservation_payments (organization_id, external_provider, external_reference)
  where source = 'GATEWAY';
create index if not exists idx_payments_reservation on public.reservation_payments (reservation_id);
create index if not exists idx_payments_refund_of on public.reservation_payments (refund_of) where refund_of is not null;
create index if not exists idx_payments_org_received on public.reservation_payments (organization_id, received_at);
create index if not exists idx_payments_arena_received on public.reservation_payments (arena_id, received_at);

-- INSERT (qualquer escritor): tenant = reserva (RGT01); received_at <= agora + 5 min (D10, sem limite
-- inferior); REFUND só para PAYMENT válido da MESMA reserva/org/arena, com teto por PAYMENT (D8).
-- O PAYMENT de origem é travado (FOR UPDATE) para serializar estornos concorrentes e VOID.
create or replace function private.enforce_payment_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_parent public.reservation_payments;
  v_refunded bigint;
begin
  if not exists (select 1 from public.reservations r
                  where r.id = new.reservation_id and r.organization_id = new.organization_id and r.arena_id = new.arena_id) then
    raise exception 'tenant_mismatch: lançamento não corresponde à organização/arena da reserva' using errcode = 'RGT01';
  end if;
  if new.received_at > now() + interval '5 minutes' then
    raise exception 'payment_invalid: received_at no futuro' using errcode = '23514';
  end if;
  if new.kind = 'REFUND' then
    select p.* into v_parent from public.reservation_payments p where p.id = new.refund_of for update;
    if not found or v_parent.kind <> 'PAYMENT' or v_parent.voided_at is not null
       or v_parent.reservation_id <> new.reservation_id or v_parent.organization_id <> new.organization_id
       or v_parent.arena_id <> new.arena_id then
      raise exception 'payment_invalid: estorno deve referenciar um pagamento válido da mesma reserva' using errcode = '23514';
    end if;
    select coalesce(sum(c.amount), 0) into v_refunded from public.reservation_payments c
     where c.refund_of = new.refund_of and c.voided_at is null;
    if v_refunded + new.amount > v_parent.amount then
      raise exception 'payment_limit: estornos acima do valor do pagamento' using errcode = 'RGP03', hint = 'OVER_REFUNDABLE';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists enforce_payment_integrity on public.reservation_payments;
create trigger enforce_payment_integrity before insert on public.reservation_payments
  for each row execute function private.enforce_payment_integrity();

-- UPDATE (qualquer escritor): a intenção do lançamento é IMUTÁVEL (RGT02). A única transição é
-- VOID (voided_at/voided_by/void_reason, uma vez); PAYMENT com estorno válido não pode ser anulado
-- (RGP01). created_by/voided_by podem apenas virar NULL (FK ON DELETE SET NULL).
create or replace function private.protect_payment_ledger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if row(new.id, new.organization_id, new.arena_id, new.reservation_id, new.kind, new.refund_of, new.method,
         new.amount, new.received_at, new.notes, new.source, new.external_provider, new.external_reference,
         new.operation_id, new.operation_fingerprint, new.created_at)
     is distinct from row(old.id, old.organization_id, old.arena_id, old.reservation_id, old.kind, old.refund_of, old.method,
         old.amount, old.received_at, old.notes, old.source, old.external_provider, old.external_reference,
         old.operation_id, old.operation_fingerprint, old.created_at)
     or (new.created_by is distinct from old.created_by and new.created_by is not null) then
    raise exception 'ledger_immutable: lançamento financeiro não pode ser alterado' using errcode = 'RGT02';
  end if;
  if old.voided_at is not null then
    if new.voided_at is distinct from old.voided_at or new.void_reason is distinct from old.void_reason
       or (new.voided_by is distinct from old.voided_by and new.voided_by is not null) then
      raise exception 'ledger_immutable: anulação já registrada' using errcode = 'RGT02';
    end if;
  elsif new.voided_at is null then
    if new.voided_by is not null or new.void_reason is not null then
      raise exception 'ledger_immutable: dados de anulação sem anulação' using errcode = 'RGT02';
    end if;
  elsif old.kind = 'PAYMENT' and exists (
    select 1 from public.reservation_payments c where c.refund_of = old.id and c.voided_at is null) then
    raise exception 'payment_state: pagamento com estorno válido não pode ser anulado' using errcode = 'RGP01', hint = 'HAS_REFUNDS';
  end if;
  return new;
end $$;

drop trigger if exists protect_payment_ledger on public.reservation_payments;
create trigger protect_payment_ledger before update on public.reservation_payments
  for each row execute function private.protect_payment_ledger();

-- DELETE (D18): histórico financeiro e tabela de preços só podem ser apagados em organização demo
-- (limpeza de fixtures dos harnesses). Vale para todos os papéis, inclusive service_role.
create or replace function private.guard_finance_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.organizations o where o.id = old.organization_id and not o.is_demo) then
    raise exception 'finance_history: registros financeiros não podem ser apagados' using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists guard_payment_delete on public.reservation_payments;
create trigger guard_payment_delete before delete on public.reservation_payments
  for each row execute function private.guard_finance_delete();
drop trigger if exists guard_pricing_rule_delete on public.court_pricing_rules;
create trigger guard_pricing_rule_delete before delete on public.court_pricing_rules
  for each row execute function private.guard_finance_delete();

-- =============================================================================
-- 3) Helpers privados (executados só por dentro das RPCs/triggers, como postgres)
-- =============================================================================

-- Cotação por INTERSEÇÃO DE INTERVALOS (D5/D6) — sem iterar minuto a minuto, só centavos inteiros.
--   1. converte [start, end) para o horário local de America/Sao_Paulo;
--   2. corta em segmentos por DIA LOCAL (reserva pode cruzar a meia-noite; no máximo 2 dias);
--   3. candidatas = regras ativas da arena (escopo ARENA) ou da quadra (COURT) com o weekday e a
--      validade do dia do segmento, cuja faixa toca o segmento; parte = segmento * faixa;
--   4. minutos efetivos: COURT = len(parte); ARENA = len(parte) − Σ len(parte ∩ parte COURT)
--      (partes do mesmo escopo são disjuntas pela exclusion constraint => subtração exata);
--   5. cobertura integral obrigatória (senão price NULL);
--   6. total = (Σ price_per_hour × minutos + 30) / 60 — half-up aplicado SOMENTE no total.
-- Entradas inválidas (NULL, fim <= início, > 24h, segundos) => price NULL (nunca adivinha).
create or replace function private.rg_price_quote(p_court_id uuid, p_start_at timestamptz, p_end_at timestamptz)
returns table (price integer, covered boolean, rule_ids uuid[])
language plpgsql stable set search_path = '' as $$
declare
  v_org uuid;
  v_arena uuid;
  v_ls timestamp;
  v_le timestamp;
  v_needed bigint;
  v_cov bigint;
  v_sum bigint;
  v_ids uuid[];
begin
  price := null; covered := false; rule_ids := '{}'::uuid[];
  if p_court_id is null or p_start_at is null or p_end_at is null or p_end_at <= p_start_at
     or p_end_at - p_start_at > interval '24 hours' then
    return next; return;
  end if;
  select c.organization_id, c.arena_id into v_org, v_arena from public.courts c where c.id = p_court_id;
  if v_arena is null then
    return next; return;
  end if;
  v_ls := p_start_at at time zone 'America/Sao_Paulo';
  v_le := p_end_at at time zone 'America/Sao_Paulo';
  if date_trunc('minute', v_ls) <> v_ls or date_trunc('minute', v_le) <> v_le then
    return next; return;
  end if;

  with segments as (
    select g.d::date as day,
           extract(dow from g.d)::integer as wd,
           int4range(
             case when g.d::date = v_ls::date then (extract(hour from v_ls) * 60 + extract(minute from v_ls))::integer else 0 end,
             case when g.d::date = v_le::date then (extract(hour from v_le) * 60 + extract(minute from v_le))::integer else 1440 end) as seg
      from generate_series(v_ls::date::timestamp, (v_le - interval '1 microsecond')::date::timestamp, interval '1 day') as g(d)
  ),
  cand as (
    select s.day, r.id, r.price_per_hour, r.scope_kind,
           s.seg * int4range(r.start_minute, r.end_minute) as part
      from segments s
      join public.court_pricing_rules r
        on r.active
       and r.organization_id = v_org
       and r.arena_id = v_arena
       and ((r.scope_kind = 'COURT' and r.court_id = p_court_id) or r.scope_kind = 'ARENA')
       and r.weekday = s.wd
       and daterange(r.valid_from, r.valid_until, '[]') @> s.day
       and int4range(r.start_minute, r.end_minute) && s.seg
  ),
  eff as (
    select c.id, c.price_per_hour,
           (upper(c.part) - lower(c.part))
           - case when c.scope_kind = 'COURT' then 0 else coalesce((
               select sum(upper(c.part * k.part) - lower(c.part * k.part))
                 from cand k
                where k.scope_kind = 'COURT' and k.day = c.day and c.part && k.part), 0) end as mins
      from cand c
  )
  select (select coalesce(sum(upper(s.seg) - lower(s.seg)), 0) from segments s),
         coalesce(sum(e.mins), 0),
         coalesce(sum(e.price_per_hour::bigint * e.mins), 0),
         coalesce(array_agg(e.id order by e.id) filter (where e.mins > 0), '{}'::uuid[])
    into v_needed, v_cov, v_sum, v_ids
    from eff e;

  if v_needed > 0 and v_cov = v_needed then
    covered := true;
    price := ((v_sum + 30) / 60)::integer;
    rule_ids := v_ids;
  end if;
  return next;
end $$;

-- Situação financeira CALCULADA (D1/D3/D4) de um conjunto de reservas. Nunca persistida.
--   amount_due = price (snapshot); received/refunded = Σ lançamentos não anulados;
--   net = received − refunded; balance = due − net; collectible = status ainda cobrável;
--   collectible_balance = única base do "a receber".
create or replace function private.rg_financials(p_ids uuid[])
returns table (
  reservation_id uuid, organization_id uuid, status text, amount_due integer,
  amount_received bigint, amount_refunded bigint, net_received bigint, balance bigint,
  collectible boolean, collectible_balance bigint, payment_status text)
language sql stable set search_path = '' as $$
  select r.id, r.organization_id, r.status, r.price,
         m.rec, m.ref, m.rec - m.ref,
         case when r.price is null then null else r.price - (m.rec - m.ref) end,
         r.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID'),
         case when r.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID') and r.price is not null
              then greatest(r.price - (m.rec - m.ref), 0) else 0 end,
         case
           when r.status = 'BLOCKED' then 'NOT_APPLICABLE'
           when r.status = 'CANCELLED' then
             case when m.rec = 0 then 'CANCELLED'
                  when m.rec - m.ref = 0 then 'REFUNDED'
                  else 'RETAINED' end
           when r.price is null then 'UNPRICED'
           when m.rec - m.ref = 0 and r.price > 0 then 'PENDING'
           when m.rec - m.ref < r.price then 'PARTIAL'
           when m.rec - m.ref = r.price then 'PAID'
           else 'OVERPAID'
         end
    from public.reservations r
    cross join lateral (
      select coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint as rec,
             coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint as ref
        from public.reservation_payments p
       where p.reservation_id = r.id and p.voided_at is null) m
   where r.id = any(coalesce(p_ids, '{}'::uuid[]))
$$;

-- Autorização + trava da reserva (autorização ANTES da trava; inexistente e outro tenant = mesmo erro).
create or replace function private.rg_fin_lock_reservation(p_reservation_id uuid, p_require_manager boolean)
returns public.reservations language plpgsql set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_res public.reservations;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select r.organization_id into v_org from public.reservations r where r.id = p_reservation_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: reserva não encontrada' using errcode = 'P0002';
  end if;
  if p_require_manager and not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para esta operação financeira' using errcode = '42501';
  end if;
  select r.* into v_res from public.reservations r where r.id = p_reservation_id for update;
  return v_res;
end $$;

-- Observação normalizada (mesma regra gravada no ledger): trim; vazio -> NULL; máx. 500.
create or replace function private.rg_fin_notes(p_notes text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text := nullif(btrim(p_notes), '');
begin
  if v is not null and char_length(v) > 500 then
    raise exception 'rg: observação muito longa' using errcode = '22023';
  end if;
  return v;
end $$;

-- Intenção normalizada COMPLETA (D9) e seu fingerprint SHA-256 (sem PII em claro no banco).
-- jsonb tem ordem de chaves canônica => jsonb::text determinístico. received_at em UTC com µs.
create or replace function private.rg_fin_fingerprint(
  p_kind text, p_reservation_id uuid, p_refund_of uuid, p_amount integer, p_method text,
  p_received_at timestamptz, p_notes text)
returns bytea language sql stable set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object(
    'v', 1,
    'kind', p_kind,
    'reservation_id', p_reservation_id,
    'refund_of', p_refund_of,
    'amount', p_amount,
    'method', p_method,
    'received_at', to_char(p_received_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'notes', p_notes)::text, 'UTF8'))
$$;

create or replace function private.rg_fin_validate_entry(p_operation_id uuid, p_method text, p_amount integer, p_received_at timestamptz)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER') then
    raise exception 'rg: meio de pagamento inválido' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000000 then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  if p_received_at is null then
    raise exception 'rg: received_at é obrigatório' using errcode = '22023';
  end if;
end $$;

-- =============================================================================
-- 4) Snapshot automático do preço (INSERT de reserva comum) — D2/D22
-- =============================================================================
-- SECURITY DEFINER (owner postgres): chama private.rg_price_quote, que NÃO tem EXECUTE para
-- nenhum papel de API. Só age em reserva NÃO recorrente, não BLOCKED e sem preço informado.
-- Ocorrência recorrente: não precifica e não interfere (D7/B3 é a autoridade).
create or replace function private.enforce_reservation_price_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_price integer;
begin
  if new.recurring_reservation_id is not null or new.status = 'BLOCKED' or new.price is not null then
    return new;
  end if;
  select q.price into v_price from private.rg_price_quote(new.court_id, new.start_at, new.end_at) q;
  new.price := v_price;
  return new;
end $$;

drop trigger if exists enforce_reservation_zz_price_snapshot on public.reservations;
create trigger enforce_reservation_zz_price_snapshot before insert on public.reservations
  for each row execute function private.enforce_reservation_price_snapshot();

-- =============================================================================
-- 5) RPCs públicas (SECURITY DEFINER, owner postgres, search_path = '', EXECUTE só authenticated)
-- =============================================================================

-- Cotação (qualquer membro). Entradas inválidas => 22023; sem cobertura => price NULL.
create or replace function public.rg_price_quote(p_court_id uuid, p_start_at timestamptz, p_end_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_q record;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select c.organization_id into v_org from public.courts c where c.id = p_court_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: quadra não encontrada' using errcode = 'P0002';
  end if;
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at or p_end_at - p_start_at > interval '24 hours'
     or date_trunc('minute', p_start_at) <> p_start_at or date_trunc('minute', p_end_at) <> p_end_at then
    raise exception 'rg: intervalo inválido para cotação' using errcode = '22023';
  end if;
  select * into v_q from private.rg_price_quote(p_court_id, p_start_at, p_end_at);
  return jsonb_build_object('price', v_q.price, 'covered', v_q.covered, 'rule_ids', to_jsonb(v_q.rule_ids));
end $$;

-- Validação comum das regras (22023 antes das constraints, mensagem sem detalhes internos).
create or replace function private.rg_pricing_validate(p_start time, p_end time, p_price integer, p_from date, p_until date)
returns void language plpgsql immutable set search_path = '' as $$
declare v_s integer; v_e integer;
begin
  if p_start is null or p_end is null or extract(second from p_start) <> 0 or extract(second from p_end) <> 0 then
    raise exception 'rg: horário inválido' using errcode = '22023';
  end if;
  v_s := (extract(hour from p_start) * 60 + extract(minute from p_start))::integer;
  v_e := case when p_end = time '00:00' then 1440 else (extract(hour from p_end) * 60 + extract(minute from p_end))::integer end;
  if v_s >= v_e then
    raise exception 'rg: a faixa da regra não pode atravessar a meia-noite' using errcode = '22023';
  end if;
  if p_price is null or p_price < 0 or p_price > 10000000 then
    raise exception 'rg: valor por hora inválido' using errcode = '22023';
  end if;
  if p_from is not null and p_until is not null and p_until < p_from then
    raise exception 'rg: validade inválida' using errcode = '22023';
  end if;
end $$;

-- CREATE: UMA ação do usuário = UMA operação atômica (Revision 2.1 + correção multi-day). Recebe a
-- INTENÇÃO ORIGINAL — vários dias da semana + UMA faixa — e materializa todas as linhas NA MESMA
-- TRANSAÇÃO (sem tabela de grupos). Para CADA dia (normalizado em ordem crescente):
--   start < end                  -> 1 linha  [start, end)   no dia;
--   end = 00:00 (qualquer start) -> 1 linha  [start, 1440)  no dia;
--   end < start e end <> 00:00   -> 2 linhas [start, 1440) no dia e [0, end) em (dia + 1) % 7;
--   start = end (<> 00:00)       -> 22023.
-- p_weekdays: obrigatório, 1..7 elementos, cada um em 0..6, SEM duplicados (duplicado = 22023, para
-- denunciar bug de cliente em vez de normalizar silenciosamente).
-- Qualquer falha em QUALQUER linha (exclusion 23P01, tenant, constraint, audit, falha injetada)
-- desfaz a intenção inteira: todos os dias ou nenhum. UM audit por intenção.
-- Pontos de falha injetada (testes de rollback): pricing_create:after_first_insert,
-- pricing_create:midway (após a linha max(1, N/2)), pricing_create:after_all_inserts,
-- pricing_create:after_audit.
-- Assinatura antiga (um único smallint) de rascunhos anteriores: removida para não sobrar overload.
drop function if exists public.rg_pricing_rule_create(uuid, uuid, smallint, time, time, integer, date, date);
create or replace function public.rg_pricing_rule_create(
  p_arena_id uuid, p_court_id uuid, p_weekdays smallint[], p_start_time time, p_end_time time,
  p_price_per_hour integer, p_valid_from date, p_valid_until date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_days smallint[];
  v_wd smallint;
  v_s integer;
  v_e integer;
  v_split boolean;
  v_total integer;
  v_mid integer;
  v_done integer := 0;
  v_id uuid;
  v_ids uuid[] := '{}'::uuid[];
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select a.organization_id into v_org from public.arenas a where a.id = p_arena_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: arena não encontrada' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para gerenciar preços' using errcode = '42501';
  end if;
  if p_court_id is not null and not exists (
    select 1 from public.courts c where c.id = p_court_id and c.arena_id = p_arena_id and c.organization_id = v_org) then
    raise exception 'rg: quadra não encontrada' using errcode = 'P0002';
  end if;

  -- Dias: obrigatório, 1..7, sem NULL, 0..6, sem duplicados; ordem determinística.
  if p_weekdays is null or coalesce(cardinality(p_weekdays), 0) < 1 or cardinality(p_weekdays) > 7
     or array_position(p_weekdays, null) is not null then
    raise exception 'rg: informe de 1 a 7 dias da semana' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_weekdays) as d where d < 0 or d > 6) then
    raise exception 'rg: dia da semana inválido' using errcode = '22023';
  end if;
  if (select count(distinct d) from unnest(p_weekdays) as d) <> cardinality(p_weekdays) then
    raise exception 'rg: dias da semana duplicados' using errcode = '22023';
  end if;
  select array_agg(d order by d) into v_days from unnest(p_weekdays) as d;

  -- Faixa (a mesma para todos os dias).
  if p_start_time is null or p_end_time is null or extract(second from p_start_time) <> 0 or extract(second from p_end_time) <> 0 then
    raise exception 'rg: horário inválido' using errcode = '22023';
  end if;
  v_s := (extract(hour from p_start_time) * 60 + extract(minute from p_start_time))::integer;
  v_e := (extract(hour from p_end_time) * 60 + extract(minute from p_end_time))::integer;   -- 00:00 -> 0 aqui
  if v_e <> 0 and v_e = v_s then
    raise exception 'rg: horário final igual ao inicial' using errcode = '22023';
  end if;
  v_split := v_e <> 0 and v_e < v_s;
  if v_split then
    perform private.rg_pricing_validate(p_start_time, time '00:00', p_price_per_hour, p_valid_from, p_valid_until);
    perform private.rg_pricing_validate(time '00:00', p_end_time, p_price_per_hour, p_valid_from, p_valid_until);
  else
    perform private.rg_pricing_validate(p_start_time, p_end_time, p_price_per_hour, p_valid_from, p_valid_until);
  end if;

  v_total := cardinality(v_days) * case when v_split then 2 else 1 end;
  v_mid := greatest(1, v_total / 2);

  foreach v_wd in array v_days loop
    insert into public.court_pricing_rules (organization_id, arena_id, court_id, weekday, start_time, end_time,
      price_per_hour, valid_from, valid_until, active, created_by)
    values (v_org, p_arena_id, p_court_id, v_wd, p_start_time, case when v_split then time '00:00' else p_end_time end,
      p_price_per_hour, p_valid_from, p_valid_until, true, v_uid)
    returning id into v_id;
    v_ids := array_append(v_ids, v_id);
    v_done := v_done + 1;
    if v_done = 1 then perform private.rg_fault('pricing_create:after_first_insert'); end if;
    if v_done = v_mid then perform private.rg_fault('pricing_create:midway'); end if;

    if v_split then
      insert into public.court_pricing_rules (organization_id, arena_id, court_id, weekday, start_time, end_time,
        price_per_hour, valid_from, valid_until, active, created_by)
      values (v_org, p_arena_id, p_court_id, ((v_wd + 1) % 7)::smallint, time '00:00', p_end_time,
        p_price_per_hour, p_valid_from, p_valid_until, true, v_uid)
      returning id into v_id;
      v_ids := array_append(v_ids, v_id);
      v_done := v_done + 1;
      if v_done = v_mid then perform private.rg_fault('pricing_create:midway'); end if;
    end if;
  end loop;
  perform private.rg_fault('pricing_create:after_all_inserts');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'PRICING_RULE_CREATED', 'court_pricing_rule', v_ids[1], jsonb_build_object(
    'arena_id', p_arena_id, 'court_id', p_court_id, 'weekdays', to_jsonb(v_days),
    'start_time', p_start_time, 'end_time', p_end_time, 'price_per_hour', p_price_per_hour,
    'valid_from', p_valid_from, 'valid_until', p_valid_until, 'split', v_split,
    'rule_ids', to_jsonb(v_ids), 'rules_created', cardinality(v_ids)));
  perform private.rg_fault('pricing_create:after_audit');
  return jsonb_build_object('rule_ids', to_jsonb(v_ids), 'weekdays', to_jsonb(v_days), 'split', v_split,
    'rules_created', cardinality(v_ids));
end $$;

-- UPDATE: lista FECHADA de chaves; escopo e dia da semana são imutáveis (desativar + criar outra).
create or replace function public.rg_pricing_rule_update(p_rule_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_changes jsonb := coalesce(p_changes, '{}'::jsonb);
  v_org uuid;
  v_old public.court_pricing_rules;
  v_start time;
  v_end time;
  v_price integer;
  v_from date;
  v_until date;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if jsonb_typeof(v_changes) <> 'object' then
    raise exception 'rg: alteração não permitida' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_changes) as k
              where k not in ('start_time', 'end_time', 'price_per_hour', 'valid_from', 'valid_until')) then
    raise exception 'rg: alteração não permitida' using errcode = '22023';
  end if;
  select r.organization_id into v_org from public.court_pricing_rules r where r.id = p_rule_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: regra não encontrada' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para gerenciar preços' using errcode = '42501';
  end if;
  select r.* into v_old from public.court_pricing_rules r where r.id = p_rule_id for update;
  if not v_old.active then
    raise exception 'rg: regra desativada não pode ser alterada' using errcode = 'RGP01', hint = 'RULE_INACTIVE';
  end if;

  v_start := case when v_changes ? 'start_time' then (v_changes->>'start_time')::time else v_old.start_time end;
  v_end := case when v_changes ? 'end_time' then (v_changes->>'end_time')::time else v_old.end_time end;
  v_price := case when v_changes ? 'price_per_hour' then (v_changes->>'price_per_hour')::integer else v_old.price_per_hour end;
  v_from := case when v_changes ? 'valid_from' then (v_changes->>'valid_from')::date else v_old.valid_from end;
  v_until := case when v_changes ? 'valid_until' then (v_changes->>'valid_until')::date else v_old.valid_until end;
  perform private.rg_pricing_validate(v_start, v_end, v_price, v_from, v_until);

  if row(v_start, v_end, v_price, v_from, v_until)
     is not distinct from row(v_old.start_time, v_old.end_time, v_old.price_per_hour, v_old.valid_from, v_old.valid_until) then
    return jsonb_build_object('rule_id', v_old.id, 'changed', false);
  end if;

  update public.court_pricing_rules r
     set start_time = v_start, end_time = v_end, price_per_hour = v_price, valid_from = v_from, valid_until = v_until
   where r.id = v_old.id;
  perform private.rg_fault('pricing_update:after_update');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'PRICING_RULE_UPDATED', 'court_pricing_rule', v_old.id, jsonb_build_object(
    'before', jsonb_build_object('start_time', v_old.start_time, 'end_time', v_old.end_time, 'price_per_hour', v_old.price_per_hour,
                                 'valid_from', v_old.valid_from, 'valid_until', v_old.valid_until),
    'after', jsonb_build_object('start_time', v_start, 'end_time', v_end, 'price_per_hour', v_price,
                                'valid_from', v_from, 'valid_until', v_until)));
  perform private.rg_fault('pricing_update:after_audit');
  return jsonb_build_object('rule_id', v_old.id, 'changed', true);
end $$;

-- DEACTIVATE: terminal; repetido = no-op (sem audit).
create or replace function public.rg_pricing_rule_deactivate(p_rule_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_rule public.court_pricing_rules;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select r.organization_id into v_org from public.court_pricing_rules r where r.id = p_rule_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: regra não encontrada' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para gerenciar preços' using errcode = '42501';
  end if;
  select r.* into v_rule from public.court_pricing_rules r where r.id = p_rule_id for update;
  if not v_rule.active then
    return jsonb_build_object('rule_id', v_rule.id, 'changed', false);
  end if;
  update public.court_pricing_rules r set active = false where r.id = v_rule.id;
  perform private.rg_fault('pricing_deactivate:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'PRICING_RULE_DEACTIVATED', 'court_pricing_rule', v_rule.id, jsonb_build_object(
    'arena_id', v_rule.arena_id, 'court_id', v_rule.court_id, 'weekday', v_rule.weekday));
  perform private.rg_fault('pricing_deactivate:after_audit');
  return jsonb_build_object('rule_id', v_rule.id, 'changed', true);
end $$;

-- PAYMENT (qualquer membro). Ordem D9: auth -> tenant/autorização -> trava -> replay/RGP02 ->
-- estado MUTÁVEL -> nova operação. Um replay confirmado nunca falha por estado posterior.
create or replace function public.rg_payment_register(
  p_operation_id uuid, p_reservation_id uuid, p_method text, p_amount integer, p_received_at timestamptz, p_notes text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_notes text;
  v_res public.reservations;
  v_fp bytea;
  v_existing public.reservation_payments;
  v_fin record;
  v_id uuid;
  v_constraint text;
  v_conflict boolean := false;
begin
  -- 1) autenticar (+ forma imutável da intenção)
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  perform private.rg_fin_validate_entry(p_operation_id, p_method, p_amount, p_received_at);
  v_notes := private.rg_fin_notes(p_notes);
  -- 2) tenant/autorização + 3) trava da reserva
  v_res := private.rg_fin_lock_reservation(p_reservation_id, false);
  -- 4) operation_id já confirmado?
  v_fp := private.rg_fin_fingerprint('PAYMENT', v_res.id, null, p_amount, p_method, p_received_at, v_notes);
  select p.* into v_existing from public.reservation_payments p
   where p.organization_id = v_res.organization_id and p.operation_id = p_operation_id;
  if found then
    -- 5) mesma intenção => replay imediato; 6) diferente => RGP02
    if v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'reservation_id', v_existing.reservation_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  -- 7) estado mutável atual
  if v_res.status not in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID') then
    raise exception 'rg: a situação da reserva não permite registrar pagamento' using errcode = 'RGP01', hint = 'RESERVATION_STATE';
  end if;
  if v_res.price is null then
    raise exception 'rg: defina o valor da reserva antes de registrar pagamento' using errcode = 'RGP01', hint = 'UNPRICED';
  end if;
  select f.* into v_fin from private.rg_financials(array[v_res.id]) f;
  if p_amount > v_fin.collectible_balance then
    raise exception 'rg: valor acima do saldo a receber' using errcode = 'RGP03', hint = 'OVER_BALANCE';
  end if;
  -- 8) nova operação (corrida do mesmo operation_id em OUTRA reserva => 23505 => reler)
  begin
    insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, refund_of, method, amount,
      received_at, notes, source, operation_id, operation_fingerprint, created_by)
    values (v_res.organization_id, v_res.arena_id, v_res.id, 'PAYMENT', null, p_method, p_amount,
      p_received_at, v_notes, 'MANUAL', p_operation_id, v_fp, v_uid)
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_payments_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select p.* into v_existing from public.reservation_payments p
     where p.organization_id = v_res.organization_id and p.operation_id = p_operation_id;
    if found and v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'reservation_id', v_existing.reservation_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('payment:after_insert');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'PAYMENT_RECORDED', 'reservation_payment', v_id,
    jsonb_build_object('reservation_id', v_res.id, 'amount', p_amount, 'method', p_method));
  perform private.rg_fault('payment:after_audit');
  return jsonb_build_object('payment_id', v_id, 'reservation_id', v_res.id, 'idempotent', false);
end $$;

-- REFUND (OWNER/MANAGER). Mesma ordem D9. Permitido em qualquer status (inclusive CANCELLED).
create or replace function public.rg_payment_refund(
  p_operation_id uuid, p_payment_id uuid, p_method text, p_amount integer, p_received_at timestamptz, p_notes text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_notes text;
  v_org uuid;
  v_res_id uuid;
  v_res public.reservations;
  v_pay public.reservation_payments;
  v_fp bytea;
  v_existing public.reservation_payments;
  v_refunded bigint;
  v_id uuid;
  v_constraint text;
  v_conflict boolean := false;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  perform private.rg_fin_validate_entry(p_operation_id, p_method, p_amount, p_received_at);
  v_notes := private.rg_fin_notes(p_notes);
  -- tenant/autorização derivados do PAYMENT de origem
  select p.organization_id, p.reservation_id into v_org, v_res_id from public.reservation_payments p where p.id = p_payment_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: pagamento não encontrado' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para estornar' using errcode = '42501';
  end if;
  -- travas: reserva, depois o PAYMENT de origem
  v_res := private.rg_fin_lock_reservation(v_res_id, true);
  select p.* into v_pay from public.reservation_payments p where p.id = p_payment_id for update;
  -- replay / RGP02
  v_fp := private.rg_fin_fingerprint('REFUND', v_res.id, p_payment_id, p_amount, p_method, p_received_at, v_notes);
  select p.* into v_existing from public.reservation_payments p
   where p.organization_id = v_res.organization_id and p.operation_id = p_operation_id;
  if found then
    if v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'reservation_id', v_existing.reservation_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  -- estado mutável
  if v_pay.kind <> 'PAYMENT' then
    raise exception 'rg: somente pagamentos podem ser estornados' using errcode = 'RGP01', hint = 'NOT_A_PAYMENT';
  end if;
  if v_pay.voided_at is not null then
    raise exception 'rg: pagamento anulado não pode ser estornado' using errcode = 'RGP01', hint = 'PAYMENT_VOIDED';
  end if;
  select coalesce(sum(c.amount), 0) into v_refunded from public.reservation_payments c
   where c.refund_of = v_pay.id and c.voided_at is null;
  if p_amount > v_pay.amount - v_refunded then
    raise exception 'rg: estorno acima do valor disponível do pagamento' using errcode = 'RGP03', hint = 'OVER_REFUNDABLE';
  end if;
  begin
    insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, refund_of, method, amount,
      received_at, notes, source, operation_id, operation_fingerprint, created_by)
    values (v_res.organization_id, v_res.arena_id, v_res.id, 'REFUND', v_pay.id, p_method, p_amount,
      p_received_at, v_notes, 'MANUAL', p_operation_id, v_fp, v_uid)
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_payments_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select p.* into v_existing from public.reservation_payments p
     where p.organization_id = v_res.organization_id and p.operation_id = p_operation_id;
    if found and v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'reservation_id', v_existing.reservation_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('refund:after_insert');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'PAYMENT_REFUNDED', 'reservation_payment', v_id,
    jsonb_build_object('reservation_id', v_res.id, 'refund_of', v_pay.id, 'amount', p_amount, 'method', p_method));
  perform private.rg_fault('refund:after_audit');
  return jsonb_build_object('payment_id', v_id, 'reservation_id', v_res.id, 'idempotent', false);
end $$;

-- VOID (OWNER/MANAGER): correção de lançamento feito por engano. Motivo obrigatório (fica no
-- ledger, visível só a OWNER/MANAGER; NÃO vai para audit_logs). Repetido = no-op.
create or replace function public.rg_payment_void(p_payment_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_reason text := nullif(btrim(p_reason), '');
  v_org uuid;
  v_res_id uuid;
  v_res public.reservations;
  v_pay public.reservation_payments;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'rg: informe o motivo da anulação' using errcode = '22023';
  end if;
  select p.organization_id, p.reservation_id into v_org, v_res_id from public.reservation_payments p where p.id = p_payment_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: lançamento não encontrado' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para anular' using errcode = '42501';
  end if;
  v_res := private.rg_fin_lock_reservation(v_res_id, true);
  select p.* into v_pay from public.reservation_payments p where p.id = p_payment_id for update;
  if v_pay.voided_at is not null then
    return jsonb_build_object('payment_id', v_pay.id, 'changed', false);
  end if;
  if v_pay.kind = 'PAYMENT' and exists (
    select 1 from public.reservation_payments c where c.refund_of = v_pay.id and c.voided_at is null) then
    raise exception 'rg: anule primeiro os estornos deste pagamento' using errcode = 'RGP01', hint = 'HAS_REFUNDS';
  end if;
  update public.reservation_payments p set voided_at = now(), voided_by = v_uid, void_reason = v_reason where p.id = v_pay.id;
  perform private.rg_fault('void:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'PAYMENT_VOIDED', 'reservation_payment', v_pay.id,
    jsonb_build_object('reservation_id', v_res.id, 'kind', v_pay.kind, 'amount', v_pay.amount));
  perform private.rg_fault('void:after_audit');
  return jsonb_build_object('payment_id', v_pay.id, 'changed', true);
end $$;

-- SET PRICE (OWNER/MANAGER): única alteração legítima do snapshot após o INSERT (roda como
-- postgres, o que os GUARDS exigem). MANUAL = valor informado (ou NULL se net = 0); RULE =
-- recalcula no servidor (sem cobertura => RGP01). Motivo = CÓDIGO controlado (sem texto livre/PII).
create or replace function public.rg_reservation_set_price(p_reservation_id uuid, p_mode text, p_price integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_res public.reservations;
  v_new integer;
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
  if v_new is not distinct from v_res.price then
    return jsonb_build_object('reservation_id', v_res.id, 'price', v_res.price, 'changed', false);
  end if;
  if v_new is null then
    select f.* into v_fin from private.rg_financials(array[v_res.id]) f;
    if v_fin.net_received > 0 then
      raise exception 'rg: reserva com valor recebido não pode ficar sem preço' using errcode = 'RGP01', hint = 'PRICE_REQUIRED';
    end if;
  end if;
  update public.reservations r set price = v_new where r.id = v_res.id;
  perform private.rg_fault('set_price:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'RESERVATION_PRICE_SET', 'reservation', v_res.id, jsonb_build_object(
    'old_price', v_res.price, 'new_price', v_new, 'mode', p_mode, 'reason', p_reason, 'rule_ids', to_jsonb(v_rules)));
  perform private.rg_fault('set_price:after_audit');
  return jsonb_build_object('reservation_id', v_res.id, 'price', v_new, 'changed', true);
end $$;

-- DETALHE de UMA reserva (qualquer membro, inclusive RECEPTIONIST): resumo + lançamentos.
-- O ledger direto é só OWNER/MANAGER (RLS); este é o caminho da recepção. Sem fingerprint.
create or replace function public.rg_reservation_financial_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
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
  select f.* into v_fin from private.rg_financials(array[p_reservation_id]) f;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'kind', p.kind, 'refund_of', p.refund_of, 'method', p.method, 'amount', p.amount,
           'received_at', p.received_at, 'notes', p.notes, 'source', p.source, 'created_by', p.created_by,
           'created_at', p.created_at, 'voided_at', p.voided_at, 'voided_by', p.voided_by, 'void_reason', p.void_reason)
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

-- RESUMOS de várias reservas (máx. 500). Valores só para OWNER/MANAGER da organização; a
-- recepção recebe apenas payment_status + collectible (sem valores agregáveis). Reservas não
-- visíveis ao chamador são omitidas.
create or replace function public.rg_reservation_financial_summaries(p_reservation_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_reservation_ids), 0) > 500 then
    raise exception 'rg: no máximo 500 reservas por consulta' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(case
           when private.is_org_manager(f.organization_id, v_uid) then jsonb_build_object(
             'reservation_id', f.reservation_id, 'payment_status', f.payment_status, 'collectible', f.collectible,
             'amount_due', f.amount_due, 'amount_received', f.amount_received, 'amount_refunded', f.amount_refunded,
             'net_received', f.net_received, 'balance', f.balance, 'collectible_balance', f.collectible_balance)
           else jsonb_build_object(
             'reservation_id', f.reservation_id, 'payment_status', f.payment_status, 'collectible', f.collectible)
         end), '[]'::jsonb)
    into v_out
    from private.rg_financials(p_reservation_ids) f
   where private.is_org_member(f.organization_id, v_uid);
  return v_out;
end $$;

-- =============================================================================
-- 6) RLS e grants das tabelas novas (default-deny; revogar os default privileges)
-- =============================================================================
alter table public.court_pricing_rules enable row level security;
alter table public.reservation_payments enable row level security;

drop policy if exists "pricing rules read member" on public.court_pricing_rules;
create policy "pricing rules read member" on public.court_pricing_rules for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

-- Ledger direto: somente OWNER/MANAGER (D13). RECEPTIONIST lê pelas RPCs de detalhe/resumo.
drop policy if exists "payments read manager" on public.reservation_payments;
create policy "payments read manager" on public.reservation_payments for select to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))));
-- Sem policies de INSERT/UPDATE/DELETE: nenhuma escrita direta por authenticated.

revoke all on table public.court_pricing_rules from public, anon, authenticated, service_role;
grant select on table public.court_pricing_rules to authenticated;
grant select, delete on table public.court_pricing_rules to service_role;

revoke all on table public.reservation_payments from public, anon, authenticated, service_role;
-- SELECT por coluna: tudo menos operation_fingerprint.
grant select (id, organization_id, arena_id, reservation_id, kind, refund_of, method, amount, received_at, notes,
              source, external_provider, external_reference, operation_id, created_by, created_at,
              voided_at, voided_by, void_reason)
  on public.reservation_payments to authenticated;
grant select, delete on table public.reservation_payments to service_role;

-- =============================================================================
-- 7) Owner explícito, grants e revokes de funções
-- =============================================================================
alter function private.enforce_pricing_rule_integrity() owner to postgres;
alter function private.enforce_payment_integrity() owner to postgres;
alter function private.protect_payment_ledger() owner to postgres;
alter function private.guard_finance_delete() owner to postgres;
alter function private.rg_price_quote(uuid, timestamptz, timestamptz) owner to postgres;
alter function private.rg_financials(uuid[]) owner to postgres;
alter function private.rg_fin_lock_reservation(uuid, boolean) owner to postgres;
alter function private.rg_fin_notes(text) owner to postgres;
alter function private.rg_fin_fingerprint(text, uuid, uuid, integer, text, timestamptz, text) owner to postgres;
alter function private.rg_fin_validate_entry(uuid, text, integer, timestamptz) owner to postgres;
alter function private.rg_pricing_validate(time, time, integer, date, date) owner to postgres;
alter function private.enforce_reservation_price_snapshot() owner to postgres;
alter function public.rg_price_quote(uuid, timestamptz, timestamptz) owner to postgres;
alter function public.rg_pricing_rule_create(uuid, uuid, smallint[], time, time, integer, date, date) owner to postgres;
alter function public.rg_pricing_rule_update(uuid, jsonb) owner to postgres;
alter function public.rg_pricing_rule_deactivate(uuid) owner to postgres;
alter function public.rg_payment_register(uuid, uuid, text, integer, timestamptz, text) owner to postgres;
alter function public.rg_payment_refund(uuid, uuid, text, integer, timestamptz, text) owner to postgres;
alter function public.rg_payment_void(uuid, text) owner to postgres;
alter function public.rg_reservation_set_price(uuid, text, integer, text) owner to postgres;
alter function public.rg_reservation_financial_detail(uuid) owner to postgres;
alter function public.rg_reservation_financial_summaries(uuid[]) owner to postgres;

-- RPCs: somente authenticated (service_role sem EXECUTE: exigem auth.uid()).
revoke all on function public.rg_price_quote(uuid, timestamptz, timestamptz) from public, anon, service_role;
revoke all on function public.rg_pricing_rule_create(uuid, uuid, smallint[], time, time, integer, date, date) from public, anon, service_role;
revoke all on function public.rg_pricing_rule_update(uuid, jsonb) from public, anon, service_role;
revoke all on function public.rg_pricing_rule_deactivate(uuid) from public, anon, service_role;
revoke all on function public.rg_payment_register(uuid, uuid, text, integer, timestamptz, text) from public, anon, service_role;
revoke all on function public.rg_payment_refund(uuid, uuid, text, integer, timestamptz, text) from public, anon, service_role;
revoke all on function public.rg_payment_void(uuid, text) from public, anon, service_role;
revoke all on function public.rg_reservation_set_price(uuid, text, integer, text) from public, anon, service_role;
revoke all on function public.rg_reservation_financial_detail(uuid) from public, anon, service_role;
revoke all on function public.rg_reservation_financial_summaries(uuid[]) from public, anon, service_role;

grant execute on function public.rg_price_quote(uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.rg_pricing_rule_create(uuid, uuid, smallint[], time, time, integer, date, date) to authenticated;
grant execute on function public.rg_pricing_rule_update(uuid, jsonb) to authenticated;
grant execute on function public.rg_pricing_rule_deactivate(uuid) to authenticated;
grant execute on function public.rg_payment_register(uuid, uuid, text, integer, timestamptz, text) to authenticated;
grant execute on function public.rg_payment_refund(uuid, uuid, text, integer, timestamptz, text) to authenticated;
grant execute on function public.rg_payment_void(uuid, text) to authenticated;
grant execute on function public.rg_reservation_set_price(uuid, text, integer, text) to authenticated;
grant execute on function public.rg_reservation_financial_detail(uuid) to authenticated;
grant execute on function public.rg_reservation_financial_summaries(uuid[]) to authenticated;

-- Helpers e funções de trigger privados: nenhum papel de API executa diretamente.
revoke all on function private.enforce_pricing_rule_integrity() from public, anon, authenticated, service_role;
revoke all on function private.enforce_payment_integrity() from public, anon, authenticated, service_role;
revoke all on function private.protect_payment_ledger() from public, anon, authenticated, service_role;
revoke all on function private.guard_finance_delete() from public, anon, authenticated, service_role;
revoke all on function private.rg_price_quote(uuid, timestamptz, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.rg_financials(uuid[]) from public, anon, authenticated, service_role;
revoke all on function private.rg_fin_lock_reservation(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function private.rg_fin_notes(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_fin_fingerprint(text, uuid, uuid, integer, text, timestamptz, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_fin_validate_entry(uuid, text, integer, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.rg_pricing_validate(time, time, integer, date, date) from public, anon, authenticated, service_role;
revoke all on function private.enforce_reservation_price_snapshot() from public, anon, authenticated, service_role;

commit;

-- =============================================================================
-- VERIFICAÇÃO (somente leitura; rodar após aplicar — NÃO faz parte da migration)
-- =============================================================================
-- 1) Tabelas, RLS e grants (esperado: RLS on; authenticated = SELECT; anon = nada;
--    service_role = SELECT, DELETE; operation_fingerprint sem SELECT para authenticated):
--   select relname, relrowsecurity from pg_class where oid in ('public.court_pricing_rules'::regclass, 'public.reservation_payments'::regclass);
--   select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) from information_schema.table_privileges
--    where table_schema = 'public' and table_name in ('court_pricing_rules', 'reservation_payments')
--      and grantee in ('anon', 'authenticated', 'service_role') group by 1, 2 order by 1, 2;
--   select has_column_privilege('authenticated', 'public.reservation_payments', 'operation_fingerprint', 'SELECT');   -- f
-- 2) Funções: RPCs -> postgres + EXECUTE só authenticated; private.* -> nenhum papel de API:
--   select n.nspname || '.' || p.proname as fn, p.prosecdef, pg_get_userbyid(p.proowner) as owner, p.proconfig,
--          has_function_privilege('anon', p.oid, 'EXECUTE') as anon, has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth,
--          has_function_privilege('service_role', p.oid, 'EXECUTE') as svc
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where (n.nspname = 'public' and (p.proname like 'rg\_payment\_%' or p.proname like 'rg\_pricing\_%'
--           or p.proname in ('rg_price_quote', 'rg_reservation_set_price', 'rg_reservation_financial_detail', 'rg_reservation_financial_summaries')))
--       or (n.nspname = 'private' and (p.proname like 'rg\_fin\_%' or p.proname in ('rg_price_quote', 'rg_financials', 'rg_pricing_validate',
--           'enforce_pricing_rule_integrity', 'enforce_payment_integrity', 'protect_payment_ledger', 'guard_finance_delete', 'enforce_reservation_price_snapshot')))
--    order by 1;
-- 3) Ordem dos BEFORE INSERT triggers de reservations:
--   select t.tgname from pg_trigger t where t.tgrelid = 'public.reservations'::regclass and not t.tgisinternal
--      and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 order by t.tgname;
-- 4) Nenhuma linha antiga mudou: contagens/somas de reservations.price iguais às de antes da migration.
