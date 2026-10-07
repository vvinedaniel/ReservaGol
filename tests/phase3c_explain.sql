-- =============================================================================
-- RESERVA GOL — FASE 03C — EXPLAIN / benchmark (banco de TESTE local; ROLLBACK no fim; zero resíduo)
-- Gates (limites de investigação/STOP, não metas de otimização):
--   trigger de proteção <= 2 ms/linha · série NOOP <= 5 ms · ~195 séries <= 5 s
-- Uso: psql -U postgres -X -At -f tests/phase3c_explain.sql   (NOTICEs = medições; EXPLAINs em seguida)
-- Medição: clock_timestamp por iteração; cold = 1ª iteração; warm = demais; média; p95.
-- O JOB (procedure) usa a MESMA unidade por série do lote; o lote é medido aqui (transacional).
-- =============================================================================
begin;
set local statement_timeout = '900s';
set local client_min_messages = notice;

create temp table bk (k text primary key, v text) on commit drop;
create temp table ms (bench text, i int, ms numeric) on commit drop;

-- fixture sintética: org demo, owner, 1 arena 06–23, N quadras, séries semanais em combinações únicas
create function pg_temp.mk(p_tag text, p_courts int) returns void language plpgsql as $$
declare u uuid := gen_random_uuid(); o uuid; a uuid; i int;
begin
  insert into auth.users (id, email) values (u, p_tag || '-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
  insert into public.organizations (name, is_demo) values ('P3C-BENCH ' || p_tag, true) returning id into o;
  insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (o, 'Bench ' || p_tag) returning id into a;
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select o, a, w, '06:00', '23:00', false from generate_series(0, 6) w;
  for i in 1..p_courts loop insert into public.courts (organization_id, arena_id, name) values (o, a, 'C' || i); end loop;
  insert into bk values (p_tag || ':owner', u), (p_tag || ':org', o), (p_tag || ':arena', a);
end $$;
-- n séries: combinações (quadra, dia da semana, hora 07..21) únicas; criadas pela RPC real (sem materializar)
create function pg_temp.series(p_tag text, p_n int) returns void language plpgsql as $$
declare r record; v_owner uuid := (select v::uuid from bk where k = p_tag || ':owner'); v_arena uuid := (select v::uuid from bk where k = p_tag || ':arena');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  for r in
    select c.id court, w, h from public.courts c cross join generate_series(0, 6) w cross join generate_series(7, 21) h
     where c.arena_id = v_arena order by h, w, c.name limit p_n
  loop
    perform public.rg_recurring_create(gen_random_uuid(), v_arena, r.court, null, '{"name":"bench"}'::jsonb, 'WEEKLY', r.w, null,
      make_time(r.h, 0, 0), make_time(r.h, 59, 0), private.rg_today() - 7, null, true, 10000, null, false, false, '{}'::date[]);
  end loop;
  perform set_config('request.jwt.claims', '', true);
end $$;
create function pg_temp.report(p_bench text) returns text language sql stable as $$
  select format('%s: n=%s cold=%s ms warm_avg=%s ms avg=%s ms p95=%s ms max=%s ms', p_bench, count(*),
    round(max(ms) filter (where i = 1), 3), round(avg(ms) filter (where i > 1), 3), round(avg(ms), 3),
    round((percentile_cont(0.95) within group (order by ms))::numeric, 3), round(max(ms), 3))
    from ms where bench = p_bench $$;

-- ----------------------------------------------------------------------------- 195 séries
do $$ begin perform pg_temp.mk('b195', 14); perform pg_temp.series('b195', 195); end $$;

do $$
declare t0 timestamptz; r jsonb; v_series uuid[];
begin
  select array_agg(id order by id) into v_series from public.recurring_reservations where arena_id = (select v::uuid from bk where k = 'b195:arena');
  insert into bk values ('b195:series', array_to_string(v_series, ','));
  -- dry-run do volume atual (195 séries, 120 dias)
  t0 := clock_timestamp();
  perform count(*) from private.rg_recurring_topup_plan(120, v_series);
  raise notice 'BENCH dry-run 195 séries/120 dias: % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  -- candidatos (pré-filtro sem lock) com tudo a materializar
  t0 := clock_timestamp();
  perform private.rg_topup_candidates(120, v_series);
  raise notice 'BENCH candidatos (195, tudo pendente): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  -- primeira materialização completa (pior caso: 195 séries vazias => 195 x ~17 inserts)
  t0 := clock_timestamp();
  r := private.rg_recurring_topup_batch(500, v_series);
  raise notice 'BENCH 1ª execução 195 séries (materializa % ocorrências): % ms  status=%', r->'counts'->>'created',
    round(extract(epoch from clock_timestamp() - t0) * 1000, 1), r->>'status';
  -- execução estável (todas NOOP)
  t0 := clock_timestamp();
  r := private.rg_recurring_topup_batch(500, v_series);
  raise notice 'BENCH execução estável 195 séries (NOOP; candidatos=%): % ms  status=%', r->'counts'->>'examined',
    round(extract(epoch from clock_timestamp() - t0) * 1000, 1), r->>'status';
  t0 := clock_timestamp();
  perform private.rg_topup_candidates(120, v_series);
  raise notice 'BENCH candidatos (195, nada pendente): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
end $$;

-- série NOOP (unidade por série chamada diretamente, mesmo sem ser candidata)
do $$
declare v_s uuid; t0 timestamptz; i int := 0;
begin
  for v_s in select unnest(string_to_array((select v from bk where k = 'b195:series'), ','))::uuid limit 60 loop
    i := i + 1; t0 := clock_timestamp();
    perform private.rg_topup_series(v_s, 120, 'MANUAL', 'SYSTEM_OPERATOR', null, null, false, 1::smallint);
    insert into ms values ('serie_noop', i, extract(epoch from clock_timestamp() - t0) * 1000);
  end loop;
  raise notice 'BENCH %', pg_temp.report('serie_noop');
end $$;

-- trigger: INSERT de avulsa numa quadra com 15 séries ACTIVE (dias/horas variados), horários livres
do $$
declare v_court uuid; v_org uuid; v_arena uuid; d date; t0 timestamptz; i int := 0; n int;
begin
  select court_id, count(*) into v_court, n from public.recurring_reservations
   where arena_id = (select v::uuid from bk where k = 'b195:arena') group by court_id order by count(*) desc limit 1;
  select organization_id, arena_id into v_org, v_arena from public.courts where id = v_court;
  insert into bk values ('trg:court', v_court), ('trg:n', n);
  for d in select g::date from generate_series(private.rg_today() + 1, private.rg_today() + 200, interval '1 day') g loop
    i := i + 1; t0 := clock_timestamp();
    insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
    values (v_org, v_arena, v_court, (to_char(d, 'YYYY-MM-DD') || ' 06:00:00-03:00')::timestamptz,
            (to_char(d, 'YYYY-MM-DD') || ' 06:50:00-03:00')::timestamptz, 'CONFIRMED', 'INTERNAL');
    insert into ms values ('insert_com_trigger', i, extract(epoch from clock_timestamp() - t0) * 1000);
  end loop;
  -- mesma carga com a trigger desabilitada (apenas nesta transação de teste) => custo marginal
  alter table public.reservations disable trigger validate_reservation_zz_series_slot;
  i := 0;
  for d in select g::date from generate_series(private.rg_today() + 1, private.rg_today() + 200, interval '1 day') g loop
    i := i + 1; t0 := clock_timestamp();
    insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
    values (v_org, v_arena, v_court, (to_char(d, 'YYYY-MM-DD') || ' 06:50:00-03:00')::timestamptz,
            (to_char(d, 'YYYY-MM-DD') || ' 06:55:00-03:00')::timestamptz, 'CONFIRMED', 'INTERNAL');
    insert into ms values ('insert_sem_trigger', i, extract(epoch from clock_timestamp() - t0) * 1000);
  end loop;
  alter table public.reservations enable trigger validate_reservation_zz_series_slot;
  raise notice 'BENCH quadra com % séries ACTIVE', n;
  raise notice 'BENCH %', pg_temp.report('insert_com_trigger');
  raise notice 'BENCH %', pg_temp.report('insert_sem_trigger');
  raise notice 'BENCH custo marginal médio da trigger: % ms/linha',
    round((select avg(ms) from ms where bench = 'insert_com_trigger') - (select avg(ms) from ms where bench = 'insert_sem_trigger'), 3);
end $$;

-- lacunas: leitura do gestor
do $$
declare t0 timestamptz; v_owner uuid := (select v::uuid from bk where k = 'b195:owner'); v_org uuid := (select v::uuid from bk where k = 'b195:org');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  t0 := clock_timestamp();
  perform public.rg_recurring_gaps(v_org, null);
  raise notice 'BENCH rg_recurring_gaps (org com 195 séries): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ----------------------------------------------------------------------------- 5.000 séries (escala)
do $$ declare t0 timestamptz := clock_timestamp(); begin
  perform pg_temp.mk('b5k', 50); perform pg_temp.series('b5k', 5000);
  raise notice 'BENCH (setup) 5000 séries criadas em % s', round(extract(epoch from clock_timestamp() - t0), 1);
end $$;
do $$
declare t0 timestamptz; v_series uuid[]; r jsonb;
begin
  select array_agg(id) into v_series from public.recurring_reservations where arena_id = (select v::uuid from bk where k = 'b5k:arena');
  t0 := clock_timestamp();
  perform private.rg_topup_candidates(120, null);
  raise notice 'BENCH candidatos globais (5195 séries, 5000 pendentes): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  t0 := clock_timestamp();
  perform count(*) from private.rg_recurring_topup_plan(120, v_series);
  raise notice 'BENCH dry-run 5000 séries/120 dias: % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  t0 := clock_timestamp();
  r := private.rg_recurring_topup_batch(500, v_series);
  raise notice 'BENCH lote 500 séries vazias (materializa %): % ms', r->'counts'->>'created', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
end $$;

-- ----------------------------------------------------------------------------- EXPLAINs
select '--- EXPLAIN trigger: séries ACTIVE da quadra (idx_recurring_court_active)';
explain (analyze, buffers, costs off)
select s.* from public.recurring_reservations s
 where s.court_id = (select v::uuid from bk where k = 'trg:court') and s.status = 'ACTIVE'
   and s.start_date <= private.rg_today() + 30 and (s.has_no_end_date or s.end_date is null or s.end_date >= private.rg_today() + 29)
 order by s.id for share;
select '--- EXPLAIN existência da ocorrência (idx_res_series_anchor)';
explain (analyze, buffers, costs off)
select 1 from public.reservations r
 where r.recurring_reservation_id = (select id from public.recurring_reservations where court_id = (select v::uuid from bk where k = 'trg:court') limit 1)
   and r.occurrence_date = private.rg_today() + 10;
select '--- EXPLAIN conflito na quadra (gist reservations_no_overlap)';
explain (analyze, buffers, costs off)
select r.id from public.reservations r
 where r.court_id = (select v::uuid from bk where k = 'trg:court') and r.status in ('PENDING', 'CONFIRMED', 'PAID', 'BLOCKED')
   and tstzrange(r.start_at, r.end_at) && tstzrange(now() + interval '10 days', now() + interval '10 days 1 hour')
 order by r.start_at, r.id limit 1;
select '--- EXPLAIN planejador de uma série sem fim (120 dias)';
explain (analyze, buffers, costs off)
select * from private.rg_plan_series((select id from public.recurring_reservations where court_id = (select v::uuid from bk where k = 'trg:court') limit 1),
                                     private.rg_today(), private.rg_today() + 120);
select '--- EXPLAIN lacunas abertas da org (idx_rog_org_open)';
explain (analyze, buffers, costs off)
select g.* from public.recurring_occurrence_gaps g where g.organization_id = (select v::uuid from bk where k = 'b195:org') and g.resolved_at is null;

rollback;
