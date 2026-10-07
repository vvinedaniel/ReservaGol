-- =============================================================================
-- RESERVA GOL — FASE 03B.3A — testes SQL de Mensalistas (visão mensal + recebimento do mês + W1 + W2)
-- Requer 03A + 03B.1 + 03B.2 (+A.1) + B3 + migration_phase3b3_recurring_month.sql aplicadas.
-- Banco de TESTE local, nunca Production.
--
-- Como rodar:
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3b3_recurring_month.sql
-- Sucesso: imprime "P3B3_RESULTS OK ..." e faz ROLLBACK explícito. Falha: erro "P3B3_RESULTS FAIL ..."
-- (exit != 0), transação nunca confirmada. ZERO RESÍDUO nos dois caminhos.
--
-- Blocos: A autorização/tenant · B leitura (semântica, mês, linhagem, histórico, pureza) ·
--         C recebimento do mês (distribuição, idempotência, validações, falha injetada, imutabilidade) ·
--         D W1 (vincular cliente) · E W2 (aplicar valor da série) · G privilégios · H regressão.
-- Concorrência real (várias sessões) fica em tests/phase3b3_concurrency.sh.
-- Datas relativas a hoje (America/Sao_Paulo): M = próximo mês (inteiro dentro da janela de 90 dias),
-- P = dois meses atrás (inteiro no passado). Ocorrências fora da janela são inseridas como postgres,
-- respeitando o contrato D7 (âncora, horário e valores da série).
-- =============================================================================
begin;
set local statement_timeout = '180s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table fd (k text primary key, d date not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
create temp table kv (k text primary key, v jsonb) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3b3: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('public.rg_recurring_month_payment_record(uuid, uuid, date, integer, text, timestamptz, text, bigint)') is null then
    raise exception 'p3b3: migration 03B.3 não aplicada';
  end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.d(p text) returns date language sql stable as $$ select d from fd where k = p $$;
create function pg_temp.v(p text) returns jsonb language sql stable as $$ select v from kv where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- Hash de tudo o que as RPCs podem tocar (checagem de "nada mudou")
create function pg_temp.snap() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'bt:' || row_to_json(r)::text as x from public.reservation_payment_batches r
    union all select 'bi:' || row_to_json(r)::text from public.reservation_payment_batch_items r
    union all select 'rp:' || row_to_json(r)::text from public.reservation_payments r
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r
    union all select 're:' || row_to_json(r)::text from public.reservations r
    union all select 'rs:' || row_to_json(r)::text from public.recurring_reservations r
    union all select 'cu:' || row_to_json(r)::text from public.customers r
  ) s), '')) $$;

create function pg_temp.call(p_actor text, p_sql text, out state text, out result jsonb)
language plpgsql as $$
declare v_claims text; v_msg text; v_hint text;
begin
  v_claims := case
    when p_actor in ('anon', 'service_role') then json_build_object('role', p_actor)::text
    when p_actor = 'postgres' then ''
    else json_build_object('sub', pg_temp.k(p_actor), 'role', 'authenticated')::text end;
  perform set_config('request.jwt.claims', v_claims, true);
  if p_actor in ('anon', 'service_role') then execute format('set local role %I', p_actor);
  elsif p_actor <> 'postgres' then execute 'set local role authenticated';
  end if;
  begin
    execute p_sql into result;
    state := 'OK';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    state := sqlstate;
    result := jsonb_build_object('msg', v_msg, 'hint', nullif(v_hint, ''));
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create function pg_temp.do_(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.call(p_actor, p_sql);
  if v.state <> 'OK' then raise exception 'p3b3 (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

create function pg_temp.expect(p_name text, p_actor text, p_sql text, p_state text, p_hint text default null) returns void
language plpgsql as $$
declare v_before text; v record;
begin
  v_before := pg_temp.snap();
  select * into v from pg_temp.call(p_actor, p_sql);
  perform pg_temp.ok(p_name,
    v.state = p_state and pg_temp.snap() = v_before and (p_hint is null or v.result->>'hint' = p_hint),
    format('esperado=%s%s veio=%s %s', p_state, coalesce(' hint=' || p_hint, ''), v.state, coalesce(v.result::text, '')));
end $$;

-- SQL das RPCs
create function pg_temp.q_list(p_org uuid, p_arena uuid, p_month date, p_status text default null, p_q text default null,
  p_limit integer default 50, p_cursor jsonb default null) returns text language sql stable as $$
  select format('select public.rg_recurring_month_list(%L::uuid, %L::uuid, %L::date, %L, %L, %s, %L::jsonb)',
    p_org, p_arena, p_month, p_status, p_q, coalesce(p_limit::text, 'null'), p_cursor) $$;
create function pg_temp.q_search(p_org uuid, p_month date, p_q text default null, p_limit integer default 20)
returns text language sql stable as $$
  select format('select public.rg_recurring_month_search(%L::uuid, %L::date, %L, %s)', p_org, p_month, p_q, coalesce(p_limit::text, 'null')) $$;
create function pg_temp.q_det(p_lineage uuid, p_month date) returns text language sql stable as $$
  select format('select public.rg_recurring_month_detail(%L::uuid, %L::date)', p_lineage, p_month) $$;
create function pg_temp.q_pay(p_op uuid, p_lineage uuid, p_month date, p_amount integer, p_method text default 'PIX',
  p_at timestamptz default now() - interval '1 hour', p_notes text default null, p_expected bigint default null)
returns text language sql stable as $$
  select format('select public.rg_recurring_month_payment_record(%L::uuid, %L::uuid, %L::date, %s, %L, %L::timestamptz, %L, %L::bigint)',
    p_op, p_lineage, p_month, coalesce(p_amount::text, 'null'), p_method, p_at, p_notes, p_expected) $$;
create function pg_temp.q_link(p_lineage uuid, p_cust uuid, p_customer jsonb default null) returns text language sql stable as $$
  select format('select public.rg_recurring_link_customer(%L::uuid, %L::uuid, %L::jsonb)', p_lineage, p_cust, p_customer) $$;
create function pg_temp.q_apply(p_lineage uuid, p_month date) returns text language sql stable as $$
  select format('select public.rg_recurring_month_apply_series_price(%L::uuid, %L::date)', p_lineage, p_month) $$;

-- Série pela RPC real (B3), sem materializar (datas inseridas depois)
create function pg_temp.series(p_key text, p_arena text, p_court text, p_cust text, p_freq text, p_wd integer, p_dom integer,
  p_st time, p_et time, p_start date, p_price integer) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, null, %L, %s, %s, %L::time, %L::time, %L::date, null, true, %s, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k(p_arena), pg_temp.k(p_court), case when p_cust is null then null else pg_temp.k(p_cust) end,
    p_freq, coalesce(p_wd::text, 'null'), coalesce(p_dom::text, 'null'), p_st, p_et, p_start, coalesce(p_price::text, 'null')));
  insert into fx values (p_key, (r->>'series_id')::uuid);
  return (r->>'series_id')::uuid;
end $$;
-- Ocorrência pelo contrato D7 (como postgres: permite datas fora da janela de materialização)
create function pg_temp.occ(p_series uuid, p_d date) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, notes,
    price, recurring_reservation_id, occurrence_date, is_exception, created_by)
  select s.organization_id, s.arena_id, s.court_id, s.customer_id, b.start_at, b.end_at, 'CONFIRMED', 'RECORRENTE', s.notes,
         s.default_price, s.id, p_d, false, null
    from public.recurring_reservations s, private.rg_occurrence_bounds(p_d, s.start_time, s.end_time) b
   where s.id = p_series
  returning id into v_id;
  return v_id;
end $$;
create function pg_temp.occ_id(p_series uuid, p_d date) returns uuid language sql stable as $$
  select r.id from public.reservations r where r.recurring_reservation_id = p_series and r.occurrence_date = p_d $$;
create function pg_temp.days(p_from date, p_to date, p_dow integer) returns date[] language sql immutable as $$
  select coalesce(array_agg(g::date order by g), '{}') from generate_series(p_from, p_to, interval '1 day') g
   where extract(dow from g)::int = p_dow $$;
create function pg_temp.item(p_list jsonb, p_lineage uuid) returns jsonb language sql immutable as $$
  select e from jsonb_array_elements(p_list->'items') e where e->>'lineage_id' = p_lineage::text $$;
create function pg_temp.fin_open(p_ids uuid[]) returns bigint language sql stable as $$
  select coalesce(sum(collectible_balance), 0) from private.rg_financials(p_ids) $$;

-- ----------------------------------------------------------------------------- datas
do $$
declare
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_m date := (date_trunc('month', v_today) + interval '1 month')::date;
  v_p date := (date_trunc('month', v_today) - interval '2 months')::date;
begin
  insert into fd values ('today', v_today), ('M', v_m), ('Mlast', (v_m + interval '1 month' - interval '1 day')::date),
    ('M2', (v_m + interval '1 month')::date), ('P', v_p), ('Plast', (v_p + interval '1 month' - interval '1 day')::date),
    ('start', v_p - 7);
end $$;

-- ----------------------------------------------------------------------------- fixtures
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_out uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); u_str uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_a2 uuid; v_b1 uuid;
  v_tag text := 'p3b3-' || substr(md5(clock_timestamp()::text), 1, 8);
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'), (u_rec, v_tag || '-rec@reservagol.test'),
    (u_out, v_tag || '-out@reservagol.test'), (u_adm, v_tag || '-adm@reservagol.test'), (u_str, v_tag || '-str@reservagol.test');
  insert into public.profiles (id) values (u_adm) on conflict (id) do nothing;
  update public.profiles set is_platform_admin = true where id = u_adm;
  insert into public.organizations (name, is_demo) values ('P3B3 ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3B3 outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE'), (v_org, u_str, 'MANAGER', 'SUSPENDED');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;
  insert into public.arenas (organization_id, name) values (v_org, 'A2 ' || v_tag) returning id into v_a2;
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  -- 03C (setup apenas): horário de funcionamento explícito que cobre todos os horários materializados
  -- por esta suíte (10:00–22:00); 06:00–23:00 todos os dias. Nenhuma assertion alterada.
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select a.organization_id, a.id, w, '06:00', '23:00', false from public.arenas a cross join generate_series(0, 6) w
   where a.id in (v_a1, v_a2, v_b1);
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('adm', u_adm), ('str', u_str),
    ('org', v_org), ('org2', v_org2), ('a1', v_a1), ('a2', v_a2), ('b1', v_b1);
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Quadra 1') returning id) insert into fx select 'c1', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Quadra 2') returning id) insert into fx select 'c2', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a2, 'Quadra 3') returning id) insert into fx select 'c3', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'Quadra B') returning id) insert into fx select 'd1', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'João P3B3', '11990000001') returning id) insert into fx select 'cu1', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a2, 'Maria P3B3', '11990000002') returning id) insert into fx select 'cu2', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Ana Meia-noite', '11990000003') returning id) insert into fx select 'cu3', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a2, 'Bruno Exceção', '11990000004') returning id) insert into fx select 'cu4', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Carla Cortesia', '11990000005') returning id) insert into fx select 'cu5', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Diego Vínculo', '11990000006') returning id) insert into fx select 'cu6', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org2, v_b1, 'Outro Tenant', '11990000009') returning id) insert into fx select 'cuX', id from x;
end $$;

-- Séries (RPC real B3) + ocorrências
do $$
declare
  v_d date;
  v_t date[];
  v_r jsonb;
begin
  -- S1 João: terça 19-20, R$100, quadra 1; ocorrências em P e M; reagendada a partir da 3ª terça de M
  perform pg_temp.series('S1', 'a1', 'c1', 'cu1', 'WEEKLY', 2, null, '19:00', '20:00', pg_temp.d('start'), 10000);
  foreach v_d in array pg_temp.days(pg_temp.d('P'), pg_temp.d('Plast'), 2) || pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 2) loop
    perform pg_temp.occ(pg_temp.k('S1'), v_d);
  end loop;
  v_t := pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 2);
  insert into fd values ('T1', v_t[1]), ('T2', v_t[2]), ('T3', v_t[3]);
  insert into kv values ('nT', to_jsonb(cardinality(v_t)));
  v_r := pg_temp.do_('owner', format(
    'select public.rg_recurring_reschedule(%L::uuid, %L::uuid, %L::date, ''{"start_time":"20:00","end_time":"21:00"}''::jsonb, false, ''{}''::date[])',
    pg_temp.k('S1'), gen_random_uuid(), pg_temp.d('T3')));
  insert into fx values ('S1b', (select s.id from public.recurring_reservations s where s.previous_series_id = pg_temp.k('S1')));
  foreach v_d in array v_t[3:] loop perform pg_temp.occ(pg_temp.k('S1b'), v_d); end loop;

  -- S2 sem cliente: quinta 19-20, R$50, quadra 2
  perform pg_temp.series('S2', 'a1', 'c2', null, 'WEEKLY', 4, null, '19:00', '20:00', pg_temp.d('start'), 5000);
  foreach v_d in array pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 4) loop perform pg_temp.occ(pg_temp.k('S2'), v_d); end loop;

  -- S3 Maria sem valor: segunda 19-20, arena 2; ocorrências em P e M
  perform pg_temp.series('S3', 'a2', 'c3', 'cu2', 'WEEKLY', 1, null, '19:00', '20:00', pg_temp.d('start'), null);
  foreach v_d in array pg_temp.days(pg_temp.d('P'), pg_temp.d('Plast'), 1) || pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 1) loop
    perform pg_temp.occ(pg_temp.k('S3'), v_d);
  end loop;

  -- S4 Ana: mensal no último dia de M, 23:00-00:30 (atravessa a meia-noite para M2)
  perform pg_temp.series('S4', 'a1', 'c1', 'cu3', 'MONTHLY', null, extract(day from pg_temp.d('Mlast'))::int, '23:00', '00:30',
    pg_temp.d('start'), 8000);
  perform pg_temp.occ(pg_temp.k('S4'), pg_temp.d('Mlast'));

  -- S5 Bruno: dia da semana do último dia de M, 10-11, arena 2, R$60; última ocorrência movida para M2 (exceção)
  perform pg_temp.series('S5', 'a2', 'c3', 'cu4', 'WEEKLY', extract(dow from pg_temp.d('Mlast'))::int, null, '10:00', '11:00',
    pg_temp.d('start'), 6000);
  v_t := pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), extract(dow from pg_temp.d('Mlast'))::int);
  foreach v_d in array v_t loop perform pg_temp.occ(pg_temp.k('S5'), v_d); end loop;
  insert into kv values ('nS5', to_jsonb(cardinality(v_t)));
  update public.reservations set start_at = start_at + interval '1 day', end_at = end_at + interval '1 day', is_exception = true
   where id = pg_temp.occ_id(pg_temp.k('S5'), pg_temp.d('Mlast'));
  update public.reservations set status = 'NO_SHOW', is_exception = true where id = pg_temp.occ_id(pg_temp.k('S5'), v_t[1]);
  update public.reservations set status = 'CANCELLED', is_exception = true where id = pg_temp.occ_id(pg_temp.k('S5'), v_t[2]);
  insert into fd values ('S5d1', v_t[1]), ('S5d2', v_t[2]);

  -- S6 Carla: valor 0 (cortesia), quarta 08-09
  perform pg_temp.series('S6', 'a1', 'c1', 'cu5', 'WEEKLY', 3, null, '08:00', '09:00', pg_temp.d('start'), 0);
  foreach v_d in array pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 3) loop perform pg_temp.occ(pg_temp.k('S6'), v_d); end loop;

  -- S7 datas faltantes: quarta 12-13, arena 2; só a 1ª quarta de M gerada (pela RPC real de geração)
  perform pg_temp.series('S7', 'a2', 'c3', 'cu5', 'WEEKLY', 3, null, '12:00', '13:00', pg_temp.d('start'), 7000);
  perform pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('S7'),
    array[(pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 3))[1]]));

  -- S8 cancelada hoje, teve jogos em P (sexta 15-16, quadra 2)
  perform pg_temp.series('S8', 'a1', 'c2', 'cu6', 'WEEKLY', 5, null, '15:00', '16:00', pg_temp.d('start'), 3000);
  foreach v_d in array pg_temp.days(pg_temp.d('P'), pg_temp.d('Plast'), 5) loop perform pg_temp.occ(pg_temp.k('S8'), v_d); end loop;
  perform pg_temp.do_('owner', format('select public.rg_recurring_cancel(%L::uuid)', pg_temp.k('S8')));

  -- S9 sem cliente com reagendamento (W1 na linhagem inteira): sábado 09-10, quadra 2
  perform pg_temp.series('S9', 'a1', 'c2', null, 'WEEKLY', 6, null, '09:00', '10:00', pg_temp.d('start'), 4000);
  v_t := pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 6);
  foreach v_d in array v_t loop perform pg_temp.occ(pg_temp.k('S9'), v_d); end loop;
  perform pg_temp.do_('owner', format(
    'select public.rg_recurring_reschedule(%L::uuid, %L::uuid, %L::date, ''{"start_time":"10:00","end_time":"11:00"}''::jsonb, false, ''{}''::date[])',
    pg_temp.k('S9'), gen_random_uuid(), v_t[2]));
  insert into fx values ('S9b', (select s.id from public.recurring_reservations s where s.previous_series_id = pg_temp.k('S9')));
  foreach v_d in array v_t[2:] loop perform pg_temp.occ(pg_temp.k('S9b'), v_d); end loop;
end $$;

-- Série da outra organização
do $$
declare r jsonb;
begin
  r := pg_temp.do_('out', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, null, ''WEEKLY'', 2, null, ''19:00''::time, ''20:00''::time, %L::date, null, true, 9000, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k('b1'), pg_temp.k('d1'), pg_temp.k('cuX'), pg_temp.d('start')));
  insert into fx values ('SX', (r->>'series_id')::uuid);
  perform pg_temp.occ(pg_temp.k('SX'), pg_temp.d('T1'));
end $$;

-- ============================================================================= A) autorização / tenant
do $$
declare v record; v_sql text := pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'));
begin
  select * into v from pg_temp.call('owner', v_sql);
  perform pg_temp.ok('A01a lista: OWNER lê', v.state = 'OK', v.state);
  select * into v from pg_temp.call('mgr', v_sql);
  perform pg_temp.ok('A01b lista: MANAGER lê', v.state = 'OK', v.state);
  perform pg_temp.expect('A01c lista: RECEPTIONIST negado (agregado)', 'rec', v_sql, '42501');
  perform pg_temp.expect('A01d lista: PLATFORM_ADMIN sem vínculo negado', 'adm', v_sql, '42501');
  perform pg_temp.expect('A01e lista: vínculo SUSPENDED negado', 'str', v_sql, '42501');
  perform pg_temp.expect('A01f lista: OWNER de outra organização negado', 'out', v_sql, '42501');
  perform pg_temp.expect('A01g lista: anon sem EXECUTE', 'anon', v_sql, '42501');
  perform pg_temp.expect('A01h lista: service_role sem EXECUTE', 'service_role', v_sql, '42501');

  v_sql := pg_temp.q_search(pg_temp.k('org'), pg_temp.d('M'), null);
  select * into v from pg_temp.call('rec', v_sql);
  perform pg_temp.ok('A02a busca: RECEPTIONIST lê', v.state = 'OK', v.state);
  perform pg_temp.expect('A02b busca: PLATFORM_ADMIN sem vínculo = não encontrado', 'adm', v_sql, 'P0002');
  perform pg_temp.expect('A02c busca: outra organização = não encontrado', 'out', v_sql, 'P0002');
  perform pg_temp.ok('A02d busca: sem nenhum valor financeiro na resposta',
    v.result::text !~ '"(expected|net|open|overdue|retained|price|amount)"', left(v.result::text, 300));

  v_sql := pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M'));
  select * into v from pg_temp.call('rec', v_sql);
  perform pg_temp.ok('A03a detalhe: RECEPTIONIST lê UMA linhagem', v.state = 'OK', v.state);
  perform pg_temp.ok('A03b detalhe RECEPTIONIST: sem "retido", sem lançamentos, sem autor',
    (v.result->'summary'->'retained') = 'null'::jsonb and v.result->>'is_manager' = 'false'
    and v.result::text !~ '(created_by|payment_id|voided|refund)' and position(pg_temp.k('owner')::text in v.result::text) = 0,
    left(v.result::text, 300));
  perform pg_temp.expect('A03c detalhe: outra organização = não encontrado', 'out', v_sql, 'P0002');
  perform pg_temp.expect('A03d detalhe: PLATFORM_ADMIN sem vínculo = não encontrado', 'adm', v_sql, 'P0002');
  perform pg_temp.expect('A03e detalhe: série da outra organização = não encontrado', 'owner', pg_temp.q_det(pg_temp.k('SX'), pg_temp.d('M')), 'P0002');
  perform pg_temp.expect('A03f detalhe: série inexistente = não encontrado', 'owner', pg_temp.q_det(gen_random_uuid(), pg_temp.d('M')), 'P0002');

  perform pg_temp.expect('A04a pagar: outra organização = não encontrado', 'out',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000), 'P0002');
  perform pg_temp.expect('A04b pagar: PLATFORM_ADMIN sem vínculo = não encontrado', 'adm',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000), 'P0002');
  perform pg_temp.expect('A04c pagar: anon sem EXECUTE', 'anon', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000), '42501');
  perform pg_temp.expect('A05a W1: RECEPTIONIST negado', 'rec', pg_temp.q_link(pg_temp.k('S2'), pg_temp.k('cu6')), '42501');
  perform pg_temp.expect('A05b W1: PLATFORM_ADMIN sem vínculo = não encontrado', 'adm', pg_temp.q_link(pg_temp.k('S2'), pg_temp.k('cu6')), 'P0002');
  perform pg_temp.expect('A05c W2: RECEPTIONIST negado', 'rec', pg_temp.q_apply(pg_temp.k('S3'), pg_temp.d('M')), '42501');
  perform pg_temp.expect('A05d W2: outra organização = não encontrado', 'out', pg_temp.q_apply(pg_temp.k('S3'), pg_temp.d('M')), 'P0002');
  perform pg_temp.expect('A06a tabela batches: authenticated sem SELECT direto', 'owner',
    'select to_jsonb(count(*)) from public.reservation_payment_batches', '42501');
  perform pg_temp.expect('A06b tabela itens: authenticated sem INSERT direto', 'owner',
    format('insert into public.reservation_payment_batch_items (batch_id, organization_id, position, payment_id, reservation_id, amount) values (%L, %L, 1, %L, %L, 1) returning to_jsonb(1)',
      gen_random_uuid(), pg_temp.k('org'), gen_random_uuid(), gen_random_uuid()), '42501');
  select * into v from pg_temp.call('service_role', 'select to_jsonb(count(*)) from public.reservation_payment_batches');
  perform pg_temp.ok('A06c tabela batches: service_role só lê (limpeza demo)', v.state = 'OK', v.state);
end $$;

-- ============================================================================= B) leitura
do $$
declare
  l jsonb; it jsonb; d jsonb; v_before text; n int := (pg_temp.v('nT'))::int; v record; p1 jsonb; p2 jsonb; v_all text[];
begin
  v_before := pg_temp.snap();
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M')));
  perform pg_temp.do_('rec', pg_temp.q_search(pg_temp.k('org'), pg_temp.d('M'), 'jo'));
  perform pg_temp.do_('rec', pg_temp.q_det(pg_temp.k('S1b'), pg_temp.d('M')));
  perform pg_temp.ok('B00 leituras não escrevem nada (lista, busca, detalhe)', pg_temp.snap() = v_before, 'snap mudou');

  it := pg_temp.item(l, pg_temp.k('S1'));
  perform pg_temp.ok('B01a linhagem reagendada = UMA linha (raiz)',
    (select count(*) from jsonb_array_elements(l->'items') e where e->>'lineage_id' in (pg_temp.k('S1')::text, pg_temp.k('S1b')::text)) = 1
    and it->>'series_id' = pg_temp.k('S1b')::text, coalesce(it::text, 'null'));
  perform pg_temp.ok('B01b jogos/canceladas somam as duas séries',
    (it->>'games')::int = n and (it->>'cancelled')::int = n - 2, coalesce(it::text, 'null'));
  perform pg_temp.ok('B01c previsto = snapshots das reservas (n × R$100)', (it->>'expected')::bigint = n * 10000
    and (it->>'open')::bigint = n * 10000 and it->>'status' = 'OPEN' and it->>'start_time' = '20:00', coalesce(it::text, 'null'));

  it := pg_temp.item(l, pg_temp.k('S2'));
  perform pg_temp.ok('B02 sem cliente aparece, customer_name null', it is not null and it->>'customer_id' is null
    and it->>'customer_name' is null, coalesce(it::text, 'null'));
  it := pg_temp.item(l, pg_temp.k('S3'));
  perform pg_temp.ok('B03 jogos sem valor => UNPRICED, previsto 0', it->>'status' = 'UNPRICED'
    and (it->>'unpriced')::int = cardinality(pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 1)) and (it->>'expected')::bigint = 0,
    coalesce(it::text, 'null'));
  it := pg_temp.item(l, pg_temp.k('S4'));
  perform pg_temp.ok('B04 jogo que atravessa a meia-noite pertence ao mês do occurrence_date', (it->>'games')::int = 1
    and (it->>'expected')::bigint = 8000, coalesce(it::text, 'null'));
  it := pg_temp.item(l, pg_temp.k('S5'));
  perform pg_temp.ok('B05a exceção movida para M2 continua em M; NO_SHOW cobrável; cancelada fora',
    (it->>'games')::int = (pg_temp.v('nS5'))::int - 1 and (it->>'cancelled')::int = 1
    and (it->>'expected')::bigint = ((pg_temp.v('nS5'))::int - 1) * 6000, coalesce(it::text, 'null'));
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M2')));
  perform pg_temp.ok('B05b exceção movida NÃO aparece em M2', pg_temp.item(l, pg_temp.k('S5')) is null and pg_temp.item(l, pg_temp.k('S4')) is null,
    left(l::text, 200));
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S5'), pg_temp.d('M')));
  perform pg_temp.ok('B05c detalhe marca a ocorrência movida (moved=true, data do slot original)',
    exists (select 1 from jsonb_array_elements(d->'occurrences') e
             where e->>'occurrence_date' = to_char(pg_temp.d('Mlast'), 'YYYY-MM-DD') and (e->>'moved')::boolean and (e->>'is_exception')::boolean),
    left(d->>'occurrences', 300));

  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M')));
  it := pg_temp.item(l, pg_temp.k('S6'));
  perform pg_temp.ok('B06 valor 0 => NO_CHARGE', it->>'status' = 'NO_CHARGE' and (it->>'open')::bigint = 0, coalesce(it::text, 'null'));
  perform pg_temp.ok('B07 cards = mês+arena (todas as linhagens com jogos em M)',
    (l->'summary'->>'lineages')::int = 8 and (l->'summary'->>'expected')::bigint = (select coalesce(sum((e->>'expected')::bigint), 0) from jsonb_array_elements(l->'items') e)
    and (l->'summary'->>'open')::bigint = (select coalesce(sum((e->>'open')::bigint), 0) from jsonb_array_elements(l->'items') e),
    l->>'summary');
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), pg_temp.k('a2'), pg_temp.d('M')));
  perform pg_temp.ok('B08 filtro de arena: só linhagens da arena 2',
    (l->'summary'->>'lineages')::int = 3 and pg_temp.item(l, pg_temp.k('S3')) is not null and pg_temp.item(l, pg_temp.k('S1')) is null, l->>'summary');
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), 'NO_CUSTOMER'));
  perform pg_temp.ok('B09a filtro NO_CUSTOMER', jsonb_array_length(l->'items') = 2 and pg_temp.item(l, pg_temp.k('S2')) is not null
    and pg_temp.item(l, pg_temp.k('S9')) is not null and (l->'summary'->>'lineages')::int = 8, left(l::text, 200));
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), 'UNPRICED'));
  perform pg_temp.ok('B09b filtro por status derivado', jsonb_array_length(l->'items') = 1 and pg_temp.item(l, pg_temp.k('S3')) is not null, left(l::text, 200));
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, 'joão'));
  perform pg_temp.ok('B09c busca por nome (sem distinção de caixa)', jsonb_array_length(l->'items') = 1 and pg_temp.item(l, pg_temp.k('S1')) is not null,
    left(l::text, 200));
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, '9000-0003'));
  perform pg_temp.ok('B09d busca por telefone (dígitos)', jsonb_array_length(l->'items') = 1 and pg_temp.item(l, pg_temp.k('S4')) is not null,
    left(l::text, 200));
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, '100%_'));
  perform pg_temp.ok('B09e curingas da busca são literais', jsonb_array_length(l->'items') = 0, left(l::text, 200));

  -- paginação por cursor: 8 linhagens em páginas de 3, sem repetição nem perda
  p1 := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, null, 3));
  v_all := array(select e->>'lineage_id' from jsonb_array_elements(p1->'items') e);
  while p1->'next_cursor' is not null and p1->>'next_cursor' <> 'null' loop
    p1 := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, null, 3, p1->'next_cursor'));
    v_all := v_all || array(select e->>'lineage_id' from jsonb_array_elements(p1->'items') e);
  end loop;
  perform pg_temp.ok('B10 paginação: 8 linhagens, sem repetição, sem cliente por último',
    cardinality(v_all) = 8 and (select count(distinct x) from unnest(v_all) x) = 8
    and v_all[7:8] @> array[pg_temp.k('S2')::text, pg_temp.k('S9')::text], array_to_string(v_all, ','));

  -- mês passado: atraso pela regra da 03B.1; série cancelada continua no histórico
  l := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('P')));
  it := pg_temp.item(l, pg_temp.k('S1'));
  perform pg_temp.ok('B11 mês passado sem pagamento => OVERDUE, vencido = previsto',
    it->>'status' = 'OVERDUE' and (it->>'overdue')::bigint = (it->>'expected')::bigint and (it->>'expected')::bigint > 0
    and (it->>'has_overdue')::boolean, coalesce(it::text, 'null'));
  it := pg_temp.item(l, pg_temp.k('S8'));
  perform pg_temp.ok('B12 série CANCELADA hoje ainda aparece no mês em que jogou', it is not null and it->>'series_status' = 'CANCELLED'
    and (it->>'games')::int = cardinality(pg_temp.days(pg_temp.d('P'), pg_temp.d('Plast'), 5)), coalesce(it::text, 'null'));

  -- histórico: mudar o valor da série não reescreve ocorrências materializadas
  perform pg_temp.do_('owner', format('select public.rg_recurring_update(%L::uuid, ''{"default_price":15000}''::jsonb)', pg_temp.k('S1b')));
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M')));
  perform pg_temp.ok('B13 novo default_price da série não reescreve o mês (snapshot)',
    (d->'summary'->>'expected')::bigint = n * 10000 and (d->'current'->>'default_price')::int = 15000, d->>'summary');
  perform pg_temp.do_('owner', format('select public.rg_recurring_update(%L::uuid, ''{"default_price":10000}''::jsonb)', pg_temp.k('S1b')));

  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S7'), pg_temp.d('M')));
  perform pg_temp.ok('B14 datas previstas ainda não geradas (cálculo puro, sem gerar)',
    jsonb_array_length(d->'missing_future_dates') = cardinality(pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 3)) - 1
    and (select count(*) from public.reservations r where r.recurring_reservation_id = pg_temp.k('S7')) = 1,
    d->>'missing_future_dates');
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1b'), pg_temp.d('M')));
  perform pg_temp.ok('B15 detalhe aceita série filha e devolve a raiz; ocorrências em ordem; 2 séries',
    d->>'lineage_id' = pg_temp.k('S1')::text and jsonb_array_length(d->'series') = 2
    and jsonb_array_length(d->'occurrences') = 2 * n - 2
    and (select bool_and(a <= b) from (select e->>'occurrence_date' a, lead(e->>'occurrence_date') over (order by ord) b
           from jsonb_array_elements(d->'occurrences') with ordinality x(e, ord)) s where b is not null),
    left(d::text, 200));
  perform pg_temp.ok('B16 detalhe: elegível; sem bloqueio; gestor vê retido', (d->>'eligible')::boolean and d->>'blocked_reason' is null
    and (d->'summary'->'retained') <> 'null'::jsonb and (d->>'is_manager')::boolean, d->>'summary');
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S2'), pg_temp.d('M')));
  perform pg_temp.ok('B17 sem cliente: inelegível (CUSTOMER_REQUIRED) e gestor pode vincular',
    not (d->>'eligible')::boolean and d->>'blocked_reason' = 'CUSTOMER_REQUIRED' and (d->>'can_link_customer')::boolean, d->>'blocked_reason');

  perform pg_temp.expect('B18a mês inválido (dia 15)', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M') + 14), '22023');
  perform pg_temp.expect('B18b mês nulo', 'owner', pg_temp.q_det(pg_temp.k('S1'), null), '22023');
  perform pg_temp.expect('B18c arena de outra organização', 'owner', pg_temp.q_list(pg_temp.k('org'), pg_temp.k('b1'), pg_temp.d('M')), '22023');
  perform pg_temp.expect('B18d status inválido', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), 'XYZ'), '22023');
  perform pg_temp.expect('B18e limite 0', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, null, 0), '22023');
  perform pg_temp.expect('B18f limite 101', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, null, 101), '22023');
  perform pg_temp.expect('B18g cursor malformado', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, null, 5, '{"nc":1}'), '22023');
  perform pg_temp.expect('B18h busca: limite 21', 'rec', pg_temp.q_search(pg_temp.k('org'), pg_temp.d('M'), null, 21), '22023');
  perform pg_temp.expect('B18i busca > 100 caracteres', 'owner', pg_temp.q_list(pg_temp.k('org'), null, pg_temp.d('M'), null, repeat('x', 101)), '22023');

  select * into v from pg_temp.call('rec', pg_temp.q_search(pg_temp.k('org'), pg_temp.d('M'), 'maria'));
  perform pg_temp.ok('B19 busca operacional: identidade + horário + elegibilidade',
    jsonb_array_length(v.result->'items') = 1 and v.result->'items'->0->>'customer_name' = 'Maria P3B3'
    and (v.result->'items'->0->>'eligible')::boolean and v.result->'items'->0->>'court_name' = 'Quadra 3', left(v.result::text, 300));
end $$;

-- ============================================================================= C) recebimento do mês
do $$
declare
  n int := (pg_temp.v('nT'))::int;
  r jsonb; r2 jsonb; d jsonb; v_op uuid := gen_random_uuid(); v_before text; v_bid uuid; v_open bigint;
  v_at timestamptz := now() - interval '2 hours';
begin
  perform pg_temp.expect('C01 sem cliente => RGP01 CUSTOMER_REQUIRED', 'owner',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S2'), pg_temp.d('M'), 1000), 'RGP01', 'CUSTOMER_REQUIRED');
  perform pg_temp.expect('C02 jogo sem valor => RGP01 UNPRICED', 'owner',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S3'), pg_temp.d('M'), 1000), 'RGP01', 'UNPRICED');
  perform pg_temp.expect('C03a nada a receber (valor 0) => RGP01 NOTHING_DUE', 'owner',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S6'), pg_temp.d('M'), 1000), 'RGP01', 'NOTHING_DUE');
  perform pg_temp.expect('C03b saldo mudou (expected_open divergente) => RGP01 STATE_CHANGED', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 25000, 'PIX', v_at, null, n * 10000 - 1), 'RGP01', 'STATE_CHANGED');
  perform pg_temp.expect('C03c overpayment => RGP03 OVER_BALANCE', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), n * 10000 + 1), 'RGP03', 'OVER_BALANCE');
  perform pg_temp.expect('C04a operation_id nulo', 'rec', pg_temp.q_pay(null, pg_temp.k('S1'), pg_temp.d('M'), 1000), '22023');
  perform pg_temp.expect('C04b método inválido', 'rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000, 'BOLETO'), '22023');
  perform pg_temp.expect('C04c valor 0', 'rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 0), '22023');
  perform pg_temp.expect('C04d valor acima do teto', 'rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 100000001), '22023');
  perform pg_temp.expect('C04e recebido_em nulo', 'rec', format('select public.rg_recurring_month_payment_record(%L::uuid, %L::uuid, %L::date, 1000, ''PIX'', null, null, null)',
    gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M')), '22023');
  perform pg_temp.expect('C04f mês inválido', 'rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M') + 3, 1000), '22023');
  perform pg_temp.expect('C04g recebido_em no futuro (> 5 min) => 23514, nada gravado', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000, 'PIX', now() + interval '1 hour'), '23514');
  perform pg_temp.expect('C04h observação > 500', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000, 'PIX', v_at, repeat('x', 501)), '22023');

  -- falha injetada no meio da distribuição: nada fica (batch, lançamentos, auditoria)
  v_before := pg_temp.snap();
  perform set_config('rg.fault_at', 'month_payment:item_2', true);
  perform pg_temp.expect('C05 falha injetada no 2º lançamento => RGF01 e ZERO linhas', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 25000), 'RGF01');
  perform set_config('rg.fault_at', '', true);

  -- recebimento parcial pela RECEPÇÃO: R$250 => T1 100, T2 100 (série S1), T3 50 (série S1b)
  r := pg_temp.do_('rec', pg_temp.q_pay(v_op, pg_temp.k('S1b'), pg_temp.d('M'), 25000, 'CASH', v_at, ' outubro ', n * 10000));
  insert into kv values ('C06', r);
  v_bid := (r->>'batch_id')::uuid;
  perform pg_temp.ok('C06a batch novo: 3 itens, mais antigo primeiro, último parcial, atravessa as 2 séries',
    not (r->>'idempotent')::boolean and (r->>'applied')::int = 25000 and jsonb_array_length(r->'items') = 3
    and r->'items'->0->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S1'), pg_temp.d('T1'))::text and (r->'items'->0->>'amount')::int = 10000
    and r->'items'->1->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S1'), pg_temp.d('T2'))::text and (r->'items'->1->>'amount')::int = 10000
    and r->'items'->2->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S1b'), pg_temp.d('T3'))::text and (r->'items'->2->>'amount')::int = 5000
    and (r->>'open_after')::bigint = n * 10000 - 25000 and r->>'lineage_id' = pg_temp.k('S1')::text, r::text);
  perform pg_temp.ok('C06b filhos = lançamentos 03A reais (PAYMENT/MANUAL, operation_id próprio, fingerprint 03A)',
    (select count(*) from public.reservation_payments p join public.reservation_payment_batch_items i on i.payment_id = p.id
      where i.batch_id = v_bid and p.kind = 'PAYMENT' and p.source = 'MANUAL' and p.method = 'CASH' and p.notes = 'outubro'
        and p.operation_id <> v_op and p.created_by = pg_temp.k('rec')
        and p.operation_fingerprint = private.rg_fin_fingerprint('PAYMENT', p.reservation_id, null, p.amount, 'CASH', v_at, 'outubro')) = 3
    and (select count(distinct p.operation_id) from public.reservation_payments p join public.reservation_payment_batch_items i on i.payment_id = p.id
          where i.batch_id = v_bid) = 3, 'filhos divergentes');
  perform pg_temp.ok('C06c auditoria: 3 PAYMENT_RECORDED (com batch_id) + 1 RECURRING_MONTH_PAYMENT_RECORDED, sem PII',
    (select count(*) from public.audit_logs a where a.action = 'PAYMENT_RECORDED' and a.metadata->>'batch_id' = v_bid::text) = 3
    and (select count(*) from public.audit_logs a where a.action = 'RECURRING_MONTH_PAYMENT_RECORDED' and a.entity_id = v_bid
          and (a.metadata->>'items')::int = 3 and (a.metadata->>'amount')::int = 25000 and a.metadata->>'lineage_id' = pg_temp.k('S1')::text
          and not (a.metadata ? 'notes')) = 1, 'auditoria divergente');
  perform pg_temp.ok('C06d semântica 03A coerente (rg_financials) e status do mês PARTIAL',
    pg_temp.fin_open(array(select r2.id from public.reservations r2 where r2.recurring_reservation_id in (pg_temp.k('S1'), pg_temp.k('S1b'))
      and r2.occurrence_date between pg_temp.d('M') and pg_temp.d('Mlast'))) = n * 10000 - 25000
    and (pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M')))->'summary'->>'status') = 'PARTIAL', 'semântica divergente');

  -- replay exato: mesmo batch, nenhuma linha nova — mesmo depois de o estado mudar
  update public.reservations set status = 'NO_SHOW', is_exception = true where id = pg_temp.occ_id(pg_temp.k('S1b'), pg_temp.d('T3'));
  v_before := pg_temp.snap();
  r2 := pg_temp.do_('owner', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('M'), 25000, 'CASH', v_at, 'outubro', 1));
  perform pg_temp.ok('C07 replay (mesmo op/payload; outro ator, expected_open divergente) => idempotent, mesmo batch, zero linhas',
    (r2->>'idempotent')::boolean and r2->>'batch_id' = v_bid::text and r2->'items' = r->'items' and pg_temp.snap() = v_before, r2::text);
  update public.reservations set status = 'CONFIRMED' where id = pg_temp.occ_id(pg_temp.k('S1b'), pg_temp.d('T3'));

  perform pg_temp.expect('C08a mesmo op, outro valor => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('M'), 25001, 'CASH', v_at, 'outubro'), 'RGP02');
  perform pg_temp.expect('C08b mesmo op, outro método => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('M'), 25000, 'PIX', v_at, 'outubro'), 'RGP02');
  perform pg_temp.expect('C08c mesmo op, outra data => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('M'), 25000, 'CASH', v_at - interval '1 second', 'outubro'), 'RGP02');
  perform pg_temp.expect('C08d mesmo op, outra observação => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('M'), 25000, 'CASH', v_at, 'novembro'), 'RGP02');
  perform pg_temp.expect('C08e mesmo op, outro mês => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S1'), pg_temp.d('P'), 25000, 'CASH', v_at, 'outubro'), 'RGP02');
  perform pg_temp.expect('C08f mesmo op, outro mensalista => RGP02', 'rec', pg_temp.q_pay(v_op, pg_temp.k('S4'), pg_temp.d('M'), 8000, 'CASH', v_at, 'outubro'), 'RGP02');

  -- recebimento individual 03A concorre com o mês (mesma reserva): o saldo do mês é recalculado
  perform pg_temp.do_('rec', format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', 5000, %L::timestamptz, null)',
    gen_random_uuid(), pg_temp.occ_id(pg_temp.k('S1b'), pg_temp.d('T3')), v_at));
  v_open := n * 10000 - 30000;
  perform pg_temp.expect('C09a pagamento individual muda o saldo => STATE_CHANGED com o saldo antigo', 'rec',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000, 'PIX', v_at, null, n * 10000 - 25000), 'RGP01', 'STATE_CHANGED');
  r := pg_temp.do_('rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), v_open::int, 'PIX', v_at, null, v_open));
  perform pg_temp.ok('C09b quitação do restante => mês PAID, saldo 0; T3 já quitado fica de fora',
    (r->>'open_after')::bigint = 0 and not exists (select 1 from jsonb_array_elements(r->'items') e
       where e->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S1b'), pg_temp.d('T3'))::text)
    and (pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M')))->'summary'->>'status') = 'PAID', r::text);
  perform pg_temp.expect('C09c mês quitado => NOTHING_DUE', 'rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('M'), 1000), 'RGP01', 'NOTHING_DUE');

  -- estorno/anulação continuam individuais (03A), só gestor
  perform pg_temp.expect('C10a RECEPTIONIST não estorna lançamento do batch', 'rec',
    format('select public.rg_payment_refund(%L::uuid, %L::uuid, ''PIX'', 1000, %L::timestamptz, null)', gen_random_uuid(),
      (pg_temp.v('C06')->'items'->0->>'payment_id')::uuid, v_at), '42501');
  perform pg_temp.do_('mgr', format('select public.rg_payment_refund(%L::uuid, %L::uuid, ''PIX'', 3000, %L::timestamptz, null)', gen_random_uuid(),
    (pg_temp.v('C06')->'items'->0->>'payment_id')::uuid, v_at));
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M')));
  perform pg_temp.ok('C10b estorno 03A de um filho reabre o mês (R$30) sem mexer no batch',
    (d->'summary'->>'open')::bigint = 3000 and d->'summary'->>'status' = 'PARTIAL'
    and (select count(*) from public.reservation_payment_batch_items i where i.batch_id = v_bid) = 3, d->>'summary');
  perform pg_temp.do_('mgr', format('select public.rg_payment_void(%L::uuid, ''lançado errado'')', (pg_temp.v('C06')->'items'->1->>'payment_id')::uuid));
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S1'), pg_temp.d('M')));
  perform pg_temp.ok('C10c anulação 03A de um filho reabre o valor anulado', (d->'summary'->>'open')::bigint = 13000, d->>'summary');

  -- NO_SHOW cobrável, cancelada ignorada (S5); a exceção movida é paga dentro de M
  r := pg_temp.do_('owner', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S5'), pg_temp.d('M'), (((pg_temp.v('nS5'))::int - 1) * 6000)));
  perform pg_temp.ok('C11 NO_SHOW recebe, CANCELADA nunca recebe; exceção movida incluída',
    jsonb_array_length(r->'items') = (pg_temp.v('nS5'))::int - 1
    and exists (select 1 from jsonb_array_elements(r->'items') e where e->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S5'), pg_temp.d('S5d1'))::text)
    and not exists (select 1 from jsonb_array_elements(r->'items') e where e->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S5'), pg_temp.d('S5d2'))::text)
    and exists (select 1 from jsonb_array_elements(r->'items') e where e->>'reservation_id' = pg_temp.occ_id(pg_temp.k('S5'), pg_temp.d('Mlast'))::text)
    and (r->>'open_after')::bigint = 0, r::text);

  -- mês passado (atrasado) também pode ser recebido; competência separada
  r := pg_temp.do_('rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S1'), pg_temp.d('P'), 10000));
  perform pg_temp.ok('C12 recebe mês passado sem tocar M', jsonb_array_length(r->'items') = 1
    and (select r3.occurrence_date from public.reservations r3 where r3.id = (r->'items'->0->>'reservation_id')::uuid) between pg_temp.d('P') and pg_temp.d('Plast'),
    r::text);

  -- imutabilidade e integridade das tabelas novas
  perform pg_temp.expect('C13a batch imutável (UPDATE)', 'postgres',
    format('update public.reservation_payment_batches set amount = 1 where id = %L returning to_jsonb(id)', v_bid), 'RGT02');
  perform pg_temp.expect('C13b item imutável (UPDATE)', 'postgres',
    format('update public.reservation_payment_batch_items set amount = 1 where batch_id = %L and position = 1 returning to_jsonb(1)', v_bid), 'RGT02');
  update public.organizations set is_demo = false where id = pg_temp.k('org');
  perform pg_temp.expect('C13c DELETE de item/batch em organização real => 42501', 'postgres',
    format('delete from public.reservation_payment_batch_items where batch_id = %L returning to_jsonb(1)', v_bid), '42501');
  update public.organizations set is_demo = true where id = pg_temp.k('org');
  perform pg_temp.expect('C13d batch com linhagem não-raiz => RGT01', 'postgres',
    format('insert into public.reservation_payment_batches (organization_id, lineage_id, month, amount, method, received_at, operation_id, operation_fingerprint) values (%L, %L, %L, 1, ''PIX'', now(), gen_random_uuid(), decode(repeat(''00'', 32), ''hex'')) returning to_jsonb(id)',
      pg_temp.k('org'), pg_temp.k('S1b'), pg_temp.d('M')), 'RGT01');
  perform pg_temp.expect('C13e item apontando para pagamento de outra reserva => 23514', 'postgres',
    format('insert into public.reservation_payment_batch_items (batch_id, organization_id, position, payment_id, reservation_id, amount) values (%L, %L, 9, %L, %L, 10000) returning to_jsonb(1)',
      v_bid, pg_temp.k('org'), (pg_temp.v('C06')->'items'->0->>'payment_id')::uuid, pg_temp.occ_id(pg_temp.k('S4'), pg_temp.d('Mlast'))), '23514');
end $$;

-- ============================================================================= D) W1 — vincular cliente
do $$
declare r jsonb; d jsonb;
begin
  perform pg_temp.expect('D01 cliente de outra organização => P0002', 'owner', pg_temp.q_link(pg_temp.k('S2'), pg_temp.k('cuX')), 'P0002');
  perform pg_temp.expect('D02 sem cliente informado => 22023', 'owner', pg_temp.q_link(pg_temp.k('S2'), null), '22023');
  perform pg_temp.expect('D03 UPDATE direto NULL->cliente sem o marcador => RGT02', 'postgres',
    format('update public.recurring_reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cu6'), pg_temp.k('S2')), 'RGT02');
  perform set_config('rg.link_customer_series', pg_temp.k('S1')::text, true);
  perform pg_temp.expect('D03b marcador de OUTRA série não libera NULL->cliente', 'postgres',
    format('update public.recurring_reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cu6'), pg_temp.k('S2')), 'RGT02');
  perform pg_temp.expect('D04 marcador não permite trocar cliente já definido (X->Y)', 'postgres',
    format('update public.recurring_reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cu6'), pg_temp.k('S1')), 'RGT02');
  perform set_config('rg.link_customer_series', '', true);
  perform pg_temp.expect('D05 quadra/arena/organização da série continuam imutáveis', 'postgres',
    format('update public.recurring_reservations set court_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('c2'), pg_temp.k('S1b')), 'RGT02');

  -- linhagem S9 (2 séries, sem cliente) por dados do cliente (reaproveita pelo telefone)
  r := pg_temp.do_('mgr', pg_temp.q_link(pg_temp.k('S9b'), null, '{"name":"Diego outro nome","phone":"(11) 99000-0006"}'));
  perform pg_temp.ok('D06a W1 vincula a linhagem inteira (raiz + filha) e reaproveita o cliente pelo telefone',
    (r->>'changed')::boolean and r->>'customer_id' = pg_temp.k('cu6')::text and r->>'lineage_id' = pg_temp.k('S9')::text
    and (select count(*) from public.recurring_reservations s where s.id in (pg_temp.k('S9'), pg_temp.k('S9b')) and s.customer_id = pg_temp.k('cu6')) = 2,
    r::text);
  perform pg_temp.ok('D06b ocorrências sem cliente da linhagem recebem o cliente (todas, inclusive canceladas)',
    not exists (select 1 from public.reservations x where x.recurring_reservation_id in (pg_temp.k('S9'), pg_temp.k('S9b')) and x.customer_id is distinct from pg_temp.k('cu6'))
    and (r->>'occurrences')::int = (select count(*) from public.reservations x where x.recurring_reservation_id in (pg_temp.k('S9'), pg_temp.k('S9b'))),
    r::text);
  perform pg_temp.ok('D06c auditoria RECURRING_CUSTOMER_LINKED', exists (select 1 from public.audit_logs a where a.action = 'RECURRING_CUSTOMER_LINKED'
    and a.entity_id = pg_temp.k('S9') and a.metadata->>'customer_id' = pg_temp.k('cu6')::text), 'sem auditoria');
  perform pg_temp.ok('D06d marcador limpo depois da RPC', coalesce(current_setting('rg.link_customer_series', true), '') = '', 'marcador ficou');
  r := pg_temp.do_('owner', pg_temp.q_link(pg_temp.k('S9'), pg_temp.k('cu6')));
  perform pg_temp.ok('D07 repetir com o mesmo cliente => changed=false', not (r->>'changed')::boolean, r::text);
  perform pg_temp.expect('D08 trocar por outro cliente => RGR01 CUSTOMER_ALREADY_SET', 'owner', pg_temp.q_link(pg_temp.k('S9'), pg_temp.k('cu5')), 'RGR01', 'CUSTOMER_ALREADY_SET');
  perform pg_temp.expect('D09 linhagem com cliente => recusa', 'owner', pg_temp.q_link(pg_temp.k('S1'), pg_temp.k('cu6')), 'RGR01', 'CUSTOMER_ALREADY_SET');

  r := pg_temp.do_('owner', pg_temp.q_link(pg_temp.k('S2'), pg_temp.k('cu6')));
  d := pg_temp.do_('owner', pg_temp.q_det(pg_temp.k('S2'), pg_temp.d('M')));
  perform pg_temp.ok('D10 depois do vínculo o mês fica elegível', (d->>'eligible')::boolean and d->'customer'->>'id' = pg_temp.k('cu6')::text, d->>'blocked_reason');
  r := pg_temp.do_('rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S2'), pg_temp.d('M'), 5000));
  perform pg_temp.ok('D11 RECEPÇÃO recebe o mês após o vínculo', jsonb_array_length(r->'items') = 1, r::text);
  -- série nova criada depois do vínculo materializa com o cliente (D7 inalterado)
  perform pg_temp.occ(pg_temp.k('S2'), pg_temp.d('M2') + ((4 - extract(dow from pg_temp.d('M2'))::int + 7) % 7));
  perform pg_temp.ok('D12 ocorrência nova nasce com o cliente vinculado (contrato D7)', exists (select 1 from public.reservations x
    where x.recurring_reservation_id = pg_temp.k('S2') and x.occurrence_date >= pg_temp.d('M2') and x.customer_id = pg_temp.k('cu6')), 'D7');
end $$;

-- ============================================================================= E) W2 — aplicar valor da série
do $$
declare r jsonb; d jsonb; v_manual uuid; v_canc uuid; v_mondays date[] := pg_temp.days(pg_temp.d('M'), pg_temp.d('Mlast'), 1); v_before text;
begin
  v_before := pg_temp.snap();
  r := pg_temp.do_('owner', pg_temp.q_apply(pg_temp.k('S3'), pg_temp.d('M')));
  perform pg_temp.ok('E01 série sem default_price => nada aplicado, nada gravado', (r->>'updated')::int = 0
    and (r->>'remaining_unpriced')::int = cardinality(v_mondays) and pg_temp.snap() = v_before, r::text);
  perform pg_temp.do_('owner', format('select public.rg_recurring_update(%L::uuid, ''{"default_price":7000}''::jsonb)', pg_temp.k('S3')));
  -- um jogo com valor manual (03A) e um cancelado sem valor: nenhum dos dois pode ser tocado
  v_manual := pg_temp.occ_id(pg_temp.k('S3'), v_mondays[1]);
  perform pg_temp.do_('owner', format('select public.rg_reservation_set_price(%L::uuid, ''MANUAL'', 4500, ''DISCOUNT'')', v_manual));
  v_canc := pg_temp.occ_id(pg_temp.k('S3'), v_mondays[2]);
  update public.reservations set status = 'CANCELLED' where id = v_canc;
  r := pg_temp.do_('mgr', pg_temp.q_apply(pg_temp.k('S3'), pg_temp.d('M')));
  perform pg_temp.ok('E02a aplica só nas cobráveis com price NULL do mês', (r->>'updated')::int = cardinality(v_mondays) - 2
    and (r->>'remaining_unpriced')::int = 0, r::text);
  perform pg_temp.ok('E02b nunca sobrescreve valor existente; cancelada intocada; snapshot SERIES',
    (select price from public.reservations where id = v_manual) = 4500
    and (select price_source from public.reservations where id = v_manual) = 'MANUAL'
    and (select price from public.reservations where id = v_canc) is null
    and not exists (select 1 from public.reservations x where x.recurring_reservation_id = pg_temp.k('S3')
                     and x.occurrence_date between pg_temp.d('M') and pg_temp.d('Mlast') and x.status <> 'CANCELLED'
                     and x.id <> v_manual and (x.price is distinct from 7000 or x.price_source is distinct from 'SERIES')), 'valores divergentes');
  perform pg_temp.ok('E02c outro mês continua sem valor (escopo = competência)',
    (select count(*) from public.reservations x where x.recurring_reservation_id = pg_temp.k('S3')
      and x.occurrence_date between pg_temp.d('P') and pg_temp.d('Plast') and x.price is null)
    = cardinality(pg_temp.days(pg_temp.d('P'), pg_temp.d('Plast'), 1)), 'P alterado');
  perform pg_temp.ok('E02d auditoria por ocorrência (RESERVATION_PRICE_SERIES_APPLIED)',
    (select count(*) from public.audit_logs a where a.action = 'RESERVATION_PRICE_SERIES_APPLIED' and a.metadata->>'lineage_id' = pg_temp.k('S3')::text
      and (a.metadata->>'new_price')::int = 7000) = cardinality(v_mondays) - 2, 'auditoria');
  v_before := pg_temp.snap();
  r := pg_temp.do_('owner', pg_temp.q_apply(pg_temp.k('S3'), pg_temp.d('M')));
  perform pg_temp.ok('E03 segunda aplicação => idempotente (0 alterações, nada gravado)', (r->>'updated')::int = 0 and pg_temp.snap() = v_before, r::text);
  d := pg_temp.do_('rec', pg_temp.q_det(pg_temp.k('S3'), pg_temp.d('M')));
  perform pg_temp.ok('E04 mês deixa de ser UNPRICED e fica elegível', d->'summary'->>'status' in ('OPEN', 'OVERDUE') and (d->>'eligible')::boolean
    and not (d->>'can_apply_series_price')::boolean, d->>'summary');
  r := pg_temp.do_('rec', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('S3'), pg_temp.d('M'), 4500));
  perform pg_temp.ok('E05 recebimento usa o valor manual primeiro (mais antigo)', jsonb_array_length(r->'items') = 1
    and r->'items'->0->>'reservation_id' = v_manual::text, r::text);
end $$;

-- ============================================================================= G) privilégios
do $$
begin
  perform pg_temp.ok('G01 tabelas novas com RLS e sem políticas',
    (select bool_and(c.relrowsecurity) from pg_class c where c.oid in ('public.reservation_payment_batches'::regclass, 'public.reservation_payment_batch_items'::regclass))
    and not exists (select 1 from pg_policies p where p.tablename in ('reservation_payment_batches', 'reservation_payment_batch_items')), 'RLS');
  perform pg_temp.ok('G02 authenticated/anon sem privilégio nas tabelas novas; service_role só SELECT/DELETE',
    not exists (select 1 from information_schema.role_table_grants g where g.table_name in ('reservation_payment_batches', 'reservation_payment_batch_items')
                 and (g.grantee in ('authenticated', 'anon', 'public') or (g.grantee = 'service_role' and g.privilege_type not in ('SELECT', 'DELETE')))),
    'grants');
  perform pg_temp.ok('G03 RPCs: EXECUTE só para authenticated (6)',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail',
        'rg_recurring_month_payment_record', 'rg_recurring_link_customer', 'rg_recurring_month_apply_series_price')
        and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
        and not has_function_privilege('service_role', p.oid, 'execute') and p.prosecdef
        and 'search_path=""' = any(p.proconfig)) = 6, 'execute');
  perform pg_temp.ok('G04 helpers privados sem EXECUTE para papéis da API',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'private' and (p.proname like 'rg_rm_%' or p.proname in ('enforce_payment_batch_integrity',
                   'enforce_payment_batch_item_integrity', 'protect_payment_batch_record'))
                   and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')
                        or has_function_privilege('service_role', p.oid, 'execute'))), 'private');
  perform pg_temp.ok('G05 leituras são STABLE (não podem escrever)',
    (select count(*) from pg_proc where oid in ('public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb)'::regprocedure,
      'public.rg_recurring_month_search(uuid, date, text, integer)'::regprocedure, 'public.rg_recurring_month_detail(uuid, date)'::regprocedure)
      and provolatile = 's') = 3, 'volatilidade');
end $$;

-- ============================================================================= H) regressão de contratos existentes
do $$
declare v record;
begin
  select * into v from pg_temp.call('rec', format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', 1000, now(), null)',
    gen_random_uuid(), pg_temp.occ_id(pg_temp.k('S4'), pg_temp.d('Mlast'))));
  perform pg_temp.ok('H01 recebimento individual 03A em ocorrência recorrente continua (RECEPTIONIST)', v.state = 'OK', v.state || v.result::text);
  perform pg_temp.expect('H02 reagendar continua exigindo gestor (B3)', 'rec',
    format('select public.rg_recurring_reschedule(%L::uuid, %L::uuid, %L::date, ''{"start_time":"21:00","end_time":"22:00"}''::jsonb, false, ''{}''::date[])',
      pg_temp.k('S4'), gen_random_uuid(), pg_temp.d('M2')), '42501');
  perform pg_temp.expect('H03 recebimento individual acima do saldo continua RGP03 (03A)', 'rec',
    format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', 99999, now(), null)', gen_random_uuid(),
      pg_temp.occ_id(pg_temp.k('S4'), pg_temp.d('Mlast'))), 'RGP03', 'OVER_BALANCE');
  perform pg_temp.expect('H04 reserva: organização imutável (A2; tenant dispara antes => RGT01)', 'postgres',
    format('update public.reservations set organization_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('org2'),
      pg_temp.occ_id(pg_temp.k('S4'), pg_temp.d('Mlast'))), 'RGT01');
  perform pg_temp.ok('H05 operation_id 03A segue único por organização (índice intacto)',
    (select indexdef from pg_indexes where indexname = 'idx_payments_org_operation') like '%UNIQUE INDEX%(organization_id, operation_id)%', 'índice');
end $$;

-- ----------------------------------------------------------------------------- resultado
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from rr;
  if v_fail > 0 then
    select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from rr;
    raise exception E'P3B3_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.\n%',
      v_total - v_fail, v_fail, v_total, v_txt;
  end if;
end $$;

select format('P3B3_RESULTS OK — %s PASS / 0 FAIL (total %s)', count(*), count(*))
       || E'\n' || string_agg('PASS ' || name, E'\n' order by seq) as p3b3_results
  from rr;

rollback;
