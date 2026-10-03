-- =============================================================================
-- RESERVA GOL — FASE 03B.1 — Visão financeira, A receber e Caixa (entradas)
-- Requer 03A (FOUNDATION + GUARDS + FIX1 + FIX2) aplicada.
--
-- Somente LEITURA: 2 índices + funções. Nenhuma tabela, dado, RLS, trigger ou RPC da 03A muda.
--
-- Contrato (03B.1, congelado):
--   - autorização: auth.uid() obrigatório + private.is_org_manager (OWNER/MANAGER/platform admin);
--     RECEPTIONIST, outro tenant, anônimo e organização inexistente => 42501 (sem distinção);
--   - tenant isolation explícita (SECURITY DEFINER ignora RLS): todo filtro tem organization_id = p_org;
--   - período [p_from, p_to] inclusivo em datas locais America/Sao_Paulo; intervalos sempre
--     col >= v_start and col < v_end (sem função na coluna => usa índice);
--   - dinheiro em centavos inteiros; instantes em ISO 8601 UTC (SET timezone = 'UTC' na função);
--   - a matemática por reserva é SET-BASED (private.rg_fin_reservation_rows) e reproduz exatamente
--     private.rg_financials (oráculo do teste de paridade F12) — rg_financials NÃO é chamada aqui.
--
-- Dívida técnica registrada: fuso fixo America/Sao_Paulo. Antes de atender organizações em outros
-- fusos, organização/arena precisa de timezone configurável e estas agregações precisam usá-lo.
-- =============================================================================
begin;

do $$ begin
  if to_regprocedure('private.rg_financials(uuid[])') is null
     or to_regclass('public.reservation_payments') is null
     or to_regprocedure('private.is_org_manager(uuid, uuid)') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'reservations' and column_name = 'price_source') then
    raise exception '03B.1: 03A (FOUNDATION + FIX2) ausente';
  end if;
end $$;

-- Preflight de colisão: os 8 objetos de destino NÃO podem existir. A migration nunca reaproveita
-- nem substitui objeto preexistente (o rollback remove esses nomes). Não é idempotente de propósito:
-- uma segunda aplicação sem rollback falha aqui, antes de qualquer CREATE.
do $$
declare v_found text;
begin
  select string_agg(o, ', ') into v_found from (
    select 'private.rg_fin_scope' as o where to_regprocedure('private.rg_fin_scope(uuid, uuid, date, date, integer)') is not null
    union all select 'private.rg_fin_reservation_rows' where to_regprocedure('private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz)') is not null
    union all select 'public.rg_fin_overview' where to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is not null
    union all select 'public.rg_fin_receivables' where to_regprocedure('public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid)') is not null
    union all select 'public.rg_fin_cashflow' where to_regprocedure('public.rg_fin_cashflow(uuid, uuid, date, date, text)') is not null
    union all select 'public.rg_fin_cash_entries' where to_regprocedure('public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid)') is not null
    union all select 'public.idx_reservations_org_start' where to_regclass('public.idx_reservations_org_start') is not null
    union all select 'public.idx_reservations_arena_start' where to_regclass('public.idx_reservations_arena_start') is not null
  ) s;
  if v_found is not null then
    raise exception '03B.1: objeto de destino já existe: %', v_found using errcode = '42710';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1) Índices de período (também servem à consulta da agenda por arena + start_at)
-- -----------------------------------------------------------------------------
create index idx_reservations_org_start on public.reservations (organization_id, start_at);
create index idx_reservations_arena_start on public.reservations (arena_id, start_at);

-- -----------------------------------------------------------------------------
-- 2) Escopo comum: autorização + período + arena => [v_start, v_end)
-- -----------------------------------------------------------------------------
create function private.rg_fin_scope(p_org uuid, p_arena uuid, p_from date, p_to date, p_max_days integer)
returns table (v_start timestamptz, v_end timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.is_org_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to
     or extract(year from p_from) not between 2000 and 2100
     or extract(year from p_to) not between 2000 and 2100 then
    raise exception 'rg: período inválido' using errcode = '22023';
  end if;
  if (p_to - p_from + 1) > p_max_days then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;
  if p_arena is not null and not exists (
       select 1 from public.arenas a where a.id = p_arena and a.organization_id = p_org) then
    raise exception 'rg: arena inválida' using errcode = '22023';
  end if;
  v_start := p_from::timestamp at time zone 'America/Sao_Paulo';
  v_end := (p_to + 1)::timestamp at time zone 'America/Sao_Paulo';
  return next;
end $$;

-- -----------------------------------------------------------------------------
-- 3) Núcleo set-based por reserva (mesma semântica de private.rg_financials, em lote)
--    Sem checagem de papel: só é chamável pelas RPCs abaixo, DEPOIS de private.rg_fin_scope.
--    Pagamentos de QUALQUER data (situação atual da reserva); anulados nunca contam.
-- -----------------------------------------------------------------------------
create function private.rg_fin_reservation_rows(p_org uuid, p_arena uuid, p_start timestamptz, p_end timestamptz)
returns table (
  reservation_id uuid, arena_id uuid, court_id uuid, customer_id uuid, recurring_reservation_id uuid,
  start_at timestamptz, end_at timestamptz, status text,
  amount_due integer, amount_received bigint, amount_refunded bigint, net_received bigint, balance bigint,
  collectible boolean, collectible_balance bigint, payment_status text)
language sql stable security definer set search_path = '' as $$
  with r as (
    select r.id, r.arena_id, r.court_id, r.customer_id, r.recurring_reservation_id,
           r.start_at, r.end_at, r.status, r.price
      from public.reservations r
     where r.organization_id = p_org
       and (p_arena is null or r.arena_id = p_arena)
       and r.start_at >= p_start and r.start_at < p_end
  ), m as (
    select p.reservation_id,
           coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint as rec,
           coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint as ref
      from public.reservation_payments p
      join r on r.id = p.reservation_id
     where p.organization_id = p_org and p.voided_at is null
     group by p.reservation_id
  ), x as (
    select r.*, coalesce(m.rec, 0)::bigint as rec, coalesce(m.ref, 0)::bigint as ref
      from r left join m on m.reservation_id = r.id
  )
  select x.id, x.arena_id, x.court_id, x.customer_id, x.recurring_reservation_id,
         x.start_at, x.end_at, x.status,
         x.price, x.rec, x.ref, x.rec - x.ref,
         case when x.price is null then null else x.price - (x.rec - x.ref) end,
         x.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID'),
         case when x.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID') and x.price is not null
              then greatest(x.price - (x.rec - x.ref), 0) else 0 end,
         case
           when x.status = 'BLOCKED' then 'NOT_APPLICABLE'
           when x.status = 'CANCELLED' then
             case when x.rec = 0 then 'CANCELLED'
                  when x.rec - x.ref = 0 then 'REFUNDED'
                  else 'RETAINED' end
           when x.price is null then 'UNPRICED'
           when x.rec - x.ref = 0 and x.price > 0 then 'PENDING'
           when x.rec - x.ref < x.price then 'PARTIAL'
           when x.rec - x.ref = x.price then 'PAID'
           else 'OVERPAID'
         end
    from x
$$;

-- -----------------------------------------------------------------------------
-- 4) Visão geral
-- -----------------------------------------------------------------------------
create function public.rg_fin_overview(p_org uuid, p_arena uuid, p_from date, p_to date,
                                                  p_compare_from date default null, p_compare_to date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  v_now timestamptz := now();
  s record;
  c_start timestamptz;
  c_end timestamptz;
  v_has_cmp boolean;
  a record;
  k record;
  -- comparação em escalares (nulos sem comparação): um record não atribuído não pode ser lido
  v_c_priced bigint;
  v_c_expected bigint;
  v_c_net bigint;
begin
  select * into s from private.rg_fin_scope(p_org, p_arena, p_from, p_to, 366);

  if (p_compare_from is null) <> (p_compare_to is null) then
    raise exception 'rg: período de comparação inválido' using errcode = '22023';
  end if;
  v_has_cmp := p_compare_from is not null;
  if v_has_cmp then
    if p_compare_from > p_compare_to or p_compare_to >= p_from
       or (p_compare_to - p_compare_from + 1) > 366
       or extract(year from p_compare_from) not between 2000 and 2100
       or extract(year from p_compare_to) not between 2000 and 2100 then
      raise exception 'rg: período de comparação inválido' using errcode = '22023';
    end if;
    c_start := p_compare_from::timestamp at time zone 'America/Sao_Paulo';
    c_end := (p_compare_to + 1)::timestamp at time zone 'America/Sao_Paulo';
  end if;

  select count(*) filter (where f.collectible) as billable,
         count(*) filter (where f.collectible and f.amount_due is not null) as priced,
         count(*) filter (where f.collectible and f.amount_due is null) as unpriced,
         count(*) filter (where f.status = 'CANCELLED') as cancelled,
         coalesce(sum(f.amount_due) filter (where f.collectible and f.amount_due is not null), 0)::bigint as expected,
         coalesce(sum(f.collectible_balance) filter (where f.collectible and f.amount_due is not null), 0)::bigint as open_total,
         coalesce(sum(f.collectible_balance) filter (where f.collectible and f.amount_due is not null and f.end_at <= v_now), 0)::bigint as overdue,
         count(*) filter (where f.collectible and f.amount_due is not null and f.collectible_balance > 0 and f.end_at <= v_now) as overdue_count,
         coalesce(sum(f.collectible_balance) filter (where f.collectible and f.amount_due is not null and f.end_at > v_now), 0)::bigint as upcoming,
         count(*) filter (where f.collectible and f.amount_due is not null and f.collectible_balance > 0 and f.end_at > v_now) as upcoming_count,
         count(*) filter (where f.collectible and f.amount_due is not null and f.net_received > f.amount_due) as credits_count,
         coalesce(sum(f.net_received - f.amount_due) filter (where f.collectible and f.amount_due is not null and f.net_received > f.amount_due), 0)::bigint as credits_total
    into a
    from private.rg_fin_reservation_rows(p_org, p_arena, s.v_start, s.v_end) f;

  select coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint as gross,
         coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint as refunds
    into k
    from public.reservation_payments p
   where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
     and p.voided_at is null and p.received_at >= s.v_start and p.received_at < s.v_end;

  if v_has_cmp then
    select count(*) filter (where f.collectible and f.amount_due is not null),
           coalesce(sum(f.amount_due) filter (where f.collectible and f.amount_due is not null), 0)::bigint
      into v_c_priced, v_c_expected
      from private.rg_fin_reservation_rows(p_org, p_arena, c_start, c_end) f;
    select coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint
           - coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint
      into v_c_net
      from public.reservation_payments p
     where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
       and p.voided_at is null and p.received_at >= c_start and p.received_at < c_end;
  end if;

  return jsonb_build_object(
    'period', jsonb_build_object('from', to_char(p_from, 'YYYY-MM-DD'), 'to', to_char(p_to, 'YYYY-MM-DD'),
                                 'days', p_to - p_from + 1, 'timezone', 'America/Sao_Paulo'),
    'compare', case when v_has_cmp then jsonb_build_object('from', to_char(p_compare_from, 'YYYY-MM-DD'),
                                 'to', to_char(p_compare_to, 'YYYY-MM-DD'), 'days', p_compare_to - p_compare_from + 1) end,
    'as_of', to_jsonb(v_now),
    'reservations', jsonb_build_object('billable', a.billable, 'priced', a.priced, 'unpriced', a.unpriced, 'cancelled', a.cancelled),
    'expected_revenue', jsonb_build_object('current', a.expected, 'compare', v_c_expected),
    'priced_count', jsonb_build_object('current', a.priced, 'compare', v_c_priced),
    'average_ticket', jsonb_build_object(
      'current', case when a.priced = 0 then null else round(a.expected::numeric / a.priced)::bigint end,
      'compare', case when coalesce(v_c_priced, 0) = 0 then null else round(v_c_expected::numeric / v_c_priced)::bigint end),
    'cash_in', jsonb_build_object('gross', k.gross, 'refunds', k.refunds, 'net', k.gross - k.refunds,
                                  'compare_net', v_c_net),
    'receivables', jsonb_build_object('open', a.open_total, 'overdue', a.overdue, 'overdue_count', a.overdue_count,
                                      'upcoming', a.upcoming, 'upcoming_count', a.upcoming_count),
    'credits', jsonb_build_object('count', a.credits_count, 'total', a.credits_total));
end $$;

-- -----------------------------------------------------------------------------
-- 5) A receber (situação atual das reservas do período), paginação por chave (start_at, id)
-- -----------------------------------------------------------------------------
create function public.rg_fin_receivables(p_org uuid, p_arena uuid, p_from date, p_to date,
                                                     p_filter text default 'OPEN', p_limit integer default 50,
                                                     p_after_start timestamptz default null, p_after_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  v_now timestamptz := now();
  s record;
  v_items jsonb;
  v_more boolean;
  v_last_start timestamptz;
  v_last_id uuid;
begin
  select * into s from private.rg_fin_scope(p_org, p_arena, p_from, p_to, 366);
  if p_filter is null or p_filter not in ('OPEN', 'OVERDUE', 'UPCOMING', 'UNPRICED') then
    raise exception 'rg: filtro inválido' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if (p_after_start is null) <> (p_after_id is null) then
    raise exception 'rg: cursor incompleto' using errcode = '22023';
  end if;

  with sel as (
    select f.*
      from private.rg_fin_reservation_rows(p_org, p_arena, s.v_start, s.v_end) f
     where f.collectible
       and case p_filter
             when 'UNPRICED' then f.amount_due is null
             when 'OPEN' then f.amount_due is not null and f.collectible_balance > 0
             when 'OVERDUE' then f.amount_due is not null and f.collectible_balance > 0 and f.end_at <= v_now
             else f.amount_due is not null and f.collectible_balance > 0 and f.end_at > v_now
           end
       and (p_after_start is null or (f.start_at, f.reservation_id) > (p_after_start, p_after_id))
     order by f.start_at, f.reservation_id
     limit p_limit + 1
  ), num as (
    select sel.*, row_number() over (order by sel.start_at, sel.reservation_id) as rn from sel
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'reservation_id', n.reservation_id, 'start_at', n.start_at, 'end_at', n.end_at,
           'court_id', n.court_id, 'court_name', c.name,
           'customer_id', n.customer_id, 'customer_name', cu.name, 'customer_phone', cu.phone,
           'status', n.status, 'payment_status', n.payment_status,
           'amount_due', n.amount_due, 'net_received', n.net_received,
           'balance', case when n.amount_due is null then null else n.collectible_balance end,
           'overdue', n.amount_due is not null and n.collectible_balance > 0 and n.end_at <= v_now,
           'recurring_reservation_id', n.recurring_reservation_id)
           order by n.start_at, n.reservation_id) filter (where n.rn <= p_limit), '[]'::jsonb),
         coalesce(bool_or(n.rn > p_limit), false)
    into v_items, v_more
    from num n
    left join public.courts c on c.id = n.court_id and c.organization_id = p_org
    left join public.customers cu on cu.id = n.customer_id and cu.organization_id = p_org;

  if v_more then
    select (e->>'start_at')::timestamptz, (e->>'reservation_id')::uuid
      into v_last_start, v_last_id
      from jsonb_array_elements(v_items) with ordinality as t(e, i)
     order by t.i desc limit 1;
  end if;

  return jsonb_build_object(
    'as_of', to_jsonb(v_now),
    'filter', p_filter,
    'items', v_items,
    'next_cursor', case when v_more then jsonb_build_object('start_at', v_last_start, 'id', v_last_id) end);
end $$;

-- -----------------------------------------------------------------------------
-- 6) Fluxo de caixa (entradas de reservas) por dia / mês / ano, buckets contínuos
-- -----------------------------------------------------------------------------
create function public.rg_fin_cashflow(p_org uuid, p_arena uuid, p_from date, p_to date, p_granularity text default 'day')
returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  v_buckets jsonb;
  v_gross bigint;
  v_refunds bigint;
begin
  -- 3660 dias cobre 10 anos de calendário; os limites de mês/ano são conferidos abaixo
  select * into s from private.rg_fin_scope(p_org, p_arena, p_from, p_to,
    case when p_granularity = 'day' then 366 else 3660 end);
  if p_granularity is null or p_granularity not in ('day', 'month', 'year') then
    raise exception 'rg: granularidade inválida' using errcode = '22023';
  end if;
  if p_granularity = 'month'
     and ((extract(year from p_to) * 12 + extract(month from p_to)) - (extract(year from p_from) * 12 + extract(month from p_from)) + 1) > 60 then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;
  if p_granularity = 'year' and (extract(year from p_to) - extract(year from p_from) + 1) > 10 then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;

  with b as (
    select g::date as bucket
      from generate_series(date_trunc(p_granularity, p_from::timestamp), date_trunc(p_granularity, p_to::timestamp),
                           ('1 ' || p_granularity)::interval) g
  ), p as (
    select date_trunc(p_granularity, p.received_at at time zone 'America/Sao_Paulo')::date as bucket,
           coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint as gross,
           coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint as refunds
      from public.reservation_payments p
     where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
       and p.voided_at is null and p.received_at >= s.v_start and p.received_at < s.v_end
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(b.bucket, 'YYYY-MM-DD'),
           'in_gross', coalesce(p.gross, 0), 'refunds', coalesce(p.refunds, 0),
           'in_net', coalesce(p.gross, 0) - coalesce(p.refunds, 0)) order by b.bucket), '[]'::jsonb),
         coalesce(sum(p.gross), 0)::bigint as gross, coalesce(sum(p.refunds), 0)::bigint as refunds
    into v_buckets, v_gross, v_refunds
    from b left join p on p.bucket = b.bucket;

  return jsonb_build_object(
    'granularity', p_granularity,
    'includes', jsonb_build_array('reservation_payments'),
    'buckets', v_buckets,
    'totals', jsonb_build_object('in_gross', v_gross, 'refunds', v_refunds, 'in_net', v_gross - v_refunds));
end $$;

-- -----------------------------------------------------------------------------
-- 7) Lançamentos de entrada/estorno do período, paginação por chave (received_at desc, id desc)
-- -----------------------------------------------------------------------------
create function public.rg_fin_cash_entries(p_org uuid, p_arena uuid, p_from date, p_to date,
                                                      p_limit integer default 50,
                                                      p_after_at timestamptz default null, p_after_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  v_items jsonb;
  v_more boolean;
  v_last_at timestamptz;
  v_last_id uuid;
begin
  select * into s from private.rg_fin_scope(p_org, p_arena, p_from, p_to, 366);
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if (p_after_at is null) <> (p_after_id is null) then
    raise exception 'rg: cursor incompleto' using errcode = '22023';
  end if;

  with sel as (
    select p.id, p.kind, p.method, p.amount, p.received_at, p.reservation_id, p.notes
      from public.reservation_payments p
     where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
       and p.voided_at is null and p.received_at >= s.v_start and p.received_at < s.v_end
       and (p_after_at is null or (p.received_at, p.id) < (p_after_at, p_after_id))
     order by p.received_at desc, p.id desc
     limit p_limit + 1
  ), num as (
    select sel.*, row_number() over (order by sel.received_at desc, sel.id desc) as rn from sel
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', n.id, 'kind', n.kind, 'method', n.method, 'amount', n.amount,
           'received_at', n.received_at, 'reservation_id', n.reservation_id,
           'reservation_start_at', r.start_at, 'court_name', c.name,
           'customer_name', cu.name, 'notes', n.notes)
           order by n.received_at desc, n.id desc) filter (where n.rn <= p_limit), '[]'::jsonb),
         coalesce(bool_or(n.rn > p_limit), false)
    into v_items, v_more
    from num n
    join public.reservations r on r.id = n.reservation_id and r.organization_id = p_org
    left join public.courts c on c.id = r.court_id and c.organization_id = p_org
    left join public.customers cu on cu.id = r.customer_id and cu.organization_id = p_org;

  if v_more then
    select (e->>'received_at')::timestamptz, (e->>'payment_id')::uuid
      into v_last_at, v_last_id
      from jsonb_array_elements(v_items) with ordinality as t(e, i)
     order by t.i desc limit 1;
  end if;

  return jsonb_build_object(
    'items', v_items,
    'next_cursor', case when v_more then jsonb_build_object('received_at', v_last_at, 'id', v_last_id) end);
end $$;

-- -----------------------------------------------------------------------------
-- 8) Owner e privilégios: públicas só para authenticated; privadas para nenhum papel de API
-- -----------------------------------------------------------------------------
alter function private.rg_fin_scope(uuid, uuid, date, date, integer) owner to postgres;
alter function private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz) owner to postgres;
alter function public.rg_fin_overview(uuid, uuid, date, date, date, date) owner to postgres;
alter function public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid) owner to postgres;
alter function public.rg_fin_cashflow(uuid, uuid, date, date, text) owner to postgres;
alter function public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid) owner to postgres;

revoke all on function private.rg_fin_scope(uuid, uuid, date, date, integer) from public, anon, authenticated, service_role;
revoke all on function private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.rg_fin_overview(uuid, uuid, date, date, date, date) from public, anon, service_role;
revoke all on function public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid) from public, anon, service_role;
revoke all on function public.rg_fin_cashflow(uuid, uuid, date, date, text) from public, anon, service_role;
revoke all on function public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid) from public, anon, service_role;
grant execute on function public.rg_fin_overview(uuid, uuid, date, date, date, date) to authenticated;
grant execute on function public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid) to authenticated;
grant execute on function public.rg_fin_cashflow(uuid, uuid, date, date, text) to authenticated;
grant execute on function public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid) to authenticated;

commit;
