-- =============================================================================
-- RESERVA GOL — FASE 03B.3A — EXPLAIN em dataset sintético (banco de TESTE local; ROLLBACK no fim)
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3b3_explain.sql
-- Dataset: 1 organização com 300 linhagens (30 reagendadas) em 30 quadras, ~4 meses de jogos semanais
-- (~5 mil ocorrências), metade do mês-alvo paga; + 20 mil reservas avulsas de outra organização (ruído).
-- Mede: lista mensal (consulta interna + RPC), detalhe de uma linhagem, lock do recebimento, replay,
-- mapa de linhagens. (Um índice dedicado (organization_id, occurrence_date) foi medido e descartado.)
-- =============================================================================
begin;
set local statement_timeout = '300s';

create temp table ex (k text primary key, id uuid) on commit drop;

do $$
declare
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_m date := (date_trunc('month', v_today) + interval '1 month')::date;
  v_from date := (date_trunc('month', v_today) - interval '2 months')::date;
  v_to date := (v_m + interval '1 month' - interval '1 day')::date;
  u uuid := gen_random_uuid(); o uuid; o2 uuid; a uuid; a2 uuid; c2 uuid; i int; s uuid; child uuid;
  v_court uuid; v_cust uuid;
begin
  insert into auth.users (id, email) values (u, 'p3b3x-' || substr(md5(random()::text), 1, 8) || '@reservagol.test');
  insert into public.organizations (name, is_demo) values ('P3B3X dataset', true) returning id into o;
  insert into public.organizations (name, is_demo) values ('P3B3X ruído', true) returning id into o2;
  insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (o, 'Arena X') returning id into a;
  insert into public.arenas (organization_id, name) values (o2, 'Arena ruído') returning id into a2;
  insert into public.courts (organization_id, arena_id, name) values (o2, a2, 'Quadra ruído') returning id into c2;
  insert into ex values ('owner', u), ('org', o), ('arena', a), ('m', null);
  for i in 0..29 loop
    insert into public.courts (organization_id, arena_id, name) values (o, a, 'Quadra ' || i) returning id into v_court;
    insert into ex values ('court' || i, v_court);
  end loop;
  for i in 0..299 loop
    insert into public.customers (organization_id, arena_id, name, phone)
    values (o, a, 'Cliente ' || lpad(i::text, 3, '0'), '1199' || lpad(i::text, 7, '0')) returning id into v_cust;
    insert into public.recurring_reservations (organization_id, arena_id, court_id, customer_id, frequency, weekday, start_time, end_time,
      start_date, has_no_end_date, default_price, created_by)
    values (o, a, (select id from ex where k = 'court' || (i % 30)), case when i % 10 = 9 then null else v_cust end, 'WEEKLY', (i / 30) % 7,
      make_time(8 + (i / 210), 0, 0), make_time(9 + (i / 210), 0, 0), v_from - 7, true, case when i % 15 = 0 then null else 10000 end, u)
    returning id into s;
    if i = 0 then update ex set id = s where k = 'm'; end if;
    insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, price,
      recurring_reservation_id, occurrence_date, is_exception)
    select o, a, rs.court_id, rs.customer_id, b.start_at, b.end_at, 'CONFIRMED', 'RECORRENTE', rs.default_price, rs.id, g::date, false
      from public.recurring_reservations rs
      cross join generate_series(v_from, v_to, interval '1 day') g
      cross join lateral private.rg_occurrence_bounds(g::date, rs.start_time, rs.end_time) b
     where rs.id = s and extract(dow from g)::int = rs.weekday
       and (i % 10 <> 3 or g::date < v_m + 14);
    if i % 10 = 3 then
      insert into public.recurring_reservations (organization_id, arena_id, court_id, customer_id, frequency, weekday, start_time, end_time,
        start_date, has_no_end_date, default_price, created_by, operation_id, operation_kind, operation_request, previous_series_id)
      select o, a, rs.court_id, rs.customer_id, 'WEEKLY', rs.weekday, make_time(10 + (i / 210), 0, 0), make_time(11 + (i / 210), 0, 0), v_m + 14, true,
             rs.default_price, u, gen_random_uuid(), 'RESCHEDULE', '{}'::jsonb, rs.id
        from public.recurring_reservations rs where rs.id = s
      returning id into child;
      insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, price,
        recurring_reservation_id, occurrence_date, is_exception)
      select o, a, rs.court_id, rs.customer_id, b.start_at, b.end_at, 'CONFIRMED', 'RECORRENTE', rs.default_price, rs.id, g::date, false
        from public.recurring_reservations rs
        cross join generate_series(v_m + 14, v_to, interval '1 day') g
        cross join lateral private.rg_occurrence_bounds(g::date, rs.start_time, rs.end_time) b
       where rs.id = child and extract(dow from g)::int = rs.weekday;
    end if;
  end loop;
  -- metade dos jogos com valor do mês-alvo pagos (lançamentos 03A diretos)
  insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, method, amount, received_at,
    operation_id, operation_fingerprint, created_by)
  select o, a, r.id, 'PAYMENT', 'PIX', r.price, now() - interval '1 day', gen_random_uuid(), decode(md5(r.id::text) || md5(r.id::text), 'hex'), u
    from public.reservations r
   where r.organization_id = o and r.price is not null and r.occurrence_date between v_m and v_to and (hashtext(r.id::text) % 2) = 0;
  -- ruído: 20 mil reservas avulsas de outra organização (sem recorrência)
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price)
  select o2, a2, c2, timestamptz '2026-01-01 00:00:00-03' + (g * interval '61 minutes'), timestamptz '2026-01-01 00:00:00-03' + (g * interval '61 minutes') + interval '1 hour',
         'CONFIRMED', 'TESTE_P3B3X', 5000
    from generate_series(1, 20000) g;
end $$;

analyze public.reservations;
analyze public.recurring_reservations;
analyze public.reservation_payments;
analyze public.customers;

select (select id from ex where k = 'owner') as owner_id, (select id from ex where k = 'org') as org_id, (select id from ex where k = 'm') as m_id \gset
select 'DATASET', (select count(*) from public.recurring_reservations where organization_id = :'org_id'::uuid) as series,
       (select count(*) from public.reservations where organization_id = :'org_id'::uuid) as occurrences,
       (select count(*) from public.reservations) as reservations_total,
       (select count(*) from public.reservation_payments where organization_id = :'org_id'::uuid) as payments;

-- Q1: consulta interna da lista mensal (mesma forma da RPC)
\echo '== Q1 lista mensal (consulta interna, índices existentes)'
explain (analyze, buffers, costs off, timing on, summary on)
with lm as (
  select m.series_id, m.lineage_id from private.rg_rm_lineage_map(:'org_id'::uuid) m
), occ as (
  select r.id, lm.lineage_id from public.reservations r join lm on lm.series_id = r.recurring_reservation_id
   where r.organization_id = :'org_id'::uuid and r.recurring_reservation_id is not null
     and r.occurrence_date between (date_trunc('month', now()) + interval '1 month')::date
                               and (date_trunc('month', now()) + interval '2 months' - interval '1 day')::date
), f as (
  select o.lineage_id, x.*, res.end_at from occ o join private.rg_financials(array(select occ.id from occ)) x on x.reservation_id = o.id
  join public.reservations res on res.id = o.id
)
select f.lineage_id, count(*), sum(f.collectible_balance) from f group by f.lineage_id;

-- Q2: a RPC completa como OWNER (tempo fim a fim)
\echo '== Q2 rg_recurring_month_list (RPC completa, OWNER, página de 50)'
select set_config('request.jwt.claims', json_build_object('sub', :'owner_id'::uuid, 'role', 'authenticated')::text, true);
set local role authenticated;
explain (analyze, costs off, timing on, summary on)
select public.rg_recurring_month_list(:'org_id'::uuid, null, (date_trunc('month', now()) + interval '1 month')::date, null, null, 50, null);
\echo '== Q3 rg_recurring_month_detail (RPC completa, uma linhagem)'
explain (analyze, costs off, timing on, summary on)
select public.rg_recurring_month_detail(:'m_id'::uuid, (date_trunc('month', now()) + interval '1 month')::date);
\echo '== Q3b média de 20 chamadas repetidas (lista, detalhe, busca), sessão aquecida'
select set_config('p3b3x.org', :'org_id', true), set_config('p3b3x.m', :'m_id', true);
do $$
declare t0 timestamptz; i int; v jsonb;
begin
  t0 := clock_timestamp();
  for i in 1..20 loop v := public.rg_recurring_month_list(current_setting('p3b3x.org')::uuid, null, (date_trunc('month', now()) + interval '1 month')::date, null, null, 50, null); end loop;
  raise notice 'LIST_AVG_MS %', round(extract(epoch from clock_timestamp() - t0) * 1000 / 20, 2);
  t0 := clock_timestamp();
  for i in 1..20 loop v := public.rg_recurring_month_detail(current_setting('p3b3x.m')::uuid, (date_trunc('month', now()) + interval '1 month')::date); end loop;
  raise notice 'DETAIL_AVG_MS %', round(extract(epoch from clock_timestamp() - t0) * 1000 / 20, 2);
  t0 := clock_timestamp();
  for i in 1..20 loop v := public.rg_recurring_month_search(current_setting('p3b3x.org')::uuid, (date_trunc('month', now()) + interval '1 month')::date, 'cliente 1', 20); end loop;
  raise notice 'SEARCH_AVG_MS %', round(extract(epoch from clock_timestamp() - t0) * 1000 / 20, 2);
end $$;
reset role;

\echo '== Q4 lock do recebimento (reservas do mês de uma linhagem, FOR UPDATE)'
explain (analyze, buffers, costs off, timing on, summary on)
select 1 from public.reservations r
 where r.recurring_reservation_id = any(array(select series_id from private.rg_rm_lineage(:'m_id'::uuid)))
   and r.occurrence_date between (date_trunc('month', now()) + interval '1 month')::date
                             and (date_trunc('month', now()) + interval '2 months' - interval '1 day')::date
 order by r.id for update;

\echo '== Q5 replay (batch por organização + operation_id)'
explain (costs off)
select * from public.reservation_payment_batches b where b.organization_id = :'org_id'::uuid and b.operation_id = gen_random_uuid();

\echo '== Q6 mapa de linhagens da organização (recursivo)'
explain (analyze, buffers, costs off, timing on, summary on)
select count(*) from private.rg_rm_lineage_map(:'org_id'::uuid);

rollback;
