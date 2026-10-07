-- =============================================================================
-- RESERVA GOL — FASE 03A — testes SQL de ROLLBACK / pricing / ledger / idempotência / permissões
-- Requer supabase/migration_phase3a_foundation.sql aplicada (e B3 FOUNDATION + LOCKDOWN).
-- Detecta sozinho o modo FOUNDATION x GUARDS (presença de enforce_reservation_zz_price_guard).
--
-- Como rodar: como postgres (SQL Editor do Supabase ou MCP execute_sql), o arquivo INTEIRO num
-- único envio. Pré-condição: session_user = postgres (ativa private.rg_fault).
--
-- ZERO RESÍDUO POR CONSTRUÇÃO: tudo numa única transação (fixtures incluídas); o script SEMPRE
-- termina com o erro proposital "P3A_ROLLBACK_RESULTS ..." => ROLLBACK total.
--
-- Blocos:
--   Q  cotação por interseção de intervalos (valores exatos em centavos, meia-noite, precedência,
--      cobertura parcial, validade, half-up, 00:00 => 0 / 1440, entradas inválidas)
--   Y  criação MULTI-DAY atômica (4 dias = 4 ou 8 linhas; conflito/falha em qualquer ponto = zero
--      linhas e zero audit; validação de weekdays)
--   X  criação ATÔMICA de faixa (cross-midnight gera 2 linhas na mesma transação; conflito em
--      qualquer metade ou falha injetada => nada permanece; UM audit por intenção)
--   R  regras: permissões, tenant, desativação terminal, UPDATE sem atravessar meia-noite,
--      colunas geradas, escrita direta negada, DELETE só em org demo
--   S  snapshot automático (SECURITY DEFINER; private.rg_price_quote sem EXECUTE para a API)
--   P  pagamentos/estornos/anulação/set_price e matriz de payment_status
--   I  idempotência (replay, RGP02 por campo, replay após mudanças de estado, papel atual)
--   V  visibilidade (ledger só OWNER/MANAGER, fingerprint ilegível, resumos sem valores p/ recepção)
--   L  imutabilidade do ledger para todos os papéis
--   F  falha injetada em cada RPC => estado idêntico
--   G  GUARDS (ou comportamento FOUNDATION) + D7 continua autoridade do INSERT recorrente
-- =============================================================================
begin;
set local statement_timeout = '180s';
set local lock_timeout = '5s';

create temp table p3fx (k text primary key, id uuid not null) on commit drop;
create temp table p3d (k text primary key, d date not null) on commit drop;
create temp table p3r (seq serial, name text, ok boolean, detail text) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3a: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('public.rg_payment_register(uuid,uuid,text,integer,timestamptz,text)') is null then raise exception 'p3a: FOUNDATION 03A não aplicada'; end if;
  if to_regprocedure('public.rg_recurring_create(uuid,uuid,uuid,uuid,jsonb,text,integer,integer,time,time,date,date,boolean,integer,text,boolean,boolean,date[])') is null then raise exception 'p3a: B3 ausente'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.p3_id(p text) returns uuid language sql stable as $$ select id from p3fx where k = p $$;
create function pg_temp.p3_day(p text) returns date language sql stable as $$ select d from p3d where k = p $$;
create function pg_temp.p3_ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into p3r (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- Instante local (America/Sao_Paulo) de um dia de fixture.
create function pg_temp.p3_ts(p_day text, p_hhmm text, p_plus_days integer default 0) returns timestamptz language sql stable as $$
  select ((pg_temp.p3_day(p_day) + p_plus_days)::text || ' ' || p_hhmm || ':00-03:00')::timestamptz $$;

-- Estado completo da organização de teste (reservas, ledger, regras, audit).
create function pg_temp.p3_snapshot() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'rs:' || row_to_json(r)::text as x from public.reservations r where r.organization_id = pg_temp.p3_id('org')
    union all select 'rp:' || row_to_json(r)::text from public.reservation_payments r where r.organization_id = pg_temp.p3_id('org')
    union all select 'pr:' || row_to_json(r)::text from public.court_pricing_rules r where r.organization_id = pg_temp.p3_id('org')
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r where r.organization_id = pg_temp.p3_id('org')
  ) s), '')) $$;

-- Executa p_sql como p_actor ('owner'|'mgr'|'rec'|'out'|'anon'|'service_role'|'postgres') com falha
-- injetada opcional. Erro => subtransação desfeita; devolve SQLSTATE (+ hint).
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

-- Caso de falha: RGF01 + estado idêntico; controle (sem falha) OK + estado alterado (desfeito).
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

-- Espera SQLSTATE específico (e, se não for OK, estado idêntico). p_hint opcional.
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

-- Setup: executa e exige OK.
create function pg_temp.p3_do(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.p3_call(p_actor, null, p_sql);
  if v.state <> 'OK' then raise exception 'p3a setup (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

-- SQL das RPCs (literais; nada vem de fora).
create function pg_temp.p3_rule_sql(p_arena text, p_court text, p_wds integer[], p_s text, p_e text, p_price integer,
  p_from date default null, p_until date default null) returns text language sql stable as $$
  select format('select public.rg_pricing_rule_create(%L::uuid, %L::uuid, %L::smallint[], %L::time, %L::time, %s, %L::date, %L::date)',
    pg_temp.p3_id(p_arena), case when p_court is null then null else pg_temp.p3_id(p_court) end, p_wds, p_s, p_e, p_price, p_from, p_until) $$;
create function pg_temp.p3_quote_sql(p_court text, p_start timestamptz, p_end timestamptz) returns text language sql stable as $$
  select format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id(p_court), p_start, p_end) $$;
create function pg_temp.p3_pay_sql(p_op uuid, p_res uuid, p_method text, p_amount integer, p_at timestamptz, p_notes text default null) returns text language sql stable as $$
  select format('select public.rg_payment_register(%L::uuid, %L::uuid, %L, %s, %L::timestamptz, %L)', p_op, p_res, p_method, p_amount, p_at, p_notes) $$;
create function pg_temp.p3_refund_sql(p_op uuid, p_pay uuid, p_method text, p_amount integer, p_at timestamptz, p_notes text default null) returns text language sql stable as $$
  select format('select public.rg_payment_refund(%L::uuid, %L::uuid, %L, %s, %L::timestamptz, %L)', p_op, p_pay, p_method, p_amount, p_at, p_notes) $$;
create function pg_temp.p3_void_sql(p_pay uuid, p_reason text) returns text language sql stable as $$
  select format('select public.rg_payment_void(%L::uuid, %L)', p_pay, p_reason) $$;
create function pg_temp.p3_price_sql(p_res uuid, p_mode text, p_price integer, p_reason text) returns text language sql stable as $$
  select format('select public.rg_reservation_set_price(%L::uuid, %L, %L::integer, %L)', p_res, p_mode, p_price, p_reason) $$;
create function pg_temp.p3_detail_sql(p_res uuid) returns text language sql stable as $$
  select format('select public.rg_reservation_financial_detail(%L::uuid)', p_res) $$;
-- Reserva de fixture inserida como postgres (price NULL => o snapshot pode precificar).
create function pg_temp.p3_res(p_court text, p_start timestamptz, p_end timestamptz, p_status text default 'CONFIRMED', p_price integer default null) returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price, created_by)
  select c.organization_id, c.arena_id, c.id, p_start, p_end, p_status, 'TESTE_P3A', p_price, pg_temp.p3_id('owner')
    from public.courts c where c.id = pg_temp.p3_id(p_court)
  returning id into v;
  return v;
end $$;
create function pg_temp.p3_fin(p_res uuid) returns jsonb language sql stable as $$
  select to_jsonb(f) from private.rg_financials(array[p_res]) f $$;

-- ----------------------------------------------------------------------------- fixtures (desfeitas no fim)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_ornd uuid; v_arena uuid; v_arena2 uuid; v_arnd uuid; v_arena_b uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_cb uuid; v_cout uuid; v_cnd uuid;
  v_tag text := 'p3rb-' || substr(md5(clock_timestamp()::text), 1, 8);
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_fri date;
begin
  v_fri := (v_today + 7) + ((5 - extract(dow from v_today + 7)::int + 7) % 7);   -- sexta >= hoje+7
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'),
    (u_rec, v_tag || '-rec@reservagol.test'), (u_out, v_tag || '-out@reservagol.test');
  insert into public.organizations (name, is_demo) values ('P3A RB ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3A RB outra ' || v_tag, true) returning id into v_org2;
  insert into public.organizations (name, is_demo) values ('P3A RB real ' || v_tag, false) returning id into v_ornd;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE'), (v_ornd, u_owner, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'Arena ' || v_tag) returning id into v_arena;
  insert into public.arenas (organization_id, name) values (v_org, 'Arena B ' || v_tag) returning id into v_arena_b;
  insert into public.arenas (organization_id, name) values (v_org2, 'Arena outra ' || v_tag) returning id into v_arena2;
  insert into public.arenas (organization_id, name) values (v_ornd, 'Arena real ' || v_tag) returning id into v_arnd;
  -- 03C (setup apenas): horário de funcionamento explícito que cobre todos os horários materializados
  -- por esta suíte (08:00–19:00); 06:00–23:00 todos os dias. Nenhuma assertion alterada.
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select a.organization_id, a.id, w, '06:00', '23:00', false from public.arenas a cross join generate_series(0, 6) w
   where a.id in (v_arena, v_arena_b, v_arena2, v_arnd);
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena, 'Q3') returning id into v_c3;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_arena_b, 'QB') returning id into v_cb;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_arena2, 'Q outra') returning id into v_cout;
  insert into public.courts (organization_id, arena_id, name) values (v_ornd, v_arnd, 'Q real') returning id into v_cnd;
  insert into p3fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('org', v_org), ('org2', v_org2),
    ('ornd', v_ornd), ('arena', v_arena), ('arena_b', v_arena_b), ('arena2', v_arena2), ('arnd', v_arnd),
    ('c1', v_c1), ('c2', v_c2), ('c3', v_c3), ('cb', v_cb), ('c_out', v_cout), ('c_nd', v_cnd);
  insert into p3d values ('today', v_today), ('fri', v_fri);
end $$;

-- Regras base (via RPC, como OWNER): arena sexta 08–18 = 10000/h; sexta 18–24 = 17000/h;
-- sábado 00–02 = 20000/h; quadra Q2 sexta 18–20 = 30000/h (vence a arena).
do $$
declare r jsonb;
begin
  r := pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', null, array[5], '08:00', '18:00', 10000));
  insert into p3fx values ('r_fri_day', (r->'rule_ids'->>0)::uuid);
  r := pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', null, array[5], '18:00', '00:00', 17000));
  insert into p3fx values ('r_fri_night', (r->'rule_ids'->>0)::uuid);
  r := pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', null, array[6], '00:00', '02:00', 20000));
  insert into p3fx values ('r_sat_early', (r->'rule_ids'->>0)::uuid);
  r := pg_temp.p3_do('mgr', pg_temp.p3_rule_sql('arena', 'c2', array[5], '18:00', '20:00', 30000));
  insert into p3fx values ('r_c2_fri', (r->'rule_ids'->>0)::uuid);
end $$;

-- ----------------------------------------------------------------------------- Q: cotação
do $$
declare r jsonb;
begin
  r := pg_temp.p3_expect('Q01 sexta 17:30–19:00 (30 min a 10000 + 60 min a 17000)', 'rec',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '17:30'), pg_temp.p3_ts('fri', '19:00')), 'OK');
  perform pg_temp.p3_ok('Q01b 10000*30 + 17000*60 = 1320000; (1320000+30)/60 = 22000 centavos', (r->>'price')::int = 22000 and (r->>'covered')::boolean, r::text);
  r := pg_temp.p3_expect('Q02 cruza a meia-noite: sexta 23:00 -> sábado 01:00', 'owner',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '23:00'), pg_temp.p3_ts('fri', '01:00', 1)), 'OK');
  perform pg_temp.p3_ok('Q02b 17000*60 + 20000*60 = 2220000 -> 37000', (r->>'price')::int = 37000, r::text);
  r := pg_temp.p3_expect('Q03 quadra vence arena: Q2 sexta 17:30–19:00', 'owner',
    pg_temp.p3_quote_sql('c2', pg_temp.p3_ts('fri', '17:30'), pg_temp.p3_ts('fri', '19:00')), 'OK');
  perform pg_temp.p3_ok('Q03b 10000*30 (arena) + 30000*60 (quadra) = 2100000 -> 35000', (r->>'price')::int = 35000, r::text);
  r := pg_temp.p3_expect('Q04 quadra cobre parte, arena o resto: Q2 sexta 19:30–20:30', 'owner',
    pg_temp.p3_quote_sql('c2', pg_temp.p3_ts('fri', '19:30'), pg_temp.p3_ts('fri', '20:30')), 'OK');
  perform pg_temp.p3_ok('Q04b 30000*30 + 17000*30 = 1410000 -> 23500', (r->>'price')::int = 23500, r::text);
  r := pg_temp.p3_expect('Q05 cobertura parcial (07:30–08:30) => NULL', 'owner',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '07:30'), pg_temp.p3_ts('fri', '08:30')), 'OK');
  perform pg_temp.p3_ok('Q05b price NULL e covered=false', r->'price' = 'null'::jsonb and not (r->>'covered')::boolean, r::text);
  r := pg_temp.p3_expect('Q06 sábado 01:00 -> 03:00 (cobre só até 02:00) => NULL', 'owner',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '01:00', 1), pg_temp.p3_ts('fri', '03:00', 1)), 'OK');
  perform pg_temp.p3_ok('Q06b price NULL', r->'price' = 'null'::jsonb, r::text);
  perform pg_temp.p3_ok('Q07 00:00 => start_minute 0 / end_minute 1440',
    (select start_minute = 0 from public.court_pricing_rules where id = pg_temp.p3_id('r_sat_early'))
    and (select end_minute = 1440 from public.court_pricing_rules where id = pg_temp.p3_id('r_fri_night')), 'geradas');
  perform pg_temp.p3_expect('Q08 intervalo > 24h => 22023', 'owner',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '10:00'), pg_temp.p3_ts('fri', '10:01', 1)), '22023');
  perform pg_temp.p3_expect('Q09 fim <= início => 22023', 'owner',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '10:00'), pg_temp.p3_ts('fri', '10:00')), '22023');
  perform pg_temp.p3_expect('Q10 quadra de outra organização => P0002', 'out',
    pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '10:00'), pg_temp.p3_ts('fri', '11:00')), 'P0002');
  perform pg_temp.p3_expect('Q11 anon sem EXECUTE', 'anon', pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '10:00'), pg_temp.p3_ts('fri', '11:00')), '42501');
  perform pg_temp.p3_expect('Q12 service_role sem EXECUTE', 'service_role', pg_temp.p3_quote_sql('c1', pg_temp.p3_ts('fri', '10:00'), pg_temp.p3_ts('fri', '11:00')), '42501');
end $$;

-- half-up e validade (Q3 segunda/terça; segunda-feira e terça da semana da sexta de fixture)
do $$
declare r jsonb; mon date := pg_temp.p3_day('fri') + 3; tue date := pg_temp.p3_day('fri') + 4;
begin
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', 'c3', array[1], '10:00', '11:00', 10001));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', 'c3', array[1], '11:00', '12:00', 90));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', 'c3', array[1], '12:00', '13:00', 89));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', 'c3', array[2], '10:00', '11:00', 5000, tue + 7, null));
  r := pg_temp.p3_do('owner', format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id('c3'), (mon::text || ' 10:00:00-03:00')::timestamptz, (mon::text || ' 10:01:00-03:00')::timestamptz));
  perform pg_temp.p3_ok('Q13 half-up: 1 min a 10001/h = 166,68 -> 167', (r->>'price')::int = 167, r::text);
  r := pg_temp.p3_do('owner', format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id('c3'), (mon::text || ' 11:00:00-03:00')::timestamptz, (mon::text || ' 11:01:00-03:00')::timestamptz));
  perform pg_temp.p3_ok('Q14 half-up: 1 min a 90/h = 1,5 -> 2', (r->>'price')::int = 2, r::text);
  r := pg_temp.p3_do('owner', format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id('c3'), (mon::text || ' 12:00:00-03:00')::timestamptz, (mon::text || ' 12:01:00-03:00')::timestamptz));
  perform pg_temp.p3_ok('Q15 half-up: 1 min a 89/h = 1,48 -> 1', (r->>'price')::int = 1, r::text);
  r := pg_temp.p3_do('owner', format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id('c3'), (tue::text || ' 10:00:00-03:00')::timestamptz, (tue::text || ' 11:00:00-03:00')::timestamptz));
  perform pg_temp.p3_ok('Q16 validade futura: antes do valid_from => NULL', r->'price' = 'null'::jsonb, r::text);
  r := pg_temp.p3_do('owner', format('select public.rg_price_quote(%L::uuid, %L::timestamptz, %L::timestamptz)', pg_temp.p3_id('c3'), ((tue + 7)::text || ' 10:00:00-03:00')::timestamptz, ((tue + 7)::text || ' 11:00:00-03:00')::timestamptz));
  perform pg_temp.p3_ok('Q17 validade: a partir do valid_from => 5000', (r->>'price')::int = 5000, r::text);
end $$;

-- ----------------------------------------------------------------------------- X: criação atômica de faixa
do $$
declare r jsonb; v_before text; v_audit_before int; v_ids uuid[];
begin
  v_audit_before := (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED');
  r := pg_temp.p3_expect('X01 sexta 22:00 -> 02:00 (QB)', 'owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[5], '22:00', '02:00', 15000, pg_temp.p3_day('today'), null), 'OK');
  select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(r->'rule_ids') x;
  perform pg_temp.p3_ok('X01b 2 regras, split=true, dias consecutivos, mesmo preço/validade',
    (r->>'split')::boolean and cardinality(v_ids) = 2
    and exists (select 1 from public.court_pricing_rules where id = v_ids[1] and weekday = 5 and start_minute = 1320 and end_minute = 1440 and price_per_hour = 15000 and valid_from = pg_temp.p3_day('today'))
    and exists (select 1 from public.court_pricing_rules where id = v_ids[2] and weekday = 6 and start_minute = 0 and end_minute = 120 and price_per_hour = 15000 and valid_from = pg_temp.p3_day('today')), r::text);
  perform pg_temp.p3_ok('X07 UM audit por intenção (com rule_ids e split)',
    (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED') = v_audit_before + 1
    and exists (select 1 from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED'
                and (metadata->>'split')::boolean and jsonb_array_length(metadata->'rule_ids') = 2), 'audit');
  r := pg_temp.p3_expect('X02 quarta 22:00 -> 00:00 (QB)', 'owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[3], '22:00', '00:00', 15000), 'OK');
  perform pg_temp.p3_ok('X02b 1 regra, end_minute 1440, split=false', not (r->>'split')::boolean and jsonb_array_length(r->'rule_ids') = 1
    and exists (select 1 from public.court_pricing_rules where id = (r->'rule_ids'->>0)::uuid and end_minute = 1440), r::text);
  r := pg_temp.p3_expect('X03 quinta 00:00 -> 02:00 (QB)', 'owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[4], '00:00', '02:00', 15000), 'OK');
  perform pg_temp.p3_ok('X03b 1 regra, start_minute 0', jsonb_array_length(r->'rule_ids') = 1
    and exists (select 1 from public.court_pricing_rules where id = (r->'rule_ids'->>0)::uuid and start_minute = 0), r::text);
  -- conflito só na SEGUNDA metade: domingo 01:00–03:00 já existe; sábado 22:00 -> 02:00 falha inteira
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[0], '01:00', '03:00', 15000));
  perform pg_temp.p3_expect('X04 conflito só na 2ª metade => 23P01, nada permanece', 'owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[6], '22:00', '02:00', 15000), '23P01');
  perform pg_temp.p3_ok('X04b nenhuma linha sábado 22:00 ficou', not exists (select 1 from public.court_pricing_rules where court_id = pg_temp.p3_id('cb') and weekday = 6 and start_minute = 1320), 'ok');
  -- conflito só na PRIMEIRA metade: segunda 21:00–23:00 já existe; segunda 22:00 -> 01:00 falha inteira
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[1], '21:00', '23:00', 15000));
  perform pg_temp.p3_expect('X05 conflito só na 1ª metade => 23P01, nada permanece', 'owner', pg_temp.p3_rule_sql('arena_b', 'cb', array[1], '22:00', '01:00', 15000), '23P01');
  perform pg_temp.p3_ok('X05b nenhuma linha terça 00:00–01:00 ficou', not exists (select 1 from public.court_pricing_rules where court_id = pg_temp.p3_id('cb') and weekday = 2 and start_minute = 0), 'ok');
  perform pg_temp.p3_fault_case('X06 falha após o 1º INSERT da faixa split => rollback total', 'owner', 'pricing_create:after_first_insert',
    pg_temp.p3_rule_sql('arena_b', null, array[2], '23:00', '01:00', 12000));
  perform pg_temp.p3_expect('X08 início = fim => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', null, array[2], '10:00', '10:00', 12000), '22023');
end $$;

-- ----------------------------------------------------------------------------- Y: criação MULTI-DAY atômica
-- UMA ação (vários dias + uma faixa) = UMA transação: todos os dias ou nenhum; UM audit por intenção.
do $$
declare
  r jsonb; v_c text; v_rules_before int; v_audit_before int;
  k text;
begin
  foreach k in array array['cm1', 'cm2', 'cm3', 'cm4', 'cm5', 'cm6', 'cm7', 'cm8'] loop
    with ins as (
      insert into public.courts (organization_id, arena_id, name)
      values (pg_temp.p3_id('org'), pg_temp.p3_id('arena_b'), 'Q ' || k) returning id)
    insert into p3fx select k, ins.id from ins;
  end loop;

  -- Y01 [1,2,3,4] faixa normal => exatamente 4 regras
  v_audit_before := (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED');
  r := pg_temp.p3_expect('Y01 weekdays [1,2,3,4] 18:00–22:00', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm1', array[1, 2, 3, 4], '18:00', '22:00', 15000), 'OK');
  perform pg_temp.p3_ok('Y01b exatamente 4 regras (rule_ids, rules_created, linhas), split=false',
    jsonb_array_length(r->'rule_ids') = 4 and (r->>'rules_created')::int = 4 and not (r->>'split')::boolean
    and r->'weekdays' = '[1, 2, 3, 4]'::jsonb
    and (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm1')) = 4
    and (select array_agg(weekday order by weekday) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm1')) = array[1, 2, 3, 4]::smallint[], r::text);
  perform pg_temp.p3_ok('Y11 exatamente UM audit para a intenção multi-day (weekdays, rules_created, rule_ids)',
    (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED') = v_audit_before + 1
    and exists (select 1 from public.audit_logs where organization_id = pg_temp.p3_id('org') and action = 'PRICING_RULE_CREATED'
                and metadata->'weekdays' = '[1, 2, 3, 4]'::jsonb and (metadata->>'rules_created')::int = 4
                and jsonb_array_length(metadata->'rule_ids') = 4), 'audit');

  -- Y02 [1,2,3,4] cross-midnight => exatamente 8 regras (dia [start,1440) + dia seguinte [0,end))
  r := pg_temp.p3_expect('Y02 weekdays [1,2,3,4] 22:00 -> 02:00', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm2', array[1, 2, 3, 4], '22:00', '02:00', 15000), 'OK');
  perform pg_temp.p3_ok('Y02b exatamente 8 regras, split=true, metades nos dias seguintes',
    jsonb_array_length(r->'rule_ids') = 8 and (r->>'rules_created')::int = 8 and (r->>'split')::boolean
    and (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm2') and start_minute = 1320 and end_minute = 1440) = 4
    and (select array_agg(weekday order by weekday) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm2') and start_minute = 0 and end_minute = 120) = array[2, 3, 4, 5]::smallint[], r::text);

  -- Y03 ordem normalizada deterministicamente no banco
  r := pg_temp.p3_expect('Y03 weekdays [4,2] normalizados', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm3', array[4, 2], '08:00', '09:00', 1000), 'OK');
  perform pg_temp.p3_ok('Y03b weekdays = [2,4]', r->'weekdays' = '[2, 4]'::jsonb, r::text);

  -- Conflitos: ZERO regras novas (e zero audit) em qualquer posição
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cm4', array[1], '19:00', '20:00', 1000));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cm5', array[3], '19:00', '20:00', 1000));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cm6', array[4], '19:00', '20:00', 1000));
  perform pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena_b', 'cm7', array[5], '01:00', '03:00', 1000));
  foreach v_c in array array['cm4', 'cm5', 'cm6'] loop
    v_rules_before := (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id(v_c));
    perform pg_temp.p3_expect(format('Y%s conflito no %s weekday => 23P01', case v_c when 'cm4' then '04' when 'cm5' then '05' else '06' end,
      case v_c when 'cm4' then 'PRIMEIRO' when 'cm5' then 'INTERMEDIÁRIO' else 'ÚLTIMO' end),
      'owner', pg_temp.p3_rule_sql('arena_b', v_c, array[1, 2, 3, 4], '18:00', '22:00', 15000), '23P01');
    perform pg_temp.p3_ok(format('Y%sb zero regras novas em %s', case v_c when 'cm4' then '04' when 'cm5' then '05' else '06' end, v_c),
      (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id(v_c)) = v_rules_before, v_c);
  end loop;
  v_rules_before := (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm7'));
  perform pg_temp.p3_expect('Y07 conflito só na 2ª metade do ÚLTIMO dia cross-midnight => 23P01', 'owner',
    pg_temp.p3_rule_sql('arena_b', 'cm7', array[1, 2, 3, 4], '22:00', '02:00', 15000), '23P01');
  perform pg_temp.p3_ok('Y07b zero regras novas em cm7', (select count(*) from public.court_pricing_rules where court_id = pg_temp.p3_id('cm7')) = v_rules_before, 'cm7');

  -- Falha injetada em cada ponto: estado idêntico (zero regras, zero audit) + controle OK
  perform pg_temp.p3_fault_case('Y08 falha after_first_insert (multi-day split) => nada', 'owner', 'pricing_create:after_first_insert',
    pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, 2, 3, 4], '22:00', '02:00', 15000));
  perform pg_temp.p3_fault_case('Y09 falha midway (multi-day split) => nada', 'owner', 'pricing_create:midway',
    pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, 2, 3, 4], '22:00', '02:00', 15000));
  perform pg_temp.p3_fault_case('Y10 falha after_all_inserts (multi-day) => nada', 'owner', 'pricing_create:after_all_inserts',
    pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, 2, 3, 4], '18:00', '22:00', 15000));
  perform pg_temp.p3_fault_case('Y12 falha after_audit (multi-day) => zero regras e zero audit', 'owner', 'pricing_create:after_audit',
    pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, 2, 3, 4], '18:00', '22:00', 15000));

  -- Validação de weekdays (22023): duplicados, vazio, fora de 0..6, NULL, mais de 7
  perform pg_temp.p3_expect('Y13 weekdays duplicados => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, 1, 2], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y14 weekdays vazio => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[]::integer[], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y15 weekday 7 => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[7], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y16 weekday -1 => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[-1], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y17 weekdays NULL => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', null::integer[], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y18 weekday NULL dentro do array => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[1, null], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_expect('Y19 mais de 7 dias => 22023', 'owner', pg_temp.p3_rule_sql('arena_b', 'cm8', array[0, 1, 2, 3, 4, 5, 6, 0], '10:00', '11:00', 1000), '22023');
  perform pg_temp.p3_ok('Y20 cm8 continua sem nenhuma regra', not exists (select 1 from public.court_pricing_rules where court_id = pg_temp.p3_id('cm8')), 'cm8');
end $$;

-- ----------------------------------------------------------------------------- R: regras (permissões e integridade)
do $$
declare r jsonb; v_rule uuid; v_nd uuid;
begin
  perform pg_temp.p3_expect('R01 RECEPTIONIST cria regra => 42501', 'rec', pg_temp.p3_rule_sql('arena', null, array[0], '08:00', '09:00', 1000), '42501');
  perform pg_temp.p3_expect('R02 OWNER de outra org => P0002', 'out', pg_temp.p3_rule_sql('arena', null, array[0], '08:00', '09:00', 1000), 'P0002');
  perform pg_temp.p3_expect('R03 anon sem EXECUTE', 'anon', pg_temp.p3_rule_sql('arena', null, array[0], '08:00', '09:00', 1000), '42501');
  perform pg_temp.p3_expect('R04 service_role sem EXECUTE', 'service_role', pg_temp.p3_rule_sql('arena', null, array[0], '08:00', '09:00', 1000), '42501');
  perform pg_temp.p3_expect('R05 quadra de outra arena da mesma org => P0002', 'owner', pg_temp.p3_rule_sql('arena', 'cb', array[0], '08:00', '09:00', 1000), 'P0002');
  perform pg_temp.p3_expect('R06 sobreposição no mesmo escopo => 23P01', 'owner', pg_temp.p3_rule_sql('arena', null, array[5], '17:00', '19:00', 1000), '23P01');
  r := pg_temp.p3_expect('R07 ARENA e COURT na mesma faixa coexistem', 'owner', pg_temp.p3_rule_sql('arena', 'c1', array[5], '08:00', '09:00', 11000), 'OK');
  v_rule := (r->'rule_ids'->>0)::uuid;
  perform pg_temp.p3_expect('R08 UPDATE atravessando a meia-noite => 22023', 'owner', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"end_time":"07:00"}'), '22023');
  perform pg_temp.p3_expect('R09 UPDATE com chave estrutural => 22023', 'owner', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"weekday":1}'), '22023');
  perform pg_temp.p3_expect('R10 RECEPTIONIST update => 42501', 'rec', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"price_per_hour":1}'), '42501');
  perform pg_temp.p3_expect('R11 MANAGER update preço', 'mgr', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"price_per_hour":11500}'), 'OK');
  perform pg_temp.p3_expect('R12 desativar', 'mgr', format('select public.rg_pricing_rule_deactivate(%L::uuid)', v_rule), 'OK');
  r := pg_temp.p3_expect('R13 desativar de novo = no-op', 'mgr', format('select public.rg_pricing_rule_deactivate(%L::uuid)', v_rule), 'OK');
  perform pg_temp.p3_ok('R13b changed=false', not (r->>'changed')::boolean, r::text);
  perform pg_temp.p3_expect('R14 update de regra desativada => RGP01', 'owner', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"price_per_hour":1}'), 'RGP01', 'RULE_INACTIVE');
  perform pg_temp.p3_expect('R15 reativar direto (postgres) => RGP01 (terminal)', 'postgres', format('update public.court_pricing_rules set active = true where id = %L::uuid returning jsonb_build_object(''id'', id)', v_rule), 'RGP01');
  perform pg_temp.p3_expect('R16 INSERT direto por authenticated => 42501', 'owner', format(
    'insert into public.court_pricing_rules (organization_id, arena_id, weekday, start_time, end_time, price_per_hour) values (%L, %L, 0, ''06:00'', ''07:00'', 1) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena')), '42501');
  perform pg_temp.p3_expect('R17 UPDATE direto por authenticated => 42501', 'owner', format('update public.court_pricing_rules set price_per_hour = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.p3_id('r_fri_day')), '42501');
  perform pg_temp.p3_expect('R18 coluna gerada scope_kind não é gravável', 'postgres', format(
    'insert into public.court_pricing_rules (organization_id, arena_id, scope_kind, weekday, start_time, end_time, price_per_hour) values (%L, %L, ''COURT'', 0, ''06:00'', ''07:00'', 1) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena')), '428C9');
  perform pg_temp.p3_expect('R19 mudar escopo (court_id) direto => RGT02', 'postgres', format('update public.court_pricing_rules set court_id = %L::uuid where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.p3_id('c1'), pg_temp.p3_id('r_fri_day')), 'RGT02');
  perform pg_temp.p3_expect('R20 regra com quadra de outra org (postgres) => RGT01', 'postgres', format(
    'insert into public.court_pricing_rules (organization_id, arena_id, court_id, weekday, start_time, end_time, price_per_hour) values (%L, %L, %L, 0, ''06:00'', ''07:00'', 1) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c_out')), 'RGT01');
  insert into public.court_pricing_rules (organization_id, arena_id, weekday, start_time, end_time, price_per_hour)
  values (pg_temp.p3_id('ornd'), pg_temp.p3_id('arnd'), 0, '06:00', '07:00', 1) returning id into v_nd;
  perform pg_temp.p3_expect('R21 service_role DELETE em org NÃO demo => 42501', 'service_role', format('delete from public.court_pricing_rules where id = %L::uuid returning jsonb_build_object(''id'', id)', v_nd), '42501');
  perform pg_temp.p3_expect('R22 authenticated DELETE => 42501', 'owner', format('delete from public.court_pricing_rules where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.p3_id('r_fri_day')), '42501');
  perform pg_temp.p3_ok('R23 SELECT de regras: recepção lê (RLS membro)', (select (pg_temp.p3_do('rec', format('select to_jsonb(count(*)) from public.court_pricing_rules where organization_id = %L', pg_temp.p3_id('org'))))::text::int) > 0, 'rec');
  perform pg_temp.p3_ok('R24 SELECT de regras: outra org não lê', (select (pg_temp.p3_do('out', format('select to_jsonb(count(*)) from public.court_pricing_rules where organization_id = %L', pg_temp.p3_id('org'))))::text::int) = 0, 'out');
end $$;

-- ----------------------------------------------------------------------------- S: snapshot automático
do $$
declare r jsonb; v_id uuid; v_s1 uuid; v_s2 uuid; fri date := pg_temp.p3_day('fri');
begin
  perform pg_temp.p3_ok('S01 private.rg_price_quote sem EXECUTE para anon/authenticated/service_role',
    not has_function_privilege('anon', 'private.rg_price_quote(uuid,timestamptz,timestamptz)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.rg_price_quote(uuid,timestamptz,timestamptz)', 'EXECUTE')
    and not has_function_privilege('service_role', 'private.rg_price_quote(uuid,timestamptz,timestamptz)', 'EXECUTE'), 'acl');
  perform pg_temp.p3_expect('S02 authenticated chamando private.rg_price_quote => 42501', 'owner',
    format('select to_jsonb(q) from private.rg_price_quote(%L::uuid, now(), now() + interval ''1 hour'') q', pg_temp.p3_id('c1')), '42501');
  perform pg_temp.p3_expect('S03 anon chamando private.rg_price_quote => 42501', 'anon',
    format('select to_jsonb(q) from private.rg_price_quote(%L::uuid, now(), now() + interval ''1 hour'') q', pg_temp.p3_id('c1')), '42501');
  perform pg_temp.p3_expect('S04 service_role chamando private.rg_price_quote => 42501', 'service_role',
    format('select to_jsonb(q) from private.rg_price_quote(%L::uuid, now(), now() + interval ''1 hour'') q', pg_temp.p3_id('c1')), '42501');
  perform pg_temp.p3_ok('S05 snapshot SECURITY DEFINER, owner postgres, search_path vazio',
    (select prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""']
       from pg_proc where oid = 'private.enforce_reservation_price_snapshot()'::regprocedure), 'pg_proc');
  -- INSERT direto por authenticated sem price: o snapshot funciona SEM EXECUTE do chamador na função privada
  r := pg_temp.p3_expect('S06 INSERT authenticated sem price recebe snapshot', 'rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, created_by) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', %L) returning jsonb_build_object(''id'', id, ''price'', price)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.p3_ts('fri', '17:30'), pg_temp.p3_ts('fri', '19:00'), pg_temp.p3_id('rec')), 'OK');
  perform pg_temp.p3_ok('S06b price = 22000', (r->>'price')::int = 22000, r::text);
  r := pg_temp.p3_expect('S07 INSERT service_role sem price (reserva pública) recebe snapshot', 'service_role', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, public_code) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''PUBLIC_WEB'', %L) returning jsonb_build_object(''id'', id, ''price'', price)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.p3_ts('fri', '23:00'), pg_temp.p3_ts('fri', '01:00', 1), 'RG-P3A' || substr(md5(random()::text), 1, 10)), 'OK');
  perform pg_temp.p3_ok('S07b pública atravessando a meia-noite: price = 37000', (r->>'price')::int = 37000, r::text);
  v_id := pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '10:00', 7), pg_temp.p3_ts('fri', '11:00', 7), 'BLOCKED');
  perform pg_temp.p3_ok('S08 BLOCKED não é precificado', (select price is null from public.reservations where id = v_id), 'blocked');
  v_id := pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '06:00', 7), pg_temp.p3_ts('fri', '07:00', 7));
  perform pg_temp.p3_ok('S09 sem regra => price NULL', (select price is null from public.reservations where id = v_id), 'unpriced');
  -- ocorrência recorrente: o snapshot NÃO interfere (D7 é a autoridade): default_price NULL => NULL
  r := pg_temp.p3_do('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', 5, null, ''08:00''::time, ''09:00''::time, %L::date, null, true, null, null, true, false, %L::date[])',
    gen_random_uuid(), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), '{"name":"Mensalista P3A"}', pg_temp.p3_day('today'), array[fri]));
  v_s1 := (r->>'series_id')::uuid;
  insert into p3fx values ('s_null', v_s1);
  perform pg_temp.p3_ok('S10 ocorrência de série com default_price NULL fica NULL (regra da arena existe)',
    (select price is null from public.reservations where recurring_reservation_id = v_s1 and occurrence_date = fri), 'recorrente');
  r := pg_temp.p3_do('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', 5, null, ''09:00''::time, ''10:00''::time, %L::date, null, true, 12345, null, true, false, %L::date[])',
    gen_random_uuid(), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), '{"name":"Mensalista P3A 2"}', pg_temp.p3_day('today'), array[fri]));
  v_s2 := (r->>'series_id')::uuid;
  insert into p3fx values ('s_price', v_s2);
  perform pg_temp.p3_ok('S11 ocorrência mantém default_price (12345), não a tabela',
    (select price = 12345 from public.reservations where recurring_reservation_id = v_s2 and occurrence_date = fri), 'recorrente');
end $$;

-- ----------------------------------------------------------------------------- P: pagamentos
do $$
declare
  r jsonb; v_res uuid; v_p1 uuid; v_p2 uuid; v_ref uuid; v_other uuid; v_at timestamptz := now() - interval '1 hour';
begin
  v_res := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '10:00', 7), pg_temp.p3_ts('fri', '11:00', 7), 'CONFIRMED', 20000);
  insert into p3fx values ('resA', v_res);
  r := pg_temp.p3_expect('P01 RECEPTIONIST registra PIX 5000', 'rec', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 5000, v_at), 'OK');
  v_p1 := (r->>'payment_id')::uuid; insert into p3fx values ('p1', v_p1);
  r := pg_temp.p3_expect('P01b detalhe para a recepção (uma reserva) com valores', 'rec', pg_temp.p3_detail_sql(v_res), 'OK');
  perform pg_temp.p3_ok('P01c PARTIAL: due 20000, received 5000, collectible_balance 15000',
    r->>'payment_status' = 'PARTIAL' and (r->>'amount_due')::int = 20000 and (r->>'net_received')::int = 5000 and (r->>'collectible_balance')::int = 15000
    and jsonb_array_length(r->'entries') = 1 and not (r->'entries'->0 ? 'operation_fingerprint'), r::text);
  r := pg_temp.p3_expect('P02 OWNER registra dinheiro 15000', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'CASH', 15000, v_at), 'OK');
  v_p2 := (r->>'payment_id')::uuid; insert into p3fx values ('p2', v_p2);
  perform pg_temp.p3_ok('P02b 50 + 150 = PAID, balance 0', pg_temp.p3_fin(v_res)->>'payment_status' = 'PAID' and (pg_temp.p3_fin(v_res)->>'balance')::int = 0, pg_temp.p3_fin(v_res)::text);
  perform pg_temp.p3_expect('P03 sobrepagamento => RGP03', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 1, v_at), 'RGP03', 'OVER_BALANCE');
  v_other := pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '07:00', 14), pg_temp.p3_ts('fri', '07:30', 14));
  perform pg_temp.p3_expect('P04 reserva sem preço => RGP01', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_other, 'PIX', 100, v_at), 'RGP01', 'UNPRICED');
  v_other := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '10:00', 14), pg_temp.p3_ts('fri', '11:00', 14), 'BLOCKED');
  perform pg_temp.p3_expect('P05 bloqueio => RGP01', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_other, 'PIX', 100, v_at), 'RGP01', 'RESERVATION_STATE');
  v_other := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '11:00', 14), pg_temp.p3_ts('fri', '12:00', 14), 'CANCELLED', 10000);
  perform pg_temp.p3_expect('P06 reserva cancelada => RGP01', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_other, 'PIX', 100, v_at), 'RGP01', 'RESERVATION_STATE');
  v_other := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '12:00', 14), pg_temp.p3_ts('fri', '13:00', 14), 'CONFIRMED', 10000);
  insert into p3fx values ('resB', v_other);
  perform pg_temp.p3_expect('P07 received_at no futuro (+10 min) => 23514', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_other, 'PIX', 100, now() + interval '10 minutes'), '23514');
  perform pg_temp.p3_expect('P08 received_at muito antigo é aceito (sem limite inferior)', 'owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_other, 'PIX', 100, '2020-01-01 10:00:00-03'::timestamptz), 'OK');
  perform pg_temp.p3_expect('P09 RECEPTIONIST estorna => 42501', 'rec', pg_temp.p3_refund_sql(gen_random_uuid(), v_p2, 'CASH', 100, v_at), '42501');
  perform pg_temp.p3_expect('P10 estorno acima do pagamento => RGP03', 'mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_p1, 'PIX', 5001, v_at), 'RGP03', 'OVER_REFUNDABLE');
  r := pg_temp.p3_expect('P11 MANAGER estorna 3000 do PIX', 'mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_p1, 'PIX', 3000, v_at), 'OK');
  v_ref := (r->>'payment_id')::uuid; insert into p3fx values ('ref1', v_ref);
  perform pg_temp.p3_ok('P11b PARTIAL após estorno (net 17000)', pg_temp.p3_fin(v_res)->>'payment_status' = 'PARTIAL' and (pg_temp.p3_fin(v_res)->>'net_received')::int = 17000, pg_temp.p3_fin(v_res)::text);
  perform pg_temp.p3_expect('P12 estornos somados acima do pagamento => RGP03', 'mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_p1, 'PIX', 2001, v_at), 'RGP03', 'OVER_REFUNDABLE');
  perform pg_temp.p3_expect('P13 estorno de um ESTORNO (RPC) => RGP01', 'mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_ref, 'PIX', 1, v_at), 'RGP01', 'NOT_A_PAYMENT');
  perform pg_temp.p3_expect('P14 refund_of apontando para REFUND (postgres direto) => 23514', 'postgres', format(
    'insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, refund_of, method, amount, received_at, operation_id, operation_fingerprint) values (%L, %L, %L, ''REFUND'', %L, ''PIX'', 1, now(), gen_random_uuid(), sha256(''x''::bytea)) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), v_res, v_ref), '23514');
  perform pg_temp.p3_expect('P15 refund_of de OUTRA reserva (postgres direto) => 23514', 'postgres', format(
    'insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, refund_of, method, amount, received_at, operation_id, operation_fingerprint) values (%L, %L, %L, ''REFUND'', %L, ''PIX'', 1, now(), gen_random_uuid(), sha256(''x''::bytea)) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('resB'), v_p1), '23514');
  perform pg_temp.p3_expect('P16 lançamento com arena diferente da reserva => RGT01', 'postgres', format(
    'insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, method, amount, received_at, operation_id, operation_fingerprint) values (%L, %L, %L, ''PAYMENT'', ''PIX'', 1, now(), gen_random_uuid(), sha256(''x''::bytea)) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena_b'), v_res), 'RGT01');
  perform pg_temp.p3_expect('P17 VOID de pagamento com estorno válido => RGP01', 'mgr', pg_temp.p3_void_sql(v_p1, 'teste'), 'RGP01', 'HAS_REFUNDS');
  perform pg_temp.p3_expect('P18 RECEPTIONIST anula => 42501', 'rec', pg_temp.p3_void_sql(v_ref, 'teste'), '42501');
  perform pg_temp.p3_expect('P19 VOID sem motivo => 22023', 'mgr', pg_temp.p3_void_sql(v_ref, '   '), '22023');
  perform pg_temp.p3_expect('P20 VOID do estorno', 'mgr', pg_temp.p3_void_sql(v_ref, 'estorno lançado por engano'), 'OK');
  perform pg_temp.p3_ok('P20b estorno anulado restaura o saldo (PAID de novo)', pg_temp.p3_fin(v_res)->>'payment_status' = 'PAID', pg_temp.p3_fin(v_res)::text);
  perform pg_temp.p3_expect('P21 VOID do pagamento (sem estorno válido)', 'owner', pg_temp.p3_void_sql(v_p1, 'pix duplicado'), 'OK');
  r := pg_temp.p3_expect('P22 VOID repetido = no-op', 'owner', pg_temp.p3_void_sql(v_p1, 'de novo'), 'OK');
  perform pg_temp.p3_ok('P22b changed=false', not (r->>'changed')::boolean, r::text);
  perform pg_temp.p3_expect('P23 estorno de pagamento anulado => RGP01', 'mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_p1, 'PIX', 1, v_at), 'RGP01', 'PAYMENT_VOIDED');
end $$;

-- matriz de payment_status (D3) e set_price
do $$
declare v_res uuid; v_pay uuid; r jsonb; v_occ uuid; v_at timestamptz := now() - interval '1 hour'; v_fin jsonb;
begin
  -- CANCELLED (nunca recebeu)
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '14:00', 14), pg_temp.p3_ts('fri', '15:00', 14), 'CANCELLED', 20000);
  perform pg_temp.p3_ok('M01 cancelada sem dinheiro => CANCELLED, collectible_balance 0',
    pg_temp.p3_fin(v_res)->>'payment_status' = 'CANCELLED' and (pg_temp.p3_fin(v_res)->>'collectible_balance')::int = 0, pg_temp.p3_fin(v_res)::text);
  -- RETAINED (200 recebidos, 150 estornados, net 50) e REFUNDED
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '15:00', 14), pg_temp.p3_ts('fri', '16:00', 14), 'CONFIRMED', 20000);
  r := pg_temp.p3_do('owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 20000, v_at));
  v_pay := (r->>'payment_id')::uuid;
  update public.reservations set status = 'CANCELLED' where id = v_res;
  perform pg_temp.p3_ok('M02 price continua 20000 após cancelar (snapshot histórico)', (select price = 20000 from public.reservations where id = v_res), 'snapshot');
  perform pg_temp.p3_do('mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_pay, 'PIX', 15000, v_at));
  v_fin := pg_temp.p3_fin(v_res);
  perform pg_temp.p3_ok('M03 200 / 150 estornado / net 50 / CANCELLED => RETAINED, collectible_balance 0',
    v_fin->>'payment_status' = 'RETAINED' and (v_fin->>'net_received')::int = 5000 and (v_fin->>'collectible_balance')::int = 0 and not (v_fin->>'collectible')::boolean, v_fin::text);
  perform pg_temp.p3_do('mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_pay, 'PIX', 5000, v_at));
  perform pg_temp.p3_ok('M04 estorno total após cancelamento => REFUNDED', pg_temp.p3_fin(v_res)->>'payment_status' = 'REFUNDED', pg_temp.p3_fin(v_res)::text);
  -- preço zero + net zero => PAID
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '16:00', 14), pg_temp.p3_ts('fri', '17:00', 14), 'CONFIRMED', 0);
  perform pg_temp.p3_ok('M05 price 0 e net 0 => PAID', pg_temp.p3_fin(v_res)->>'payment_status' = 'PAID', pg_temp.p3_fin(v_res)::text);
  -- PENDING / NO_SHOW cobrável / UNPRICED / NOT_APPLICABLE
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '17:00', 14), pg_temp.p3_ts('fri', '18:00', 14), 'NO_SHOW', 9000);
  perform pg_temp.p3_ok('M06 NO_SHOW continua cobrável => PENDING, collectible_balance 9000',
    pg_temp.p3_fin(v_res)->>'payment_status' = 'PENDING' and (pg_temp.p3_fin(v_res)->>'collectible_balance')::int = 9000, pg_temp.p3_fin(v_res)::text);
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '06:00', 14), pg_temp.p3_ts('fri', '07:00', 14));
  perform pg_temp.p3_ok('M07 sem preço => UNPRICED', pg_temp.p3_fin(v_res)->>'payment_status' = 'UNPRICED', pg_temp.p3_fin(v_res)::text);
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '07:00', 14), pg_temp.p3_ts('fri', '08:00', 14), 'BLOCKED');
  perform pg_temp.p3_ok('M08 bloqueio => NOT_APPLICABLE', pg_temp.p3_fin(v_res)->>'payment_status' = 'NOT_APPLICABLE', pg_temp.p3_fin(v_res)::text);
  -- OVERPAID via set_price
  v_res := pg_temp.p3_res('c3', pg_temp.p3_ts('fri', '18:00', 14), pg_temp.p3_ts('fri', '19:00', 14), 'CONFIRMED', 10000);
  perform pg_temp.p3_do('owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 10000, v_at));
  perform pg_temp.p3_expect('M09 RECEPTIONIST set_price => 42501', 'rec', pg_temp.p3_price_sql(v_res, 'MANUAL', 8000, 'DISCOUNT'), '42501');
  perform pg_temp.p3_expect('M10 MANAGER reduz o valor para 8000', 'mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', 8000, 'DISCOUNT'), 'OK');
  perform pg_temp.p3_ok('M10b => OVERPAID', pg_temp.p3_fin(v_res)->>'payment_status' = 'OVERPAID', pg_temp.p3_fin(v_res)::text);
  perform pg_temp.p3_ok('M10c audit RESERVATION_PRICE_SET com motivo em CÓDIGO (sem texto livre)',
    exists (select 1 from public.audit_logs where entity_id = v_res and action = 'RESERVATION_PRICE_SET' and metadata->>'reason' = 'DISCOUNT' and (metadata->>'old_price')::int = 10000), 'audit');
  perform pg_temp.p3_expect('M11 NULL com dinheiro recebido => RGP01', 'mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', null, 'CORRECTION'), 'RGP01', 'PRICE_REQUIRED');
  r := pg_temp.p3_expect('M12 mesmo valor = no-op', 'mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', 8000, 'CORRECTION'), 'OK');
  perform pg_temp.p3_ok('M12b changed=false', not (r->>'changed')::boolean, r::text);
  perform pg_temp.p3_expect('M13 motivo em texto livre => 22023', 'mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', 7000, 'cliente João pediu'), '22023');
  perform pg_temp.p3_expect('M14 RULE sem cobertura => RGP01', 'mgr', pg_temp.p3_price_sql(pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '05:00', 21), pg_temp.p3_ts('fri', '06:00', 21)), 'RULE', null, 'RULE_RECALC'), 'RGP01', 'NO_RULE');
  v_res := pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '12:00', 21), pg_temp.p3_ts('fri', '13:00', 21), 'CONFIRMED', 1);
  r := pg_temp.p3_expect('M15 RULE recalcula no servidor (10000)', 'owner', pg_temp.p3_price_sql(v_res, 'RULE', 999999, 'RULE_RECALC'), 'OK');
  perform pg_temp.p3_ok('M15b price = 10000 (p_price ignorado em RULE)', (r->>'price')::int = 10000, r::text);
  perform pg_temp.p3_expect('M16 set_price em bloqueio => RGP01', 'owner', pg_temp.p3_price_sql(pg_temp.p3_res('c1', pg_temp.p3_ts('fri', '13:00', 21), pg_temp.p3_ts('fri', '14:00', 21), 'BLOCKED'), 'MANUAL', 100, 'CORRECTION'), 'RGP01', 'BLOCKED');
  -- set_price legítimo em ocorrência recorrente (âncora e is_exception intactos)
  select id into v_occ from public.reservations where recurring_reservation_id = pg_temp.p3_id('s_price') order by occurrence_date limit 1;
  insert into p3fx values ('occ', v_occ);
  perform pg_temp.p3_expect('M17 set_price por MANAGER em ocorrência recorrente', 'mgr', pg_temp.p3_price_sql(v_occ, 'MANUAL', 15000, 'CORRECTION'), 'OK');
  perform pg_temp.p3_ok('M17b preço 15000, is_exception=false, âncora igual',
    (select price = 15000 and not is_exception and occurrence_date = pg_temp.p3_day('fri') from public.reservations where id = v_occ), 'occ');
end $$;

-- ----------------------------------------------------------------------------- I: idempotência (D9)
do $$
declare
  v_res uuid; v_res2 uuid; v_op uuid := gen_random_uuid(); v_op2 uuid := gen_random_uuid(); v_op3 uuid := gen_random_uuid();
  v_at timestamptz := now() - interval '2 hours'; r jsonb; r2 jsonb; v_pay uuid; v_audit int; v_ref uuid; v_other uuid;
begin
  v_res := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '10:00', 21), pg_temp.p3_ts('fri', '11:00', 21), 'CONFIRMED', 30000);
  v_res2 := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '11:00', 21), pg_temp.p3_ts('fri', '12:00', 21), 'CONFIRMED', 30000);
  r := pg_temp.p3_expect('I01 pagamento novo', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, '  nota  '), 'OK');
  v_pay := (r->>'payment_id')::uuid;
  v_audit := (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org'));
  r2 := pg_temp.p3_expect('I02 replay mesma intenção (notas normalizadas)', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, 'nota'), 'OK');
  perform pg_temp.p3_ok('I02b idempotent=true, mesmo payment_id, sem novo audit',
    (r2->>'idempotent')::boolean and (r2->>'payment_id')::uuid = v_pay
    and (select count(*) from public.audit_logs where organization_id = pg_temp.p3_id('org')) = v_audit, r2::text);
  perform pg_temp.p3_expect('I03 mesmo op + amount diferente => RGP02', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10001, v_at, 'nota'), 'RGP02');
  perform pg_temp.p3_expect('I04 mesmo op + method diferente => RGP02', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'CASH', 10000, v_at, 'nota'), 'RGP02');
  perform pg_temp.p3_expect('I05 mesmo op + received_at diferente => RGP02', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at + interval '1 second', 'nota'), 'RGP02');
  perform pg_temp.p3_expect('I06 mesmo op + notes diferente => RGP02', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, 'outra'), 'RGP02');
  perform pg_temp.p3_expect('I07 mesmo op em OUTRA reserva => RGP02', 'rec', pg_temp.p3_pay_sql(v_op, v_res2, 'PIX', 10000, v_at, 'nota'), 'RGP02');
  perform pg_temp.p3_expect('I08 op de PAYMENT reutilizado em REFUND => RGP02', 'mgr', pg_temp.p3_refund_sql(v_op, v_pay, 'PIX', 10000, v_at, 'nota'), 'RGP02');
  -- replay depois de mudanças de estado (a operação original já aconteceu)
  perform pg_temp.p3_do('owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'CASH', 20000, v_at));   -- quita o saldo
  r2 := pg_temp.p3_expect('I09 replay após outro pagamento quitar o saldo', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, 'nota'), 'OK');
  perform pg_temp.p3_ok('I09b idempotent', (r2->>'idempotent')::boolean and (r2->>'payment_id')::uuid = v_pay, r2::text);
  perform pg_temp.p3_do('mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', 5000, 'DISCOUNT'));
  r2 := pg_temp.p3_expect('I10 replay após mudança de preço', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, 'nota'), 'OK');
  perform pg_temp.p3_ok('I10b idempotent', (r2->>'idempotent')::boolean, r2::text);
  update public.reservations set status = 'CANCELLED' where id = v_res;
  r2 := pg_temp.p3_expect('I11 replay após cancelamento', 'rec', pg_temp.p3_pay_sql(v_op, v_res, 'PIX', 10000, v_at, 'nota'), 'OK');
  perform pg_temp.p3_ok('I11b idempotent', (r2->>'idempotent')::boolean, r2::text);
  -- estorno: replay após esgotar a capacidade e após VOID do próprio pagamento
  r := pg_temp.p3_do('mgr', pg_temp.p3_refund_sql(v_op2, v_pay, 'PIX', 4000, v_at));
  v_ref := (r->>'payment_id')::uuid;
  perform pg_temp.p3_do('mgr', pg_temp.p3_refund_sql(gen_random_uuid(), v_pay, 'PIX', 6000, v_at));   -- esgota os 10000
  r2 := pg_temp.p3_expect('I12 replay de estorno após esgotar a capacidade', 'mgr', pg_temp.p3_refund_sql(v_op2, v_pay, 'PIX', 4000, v_at), 'OK');
  perform pg_temp.p3_ok('I12b idempotent, mesmo id', (r2->>'idempotent')::boolean and (r2->>'payment_id')::uuid = v_ref, r2::text);
  perform pg_temp.p3_expect('I13 estorno com intenção diferente => RGP02 (não erro de estado)', 'mgr', pg_temp.p3_refund_sql(v_op2, v_pay, 'PIX', 4001, v_at), 'RGP02');
  v_other := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '12:00', 21), pg_temp.p3_ts('fri', '13:00', 21), 'CONFIRMED', 30000);
  r := pg_temp.p3_do('rec', pg_temp.p3_pay_sql(v_op3, v_other, 'PIX', 1000, v_at));
  perform pg_temp.p3_do('mgr', pg_temp.p3_void_sql((r->>'payment_id')::uuid, 'teste de replay'));
  r2 := pg_temp.p3_expect('I14 replay após VOID do próprio lançamento', 'rec', pg_temp.p3_pay_sql(v_op3, v_other, 'PIX', 1000, v_at), 'OK');
  perform pg_temp.p3_ok('I14b idempotent, mesmo id', (r2->>'idempotent')::boolean and (r2->>'payment_id') = (r->>'payment_id'), r2::text);
  -- autorização é a ATUAL: MANAGER rebaixado não consegue nem o replay do estorno
  update public.organization_members set role = 'RECEPTIONIST' where organization_id = pg_temp.p3_id('org') and user_id = pg_temp.p3_id('mgr');
  perform pg_temp.p3_expect('I15 replay de estorno por quem perdeu o papel => 42501', 'mgr', pg_temp.p3_refund_sql(v_op2, v_pay, 'PIX', 4000, v_at), '42501');
  update public.organization_members set role = 'MANAGER' where organization_id = pg_temp.p3_id('org') and user_id = pg_temp.p3_id('mgr');
  -- o MESMO operation_id numa outra organização é independente
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price)
  values (pg_temp.p3_id('org2'), pg_temp.p3_id('arena2'), pg_temp.p3_id('c_out'), pg_temp.p3_ts('fri', '10:00', 7), pg_temp.p3_ts('fri', '11:00', 7), 'CONFIRMED', 'TESTE_P3A', 5000)
  returning id into v_res2;
  r2 := pg_temp.p3_expect('I16 mesmo operation_id em outra organização', 'out', pg_temp.p3_pay_sql(v_op, v_res2, 'PIX', 1000, v_at), 'OK');
  perform pg_temp.p3_ok('I16b idempotent=false (lançamento novo)', not (r2->>'idempotent')::boolean, r2::text);
  perform pg_temp.p3_expect('I17 sem operation_id => 22023', 'rec', pg_temp.p3_pay_sql(null, v_res2, 'PIX', 1000, v_at), '22023');
end $$;

-- ----------------------------------------------------------------------------- V: visibilidade / L: ledger imutável
do $$
declare r jsonb; v_nd_res uuid; v_nd_pay uuid; v_pay uuid := pg_temp.p3_id('p2');
begin
  r := pg_temp.p3_do('rec', format('select to_jsonb(count(*)) from public.reservation_payments where organization_id = %L', pg_temp.p3_id('org')));
  perform pg_temp.p3_ok('V01 RECEPTIONIST lê 0 linhas do ledger direto (RLS)', r::text::int = 0, r::text);
  r := pg_temp.p3_do('mgr', format('select to_jsonb(count(*)) from public.reservation_payments where organization_id = %L', pg_temp.p3_id('org')));
  perform pg_temp.p3_ok('V02 MANAGER lê o ledger', r::text::int > 0, r::text);
  perform pg_temp.p3_expect('V03 operation_fingerprint ilegível até para OWNER', 'owner', 'select jsonb_agg(operation_fingerprint) from public.reservation_payments', '42501');
  r := pg_temp.p3_do('rec', format('select public.rg_reservation_financial_summaries(%L::uuid[])', array[pg_temp.p3_id('resA')]));
  perform pg_temp.p3_ok('V04 resumos para a recepção: só status/collectible (sem valores)',
    jsonb_array_length(r) = 1 and r->0 ? 'payment_status' and not (r->0 ? 'amount_due') and not (r->0 ? 'net_received'), r::text);
  r := pg_temp.p3_do('owner', format('select public.rg_reservation_financial_summaries(%L::uuid[])', array[pg_temp.p3_id('resA')]));
  perform pg_temp.p3_ok('V05 resumos para OWNER: com valores', r->0 ? 'amount_due' and r->0 ? 'collectible_balance', r::text);
  r := pg_temp.p3_do('out', format('select public.rg_reservation_financial_summaries(%L::uuid[])', array[pg_temp.p3_id('resA')]));
  perform pg_temp.p3_ok('V06 resumos de outra org: omitidos', jsonb_array_length(r) = 0, r::text);
  perform pg_temp.p3_expect('V07 detalhe por outra org => P0002', 'out', pg_temp.p3_detail_sql(pg_temp.p3_id('resA')), 'P0002');
  perform pg_temp.p3_expect('V08 detalhe por anon => 42501', 'anon', pg_temp.p3_detail_sql(pg_temp.p3_id('resA')), '42501');
  perform pg_temp.p3_expect('V09 detalhe por service_role => 42501', 'service_role', pg_temp.p3_detail_sql(pg_temp.p3_id('resA')), '42501');
  perform pg_temp.p3_expect('V10 mais de 500 ids => 22023', 'owner', format('select public.rg_reservation_financial_summaries(%L::uuid[])', (select array_agg(gen_random_uuid()) from generate_series(1, 501))), '22023');
  -- L: imutabilidade
  perform pg_temp.p3_expect('L01 INSERT direto no ledger por authenticated => 42501', 'owner', format(
    'insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, method, amount, received_at, operation_id, operation_fingerprint) values (%L, %L, %L, ''PAYMENT'', ''PIX'', 1, now(), gen_random_uuid(), sha256(''x''::bytea)) returning jsonb_build_object(''id'', id)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('resA')), '42501');
  perform pg_temp.p3_expect('L02 UPDATE direto por authenticated => 42501', 'owner', format('update public.reservation_payments set amount = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_pay), '42501');
  perform pg_temp.p3_expect('L03 UPDATE direto por service_role => 42501', 'service_role', format('update public.reservation_payments set amount = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_pay), '42501');
  perform pg_temp.p3_expect('L04 UPDATE da intenção até por postgres => RGT02', 'postgres', format('update public.reservation_payments set amount = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_pay), 'RGT02');
  perform pg_temp.p3_expect('L05 re-anular lançamento anulado (postgres) => RGT02', 'postgres', format('update public.reservation_payments set void_reason = ''outro'' where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.p3_id('p1')), 'RGT02');
  perform pg_temp.p3_expect('L06 DELETE por authenticated => 42501', 'owner', format('delete from public.reservation_payments where id = %L::uuid returning jsonb_build_object(''id'', id)', v_pay), '42501');
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price)
  values (pg_temp.p3_id('ornd'), pg_temp.p3_id('arnd'), pg_temp.p3_id('c_nd'), pg_temp.p3_ts('fri', '10:00', 7), pg_temp.p3_ts('fri', '11:00', 7), 'CONFIRMED', 'TESTE_P3A', 5000)
  returning id into v_nd_res;
  insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, method, amount, received_at, operation_id, operation_fingerprint)
  values (pg_temp.p3_id('ornd'), pg_temp.p3_id('arnd'), v_nd_res, 'PAYMENT', 'PIX', 100, now(), gen_random_uuid(), sha256('x'::bytea))
  returning id into v_nd_pay;
  perform pg_temp.p3_expect('L07 service_role DELETE em org NÃO demo => 42501', 'service_role', format('delete from public.reservation_payments where id = %L::uuid returning jsonb_build_object(''id'', id)', v_nd_pay), '42501');
  perform pg_temp.p3_ok('L08 grants: anon sem nada; service_role sem EXECUTE nas RPCs',
    not has_table_privilege('anon', 'public.reservation_payments', 'SELECT') and not has_table_privilege('anon', 'public.court_pricing_rules', 'SELECT')
    and not has_function_privilege('service_role', 'public.rg_payment_register(uuid,uuid,text,integer,timestamptz,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.rg_payment_register(uuid,uuid,text,integer,timestamptz,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.rg_payment_register(uuid,uuid,text,integer,timestamptz,text)', 'EXECUTE')
    and not has_table_privilege('authenticated', 'public.reservation_payments', 'INSERT')
    and not has_table_privilege('authenticated', 'public.court_pricing_rules', 'INSERT'), 'acl');
end $$;

-- ----------------------------------------------------------------------------- F: falha injetada => estado idêntico
do $$
declare v_at timestamptz := now() - interval '3 hours'; v_res uuid; v_pay uuid; v_rule uuid; r jsonb;
begin
  v_res := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '14:00', 21), pg_temp.p3_ts('fri', '15:00', 21), 'CONFIRMED', 40000);
  r := pg_temp.p3_do('owner', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 10000, v_at));
  v_pay := (r->>'payment_id')::uuid;
  r := pg_temp.p3_do('owner', pg_temp.p3_rule_sql('arena', null, array[0], '09:00', '10:00', 1000));
  v_rule := (r->'rule_ids'->>0)::uuid;
  perform pg_temp.p3_fault_case('F01 payment: após insert', 'rec', 'payment:after_insert', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 100, v_at));
  perform pg_temp.p3_fault_case('F02 payment: após audit', 'rec', 'payment:after_audit', pg_temp.p3_pay_sql(gen_random_uuid(), v_res, 'PIX', 100, v_at));
  perform pg_temp.p3_fault_case('F03 refund: após insert', 'mgr', 'refund:after_insert', pg_temp.p3_refund_sql(gen_random_uuid(), v_pay, 'PIX', 100, v_at));
  perform pg_temp.p3_fault_case('F04 refund: após audit', 'mgr', 'refund:after_audit', pg_temp.p3_refund_sql(gen_random_uuid(), v_pay, 'PIX', 100, v_at));
  perform pg_temp.p3_fault_case('F05 void: após update', 'mgr', 'void:after_update', pg_temp.p3_void_sql(v_pay, 'teste'));
  perform pg_temp.p3_fault_case('F06 void: após audit', 'mgr', 'void:after_audit', pg_temp.p3_void_sql(v_pay, 'teste'));
  perform pg_temp.p3_fault_case('F07 set_price: após update', 'mgr', 'set_price:after_update', pg_temp.p3_price_sql(v_res, 'MANUAL', 35000, 'DISCOUNT'));
  perform pg_temp.p3_fault_case('F08 set_price: após audit', 'mgr', 'set_price:after_audit', pg_temp.p3_price_sql(v_res, 'MANUAL', 35000, 'DISCOUNT'));
  perform pg_temp.p3_fault_case('F09 pricing create: após todos os inserts', 'owner', 'pricing_create:after_all_inserts', pg_temp.p3_rule_sql('arena', null, array[0], '10:00', '11:00', 1000));
  perform pg_temp.p3_fault_case('F10 pricing create: após audit', 'owner', 'pricing_create:after_audit', pg_temp.p3_rule_sql('arena', null, array[0], '10:00', '11:00', 1000));
  perform pg_temp.p3_fault_case('F11 pricing update: após update', 'owner', 'pricing_update:after_update', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"price_per_hour":2000}'));
  perform pg_temp.p3_fault_case('F12 pricing update: após audit', 'owner', 'pricing_update:after_audit', format('select public.rg_pricing_rule_update(%L::uuid, %L::jsonb)', v_rule, '{"price_per_hour":2000}'));
  perform pg_temp.p3_fault_case('F13 pricing deactivate: após update', 'owner', 'pricing_deactivate:after_update', format('select public.rg_pricing_rule_deactivate(%L::uuid)', v_rule));
  perform pg_temp.p3_fault_case('F14 pricing deactivate: após audit', 'owner', 'pricing_deactivate:after_audit', format('select public.rg_pricing_rule_deactivate(%L::uuid)', v_rule));
end $$;

-- ----------------------------------------------------------------------------- G: GUARDS x FOUNDATION + D7
do $$
declare
  v_guards boolean := exists (select 1 from pg_trigger where tgname = 'enforce_reservation_zz_price_guard' and tgrelid = 'public.reservations'::regclass);
  v_res uuid; v_occ uuid := pg_temp.p3_id('occ'); s public.recurring_reservations; v_start timestamptz; v_end timestamptz;
  v_next date := pg_temp.p3_day('fri') + 7; base jsonb; r jsonb;
  row_sql text := 'insert into public.reservations select * from jsonb_populate_record(null::public.reservations, %L::jsonb) returning jsonb_build_object(''id'', id)';
begin
  perform pg_temp.p3_ok('G00 modo detectado', true, case when v_guards then 'GUARDS' else 'FOUNDATION' end);
  v_res := pg_temp.p3_res('c2', pg_temp.p3_ts('fri', '16:00', 21), pg_temp.p3_ts('fri', '17:00', 21), 'CONFIRMED', 10000);
  if v_guards then
    perform pg_temp.p3_ok('G01 guard SECURITY INVOKER, owner postgres, search_path vazio',
      (select not prosecdef and pg_get_userbyid(proowner) = 'postgres' and proconfig = array['search_path=""']
         from pg_proc where oid = 'private.enforce_reservation_price_guard()'::regprocedure), 'pg_proc');
    perform pg_temp.p3_expect('G02 UPDATE direto de price (OWNER) => 42501', 'owner', format('update public.reservations set price = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), '42501');
    perform pg_temp.p3_expect('G03 UPDATE direto de price (RECEPTIONIST) em ocorrência recorrente => 42501', 'rec', format('update public.reservations set price = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_occ), '42501');
    perform pg_temp.p3_expect('G04 UPDATE direto de price (OWNER) em ocorrência recorrente => 42501', 'owner', format('update public.reservations set price = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_occ), '42501');
    perform pg_temp.p3_expect('G05 UPDATE direto de price por service_role => 42501', 'service_role', format('update public.reservations set price = 1 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), '42501');
    perform pg_temp.p3_expect('G06 UPDATE para PAID (OWNER) => 23514', 'owner', format('update public.reservations set status = ''PAID'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), '23514');
    perform pg_temp.p3_expect('G07 UPDATE para PAID em ocorrência recorrente => 23514', 'owner', format('update public.reservations set status = ''PAID'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_occ), '23514');
    perform pg_temp.p3_expect('G08 UPDATE para PAID por service_role => 23514', 'service_role', format('update public.reservations set status = ''PAID'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), '23514');
    perform pg_temp.p3_expect('G09 UPDATE para PAID por postgres => 23514', 'postgres', format('update public.reservations set status = ''PAID'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), '23514');
    perform pg_temp.p3_expect('G10 INSERT comum com price por authenticated => 42501', 'owner', format(
      'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price, created_by) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''TESTE_P3A'', 1, %L) returning jsonb_build_object(''id'', id)',
      pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c3'), pg_temp.p3_ts('fri', '20:00', 21), pg_temp.p3_ts('fri', '21:00', 21), pg_temp.p3_id('owner')), '42501');
    perform pg_temp.p3_expect('G11 INSERT comum com status PAID (service_role) => 23514', 'service_role', format(
      'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source) values (%L, %L, %L, %L, %L, ''PAID'', ''TESTE_P3A'') returning jsonb_build_object(''id'', id)',
      pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c3'), pg_temp.p3_ts('fri', '21:00', 21), pg_temp.p3_ts('fri', '22:00', 21)), '23514');
    perform pg_temp.p3_expect('G12 UPDATE sem mudar price continua permitido (RECEPTIONIST move ocorrência)', 'rec', format(
      'update public.reservations set is_exception = true, start_at = start_at + interval ''30 minutes'', end_at = end_at + interval ''30 minutes'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_occ), 'OK');
  else
    perform pg_temp.p3_expect('G02 FOUNDATION: UPDATE direto de price ainda permitido (grant atual)', 'owner', format('update public.reservations set price = 11000 where id = %L::uuid returning jsonb_build_object(''id'', id)', v_res), 'OK');
  end if;
  -- em AMBOS os modos: set_price legítimo e INSERT público sem price
  perform pg_temp.p3_expect('G13 set_price legítimo (MANAGER) em reserva comum', 'mgr', pg_temp.p3_price_sql(v_res, 'MANUAL', 12000, 'CORRECTION'), 'OK');
  perform pg_temp.p3_expect('G14 set_price legítimo (OWNER) em ocorrência recorrente', 'owner', pg_temp.p3_price_sql(v_occ, 'MANUAL', 16000, 'CORRECTION'), 'OK');
  r := pg_temp.p3_expect('G15 INSERT service_role sem price (reserva pública) continua', 'service_role', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, public_code) values (%L, %L, %L, %L, %L, ''CONFIRMED'', ''PUBLIC_WEB'', %L) returning jsonb_build_object(''id'', id, ''price'', price)',
    pg_temp.p3_id('org'), pg_temp.p3_id('arena'), pg_temp.p3_id('c1'), pg_temp.p3_ts('fri', '10:00', 28), pg_temp.p3_ts('fri', '11:00', 28), 'RG-P3B' || substr(md5(random()::text), 1, 10)), 'OK');
  perform pg_temp.p3_ok('G15b snapshot da pública = 10000', (r->>'price')::int = 10000, r::text);
  -- D7 continua autoridade do INSERT recorrente forjado (mesmos 23514 da B3), nos dois modos
  select * into s from public.recurring_reservations where id = pg_temp.p3_id('s_price');
  select b.start_at, b.end_at into v_start, v_end from private.rg_occurrence_bounds(v_next, s.start_time, s.end_time) b;
  base := jsonb_build_object('id', gen_random_uuid(), 'created_at', now(), 'updated_at', now(), 'organization_id', s.organization_id, 'arena_id', s.arena_id, 'court_id', s.court_id,
    'customer_id', s.customer_id, 'start_at', v_start, 'end_at', v_end, 'status', 'CONFIRMED', 'source', 'RECORRENTE',
    'notes', s.notes, 'price', s.default_price, 'recurring_reservation_id', s.id, 'occurrence_date', v_next,
    'is_exception', false, 'created_by', pg_temp.p3_id('owner'));
  perform pg_temp.p3_expect('G16 D7: ocorrência forjada com price diferente => 23514', 'owner', format(row_sql, base || '{"price": 1}'::jsonb), '23514');
  perform pg_temp.p3_expect('G17 D7: ocorrência forjada com status PAID => 23514', 'owner', format(row_sql, base || '{"status": "PAID"}'::jsonb), '23514');
  perform pg_temp.p3_expect('G18 D7: ocorrência forjada com price NULL (série 12345) => 23514', 'rec', format(row_sql, base || '{"price": null}'::jsonb), '23514');
  perform pg_temp.p3_ok('G19 B3 intacta: triggers/funções B3 presentes',
    exists (select 1 from pg_trigger where tgname = 'validate_reservation_zz_series_occurrence')
    and exists (select 1 from pg_trigger where tgname = 'validate_recurring_zz_terminal_state')
    and to_regprocedure('private.enforce_recurring_occurrence()') is not null, 'b3');
end $$;

-- ----------------------------------------------------------------------------- resultado (SEMPRE termina em erro => ROLLBACK)
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from p3r;
  select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from p3r;
  raise exception E'P3A_ROLLBACK_RESULTS % — % PASS / % FAIL (total %). Transação DESFEITA.\n%',
    case when v_fail = 0 then 'OK' else 'FAIL' end, v_total - v_fail, v_fail, v_total, v_txt;
end $$;
rollback;
