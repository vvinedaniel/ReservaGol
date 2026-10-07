-- =============================================================================
-- RESERVA GOL — FASE 03A — testes SQL de ROLLBACK dos FIX1 e FIX2 (revisão final do PR #12)
-- Requer FOUNDATION + GUARDS + migration_phase3a_fix1_void_reason_visibility.sql +
-- migration_phase3a_fix2_price_origin.sql aplicadas (B3 FOUNDATION + LOCKDOWN também).
--
-- Como rodar: como postgres, o arquivo INTEIRO num único envio (session_user = postgres ativa
-- private.rg_fault). ZERO RESÍDUO POR CONSTRUÇÃO: uma única transação; o script SEMPRE termina com
-- o erro proposital "P3A_FIX_RESULTS ..." => ROLLBACK total.
--
-- Blocos:
--   V  FIX1: void_reason/voided_by só para OWNER/MANAGER/platform admin; RECEPTIONIST vê voided_at;
--      outro tenant P0002; restante do detalhe idêntico; propriedades da função
--   I  FIX2: origem no INSERT (RULE / NULL / MANUAL / SERIES), cliente nunca define price_source
--   R  FIX2: recálculo ao editar (horário, duração, data, quadra, faixa sem regra, sem valor -> RULE,
--      MANUAL/legado/SERIES preservados, lançamento ativo preserva, anulados não impedem,
--      cross-midnight, status, audit RESERVATION_PRICE_REPRICED)
--   S  FIX2: segurança e ordem dos BEFORE UPDATE (guards antes do recálculo; price/PAID/price_source)
--   P  FIX2: rg_reservation_set_price grava a origem
--   F  falha injetada => UPDATE + recálculo + audit desfeitos juntos
-- =============================================================================
begin;
set local statement_timeout = '180s';
set local lock_timeout = '5s';

create temp table p3fx (k text primary key, id uuid not null) on commit drop;
create temp table p3d (k text primary key, d date not null) on commit drop;
create temp table p3r (seq serial, name text, ok boolean, detail text) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3a fix: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('private.enforce_reservation_price_reprice()') is null
     or to_regprocedure('private.enforce_reservation_price_origin_guard()') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'reservations' and column_name = 'price_source') then
    raise exception 'p3a fix: FIX2 não aplicado';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'enforce_reservation_zz_price_guard') then raise exception 'p3a fix: GUARDS ausentes'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.p3_id(p text) returns uuid language sql stable as $$ select id from p3fx where k = p $$;
create function pg_temp.p3_day(p text) returns date language sql stable as $$ select d from p3d where k = p $$;
create function pg_temp.p3_ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into p3r (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- Instante local (America/Sao_Paulo): sexta de fixture + p_week semanas + p_plus_days dias.
create function pg_temp.fx_ts(p_week integer, p_hhmm text, p_plus_days integer default 0) returns timestamptz language sql stable as $$
  select ((pg_temp.p3_day('fri') + 7 * p_week + p_plus_days)::text || ' ' || p_hhmm || ':00-03:00')::timestamptz $$;

create function pg_temp.p3_snapshot() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'rs:' || row_to_json(r)::text as x from public.reservations r where r.organization_id = pg_temp.p3_id('org')
    union all select 'rp:' || row_to_json(r)::text from public.reservation_payments r where r.organization_id = pg_temp.p3_id('org')
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r where r.organization_id = pg_temp.p3_id('org')
  ) s), '')) $$;

create function pg_temp.p3_call(p_actor text, p_fault text, p_sql text, out state text, out result jsonb)
language plpgsql as $$
declare v_claims text; v_hint text;
begin
  v_claims := case
    when p_actor in ('anon', 'service_role') then json_build_object('role', p_actor)::text
    when p_actor = 'postgres' then ''
    else json_build_object('sub', pg_temp.p3_id(p_actor), 'role', 'authenticated')::text end;
  perform set_config('rg.fault_at', coalesce(p_fault, ''), true);
  perform set_config('request.jwt.claims', v_claims, true);
  begin
    if p_actor in ('anon', 'service_role') then execute format('set local role %I', p_actor);
    elsif p_actor <> 'postgres' then execute 'set local role authenticated';
    end if;
  exception when others then
    state := 'P3ROL:' || sqlstate;
    result := jsonb_build_object('msg', sqlerrm);
  end;
  if state is null then
    begin
      execute p_sql into result;
      state := 'OK';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      state := sqlstate;
      result := jsonb_build_object('msg', sqlerrm, 'hint', nullif(v_hint, ''));
    end;
  end if;
  execute 'reset role';
  perform set_config('rg.fault_at', '', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function pg_temp.p3_fault_case(p_name text, p_actor text, p_fault text, p_sql text) returns void
language plpgsql as $$
declare v_before text; v_after text; v_c record; v_f record; v_changed boolean;
begin
  v_before := pg_temp.p3_snapshot();
  select * into v_f from pg_temp.p3_call(p_actor, p_fault, p_sql);
  v_after := pg_temp.p3_snapshot();
  begin
    select * into v_c from pg_temp.p3_call(p_actor, null, p_sql);
    v_changed := pg_temp.p3_snapshot() <> v_before;
    raise exception using errcode = 'P3CTL';
  exception when sqlstate 'P3CTL' then null;
  end;
  perform pg_temp.p3_ok(p_name, v_f.state = 'RGF01' and v_before = v_after and v_c.state = 'OK' and v_changed,
    format('fault=%s estado_igual=%s controle=%s alterou=%s', v_f.state, v_before = v_after, v_c.state, v_changed));
end $$;

create function pg_temp.p3_expect(p_name text, p_actor text, p_sql text, p_state text, p_hint text default null) returns jsonb
language plpgsql as $$
declare v_before text; v_r record;
begin
  v_before := pg_temp.p3_snapshot();
  select * into v_r from pg_temp.p3_call(p_actor, null, p_sql);
  perform pg_temp.p3_ok(p_name,
    v_r.state = p_state and (p_state = 'OK' or pg_temp.p3_snapshot() = v_before)
      and (p_hint is null or v_r.result->>'hint' = p_hint),
    format('esperado=%s%s veio=%s %s', p_state, coalesce('/' || p_hint, ''), v_r.state, coalesce(v_r.result->>'hint', '')));
  return v_r.result;
end $$;

create function pg_temp.p3_do(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.p3_call(p_actor, null, p_sql);
  if v.state <> 'OK' then raise exception 'p3a fix setup (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

create function pg_temp.fx_rule(p_court text, p_wd integer, p_s text, p_e text, p_price integer) returns void language plpgsql as $$
begin
  perform pg_temp.p3_do('owner', format('select public.rg_pricing_rule_create(%L::uuid, %L::uuid, %L::smallint[], %L::time, %L::time, %s, null, null)',
    pg_temp.p3_id('arena'), case when p_court is null then null else pg_temp.p3_id(p_court) end, array[p_wd], p_s, p_e, p_price));
end $$;
-- Reserva comum criada pela RECEPÇÃO (sem price: o banco decide valor e origem).
create function pg_temp.fx_new(p_court text, p_start timestamptz, p_end timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.p3_do('rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, created_by) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', %L) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id(p_court), p_start, p_end, pg_temp.p3_id('rec')));
  return (r->>'id')::uuid;
end $$;
create function pg_temp.fx_move_sql(p_res uuid, p_court text, p_start timestamptz, p_end timestamptz) returns text language sql stable as $$
  select format('update public.reservations set court_id = %L::uuid, start_at = %L::timestamptz, end_at = %L::timestamptz where id = %L::uuid returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id(p_court), p_start, p_end, p_res) $$;
create function pg_temp.fx_row(p_res uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('price', price, 'price_source', price_source) from public.reservations where id = p_res $$;
create function pg_temp.fx_repriced(p_res uuid) returns integer language sql stable as $$
  select count(*)::integer from public.audit_logs where entity_id = p_res and action = 'RESERVATION_PRICE_REPRICED' $$;
create function pg_temp.fx_is(p jsonb, p_price integer, p_source text) returns boolean language sql immutable as $$
  select (p->'price') = coalesce(to_jsonb(p_price), 'null'::jsonb) and (p->'price_source') = coalesce(to_jsonb(p_source), 'null'::jsonb) $$;
create function pg_temp.fx_pay_sql(p_res uuid, p_amount integer) returns text language sql stable as $$
  select format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', %s, %L::timestamptz, null)', gen_random_uuid(), p_res, p_amount, now() - interval '1 hour') $$;
create function pg_temp.fx_price_sql(p_res uuid, p_mode text, p_price integer, p_reason text) returns text language sql stable as $$
  select format('select public.rg_reservation_set_price(%L::uuid, %L, %L::integer, %L)', p_res, p_mode, p_price, p_reason) $$;

-- ----------------------------------------------------------------------------- fixtures (desfeitas no fim)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_out uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_arena uuid; v_arena2 uuid; v_c1 uuid; v_c2 uuid; v_cout uuid;
  v_tag text := 'p3fx-' || substr(md5(clock_timestamp()::text), 1, 8);
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'), (u_rec, v_tag || '-rec@reservagol.test'),
    (u_out, v_tag || '-out@reservagol.test'), (u_adm, v_tag || '-adm@reservagol.test');
  insert into public.profiles (id) values (u_adm) on conflict (id) do nothing;
  update public.profiles set is_platform_admin = true where id = u_adm;
  insert into public.organizations (name, is_demo) values ('P3A FX ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3A FX outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'), (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'Arena ' || v_tag) returning id into v_arena;
  insert into public.arenas (organization_id, name) values (v_org2, 'Arena outra ' || v_tag) returning id into v_arena2;
  -- 03C (setup apenas): horário de funcionamento explícito que cobre todos os horários materializados
  -- por esta suíte (08:00–19:00); 06:00–23:00 todos os dias. Nenhuma assertion alterada.
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select a.organization_id, a.id, w, '06:00', '23:00', false from public.arenas a cross join generate_series(0, 6) w
   where a.id in (v_arena, v_arena2);
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_arena2, 'Q outra') returning id into v_cout;
  insert into p3fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('adm', u_adm), ('org', v_org), ('org2', v_org2),
    ('arena', v_arena), ('arena2', v_arena2), ('c1', v_c1), ('c2', v_c2), ('c_out', v_cout);
  insert into p3d values ('today', v_today), ('fri', (v_today + 7) + ((5 - extract(dow from v_today + 7)::int + 7) % 7));
end $$;

-- Tabela: arena sexta 08–18 = 10000/h, sexta 18–24 = 17000/h, sábado 00–02 = 20000/h, sábado 08–12 = 5000/h;
-- quadra Q2 sexta 18–20 = 30000/h (vence a arena).
do $$ begin
  perform pg_temp.fx_rule(null, 5, '08:00', '18:00', 10000);
  perform pg_temp.fx_rule(null, 5, '18:00', '00:00', 17000);
  perform pg_temp.fx_rule(null, 6, '00:00', '02:00', 20000);
  perform pg_temp.fx_rule(null, 6, '08:00', '12:00', 5000);
  perform pg_temp.fx_rule('c2', 5, '18:00', '20:00', 30000);
end $$;

-- ----------------------------------------------------------------------------- V: FIX1
do $$
declare v_res uuid; v_pay uuid; r jsonb; r_rec jsonb; r_own jsonb; e jsonb;
  strip constant text[] := array['voided_by', 'void_reason'];
begin
  v_res := pg_temp.fx_new('c1', pg_temp.fx_ts(0, '10:00'), pg_temp.fx_ts(0, '11:00'));
  r := pg_temp.p3_do('rec', pg_temp.fx_pay_sql(v_res, 5000));
  v_pay := (r->>'payment_id')::uuid;
  perform pg_temp.p3_do('mgr', format('select public.rg_payment_void(%L::uuid, %L)', v_pay, 'motivo interno do teste'));
  perform pg_temp.p3_do('rec', pg_temp.fx_pay_sql(v_res, 3000));   -- segundo lançamento, ativo
  r_own := pg_temp.p3_expect('V01 OWNER lê o detalhe', 'owner', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), 'OK');
  e := (select x from jsonb_array_elements(r_own->'entries') x where x->>'id' = v_pay::text);
  perform pg_temp.p3_ok('V01b OWNER recebe void_reason e voided_by', e->>'void_reason' = 'motivo interno do teste' and e->>'voided_by' = pg_temp.p3_id('mgr')::text, e::text);
  r := pg_temp.p3_expect('V02 MANAGER lê o detalhe', 'mgr', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), 'OK');
  e := (select x from jsonb_array_elements(r->'entries') x where x->>'id' = v_pay::text);
  perform pg_temp.p3_ok('V02b MANAGER recebe void_reason e voided_by', e->>'void_reason' = 'motivo interno do teste' and e->>'voided_by' = pg_temp.p3_id('mgr')::text, e::text);
  r_rec := pg_temp.p3_expect('V03 RECEPTIONIST lê o detalhe', 'rec', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), 'OK');
  e := (select x from jsonb_array_elements(r_rec->'entries') x where x->>'id' = v_pay::text);
  perform pg_temp.p3_ok('V03b RECEPTIONIST recebe voided_at, SEM void_reason e SEM voided_by',
    e->>'voided_at' is not null and not (e ? 'void_reason') and not (e ? 'voided_by')
    and not exists (select 1 from jsonb_array_elements(r_rec->'entries') x where x ? 'void_reason' or x ? 'voided_by'), e::text);
  perform pg_temp.p3_ok('V04 restante do detalhe idêntico entre RECEPTIONIST e OWNER',
    (r_rec - 'entries') = (r_own - 'entries')
    and (select jsonb_agg(x - strip order by x->>'id') from jsonb_array_elements(r_rec->'entries') x)
      = (select jsonb_agg(x - strip order by x->>'id') from jsonb_array_elements(r_own->'entries') x)
    and jsonb_array_length(r_rec->'entries') = 2, 'diff');
  perform pg_temp.p3_expect('V05 outro tenant => P0002', 'out', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), 'P0002');
  r := pg_temp.p3_expect('V06 platform admin lê o detalhe', 'adm', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), 'OK');
  e := (select x from jsonb_array_elements(r->'entries') x where x->>'id' = v_pay::text);
  perform pg_temp.p3_ok('V06b platform admin recebe void_reason e voided_by (equivalente a OWNER)', e ? 'void_reason' and e ? 'voided_by', coalesce(e::text, 'null'));
  perform pg_temp.p3_expect('V07 anon sem EXECUTE', 'anon', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), '42501');
  perform pg_temp.p3_expect('V08 service_role sem EXECUTE', 'service_role', format('select public.rg_reservation_financial_detail(%L::uuid)', v_res), '42501');
  perform pg_temp.p3_ok('V09 detalhe: SECURITY DEFINER, owner postgres, search_path vazio, EXECUTE só authenticated',
    (select prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""']
       from pg_proc where oid = 'public.rg_reservation_financial_detail(uuid)'::regprocedure)
    and has_function_privilege('authenticated', 'public.rg_reservation_financial_detail(uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.rg_reservation_financial_detail(uuid)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.rg_reservation_financial_detail(uuid)', 'EXECUTE'), 'acl');
end $$;

-- ----------------------------------------------------------------------------- I: origem no INSERT
do $$
declare v_id uuid; r jsonb; v_series uuid;
begin
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(1, '10:00'), pg_temp.fx_ts(1, '11:00'));
  perform pg_temp.p3_ok('I01 recepção cria em faixa com regra => 10000 / RULE', pg_temp.fx_is(pg_temp.fx_row(v_id), 10000, 'RULE'), pg_temp.fx_row(v_id)::text);
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(1, '06:00'), pg_temp.fx_ts(1, '07:00'));
  perform pg_temp.p3_ok('I02 faixa sem regra => sem valor / origem NULL', pg_temp.fx_is(pg_temp.fx_row(v_id), null, null), pg_temp.fx_row(v_id)::text);
  r := pg_temp.p3_expect('I03 reserva pública (service_role, sem price)', 'service_role', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, public_code) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''PUBLIC_WEB'', %L) returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.fx_ts(1, '12:00'), pg_temp.fx_ts(1, '13:00'), 'RG-P3FX' || substr(md5(random()::text), 1, 8)), 'OK');
  perform pg_temp.p3_ok('I03b pública => 10000 / RULE', pg_temp.fx_is(r, 10000, 'RULE'), r::text);
  r := pg_temp.p3_expect('I04 caminho interno com valor explícito (service_role)', 'service_role', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', 4321) returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.fx_ts(1, '13:00'), pg_temp.fx_ts(1, '14:00')), 'OK');
  perform pg_temp.p3_ok('I04b valor explícito => MANUAL', pg_temp.fx_is(r, 4321, 'MANUAL'), r::text);
  r := pg_temp.p3_expect('I05 cliente tenta definir price_source no INSERT (sem price)', 'rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price_source, created_by) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', ''MANUAL'', %L) returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.fx_ts(1, '14:00'), pg_temp.fx_ts(1, '15:00'), pg_temp.p3_id('rec')), 'OK');
  perform pg_temp.p3_ok('I05b origem enviada pelo cliente é ignorada => 10000 / RULE', pg_temp.fx_is(r, 10000, 'RULE'), r::text);
  perform pg_temp.p3_expect('I06 cliente com price no INSERT continua 42501 (GUARDS)', 'rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price, created_by) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', 1, %L) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.fx_ts(1, '15:00'), pg_temp.fx_ts(1, '16:00'), pg_temp.p3_id('rec')), '42501');
  r := pg_temp.p3_expect('I07 bloqueio', 'rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, created_by) values (%L, %L, %L, %L, %L, ''BLOCKED'', ''INTERNAL'', %L) returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.fx_ts(1, '16:00'), pg_temp.fx_ts(1, '17:00'), pg_temp.p3_id('rec')), 'OK');
  perform pg_temp.p3_ok('I07b bloqueio => sem valor / origem NULL', pg_temp.fx_is(r, null, null), r::text);
  -- recorrente: série com default_price => SERIES; sem default_price => NULL
  r := pg_temp.p3_do('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', 5, null, ''08:00''::time, ''09:00''::time, %L::date, null, true, 12345, null, true, false, %L::date[])',
    gen_random_uuid(), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), '{"name":"Mensalista FX"}', pg_temp.p3_day('today'), array[pg_temp.p3_day('fri') + 7 * 11]));
  v_series := (r->>'series_id')::uuid;
  insert into p3fx values ('s_price', v_series);
  select id into v_id from public.reservations where recurring_reservation_id = v_series;
  insert into p3fx values ('occ', v_id);
  perform pg_temp.p3_ok('I08 ocorrência de série com default_price => 12345 / SERIES', pg_temp.fx_is(pg_temp.fx_row(v_id), 12345, 'SERIES'), pg_temp.fx_row(v_id)::text);
  r := pg_temp.p3_do('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', 5, null, ''09:00''::time, ''10:00''::time, %L::date, null, true, null, null, true, false, %L::date[])',
    gen_random_uuid(), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), '{"name":"Mensalista FX 2"}', pg_temp.p3_day('today'), array[pg_temp.p3_day('fri') + 7 * 11]));
  select id into v_id from public.reservations where recurring_reservation_id = (r->>'series_id')::uuid;
  perform pg_temp.p3_ok('I09 ocorrência de série sem default_price => sem valor / NULL', pg_temp.fx_is(pg_temp.fx_row(v_id), null, null), pg_temp.fx_row(v_id)::text);
end $$;

-- ----------------------------------------------------------------------------- R: recálculo ao editar
do $$
declare v_id uuid; r jsonb; a jsonb; v_pay uuid;
begin
  -- R01..R06: a MESMA reserva percorre horário, duração, data, quadra, faixa sem regra e volta a ter regra
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(2, '10:00'), pg_temp.fx_ts(2, '11:00'));
  r := pg_temp.p3_expect('R01 horário: sexta 10–11 -> 19–20 (recepção)', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '19:00'), pg_temp.fx_ts(2, '20:00')), 'OK');
  perform pg_temp.p3_ok('R01b faixa com outro preço => 17000 / RULE', pg_temp.fx_is(r, 17000, 'RULE'), r::text);
  a := (select metadata from public.audit_logs where entity_id = v_id and action = 'RESERVATION_PRICE_REPRICED');   -- único até aqui
  perform pg_temp.p3_ok('R01c audit RESERVATION_PRICE_REPRICED (preços/origens/campos, sem PII)',
    pg_temp.fx_repriced(v_id) = 1 and (a->>'old_price')::int = 10000 and (a->>'new_price')::int = 17000
    and a->>'old_source' = 'RULE' and a->>'new_source' = 'RULE' and a->'changed' = '["start_at", "end_at"]'::jsonb
    and (select count(*) from jsonb_object_keys(a)) = 5
    and exists (select 1 from public.audit_logs where entity_id = v_id and action = 'RESERVATION_PRICE_REPRICED' and user_id = pg_temp.p3_id('rec')), coalesce(a::text, 'null'));
  r := pg_temp.p3_expect('R02 duração: 19–20 -> 19–21', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '19:00'), pg_temp.fx_ts(2, '21:00')), 'OK');
  perform pg_temp.p3_ok('R02b 2h a 17000 => 34000 / RULE', pg_temp.fx_is(r, 34000, 'RULE'), r::text);
  r := pg_temp.p3_expect('R03 data: sexta 19–21 -> sábado 09–10', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '09:00', 1), pg_temp.fx_ts(2, '10:00', 1)), 'OK');
  perform pg_temp.p3_ok('R03b regra de sábado => 5000 / RULE', pg_temp.fx_is(r, 5000, 'RULE'), r::text);
  perform pg_temp.p3_do('rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '18:00'), pg_temp.fx_ts(2, '19:00')));
  perform pg_temp.p3_ok('R04a sexta 18–19 em Q1 => 17000 (arena)', pg_temp.fx_is(pg_temp.fx_row(v_id), 17000, 'RULE'), pg_temp.fx_row(v_id)::text);
  r := pg_temp.p3_expect('R04 quadra: Q1 -> Q2 no mesmo horário', 'rec', pg_temp.fx_move_sql(v_id, 'c2', pg_temp.fx_ts(2, '18:00'), pg_temp.fx_ts(2, '19:00')), 'OK');
  perform pg_temp.p3_ok('R04b regra da quadra Q2 vence => 30000 / RULE', pg_temp.fx_is(r, 30000, 'RULE'), r::text);
  r := pg_temp.p3_expect('R05 faixa sem regra: -> sexta 06–07', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '06:00'), pg_temp.fx_ts(2, '07:00')), 'OK');
  perform pg_temp.p3_ok('R05b sem regra => sem valor / origem NULL (+ audit 30000 -> NULL)', pg_temp.fx_is(r, null, null)
    and exists (select 1 from public.audit_logs where entity_id = v_id and action = 'RESERVATION_PRICE_REPRICED'
                  and (metadata->>'old_price')::int = 30000 and metadata->'new_price' = 'null'::jsonb
                  and metadata->>'old_source' = 'RULE' and metadata->'new_source' = 'null'::jsonb), r::text);
  r := pg_temp.p3_expect('R06 sem valor volta para faixa com regra: -> sexta 10–11', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '10:00'), pg_temp.fx_ts(2, '11:00')), 'OK');
  perform pg_temp.p3_ok('R06b sem valor => 10000 / RULE', pg_temp.fx_is(r, 10000, 'RULE'), r::text);
  r := pg_temp.p3_expect('R07 mesmo preço: sexta 10–11 -> 11–12', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(2, '11:00'), pg_temp.fx_ts(2, '12:00')), 'OK');
  perform pg_temp.p3_ok('R07b valor igual => sem audit novo', pg_temp.fx_is(r, 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 7, format('%s audits=%s', r, pg_temp.fx_repriced(v_id)));
  perform pg_temp.p3_do('rec', format('update public.reservations set notes = %L where id = %L::uuid returning jsonb_build_object(''id'', id)', 'só observação', v_id));
  perform pg_temp.p3_ok('R08 editar só observação não recalcula nem audita', pg_temp.fx_is(pg_temp.fx_row(v_id), 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 7, pg_temp.fx_row(v_id)::text);

  -- R09 cross-midnight
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(3, '10:00'), pg_temp.fx_ts(3, '11:00'));
  r := pg_temp.p3_expect('R09 cross-midnight: -> sexta 23:00 / sábado 01:00', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(3, '23:00'), pg_temp.fx_ts(3, '01:00', 1)), 'OK');
  perform pg_temp.p3_ok('R09b 17000*60 + 20000*60 => 37000 / RULE', pg_temp.fx_is(r, 37000, 'RULE'), r::text);

  -- R10 MANUAL nunca é sobrescrito
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(4, '10:00'), pg_temp.fx_ts(4, '11:00'));
  perform pg_temp.p3_do('mgr', pg_temp.fx_price_sql(v_id, 'MANUAL', 12345, 'DISCOUNT'));
  r := pg_temp.p3_expect('R10 MANUAL: move para 19–20', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(4, '19:00'), pg_temp.fx_ts(4, '20:00')), 'OK');
  perform pg_temp.p3_ok('R10b MANUAL preservado (12345 / MANUAL, sem audit de recálculo)', pg_temp.fx_is(r, 12345, 'MANUAL') and pg_temp.fx_repriced(v_id) = 0, r::text);

  -- R11 legado: valor com origem desconhecida (NULL) nunca é recalculado
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(5, '10:00'), pg_temp.fx_ts(5, '11:00'));
  update public.reservations set price = 999, price_source = null where id = v_id;   -- simula linha anterior ao FIX2 (como postgres)
  r := pg_temp.p3_expect('R11 legado (999, origem NULL): move para 19–20', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(5, '19:00'), pg_temp.fx_ts(5, '20:00')), 'OK');
  perform pg_temp.p3_ok('R11b legado preservado (999 / NULL)', pg_temp.fx_is(r, 999, null) and pg_temp.fx_repriced(v_id) = 0, r::text);

  -- R12 pagamento ativo preserva o snapshot
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(6, '10:00'), pg_temp.fx_ts(6, '11:00'));
  perform pg_temp.p3_do('rec', pg_temp.fx_pay_sql(v_id, 1000));
  r := pg_temp.p3_expect('R12 com pagamento ativo: move para 19–20 (alteração é salva)', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(6, '19:00'), pg_temp.fx_ts(6, '20:00')), 'OK');
  perform pg_temp.p3_ok('R12b valor preservado (10000 / RULE), horário salvo, ledger intacto',
    pg_temp.fx_is(r, 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 0
    and (select start_at = pg_temp.fx_ts(6, '19:00') from public.reservations where id = v_id)
    and (select count(*) from public.reservation_payments where reservation_id = v_id and voided_at is null) = 1, r::text);

  -- R13 pagamento + estorno ativos também preservam
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(7, '10:00'), pg_temp.fx_ts(7, '11:00'));
  r := pg_temp.p3_do('rec', pg_temp.fx_pay_sql(v_id, 1000));
  v_pay := (r->>'payment_id')::uuid;
  perform pg_temp.p3_do('mgr', format('select public.rg_payment_refund(%L::uuid, %L::uuid, ''PIX'', 1000, %L::timestamptz, null)', gen_random_uuid(), v_pay, now() - interval '30 minutes'));
  r := pg_temp.p3_expect('R13 pagamento + estorno ativos (líquido 0): move para 19–20', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(7, '19:00'), pg_temp.fx_ts(7, '20:00')), 'OK');
  perform pg_temp.p3_ok('R13b estorno não anulado impede o recálculo (10000 / RULE)', pg_temp.fx_is(r, 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 0, r::text);

  -- R14 lançamentos anulados não impedem
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(8, '10:00'), pg_temp.fx_ts(8, '11:00'));
  r := pg_temp.p3_do('rec', pg_temp.fx_pay_sql(v_id, 1000));
  perform pg_temp.p3_do('mgr', format('select public.rg_payment_void(%L::uuid, %L)', (r->>'payment_id')::uuid, 'lançado por engano'));
  r := pg_temp.p3_expect('R14 só lançamentos anulados: move para 19–20', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(8, '19:00'), pg_temp.fx_ts(8, '20:00')), 'OK');
  perform pg_temp.p3_ok('R14b recalcula (17000 / RULE)', pg_temp.fx_is(r, 17000, 'RULE') and pg_temp.fx_repriced(v_id) = 1, r::text);

  -- R15 ocorrência recorrente mantém o valor da série
  r := pg_temp.p3_expect('R15 ocorrência movida "apenas esta" (recepção, +10h)', 'rec', format(
    'update public.reservations set is_exception = true, start_at = start_at + interval ''10 hours'', end_at = end_at + interval ''10 hours'' where id = %L::uuid returning jsonb_build_object(''price'', price, ''price_source'', price_source)',
    pg_temp.p3_id('occ')), 'OK');
  perform pg_temp.p3_ok('R15b SERIES preservado (12345 / SERIES)', pg_temp.fx_is(r, 12345, 'SERIES') and pg_temp.fx_repriced(pg_temp.p3_id('occ')) = 0, r::text);

  -- R16 status que não é precificável
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(9, '10:00'), pg_temp.fx_ts(9, '11:00'));
  perform pg_temp.p3_do('rec', format('update public.reservations set status = ''CANCELLED'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id));
  r := pg_temp.p3_expect('R16 cancelada: move para 19–20', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(9, '19:00'), pg_temp.fx_ts(9, '20:00')), 'OK');
  perform pg_temp.p3_ok('R16b cancelada não é recalculada (10000 / RULE)', pg_temp.fx_is(r, 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 0, r::text);
end $$;

-- ----------------------------------------------------------------------------- S: segurança e ordem dos triggers
do $$
declare v_id uuid; r jsonb;
begin
  perform pg_temp.p3_ok('S01 ordem EXATA dos BEFORE UPDATE de reservations',
    (select array_agg(t.tgname::text order by t.tgname) from pg_trigger t where t.tgrelid = 'public.reservations'::regclass and not t.tgisinternal
       and t.tgtype & 2 = 2 and t.tgtype & 16 = 16)
    = array['enforce_reservation_tenant', 'enforce_reservation_zz_price_guard', 'enforce_reservation_zz_price_origin_guard',
            'enforce_reservation_zz_price_reprice', 'protect_occurrence_anchor', 'protect_reservation_links', 'trg_reservations_updated',
            'validate_reservation_recurring', 'validate_reservation_zz_series_slot'], 'pg_trigger');  -- 03C: + trigger estrutural (ordem anterior preservada)
  perform pg_temp.p3_ok('S02 guards SECURITY INVOKER; recálculo SECURITY DEFINER; owner postgres; search_path vazio; sem EXECUTE para a API',
    (select not prosecdef from pg_proc where oid = 'private.enforce_reservation_price_guard()'::regprocedure)
    and (select not prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""'] from pg_proc where oid = 'private.enforce_reservation_price_origin_guard()'::regprocedure)
    and (select prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""'] from pg_proc where oid = 'private.enforce_reservation_price_reprice()'::regprocedure)
    and (select prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""'] from pg_proc where oid = 'private.enforce_reservation_price_snapshot()'::regprocedure)
    and not has_function_privilege('authenticated', 'private.enforce_reservation_price_reprice()', 'EXECUTE')
    and not has_function_privilege('service_role', 'private.enforce_reservation_price_reprice()', 'EXECUTE')
    and not has_function_privilege('anon', 'private.enforce_reservation_price_origin_guard()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.enforce_reservation_price_origin_guard()', 'EXECUTE'), 'pg_proc');
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(10, '10:00'), pg_temp.fx_ts(10, '11:00'));
  perform pg_temp.p3_expect('S03 RECEPTIONIST altera price_source direto => 42501', 'rec', format('update public.reservations set price_source = ''MANUAL'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '42501');
  perform pg_temp.p3_expect('S04 OWNER altera price_source direto => 42501', 'owner', format('update public.reservations set price_source = null where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '42501');
  perform pg_temp.p3_expect('S05 service_role altera price_source direto => 42501', 'service_role', format('update public.reservations set price_source = ''MANUAL'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '42501');
  perform pg_temp.p3_expect('S06 OWNER altera price direto continua 42501', 'owner', format('update public.reservations set price = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '42501');
  perform pg_temp.p3_expect('S07 cliente muda horário + price na mesma instrução => 42501 (guard antes do recálculo)', 'rec', format(
    'update public.reservations set price = 1, start_at = %L::timestamptz, end_at = %L::timestamptz where id = %L::uuid returning jsonb_build_object(''id'', id)',
    pg_temp.fx_ts(10, '19:00'), pg_temp.fx_ts(10, '20:00'), v_id), '42501');
  perform pg_temp.p3_expect('S08 cliente muda horário + price_source na mesma instrução => 42501', 'owner', format(
    'update public.reservations set price_source = ''MANUAL'', start_at = %L::timestamptz, end_at = %L::timestamptz where id = %L::uuid returning jsonb_build_object(''id'', id)',
    pg_temp.fx_ts(10, '19:00'), pg_temp.fx_ts(10, '20:00'), v_id), '42501');
  perform pg_temp.p3_expect('S09 PAID continua bloqueado (UPDATE) => 23514', 'owner', format('update public.reservations set status = ''PAID'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '23514');
  perform pg_temp.p3_expect('S10 PAID continua bloqueado (INSERT service_role) => 23514', 'service_role', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source) values (%L, %L, %L, %L, %L, ''PAID'', ''TESTE_P3A'') returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c2'), pg_temp.fx_ts(10, '12:00'), pg_temp.fx_ts(10, '13:00')), '23514');
  perform pg_temp.p3_ok('S11 estado intacto após as tentativas negadas (10000 / RULE, horário original)',
    pg_temp.fx_is(pg_temp.fx_row(v_id), 10000, 'RULE') and (select start_at = pg_temp.fx_ts(10, '10:00') from public.reservations where id = v_id), pg_temp.fx_row(v_id)::text);
  -- o recálculo legítimo (trigger interno) consegue alterar price/price_source numa edição do cliente
  r := pg_temp.p3_expect('S12 mesma recepção, só horário => o trigger interno recalcula', 'rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(10, '19:00'), pg_temp.fx_ts(10, '20:00')), 'OK');
  perform pg_temp.p3_ok('S12b 17000 / RULE', pg_temp.fx_is(r, 17000, 'RULE'), r::text);
  perform pg_temp.p3_expect('S13 constraint: origem sem valor (postgres) => 23514', 'postgres', format('update public.reservations set price = null, price_source = ''RULE'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '23514');
  perform pg_temp.p3_expect('S14 constraint: origem fora da lista (postgres) => 23514', 'postgres', format('update public.reservations set price_source = ''OUTRA'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id), '23514');
end $$;

-- ----------------------------------------------------------------------------- P: set_price grava a origem
do $$
declare v_id uuid; r jsonb; a jsonb;
begin
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(11, '10:00'), pg_temp.fx_ts(11, '11:00'));
  r := pg_temp.p3_expect('P01 MANUAL com valor (MANAGER)', 'mgr', pg_temp.fx_price_sql(v_id, 'MANUAL', 15000, 'CORRECTION'), 'OK');
  a := (select metadata from public.audit_logs where entity_id = v_id and action = 'RESERVATION_PRICE_SET');   -- único até aqui
  perform pg_temp.p3_ok('P01b 15000 / MANUAL; audit com old_source/new_source', pg_temp.fx_is(pg_temp.fx_row(v_id), 15000, 'MANUAL')
    and a->>'old_source' = 'RULE' and a->>'new_source' = 'MANUAL' and (a->>'old_price')::int = 10000, coalesce(a::text, 'null'));
  r := pg_temp.p3_expect('P02 MANUAL 10000 (igual ao valor da tabela)', 'owner', pg_temp.fx_price_sql(v_id, 'MANUAL', 10000, 'CORRECTION'), 'OK');
  r := pg_temp.p3_expect('P02b RULE (recalcular pela tabela)', 'owner', pg_temp.fx_price_sql(v_id, 'RULE', null, 'RULE_RECALC'), 'OK');
  perform pg_temp.p3_ok('P02c MANUAL 10000 -> RULE 10000 => changed=true, origem RULE', (r->>'changed')::boolean and pg_temp.fx_is(pg_temp.fx_row(v_id), 10000, 'RULE'), r::text);
  r := pg_temp.p3_expect('P03 RULE repetido = no-op', 'owner', pg_temp.fx_price_sql(v_id, 'RULE', null, 'RULE_RECALC'), 'OK');
  perform pg_temp.p3_ok('P03b changed=false', not (r->>'changed')::boolean, r::text);
  r := pg_temp.p3_expect('P04 MANUAL limpando o valor (sem lançamentos)', 'mgr', pg_temp.fx_price_sql(v_id, 'MANUAL', null, 'CORRECTION'), 'OK');
  perform pg_temp.p3_ok('P04b sem valor => price/price_source NULL', pg_temp.fx_is(pg_temp.fx_row(v_id), null, null), pg_temp.fx_row(v_id)::text);
  perform pg_temp.p3_do('rec', pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(11, '06:00'), pg_temp.fx_ts(11, '07:00')));
  perform pg_temp.p3_expect('P05 RULE sem regra => RGP01 NO_RULE (comportamento seguro mantido)', 'owner', pg_temp.fx_price_sql(v_id, 'RULE', null, 'RULE_RECALC'), 'RGP01', 'NO_RULE');
  perform pg_temp.p3_ok('P05b continua sem valor', pg_temp.fx_is(pg_temp.fx_row(v_id), null, null), pg_temp.fx_row(v_id)::text);
  perform pg_temp.p3_expect('P06 RECEPTIONIST set_price continua 42501', 'rec', pg_temp.fx_price_sql(v_id, 'MANUAL', 100, 'CORRECTION'), '42501');
  r := pg_temp.p3_expect('P07 set_price em ocorrência recorrente (MANUAL)', 'mgr', pg_temp.fx_price_sql(pg_temp.p3_id('occ'), 'MANUAL', 11111, 'CORRECTION'), 'OK');
  perform pg_temp.p3_ok('P07b ocorrência com valor manual => 11111 / MANUAL, âncora intacta',
    pg_temp.fx_is(pg_temp.fx_row(pg_temp.p3_id('occ')), 11111, 'MANUAL')
    and (select occurrence_date = pg_temp.p3_day('fri') + 7 * 11 from public.reservations where id = pg_temp.p3_id('occ')), pg_temp.fx_row(pg_temp.p3_id('occ'))::text);
end $$;

-- ----------------------------------------------------------------------------- F: falha injetada
do $$
declare v_id uuid;
begin
  v_id := pg_temp.fx_new('c1', pg_temp.fx_ts(12, '10:00'), pg_temp.fx_ts(12, '11:00'));
  perform pg_temp.p3_fault_case('F01 falha após o audit do recálculo => UPDATE + recálculo + audit desfeitos', 'rec', 'reprice:after_audit',
    pg_temp.fx_move_sql(v_id, 'c1', pg_temp.fx_ts(12, '19:00'), pg_temp.fx_ts(12, '20:00')));
  perform pg_temp.p3_ok('F01b após a falha: 10000 / RULE, horário original, 0 audit de recálculo',
    pg_temp.fx_is(pg_temp.fx_row(v_id), 10000, 'RULE') and pg_temp.fx_repriced(v_id) = 0
    and (select start_at = pg_temp.fx_ts(12, '10:00') from public.reservations where id = v_id), pg_temp.fx_row(v_id)::text);
  perform pg_temp.p3_fault_case('F02 set_price: falha após o update => valor e origem intactos', 'mgr', 'set_price:after_update',
    pg_temp.fx_price_sql(v_id, 'MANUAL', 777, 'DISCOUNT'));
  perform pg_temp.p3_fault_case('F03 set_price: falha após o audit => valor e origem intactos', 'mgr', 'set_price:after_audit',
    pg_temp.fx_price_sql(v_id, 'MANUAL', 777, 'DISCOUNT'));
end $$;

-- ----------------------------------------------------------------------------- resultado (SEMPRE termina em erro => ROLLBACK)
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from p3r;
  select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from p3r;
  raise exception E'P3A_FIX_RESULTS % — % PASS / % FAIL (total %). Transação DESFEITA.\n%',
    case when v_fail = 0 then 'OK' else 'FAIL' end, v_total - v_fail, v_fail, v_total, v_txt;
end $$;
rollback;
