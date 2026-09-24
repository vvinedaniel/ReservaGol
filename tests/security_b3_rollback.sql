-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING B3 — testes de ROLLBACK / idempotência / permissões / D7
-- ETAPA 3 SOMENTE: requer supabase/migration_security_b3.sql (FOUNDATION) aplicada.
--
-- Como rodar: como postgres (SQL Editor do Supabase ou MCP execute_sql), o arquivo INTEIRO num
-- único envio. Pré-condição: session_user = postgres (é o que ativa private.rg_fault).
--
-- ZERO RESÍDUO POR CONSTRUÇÃO: tudo acontece dentro de UMA transação (fixtures incluídas) e o
-- script SEMPRE termina com o erro proposital "B3_ROLLBACK_RESULTS ..." => ROLLBACK total.
-- Os resultados (PASS/FAIL por caso) vêm na mensagem desse erro final.
--
-- O que é provado:
--   F*  falha injetada em cada ponto de cada RPC => a RPC propaga RGF01 (não engole) e o estado
--       da organização de teste (séries, ocorrências, clientes, audit) fica IDÊNTICO ao anterior;
--       e a mesma chamada SEM falha altera o estado (controle desfeito em seguida).
--   I*  idempotência: mesmo operation_id + mesmo request => idempotent=true (inclusive após PATCH);
--       request diferente / outro tipo / outra série => RGR02.
--   P*  permissões: RECEPTIONIST (estrutural 42501, generate ok), outra org (P0002), anon e
--       service_role (sem EXECUTE), postgres sem claims (42501).
--   D*  D7: INSERT direto de ocorrência recorrente só se idêntica à gerada pela série; UPDATE
--       "apenas esta" continua permitido; série pausada => RGR01.
--   M*  metadados B3 não graváveis/legíveis por authenticated; comportamento FOUNDATION x LOCKDOWN.
-- Concorrência real (2 sessões) fica em tests/security_b3_recurring_integration.py.
-- =============================================================================
begin;
set local statement_timeout = '120s';
set local lock_timeout = '5s';

create temp table b3fx (k text primary key, id uuid not null) on commit drop;
create temp table b3d (k text primary key, d date not null) on commit drop;
create temp table b3r (seq serial, name text, ok boolean, detail text) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'b3: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('public.rg_recurring_pause(uuid,boolean)') is null then raise exception 'b3: FOUNDATION não aplicada'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.b3_id(p text) returns uuid language sql stable as $$ select id from b3fx where k = p $$;
create function pg_temp.b3_day(p text) returns date language sql stable as $$ select d from b3d where k = p $$;
create function pg_temp.b3_ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into b3r (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- Estado completo da organização de teste (séries, ocorrências, clientes, audit).
create function pg_temp.b3_snapshot() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'rr:' || row_to_json(r)::text as x from public.recurring_reservations r where r.organization_id = pg_temp.b3_id('org')
    union all select 'rs:' || row_to_json(r)::text from public.reservations r where r.organization_id = pg_temp.b3_id('org')
    union all select 'cu:' || row_to_json(r)::text from public.customers r where r.organization_id = pg_temp.b3_id('org')
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r where r.organization_id = pg_temp.b3_id('org')
  ) s), '')) $$;

-- Executa p_sql como p_actor ('owner'|'mgr'|'rec'|'out'|'anon'|'service_role'|'postgres'),
-- com falha injetada opcional. Erro => subtransação desfeita; devolve SQLSTATE.
-- Falha ao TROCAR de papel vira 'B3ROL:<sqlstate>' (nunca se confunde com o 42501 do teste).
create function pg_temp.b3_call(p_actor text, p_fault text, p_sql text, out state text, out result jsonb)
language plpgsql as $$
declare v_claims text;
begin
  v_claims := case
    when p_actor in ('anon', 'service_role') then json_build_object('role', p_actor)::text
    when p_actor = 'postgres' then ''
    else json_build_object('sub', pg_temp.b3_id(p_actor), 'role', 'authenticated')::text end;
  perform set_config('rg.fault_at', coalesce(p_fault, ''), true);
  perform set_config('request.jwt.claims', v_claims, true);
  begin
    if p_actor in ('anon', 'service_role') then execute format('set local role %I', p_actor);
    elsif p_actor <> 'postgres' then execute 'set local role authenticated';
    end if;
  exception when others then
    state := 'B3ROL:' || sqlstate;
    result := jsonb_build_object('msg', sqlerrm);
  end;
  if state is null then
    begin
      execute p_sql into result;
      state := 'OK';
    exception when others then
      state := sqlstate;
      result := jsonb_build_object('msg', sqlerrm);
    end;
  end if;
  execute 'reset role';
  perform set_config('rg.fault_at', '', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Caso de falha: RGF01 esperado + estado idêntico; controle (sem falha) OK + estado alterado.
create function pg_temp.b3_fault_case(p_name text, p_actor text, p_fault text, p_sql text) returns void
language plpgsql as $$
declare v_before text; v_after text; v_c record; v_f record; v_changed boolean;
begin
  v_before := pg_temp.b3_snapshot();
  select * into v_f from pg_temp.b3_call(p_actor, p_fault, p_sql);
  v_after := pg_temp.b3_snapshot();
  begin
    select * into v_c from pg_temp.b3_call(p_actor, null, p_sql);
    v_changed := pg_temp.b3_snapshot() <> v_before;
    raise exception using errcode = 'B3CTL';
  exception when sqlstate 'B3CTL' then null;
  end;
  perform pg_temp.b3_ok(p_name, v_f.state = 'RGF01' and v_before = v_after and v_c.state = 'OK' and v_changed,
    format('fault=%s estado_igual=%s controle=%s alterou=%s', v_f.state, v_before = v_after, v_c.state, v_changed));
end $$;

-- Espera SQLSTATE específico (e estado idêntico).
create function pg_temp.b3_expect(p_name text, p_actor text, p_sql text, p_state text) returns jsonb
language plpgsql as $$
declare v_before text; v_r record;
begin
  v_before := pg_temp.b3_snapshot();
  select * into v_r from pg_temp.b3_call(p_actor, null, p_sql);
  perform pg_temp.b3_ok(p_name, v_r.state = p_state and (p_state = 'OK' or pg_temp.b3_snapshot() = v_before),
    format('esperado=%s veio=%s', p_state, v_r.state));
  return v_r.result;
end $$;

-- SQL de chamada das RPCs (literais; nada vem de fora).
create function pg_temp.b3_create_sql(p_op uuid, p_court text, p_start text, p_end text, p_dates date[],
  p_customer_id uuid default null, p_customer jsonb default null, p_notes text default 'b3 nota') returns text
language sql stable as $$
  select format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, %L::jsonb, ''WEEKLY'', %s, null, %L::time, %L::time, %L::date, null, true, 15000, %L, true, false, %L::date[])',
    p_op, pg_temp.b3_id('arena'), pg_temp.b3_id(p_court), p_customer_id, p_customer,
    extract(dow from pg_temp.b3_day('d7'))::int, p_start, p_end, pg_temp.b3_day('today'), p_notes, p_dates) $$;
create function pg_temp.b3_resched_sql(p_series uuid, p_op uuid, p_from date, p_changes jsonb, p_dates date[]) returns text
language sql stable as $$
  select format('select public.rg_recurring_reschedule(%L::uuid, %L::uuid, %L::date, %L::jsonb, false, %L::date[])', p_series, p_op, p_from, p_changes, p_dates) $$;

-- ----------------------------------------------------------------------------- fixtures (desfeitas no fim)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_arena uuid; v_arena2 uuid; v_c1 uuid; v_c2 uuid; v_cout uuid; v_cust uuid;
  v_tag text := 'b3rb-' || substr(md5(clock_timestamp()::text), 1, 8);
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'),
    (u_rec, v_tag || '-rec@reservagol.test'), (u_out, v_tag || '-out@reservagol.test');
  insert into public.organizations (name, is_demo) values ('B3 RB ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('B3 RB outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'Arena ' || v_tag) returning id into v_arena;
  insert into public.arenas (organization_id, name) values (v_org2, 'Arena outra ' || v_tag) returning id into v_arena2;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_arena2, 'Q outra') returning id into v_cout;
  insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_arena, 'Cliente ' || v_tag, '11900000001') returning id into v_cust;
  insert into b3fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('org', v_org), ('org2', v_org2),
    ('arena', v_arena), ('arena2', v_arena2), ('c1', v_c1), ('c2', v_c2), ('c_out', v_cout), ('cust', v_cust);
  insert into b3d values ('today', v_today), ('d7', v_today + 7), ('d14', v_today + 14), ('d21', v_today + 21), ('d28', v_today + 28);
end $$;

-- Séries base (criadas pela RPC como OWNER; ficam só dentro desta transação):
--   SA ativa 10:00-11:00 Q1 [d7,d14]; SP pausada 12:00-13:00 Q1 [d7]; SB ativa 18:00-19:00 Q2 [d7].
do $$
declare v record;
begin
  select * into v from pg_temp.b3_call('owner', null, pg_temp.b3_create_sql(gen_random_uuid(), 'c1', '10:00', '11:00',
    array[pg_temp.b3_day('d7'), pg_temp.b3_day('d14')], pg_temp.b3_id('cust')));
  if v.state <> 'OK' then raise exception 'b3 setup SA: % %', v.state, v.result; end if;
  insert into b3fx values ('sa', (v.result->>'series_id')::uuid);
  select * into v from pg_temp.b3_call('owner', null, pg_temp.b3_create_sql(gen_random_uuid(), 'c1', '12:00', '13:00',
    array[pg_temp.b3_day('d7')], pg_temp.b3_id('cust')));
  if v.state <> 'OK' then raise exception 'b3 setup SP: % %', v.state, v.result; end if;
  insert into b3fx values ('sp', (v.result->>'series_id')::uuid);
  select * into v from pg_temp.b3_call('owner', null, format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.b3_id('sp')));
  if v.state <> 'OK' then raise exception 'b3 setup pause SP: % %', v.state, v.result; end if;
  select * into v from pg_temp.b3_call('owner', null, pg_temp.b3_create_sql(gen_random_uuid(), 'c2', '18:00', '19:00',
    array[pg_temp.b3_day('d7')], pg_temp.b3_id('cust')));
  if v.state <> 'OK' then raise exception 'b3 setup SB: % %', v.state, v.result; end if;
  insert into b3fx values ('sb', (v.result->>'series_id')::uuid);
end $$;

-- ----------------------------------------------------------------------------- F: rollback por falha injetada
do $$
declare
  sa uuid := pg_temp.b3_id('sa'); sp uuid := pg_temp.b3_id('sp');
  d7 date := pg_temp.b3_day('d7'); d14 date := pg_temp.b3_day('d14'); d21 date := pg_temp.b3_day('d21');
  v_create text := pg_temp.b3_create_sql(gen_random_uuid(), 'c1', '14:00', '15:00', array[d7, d14], null,
    '{"name":"Novo B3","phone":"(11) 90000-0002","email":"novo@b3.test"}'::jsonb);
  v_resched text := pg_temp.b3_resched_sql(sa, gen_random_uuid(), d14, '{"start_time":"16:00","end_time":"17:00"}'::jsonb, array[d14, d21]);
begin
  perform pg_temp.b3_fault_case('F01 create: após série', 'owner', 'create:after_series', v_create);
  perform pg_temp.b3_fault_case('F02 create: materialize 1', 'owner', 'materialize:1', v_create);
  perform pg_temp.b3_fault_case('F03 create: materialize 2', 'owner', 'materialize:2', v_create);
  perform pg_temp.b3_fault_case('F04 create: antes do audit', 'owner', 'create:before_audit', v_create);
  perform pg_temp.b3_fault_case('F05 pause: após status', 'owner', 'pause:after_status', format('select public.rg_recurring_pause(%L::uuid, true)', sa));
  perform pg_temp.b3_fault_case('F06 pause: antes do audit', 'owner', 'pause:before_audit', format('select public.rg_recurring_pause(%L::uuid, true)', sa));
  perform pg_temp.b3_fault_case('F07 cancel: após status', 'owner', 'cancel:after_status', format('select public.rg_recurring_cancel(%L::uuid)', sa));
  perform pg_temp.b3_fault_case('F08 cancel: antes do audit', 'owner', 'cancel:before_audit', format('select public.rg_recurring_cancel(%L::uuid)', sa));
  perform pg_temp.b3_fault_case('F09 reactivate: após status', 'owner', 'reactivate:after_status', format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', sp, array[d14]));
  perform pg_temp.b3_fault_case('F10 reactivate: materialize 1', 'owner', 'materialize:1', format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', sp, array[d14]));
  perform pg_temp.b3_fault_case('F11 reactivate: antes do audit', 'owner', 'reactivate:before_audit', format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', sp, array[d14]));
  perform pg_temp.b3_fault_case('F12 reschedule: após série nova', 'owner', 'reschedule:after_new_series', v_resched);
  perform pg_temp.b3_fault_case('F13 reschedule: após encerrar antiga', 'owner', 'reschedule:after_old_update', v_resched);
  perform pg_temp.b3_fault_case('F14 reschedule: após cancelar futuras', 'owner', 'reschedule:after_cancel_future', v_resched);
  perform pg_temp.b3_fault_case('F15 reschedule: materialize 1', 'owner', 'materialize:1', v_resched);
  perform pg_temp.b3_fault_case('F16 reschedule: antes do audit', 'owner', 'reschedule:before_audit', v_resched);
  perform pg_temp.b3_fault_case('F17 update: antes do audit', 'owner', 'update:before_audit', format('select public.rg_recurring_update(%L::uuid, %L::jsonb)', sa, '{"notes":"b3 editada"}'));
  perform pg_temp.b3_fault_case('F18 generate: materialize 1', 'rec', 'materialize:1', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', sa, array[d21]));
end $$;

-- ----------------------------------------------------------------------------- I: idempotência (persistem nesta transação)
do $$
declare
  op uuid := gen_random_uuid(); op2 uuid := gen_random_uuid();
  d7 date := pg_temp.b3_day('d7'); d14 date := pg_temp.b3_day('d14'); d21 date := pg_temp.b3_day('d21'); d28 date := pg_temp.b3_day('d28');
  cust jsonb := '{"name":"Idem B3","phone":"11 90000-0003"}'::jsonb;
  v_sql text := pg_temp.b3_create_sql(op, 'c2', '20:00', '21:00', array[d7], null, cust);
  r jsonb; r2 jsonb; v_before text; v_new uuid; v_sb uuid := pg_temp.b3_id('sb');
begin
  r := pg_temp.b3_expect('I01 create novo', 'owner', v_sql, 'OK');
  perform pg_temp.b3_ok('I01b create novo: idempotent=false + customer criado', (r->>'idempotent')::boolean is false and r ? 'customer_id', r::text);
  v_before := pg_temp.b3_snapshot();
  r2 := pg_temp.b3_expect('I02 replay mesmo request', 'owner', pg_temp.b3_create_sql(op, 'c2', '20:00', '21:00', array[]::date[], null, cust), 'OK');
  perform pg_temp.b3_ok('I02b replay: idempotent=true, mesma série, sem contadores, estado igual',
    (r2->>'idempotent')::boolean and r2->>'series_id' = r->>'series_id' and not (r2 ? 'created') and pg_temp.b3_snapshot() = v_before, r2::text);
  perform pg_temp.b3_expect('I03 mesmo op + quadra diferente', 'owner', pg_temp.b3_create_sql(op, 'c1', '20:00', '21:00', array[d7], null, cust), 'RGR02');
  perform pg_temp.b3_expect('I04 mesmo op + cliente diferente', 'owner', pg_temp.b3_create_sql(op, 'c2', '20:00', '21:00', array[d7], null, '{"name":"Outro"}'::jsonb), 'RGR02');
  perform pg_temp.b3_expect('I05 PATCH posterior (notes/preço)', 'owner', format('select public.rg_recurring_update(%L::uuid, %L::jsonb)', r->>'series_id', '{"notes":"mudou","default_price":999}'), 'OK');
  r2 := pg_temp.b3_expect('I06 replay após PATCH continua válido', 'owner', pg_temp.b3_create_sql(op, 'c2', '20:00', '21:00', array[d7], null, cust), 'OK');
  perform pg_temp.b3_ok('I06b replay após PATCH: idempotent=true', (r2->>'idempotent')::boolean, r2::text);
  -- reschedule
  r := pg_temp.b3_expect('I07 reschedule novo', 'owner', pg_temp.b3_resched_sql(v_sb, op2, d14, '{"start_time":"19:00","end_time":"20:00"}', array[d14, d21]), 'OK');
  v_new := (r->>'new_series_id')::uuid;
  perform pg_temp.b3_ok('I07b linhagem gravada', exists (select 1 from public.recurring_reservations x where x.id = v_new and x.previous_series_id = v_sb and x.operation_kind = 'RESCHEDULE'), r::text);
  r2 := pg_temp.b3_expect('I08 replay reschedule (antiga já encerrada)', 'owner', pg_temp.b3_resched_sql(v_sb, op2, d14, '{"start_time":"19:00","end_time":"20:00"}', array[]::date[]), 'OK');
  perform pg_temp.b3_ok('I08b replay reschedule: idempotent=true, mesma série nova', (r2->>'idempotent')::boolean and (r2->>'new_series_id')::uuid = v_new, r2::text);
  perform pg_temp.b3_expect('I09 mesmo op em OUTRA série (A x B)', 'owner', pg_temp.b3_resched_sql(pg_temp.b3_id('sa'), op2, d14, '{"start_time":"19:00","end_time":"20:00"}', array[d14]), 'RGR02');
  perform pg_temp.b3_expect('I10 op de reschedule reaproveitado em create', 'owner', pg_temp.b3_create_sql(op2, 'c2', '20:00', '21:00', array[d7]), 'RGR02');
  perform pg_temp.b3_expect('I11 D6: reagendar a origem com continuação viva', 'owner', pg_temp.b3_resched_sql(v_sb, gen_random_uuid(), d7, '{"start_time":"07:00","end_time":"08:00"}', array[]::date[]), 'RGR01');
  perform pg_temp.b3_expect('I12 D2: from_date no passado', 'owner', pg_temp.b3_resched_sql(pg_temp.b3_id('sa'), gen_random_uuid(), pg_temp.b3_day('today') - 1, '{}', array[]::date[]), '22023');
  perform pg_temp.b3_expect('I13 data que não é âncora', 'owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.b3_id('sa'), array[d21 + 1]), '22023');
  perform pg_temp.b3_expect('I14 data fora da janela (hoje+91)', 'owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.b3_id('sa'), array[pg_temp.b3_day('today') + 91]), '22023');
  perform pg_temp.b3_expect('I15 update com campo estrutural', 'owner', format('select public.rg_recurring_update(%L::uuid, %L::jsonb)', pg_temp.b3_id('sa'), '{"court_id":"00000000-0000-0000-0000-000000000000"}'), '22023');
  perform pg_temp.b3_expect('I16 create sem operation_id', 'owner', pg_temp.b3_create_sql(null, 'c2', '06:00', '07:00', array[d28]), '22023');
  -- I17: o MESMO operation_id (já usado na org 1 em I01) é aceito de forma independente na org 2.
  r2 := pg_temp.b3_expect('I17 mesmo operation_id em OUTRA organização', 'out', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', %s, null, ''10:00''::time, ''11:00''::time, %L::date, null, true, null, null, true, false, %L::date[])',
    op, pg_temp.b3_id('arena2'), pg_temp.b3_id('c_out'), '{"name":"Outra org"}', extract(dow from d7)::int, pg_temp.b3_day('today'), array[d7]), 'OK');
  perform pg_temp.b3_ok('I17b outra org: série nova (idempotent=false) e as duas coexistem',
    (r2->>'idempotent')::boolean is false
    and (select count(*) from public.recurring_reservations where operation_id = op) = 2
    and (select count(distinct organization_id) from public.recurring_reservations where operation_id = op) = 2, r2::text);
end $$;

-- ----------------------------------------------------------------------------- P: permissões
do $$
declare sa uuid := pg_temp.b3_id('sa'); v_sql text := format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.b3_id('sa'));
begin
  perform pg_temp.b3_expect('P01 RECEPTIONIST pause', 'rec', v_sql, '42501');
  perform pg_temp.b3_expect('P02 RECEPTIONIST cancel', 'rec', format('select public.rg_recurring_cancel(%L::uuid)', sa), '42501');
  perform pg_temp.b3_expect('P03 RECEPTIONIST reschedule', 'rec', pg_temp.b3_resched_sql(sa, gen_random_uuid(), pg_temp.b3_day('d14'), '{}', array[]::date[]), '42501');
  perform pg_temp.b3_expect('P04 RECEPTIONIST update', 'rec', format('select public.rg_recurring_update(%L::uuid, %L::jsonb)', sa, '{"notes":"x"}'), '42501');
  perform pg_temp.b3_expect('P05 RECEPTIONIST create', 'rec', pg_temp.b3_create_sql(gen_random_uuid(), 'c1', '06:00', '07:00', array[]::date[]), '42501');
  perform pg_temp.b3_expect('P06 RECEPTIONIST generate (D5)', 'rec', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', sa, array[pg_temp.b3_day('d28')]), 'OK');
  perform pg_temp.b3_expect('P07 OWNER de outra org', 'out', v_sql, 'P0002');
  perform pg_temp.b3_expect('P08 série inexistente', 'owner', format('select public.rg_recurring_pause(%L::uuid, false)', gen_random_uuid()), 'P0002');
  perform pg_temp.b3_expect('P09 anon sem EXECUTE', 'anon', v_sql, '42501');
  perform pg_temp.b3_expect('P10 service_role sem EXECUTE', 'service_role', v_sql, '42501');
  perform pg_temp.b3_expect('P11 postgres sem claims (auth.uid() nulo)', 'postgres', v_sql, '42501');
  perform pg_temp.b3_expect('P12 MANAGER pause', 'mgr', v_sql, 'OK');
  perform pg_temp.b3_expect('P13 MANAGER reactivate', 'mgr', format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', sa, array[]::date[]), 'OK');
  perform pg_temp.b3_expect('P14 reactivate SP (PAUSED -> ACTIVE)', 'owner',
    format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', pg_temp.b3_id('sp'), array[]::date[]), 'OK');
  perform pg_temp.b3_expect('P15 cancel SP', 'owner', format('select public.rg_recurring_cancel(%L::uuid)', pg_temp.b3_id('sp')), 'OK');
  perform pg_temp.b3_expect('P16 reactivate de CANCELLED', 'owner', format('select public.rg_recurring_reactivate(%L::uuid, %L::date[])', pg_temp.b3_id('sp'), array[]::date[]), 'RGR01');
  perform pg_temp.b3_expect('P17 pause de CANCELLED', 'owner', format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.b3_id('sp')), 'RGR01');
  perform pg_temp.b3_expect('P18 generate de CANCELLED', 'owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.b3_id('sp'), array[pg_temp.b3_day('d28')]), 'RGR01');
end $$;

-- ----------------------------------------------------------------------------- D: D7 (INSERT direto de ocorrência)
do $$
declare
  s public.recurring_reservations; v_start timestamptz; v_end timestamptz; d21 date := pg_temp.b3_day('d21');
  base jsonb; v_occ uuid; v_before text; v record;
  cases constant text[] := array['occurrence_date', 'start_at', 'status', 'source', 'customer_id', 'price', 'notes', 'is_exception', 'public_code', 'idempotency_key', 'created_by'];
  bad constant jsonb := jsonb_build_object(
    'occurrence_date', d21 + 1, 'start_at', 'shift', 'status', 'CANCELLED', 'source', 'INTERNAL', 'customer_id', null,
    'price', 1, 'notes', 'outra nota', 'is_exception', true, 'public_code', 'RG-B3TESTE', 'idempotency_key', 'b3-key',
    'created_by', pg_temp.b3_id('mgr'));
  k text; row_sql text;
begin
  select * into s from public.recurring_reservations where id = pg_temp.b3_id('sa');
  select b.start_at, b.end_at into v_start, v_end from private.rg_occurrence_bounds(d21, s.start_time, s.end_time) b;
  -- id/created_at/updated_at explícitos: jsonb_populate_record + select * não usa os defaults.
  base := jsonb_build_object('id', gen_random_uuid(), 'created_at', now(), 'updated_at', now(), 'organization_id', s.organization_id, 'arena_id', s.arena_id, 'court_id', s.court_id,
    'customer_id', s.customer_id, 'start_at', v_start, 'end_at', v_end, 'status', 'CONFIRMED', 'source', 'RECORRENTE',
    'notes', s.notes, 'price', s.default_price, 'recurring_reservation_id', s.id, 'occurrence_date', d21,
    'is_exception', false, 'created_by', pg_temp.b3_id('owner'));
  -- controle: a linha idêntica à gerada é aceita (desfeita em seguida)
  begin
    select * into v from pg_temp.b3_call('owner', null, format(
      'insert into public.reservations select * from jsonb_populate_record(null::public.reservations, %L::jsonb) returning jsonb_build_object(''id'', id)', base));
    perform pg_temp.b3_ok('D00 controle: ocorrência idêntica à da série é aceita', v.state = 'OK', v.state);
    raise exception using errcode = 'B3CTL';
  exception when sqlstate 'B3CTL' then null;
  end;
  foreach k in array cases loop
    row_sql := format('insert into public.reservations select * from jsonb_populate_record(null::public.reservations, %L::jsonb) returning jsonb_build_object(''id'', id)',
      case when k = 'start_at' then base || jsonb_build_object('start_at', v_start + interval '1 hour', 'end_at', v_end + interval '1 hour')
           else base || jsonb_build_object(k, bad->k) end);
    perform pg_temp.b3_expect(format('D%s INSERT direto com %s inválido', lpad((array_position(cases, k))::text, 2, '0'), k), 'owner', row_sql, '23514');
  end loop;
  -- série pausada: nenhuma ocorrência nova
  perform pg_temp.b3_expect('D12 INSERT direto em série não ACTIVE', 'owner', format(
    'insert into public.reservations select * from jsonb_populate_record(null::public.reservations, %L::jsonb) returning jsonb_build_object(''id'', id)',
    base || jsonb_build_object('recurring_reservation_id', pg_temp.b3_id('sp'))), 'RGR01');
  -- UPDATE "apenas esta" continua permitido (RECEPTIONIST move a ocorrência de d7 para Q2 +1h)
  select id into v_occ from public.reservations where recurring_reservation_id = s.id and occurrence_date = pg_temp.b3_day('d7');
  perform pg_temp.b3_expect('D13 UPDATE "apenas esta" (exceção) continua permitido', 'rec', format(
    'update public.reservations set is_exception = true, court_id = %L::uuid, start_at = start_at + interval ''1 hour'', end_at = end_at + interval ''1 hour'' where id = %L::uuid returning jsonb_build_object(''id'', id)',
    pg_temp.b3_id('c2'), v_occ), 'OK');
end $$;

-- ----------------------------------------------------------------------------- M: metadados B3 / FOUNDATION x LOCKDOWN
do $$
declare
  v_locked boolean := not has_column_privilege('authenticated', 'public.recurring_reservations', 'status', 'UPDATE');
  sa uuid := pg_temp.b3_id('sa');
begin
  perform pg_temp.b3_ok('M00 modo detectado', true, case when v_locked then 'LOCKDOWN' else 'FOUNDATION' end);
  perform pg_temp.b3_expect('M01 INSERT direto com operation_id', 'owner', format(
    'insert into public.recurring_reservations (organization_id, arena_id, court_id, frequency, weekday, start_time, end_time, start_date, has_no_end_date, operation_id, operation_kind, operation_request) values (%L, %L, %L, ''WEEKLY'', 1, ''06:00'', ''07:00'', %L, true, gen_random_uuid(), ''CREATE'', ''{}'') returning jsonb_build_object(''id'', id)',
    pg_temp.b3_id('org'), pg_temp.b3_id('arena'), pg_temp.b3_id('c1'), pg_temp.b3_day('today')), '42501');
  perform pg_temp.b3_expect('M02 UPDATE direto de frequency', 'owner', format('update public.recurring_reservations set frequency = ''MONTHLY'' where id = %L::uuid returning jsonb_build_object(''id'', id)', sa), '42501');
  perform pg_temp.b3_expect('M03 UPDATE direto de start_time', 'owner', format('update public.recurring_reservations set start_time = ''20:00'' where id = %L::uuid returning jsonb_build_object(''id'', id)', sa), '42501');
  perform pg_temp.b3_expect('M04 UPDATE direto de created_by', 'owner', format('update public.recurring_reservations set created_by = %L::uuid where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.b3_id('mgr'), sa), '42501');
  perform pg_temp.b3_expect('M05 SELECT operation_request', 'owner', 'select jsonb_agg(operation_request) from public.recurring_reservations', '42501');
  perform pg_temp.b3_expect('M06 SELECT de metadados legíveis', 'owner', format('select jsonb_build_object(''k'', operation_kind, ''p'', previous_series_id) from public.recurring_reservations where id = %L::uuid', sa), 'OK');
  perform pg_temp.b3_expect('M07 UPDATE direto de status (' || case when v_locked then 'LOCKDOWN: negado' else 'FOUNDATION: grant permite' end || ')', 'owner',
    format('update public.recurring_reservations set status = ''PAUSED'' where id = %L::uuid returning jsonb_build_object(''id'', id)', sa),
    case when v_locked then '42501' else 'OK' end);
  if exists (select 1 from pg_trigger where tgname = 'validate_recurring_zz_terminal_state') then
    perform pg_temp.b3_expect('M08 LOCKDOWN: CANCELLED terminal até para postgres', 'postgres',
      format('update public.recurring_reservations set status = ''ACTIVE'' where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.b3_id('sp')), 'RGR01');
  end if;
end $$;

-- ----------------------------------------------------------------------------- resultado (SEMPRE termina em erro => ROLLBACK)
do $$
declare v_fail int; v_total int; v_json text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from b3r;
  select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_json from b3r;
  raise exception E'B3_ROLLBACK_RESULTS % — % PASS / % FAIL (total %). Transação DESFEITA.\n%',
    case when v_fail = 0 then 'OK' else 'FAIL' end, v_total - v_fail, v_fail, v_total, v_json;
end $$;
rollback;
