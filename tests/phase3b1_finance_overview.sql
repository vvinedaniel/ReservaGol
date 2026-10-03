-- =============================================================================
-- RESERVA GOL — FASE 03B.1 — testes SQL da visão financeira (A receber, Caixa)
-- Requer 03A completa + migration_phase3b1_finance_overview.sql aplicadas. Banco de TESTE.
--
-- Como rodar (banco de TESTE local, nunca Production):
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3b1_finance_overview.sql
-- Sucesso: imprime "P3B1_RESULTS OK ..." (determinístico), executa ROLLBACK explícito, exit code 0.
-- Falha de asserção: erro "P3B1_RESULTS FAIL ..." com os detalhes => exit code != 0; a transação
-- nunca é confirmada (a conexão termina sem COMMIT). ZERO RESÍDUO nos dois caminhos.
--
-- Zonas de datas (relativas a hoje, America/Sao_Paulo), sem sobreposição:
--   M    hoje-20 .. hoje+20   período principal
--   CMP  hoje-61 .. hoje-21   período de comparação (F05/F11)
--   L    hoje-80              fuso (F01): reserva e pagamento às 23:30 locais = dia seguinte em UTC
--   T    hoje-90 / hoje-95    arredondamento do ticket (F09)
-- Blocos: F01–F12 semântica (F12 = paridade com private.rg_financials), A autorização, V validação,
--         P paginação, C cashflow, K consistência, S sem efeito colateral, G privilégios.
-- O fixture PAID (status legado, impossível de gravar desde os GUARDS) é inserido com
-- SET LOCAL session_replication_role = replica, restaurado para origin logo após o INSERT (S01b confere).
-- Autorizado SOMENTE no banco Docker local isolado. Sem superusuário, os casos PAID ficam como N/A.
-- =============================================================================
begin;
set local statement_timeout = '180s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table fd (k text primary key, d date not null) on commit drop;
create temp table ff (k text primary key, b boolean not null) on commit drop;
create temp table fs (k text primary key, v text not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3b1: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is null
     or to_regprocedure('private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz)') is null then
    raise exception 'p3b1: migration 03B.1 não aplicada';
  end if;
  if to_regprocedure('private.rg_financials(uuid[])') is null then raise exception 'p3b1: 03A ausente'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.today() returns date language sql stable as $$ select d from fd where k = 'today' $$;
create function pg_temp.dd(p_day integer) returns date language sql stable as $$ select pg_temp.today() + p_day $$;
create function pg_temp.ts(p_day integer, p_hhmm text) returns timestamptz language sql stable as $$
  select ((pg_temp.today() + p_day)::text || ' ' || p_hhmm || ':00-03:00')::timestamptz $$;
create function pg_temp.paid() returns boolean language sql stable as $$ select b from ff where k = 'paid' $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.sel(p_paid integer, p_nopaid integer) returns bigint language sql stable as $$
  select case when pg_temp.paid() then p_paid else p_nopaid end::bigint $$;

-- Hash das linhas das organizações de fixture (S01 e checagem de "nada mudou" nos erros).
create function pg_temp.snap() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'rs:' || row_to_json(r)::text as x from public.reservations r where r.organization_id in (pg_temp.k('org'), pg_temp.k('org2'))
    union all select 'rp:' || row_to_json(r)::text from public.reservation_payments r where r.organization_id in (pg_temp.k('org'), pg_temp.k('org2'))
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r where r.organization_id in (pg_temp.k('org'), pg_temp.k('org2'))
    union all select 'cu:' || row_to_json(r)::text from public.customers r where r.organization_id in (pg_temp.k('org'), pg_temp.k('org2'))
  ) s), '')
  || '#' || (select count(*) from public.reservations)::text || '/' || (select count(*) from public.reservation_payments)::text
  || '/' || (select count(*) from public.audit_logs)::text || '/' || (select count(*) from public.court_pricing_rules)::text
  || '/' || (select count(*) from public.recurring_reservations)::text) $$;

-- Executa SQL como um ator (JWT simulado + papel authenticated/anon), devolvendo estado e resultado.
create function pg_temp.call(p_actor text, p_sql text, out state text, out result jsonb)
language plpgsql as $$
declare v_claims text;
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
    state := sqlstate;
    result := jsonb_build_object('msg', sqlerrm);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create function pg_temp.do_(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.call(p_actor, p_sql);
  if v.state <> 'OK' then raise exception 'p3b1 (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

create function pg_temp.expect(p_name text, p_actor text, p_sql text, p_state text, p_msg text default null) returns void
language plpgsql as $$
declare v_before text; v record;
begin
  v_before := pg_temp.snap();
  select * into v from pg_temp.call(p_actor, p_sql);
  perform pg_temp.ok(p_name,
    v.state = p_state and pg_temp.snap() = v_before and (p_msg is null or v.result->>'msg' = p_msg),
    format('esperado=%s%s veio=%s %s', p_state, coalesce(' "' || p_msg || '"', ''), v.state, coalesce(v.result->>'msg', '')));
end $$;

-- SQL das 4 RPCs (uuid/datas nulos viram NULL tipado)
create function pg_temp.ov(p_org uuid, p_arena uuid, p_from date, p_to date, p_cf date default null, p_ct date default null) returns text
language sql stable as $$ select format('select public.rg_fin_overview(%L::uuid, %L::uuid, %L::date, %L::date, %L::date, %L::date)',
  p_org, p_arena, p_from, p_to, p_cf, p_ct) $$;
create function pg_temp.rcv(p_org uuid, p_arena uuid, p_from date, p_to date, p_filter text, p_limit integer,
  p_as timestamptz default null, p_ai uuid default null) returns text language sql stable as $$
  select format('select public.rg_fin_receivables(%L::uuid, %L::uuid, %L::date, %L::date, %L::text, %L::integer, %L::timestamptz, %L::uuid)',
    p_org, p_arena, p_from, p_to, p_filter, p_limit, p_as, p_ai) $$;
create function pg_temp.cf(p_org uuid, p_arena uuid, p_from date, p_to date, p_gran text) returns text language sql stable as $$
  select format('select public.rg_fin_cashflow(%L::uuid, %L::uuid, %L::date, %L::date, %L::text)', p_org, p_arena, p_from, p_to, p_gran) $$;
create function pg_temp.ce(p_org uuid, p_arena uuid, p_from date, p_to date, p_limit integer,
  p_aa timestamptz default null, p_ai uuid default null) returns text language sql stable as $$
  select format('select public.rg_fin_cash_entries(%L::uuid, %L::uuid, %L::date, %L::date, %L::integer, %L::timestamptz, %L::uuid)',
    p_org, p_arena, p_from, p_to, p_limit, p_aa, p_ai) $$;

-- Fixtures de reserva (caminho de sistema: postgres grava valor => origem MANUAL; sem valor e sem regra => NULL)
create function pg_temp.res(p_key text, p_org text, p_arena text, p_court text, p_start timestamptz, p_end timestamptz,
  p_status text, p_price integer, p_customer text default null) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, price, created_by)
  values (pg_temp.k(p_org), pg_temp.k(p_arena), pg_temp.k(p_court), case when p_customer is null then null else pg_temp.k(p_customer) end,
          p_start, p_end, p_status, 'TESTE_P3B1', p_price, pg_temp.k('owner'))
  returning id into v_id;
  insert into fx values (p_key, v_id);
  return v_id;
end $$;
-- Lançamentos pelas RPCs reais da 03A
create function pg_temp.pay(p_key text, p_actor text, p_res text, p_amount integer, p_at timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_(p_actor, format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', %s, %L::timestamptz, null)',
    gen_random_uuid(), pg_temp.k(p_res), p_amount, p_at));
  insert into fx values (p_key, (r->>'payment_id')::uuid);
  return (r->>'payment_id')::uuid;
end $$;
create function pg_temp.refund(p_pay text, p_amount integer, p_at timestamptz) returns void language plpgsql as $$
begin
  perform pg_temp.do_('mgr', format('select public.rg_payment_refund(%L::uuid, %L::uuid, ''PIX'', %s, %L::timestamptz, null)',
    gen_random_uuid(), pg_temp.k(p_pay), p_amount, p_at));
end $$;

-- ----------------------------------------------------------------------------- fixtures (desfeitas no fim)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_out uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_a2 uuid; v_b1 uuid; v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_cust uuid;
  v_tag text := 'p3b1-' || substr(md5(clock_timestamp()::text), 1, 8);
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'), (u_rec, v_tag || '-rec@reservagol.test'),
    (u_out, v_tag || '-out@reservagol.test'), (u_adm, v_tag || '-adm@reservagol.test');
  insert into public.profiles (id) values (u_adm) on conflict (id) do nothing;
  update public.profiles set is_platform_admin = true where id = u_adm;
  insert into public.organizations (name, is_demo) values ('P3B1 ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3B1 outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;
  insert into public.arenas (organization_id, name) values (v_org, 'A2 ' || v_tag) returning id into v_a2;
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a2, 'Q3') returning id into v_c3;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'Q4') returning id into v_c4;
  insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Cliente P3B1', '11988887777') returning id into v_cust;
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('adm', u_adm),
    ('org', v_org), ('org2', v_org2), ('a1', v_a1), ('a2', v_a2), ('b1', v_b1),
    ('c1', v_c1), ('c2', v_c2), ('c3', v_c3), ('c4', v_c4), ('cust', v_cust);
  insert into fd values ('today', (now() at time zone 'America/Sao_Paulo')::date);
end $$;

-- Zona M
do $$
begin
  perform pg_temp.res('r01', 'org', 'a1', 'c1', pg_temp.ts(-10, '10:00'), pg_temp.ts(-10, '11:00'), 'CONFIRMED', 10000);
  perform pg_temp.pay('p01', 'rec', 'r01', 10000, pg_temp.ts(-10, '12:00'));                      -- integral => PAID
  perform pg_temp.res('r02', 'org', 'a1', 'c1', pg_temp.ts(-9, '10:00'), pg_temp.ts(-9, '11:00'), 'CONFIRMED', 15000, 'cust');
  perform pg_temp.pay('p02', 'rec', 'r02', 5000, pg_temp.ts(-9, '12:00'));                        -- parcial, vencida
  perform pg_temp.res('r03', 'org', 'a1', 'c1', pg_temp.ts(5, '10:00'), pg_temp.ts(5, '11:00'), 'PENDING', 12000);   -- a vencer
  perform pg_temp.res('r04', 'org', 'a1', 'c1', pg_temp.ts(-8, '10:00'), pg_temp.ts(-8, '11:00'), 'NO_SHOW', 8000);  -- vencida
  perform pg_temp.res('r06', 'org', 'a1', 'c1', pg_temp.ts(-6, '10:00'), pg_temp.ts(-6, '11:00'), 'CONFIRMED', 10000);
  perform pg_temp.pay('p06', 'rec', 'r06', 3000, pg_temp.ts(-6, '12:00'));
  update public.reservations set status = 'CANCELLED' where id = pg_temp.k('r06');               -- RETAINED
  perform pg_temp.res('r07', 'org', 'a1', 'c1', pg_temp.ts(-5, '10:00'), pg_temp.ts(-5, '11:00'), 'CANCELLED', 7000); -- CANCELLED
  perform pg_temp.res('r08', 'org', 'a1', 'c1', pg_temp.ts(-4, '10:00'), pg_temp.ts(-4, '11:00'), 'CONFIRMED', 6000);
  perform pg_temp.pay('p08', 'rec', 'r08', 6000, pg_temp.ts(-4, '12:00'));
  perform pg_temp.refund('p08', 6000, pg_temp.ts(-4, '13:00'));
  update public.reservations set status = 'CANCELLED' where id = pg_temp.k('r08');               -- REFUNDED
  perform pg_temp.res('r09', 'org', 'a1', 'c1', pg_temp.ts(-3, '10:00'), pg_temp.ts(-3, '11:00'), 'CONFIRMED', null); -- sem valor
  perform pg_temp.res('r10', 'org', 'a1', 'c1', pg_temp.ts(6, '10:00'), pg_temp.ts(6, '11:00'), 'PENDING', null);     -- sem valor
  perform pg_temp.res('r11', 'org', 'a1', 'c1', pg_temp.ts(-2, '10:00'), pg_temp.ts(-2, '11:00'), 'CONFIRMED', 5000);
  perform pg_temp.pay('p11', 'rec', 'r11', 5000, pg_temp.ts(-2, '12:00'));
  perform pg_temp.do_('mgr', format('select public.rg_payment_void(%L::uuid, %L)', pg_temp.k('p11'), 'lançamento errado'));  -- VOID
  perform pg_temp.res('r12', 'org', 'a1', 'c1', pg_temp.ts(-1, '10:00'), pg_temp.ts(-1, '11:00'), 'CONFIRMED', 10000);
  perform pg_temp.pay('p12', 'rec', 'r12', 10000, pg_temp.ts(-1, '12:00'));
  perform pg_temp.do_('mgr', format('select public.rg_reservation_set_price(%L::uuid, ''MANUAL'', 8000, ''DISCOUNT'')', pg_temp.k('r12'))); -- OVERPAID
  perform pg_temp.res('r13', 'org', 'a1', 'c1', pg_temp.ts(1, '10:00'), pg_temp.ts(1, '11:00'), 'BLOCKED', null);     -- NOT_APPLICABLE
  perform pg_temp.res('r14', 'org', 'a1', 'c2', pg_temp.ts(3, '10:00'), pg_temp.ts(3, '11:00'), 'CONFIRMED', 20000);
  perform pg_temp.pay('p14', 'rec', 'r14', 5000, now() - interval '1 hour');                      -- parcial, a vencer
  perform pg_temp.res('r15', 'org', 'a2', 'c3', pg_temp.ts(-1, '10:00'), pg_temp.ts(-1, '11:00'), 'CONFIRMED', 30000);
  perform pg_temp.pay('p15', 'rec', 'r15', 10000, pg_temp.ts(-1, '12:00'));                       -- outra arena
  perform pg_temp.res('r16', 'org', 'a1', 'c1', pg_temp.ts(8, '10:00'), pg_temp.ts(8, '11:00'), 'CONFIRMED', 1000);   -- empate de start_at
  perform pg_temp.res('r17', 'org', 'a1', 'c2', pg_temp.ts(8, '10:00'), pg_temp.ts(8, '11:00'), 'CONFIRMED', 1000);
  -- outra organização (isolamento)
  perform pg_temp.res('r26', 'org2', 'b1', 'c4', pg_temp.ts(-1, '10:00'), pg_temp.ts(-1, '11:00'), 'CONFIRMED', 50000);
  perform pg_temp.pay('p26', 'out', 'r26', 50000, pg_temp.ts(-1, '12:00'));
end $$;

-- PAID legado (status bloqueado desde os GUARDS): só com session_replication_role (superusuário)
do $$
declare v_id uuid := gen_random_uuid();
begin
  begin
    set local session_replication_role = replica;
    insert into public.reservations (id, organization_id, arena_id, court_id, start_at, end_at, status, source, price, created_by)
    values (v_id, pg_temp.k('org'), pg_temp.k('a1'), pg_temp.k('c1'), pg_temp.ts(-7, '10:00'), pg_temp.ts(-7, '11:00'),
            'PAID', 'TESTE_P3B1', 9000, pg_temp.k('owner'));
    set local session_replication_role = origin;
    insert into fx values ('r05', v_id);
    insert into ff values ('paid', true);
  exception when insufficient_privilege then
    insert into ff values ('paid', false);
  end;
  insert into fs values ('srr_after_paid', current_setting('session_replication_role'));
  if pg_temp.paid() then
    perform pg_temp.pay('p05', 'rec', 'r05', 4000, pg_temp.ts(-7, '12:00'));                      -- PAID legado, parcial
  end if;
end $$;

-- Zona CMP, zona L (fuso) e zona T (ticket)
do $$
begin
  perform pg_temp.res('r18', 'org', 'a1', 'c1', pg_temp.ts(-30, '10:00'), pg_temp.ts(-30, '11:00'), 'CONFIRMED', 20000);
  perform pg_temp.pay('p18', 'rec', 'r18', 20000, pg_temp.ts(-30, '12:00'));
  perform pg_temp.res('r19', 'org', 'a1', 'c1', pg_temp.ts(-25, '10:00'), pg_temp.ts(-25, '11:00'), 'CONFIRMED', 9000);
  perform pg_temp.pay('p19', 'rec', 'r19', 9000, pg_temp.ts(-25, '12:00'));
  perform pg_temp.refund('p19', 4000, pg_temp.ts(-15, '12:00'));                                -- estorno lançado no período M
  perform pg_temp.res('r20', 'org', 'a1', 'c1', pg_temp.ts(-80, '23:30'), pg_temp.ts(-79, '00:30'), 'CONFIRMED', 11111);
  perform pg_temp.pay('p20', 'rec', 'r20', 11111, pg_temp.ts(-80, '23:30'));
  perform pg_temp.res('r21', 'org', 'a1', 'c1', pg_temp.ts(-90, '10:00'), pg_temp.ts(-90, '11:00'), 'CONFIRMED', 10000);
  perform pg_temp.res('r22', 'org', 'a1', 'c1', pg_temp.ts(-90, '11:00'), pg_temp.ts(-90, '12:00'), 'CONFIRMED', 10001);
  perform pg_temp.res('r23', 'org', 'a1', 'c1', pg_temp.ts(-90, '12:00'), pg_temp.ts(-90, '13:00'), 'CONFIRMED', 10001);
  perform pg_temp.res('r24', 'org', 'a1', 'c1', pg_temp.ts(-95, '10:00'), pg_temp.ts(-95, '11:00'), 'CONFIRMED', 10000);
  perform pg_temp.res('r25', 'org', 'a1', 'c1', pg_temp.ts(-95, '11:00'), pg_temp.ts(-95, '12:00'), 'CONFIRMED', 10001);
  insert into fs values ('snap0', pg_temp.snap());
end $$;

-- ----------------------------------------------------------------------------- F: semântica
do $$
declare
  o jsonb; o2 jsonb; r jsonb; e jsonb;
  M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20);
  C_F date := pg_temp.dd(-61); C_T date := pg_temp.dd(-21);
  L date := pg_temp.dd(-80);
  org uuid := pg_temp.k('org');
begin
  o := pg_temp.do_('owner', pg_temp.ov(org, null, M_F, M_T));

  -- F01 fuso: 23:30 local do dia L conta em L (em UTC já é L+1)
  o2 := pg_temp.do_('owner', pg_temp.ov(org, null, L, L));
  r := pg_temp.do_('owner', pg_temp.ov(org, null, L + 1, L + 1));
  perform pg_temp.ok('F01 fuso: reserva e pagamento às 23:30 locais contam no dia local, não no dia UTC',
    (o2->'reservations'->>'billable')::int = 1 and (o2->'expected_revenue'->>'current')::bigint = 11111
    and (o2->'cash_in'->>'gross')::bigint = 11111
    and (r->'reservations'->>'billable')::int = 0 and (r->'cash_in'->>'gross')::bigint = 0,
    format('L=%s L+1=%s', o2->'reservations', r->'reservations'));

  -- F02 cancelada e bloqueio fora do valor das reservas
  perform pg_temp.ok('F02 CANCELLED/BLOCKED fora do valor das reservas; canceladas contadas',
    (o->'reservations'->>'cancelled')::int = 3
    and (o->'reservations'->>'billable')::bigint = pg_temp.sel(13, 12)
    and (o->'expected_revenue'->>'current')::bigint = pg_temp.sel(119000, 110000),
    format('%s / %s', o->'reservations', o->'expected_revenue'));

  -- F03 sem valor: contado à parte, fora da receita e do ticket; lista UNPRICED
  r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'UNPRICED', 50));
  perform pg_temp.ok('F03 sem valor: unpriced=2; UNPRICED lista r09/r10 com amount_due/balance nulos e overdue=false',
    (o->'reservations'->>'unpriced')::int = 2 and (o->'reservations'->>'priced')::bigint = pg_temp.sel(11, 10)
    and jsonb_array_length(r->'items') = 2
    and (select bool_and(i->'amount_due' = 'null'::jsonb and i->'balance' = 'null'::jsonb and i->>'payment_status' = 'UNPRICED'
                         and i->'overdue' = 'false'::jsonb) from jsonb_array_elements(r->'items') i)
    and (select array_agg((i->>'reservation_id')::uuid order by i->>'start_at') from jsonb_array_elements(r->'items') i)
        = array[pg_temp.k('r09'), pg_temp.k('r10')],
    r::text);

  -- F04 pagamento anulado não conta (caixa nem saldo)
  r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 200));
  perform pg_temp.ok('F04 anulado fora do caixa e do saldo: bruto sem p11; r11 aberta com saldo integral',
    (o->'cash_in'->>'gross')::bigint = pg_temp.sel(53000, 49000)
    and exists (select 1 from jsonb_array_elements(r->'items') i where (i->>'reservation_id')::uuid = pg_temp.k('r11')
                and (i->>'balance')::bigint = 5000 and (i->>'net_received')::bigint = 0 and i->>'payment_status' = 'PENDING'),
    o->>'cash_in');

  -- F05 estorno lançado no período seguinte conta no período dele; saldo atual reflete o estorno
  o2 := pg_temp.do_('owner', pg_temp.ov(org, null, C_F, C_T));
  r := pg_temp.do_('owner', pg_temp.rcv(org, null, C_F, C_T, 'OPEN', 50));
  perform pg_temp.ok('F05 estorno no período seguinte: CMP bruto 29000 sem estorno; M estornos 10000; r19 saldo atual 4000',
    (o2->'cash_in'->>'gross')::bigint = 29000 and (o2->'cash_in'->>'refunds')::bigint = 0
    and (o->'cash_in'->>'refunds')::bigint = 10000
    and (o2->'receivables'->>'open')::bigint = 4000
    and jsonb_array_length(r->'items') = 1 and (r->'items'->0->>'reservation_id')::uuid = pg_temp.k('r19')
    and (r->'items'->0->>'balance')::bigint = 4000 and r->'items'->0->>'payment_status' = 'PARTIAL',
    format('cmp=%s m_refunds=%s', o2->'cash_in', o->'cash_in'->'refunds'));

  -- F06 parcial com cliente
  r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 200));
  select i into e from jsonb_array_elements(r->'items') i where (i->>'reservation_id')::uuid = pg_temp.k('r02');
  perform pg_temp.ok('F06 parcial: r02 devido 15000, líquido 5000, saldo 10000, PARTIAL, vencida, cliente e quadra',
    (e->>'amount_due')::int = 15000 and (e->>'net_received')::bigint = 5000 and (e->>'balance')::bigint = 10000
    and e->>'payment_status' = 'PARTIAL' and e->'overdue' = 'true'::jsonb and e->>'status' = 'CONFIRMED'
    and e->>'customer_name' = 'Cliente P3B1' and e->>'customer_phone' = '11988887777' and e->>'court_name' = 'Q1'
    and e->'recurring_reservation_id' = 'null'::jsonb,
    coalesce(e::text, 'r02 ausente'));

  -- F07 vencido × a vencer pelo end_at contra as_of
  perform pg_temp.ok('F07 vencido x a vencer: overdue/upcoming e contagens',
    (o->'receivables'->>'overdue')::bigint = pg_temp.sel(48000, 43000) and (o->'receivables'->>'overdue_count')::bigint = pg_temp.sel(5, 4)
    and (o->'receivables'->>'upcoming')::bigint = 29000 and (o->'receivables'->>'upcoming_count')::int = 4
    and (o->'receivables'->>'open')::bigint = pg_temp.sel(77000, 72000),
    o->>'receivables');

  -- F08 crédito: entra em credits, não em open
  r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 200));
  perform pg_temp.ok('F08 crédito (OVERPAID): credits 1/2000 e r12 fora de A receber',
    (o->'credits'->>'count')::int = 1 and (o->'credits'->>'total')::bigint = 2000
    and not exists (select 1 from jsonb_array_elements(r->'items') i where (i->>'reservation_id')::uuid = pg_temp.k('r12')),
    o->>'credits');

  -- F09 ticket arredondado ao centavo mais próximo (meio centavo para cima), nunca floor
  o2 := pg_temp.do_('owner', pg_temp.ov(org, null, pg_temp.dd(-90), pg_temp.dd(-90)));
  r := pg_temp.do_('owner', pg_temp.ov(org, null, pg_temp.dd(-95), pg_temp.dd(-95)));
  perform pg_temp.ok('F09 ticket: 30002/3 => 10001; 20001/2 => 10001 (floor daria 10000)',
    (o2->'average_ticket'->>'current')::bigint = 10001 and (o2->'expected_revenue'->>'current')::bigint = 30002
    and (r->'average_ticket'->>'current')::bigint = 10001 and (r->'expected_revenue'->>'current')::bigint = 20001
    and (o->'average_ticket'->>'current')::bigint = pg_temp.sel(10818, 11000),
    format('%s %s %s', o2->'average_ticket', r->'average_ticket', o->'average_ticket'));

  -- F10 filtro de arena restringe reservas e pagamentos; outra organização nunca entra
  o2 := pg_temp.do_('owner', pg_temp.ov(org, pg_temp.k('a2'), M_F, M_T));
  r := pg_temp.do_('owner', pg_temp.ov(org, pg_temp.k('a1'), M_F, M_T));
  perform pg_temp.ok('F10 arena: A2 = r15 (30000, aberto 20000, bruto 10000); A1 = total - A2; org2 ausente',
    (o2->'expected_revenue'->>'current')::bigint = 30000 and (o2->'receivables'->>'open')::bigint = 20000
    and (o2->'cash_in'->>'gross')::bigint = 10000 and (o2->'cash_in'->>'refunds')::bigint = 0
    and (r->'expected_revenue'->>'current')::bigint = pg_temp.sel(89000, 80000)
    and (r->'cash_in'->>'gross')::bigint = pg_temp.sel(43000, 39000) and (r->'cash_in'->>'refunds')::bigint = 10000
    and (pg_temp.do_('out', pg_temp.ov(pg_temp.k('org2'), null, M_F, M_T))->'expected_revenue'->>'current')::bigint = 50000,
    format('a2=%s a1=%s', o2->'expected_revenue', r->'expected_revenue'));

  -- F11 comparação explícita e ausência dela; contrato JSON
  o2 := pg_temp.do_('owner', pg_temp.ov(org, null, M_F, M_T, C_F, C_T));
  perform pg_temp.ok('F11 comparação: valores do período informado (29000 / 2 / 14500 / 29000)',
    o2->'compare' = jsonb_build_object('from', to_char(C_F, 'YYYY-MM-DD'), 'to', to_char(C_T, 'YYYY-MM-DD'), 'days', 41)
    and (o2->'expected_revenue'->>'compare')::bigint = 29000 and (o2->'priced_count'->>'compare')::int = 2
    and (o2->'average_ticket'->>'compare')::bigint = 14500 and (o2->'cash_in'->>'compare_net')::bigint = 29000
    and o2->'expected_revenue'->'current' = o->'expected_revenue'->'current',
    o2::text);
  perform pg_temp.ok('F11b sem comparação: compare e campos *_compare nulos',
    o->'compare' = 'null'::jsonb and o->'expected_revenue'->'compare' = 'null'::jsonb and o->'priced_count'->'compare' = 'null'::jsonb
    and o->'average_ticket'->'compare' = 'null'::jsonb and o->'cash_in'->'compare_net' = 'null'::jsonb,
    o::text);
  perform pg_temp.ok('F11c contrato JSON exato da visão geral, sem despesa/resultado/saldo',
    (select array_agg(x order by x) from jsonb_object_keys(o) x)
      = array['as_of','average_ticket','cash_in','compare','credits','expected_revenue','period','priced_count','receivables','reservations']
    and (select array_agg(x order by x) from jsonb_object_keys(o->'reservations') x) = array['billable','cancelled','priced','unpriced']
    and (select array_agg(x order by x) from jsonb_object_keys(o->'cash_in') x) = array['compare_net','gross','net','refunds']
    and (select array_agg(x order by x) from jsonb_object_keys(o->'receivables') x) = array['open','overdue','overdue_count','upcoming','upcoming_count']
    and o->'period' = jsonb_build_object('from', to_char(M_F, 'YYYY-MM-DD'), 'to', to_char(M_T, 'YYYY-MM-DD'), 'days', 41, 'timezone', 'America/Sao_Paulo')
    and o->>'as_of' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?\+00:00$'
    and o::text !~* '(expense|despesa|saldo|result)'
    and (o->'cash_in'->>'net')::bigint = (o->'cash_in'->>'gross')::bigint - (o->'cash_in'->>'refunds')::bigint,
    o::text);
end $$;

-- ----------------------------------------------------------------------------- F12: paridade com private.rg_financials (oráculo)
do $$
declare
  v_start timestamptz := pg_temp.dd(-100)::timestamp at time zone 'America/Sao_Paulo';
  v_end timestamptz := (pg_temp.dd(20) + 1)::timestamp at time zone 'America/Sao_Paulo';
  v_n int; v_bad int; v_detail text; v_status text[]; v_pstatus text[];
  r jsonb; v_bad2 int;
begin
  create temp table mine on commit drop as select * from private.rg_fin_reservation_rows(pg_temp.k('org'), null, v_start, v_end);
  create temp table oracle on commit drop as
    select * from private.rg_financials((select array_agg(reservation_id) from mine));
  select count(*) into v_n from mine;
  select count(*), string_agg(coalesce(m.reservation_id, o.reservation_id)::text, ',') into v_bad, v_detail
    from mine m full join oracle o on o.reservation_id = m.reservation_id
   where m.reservation_id is null or o.reservation_id is null
      or m.status is distinct from o.status
      or m.amount_due is distinct from o.amount_due
      or m.amount_received is distinct from o.amount_received
      or m.amount_refunded is distinct from o.amount_refunded
      or m.net_received is distinct from o.net_received
      or m.balance is distinct from o.balance
      or m.collectible is distinct from o.collectible
      or m.collectible_balance is distinct from o.collectible_balance
      or m.payment_status is distinct from o.payment_status;
  select array_agg(distinct status order by status), array_agg(distinct payment_status order by payment_status)
    into v_status, v_pstatus from mine;
  perform pg_temp.ok('F12 paridade: amount_due, recebido, estornado, net_received, balance, collectible(_balance) e payment_status idênticos a rg_financials',
    v_bad = 0 and v_n = (select count(*) from public.reservations where organization_id = pg_temp.k('org')),
    format('%s reservas, %s divergências %s', v_n, v_bad, coalesce(v_detail, '')));
  perform pg_temp.ok('F12b cobertura: PENDING/CONFIRMED/NO_SHOW/CANCELLED/BLOCKED' || case when pg_temp.paid() then '/PAID' else ' (PAID: N/A sem superusuário)' end
      || '; parcial/integral/estorno/anulado/crédito/sem valor',
    v_status @> array['BLOCKED','CANCELLED','CONFIRMED','NO_SHOW','PENDING'] and (not pg_temp.paid() or 'PAID' = any(v_status))
    and v_pstatus @> array['CANCELLED','NOT_APPLICABLE','OVERPAID','PAID','PARTIAL','PENDING','REFUNDED','RETAINED','UNPRICED']
    and exists (select 1 from public.reservation_payments p where p.organization_id = pg_temp.k('org') and p.voided_at is not null)
    and exists (select 1 from public.reservation_payments p where p.organization_id = pg_temp.k('org') and p.kind = 'REFUND'),
    format('status=%s payment_status=%s', v_status, v_pstatus));
  -- paridade também pelo contrato público (A receber OPEN + UNPRICED)
  select count(*) into v_bad2 from (
    select (i->>'reservation_id')::uuid id, (i->>'amount_due')::int due, (i->>'net_received')::bigint net,
           (i->>'balance')::bigint bal, i->>'payment_status' ps
      from jsonb_array_elements(pg_temp.do_('owner', pg_temp.rcv(pg_temp.k('org'), null, pg_temp.dd(-100), pg_temp.dd(20), 'OPEN', 200))->'items') i
    union all
    select (i->>'reservation_id')::uuid, null, (i->>'net_received')::bigint, null, i->>'payment_status'
      from jsonb_array_elements(pg_temp.do_('owner', pg_temp.rcv(pg_temp.k('org'), null, pg_temp.dd(-100), pg_temp.dd(20), 'UNPRICED', 200))->'items') i
  ) x join oracle o on o.reservation_id = x.id
  where x.due is distinct from o.amount_due or x.net is distinct from o.net_received
     or (x.bal is distinct from case when o.amount_due is null then null else o.collectible_balance end)
     or x.ps is distinct from o.payment_status;
  perform pg_temp.ok('F12c paridade pelo contrato público (rg_fin_receivables OPEN/UNPRICED x rg_financials)', v_bad2 = 0, v_bad2::text || ' divergências');
end $$;

-- ----------------------------------------------------------------------------- A: autorização
do $$
declare
  org uuid := pg_temp.k('org'); M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20);
  o_owner jsonb; o_mgr jsonb; o_adm jsonb;
begin
  perform pg_temp.expect('A01a RECEPTIONIST: overview => 42501', 'rec', pg_temp.ov(org, null, M_F, M_T), '42501', 'rg: sem permissão financeira');
  perform pg_temp.expect('A01b RECEPTIONIST: receivables => 42501', 'rec', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 50), '42501');
  perform pg_temp.expect('A01c RECEPTIONIST: cashflow => 42501', 'rec', pg_temp.cf(org, null, M_F, M_T, 'day'), '42501');
  perform pg_temp.expect('A01d RECEPTIONIST: cash_entries => 42501', 'rec', pg_temp.ce(org, null, M_F, M_T, 50), '42501');
  perform pg_temp.expect('A02 OWNER de outro tenant => 42501', 'out', pg_temp.ov(org, null, M_F, M_T), '42501', 'rg: sem permissão financeira');
  perform pg_temp.expect('A03 anônimo => 42501 (sem EXECUTE)', 'anon', pg_temp.ov(org, null, M_F, M_T), '42501');
  perform pg_temp.expect('A04 organização inexistente => 42501', 'owner', pg_temp.ov(gen_random_uuid(), null, M_F, M_T), '42501', 'rg: sem permissão financeira');
  perform pg_temp.expect('A05 arena de outra organização => 22023', 'owner', pg_temp.ov(org, pg_temp.k('b1'), M_F, M_T), '22023', 'rg: arena inválida');
  perform pg_temp.expect('A05b arena de outra organização em receivables => 22023', 'owner', pg_temp.rcv(org, pg_temp.k('b1'), M_F, M_T, 'OPEN', 50), '22023');
  perform pg_temp.expect('A05c service_role sem EXECUTE => 42501', 'service_role', pg_temp.ov(org, null, M_F, M_T), '42501');
  o_owner := pg_temp.do_('owner', pg_temp.ov(org, null, M_F, M_T));
  o_mgr := pg_temp.do_('mgr', pg_temp.ov(org, null, M_F, M_T));
  o_adm := pg_temp.do_('adm', pg_temp.ov(org, null, M_F, M_T));
  perform pg_temp.ok('A06 MANAGER e platform admin recebem exatamente o mesmo que o OWNER', o_mgr = o_owner and o_adm = o_owner, 'ok');
end $$;

-- ----------------------------------------------------------------------------- V: validação
do $$
declare org uuid := pg_temp.k('org'); M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20);
begin
  perform pg_temp.expect('V01 from > to => 22023', 'owner', pg_temp.ov(org, null, M_T, M_F), '22023', 'rg: período inválido');
  perform pg_temp.expect('V01b from nulo => 22023', 'owner', pg_temp.ov(org, null, null, M_T), '22023', 'rg: período inválido');
  perform pg_temp.expect('V02 367 dias => 22023', 'owner', pg_temp.ov(org, null, M_F, M_F + 366), '22023', 'rg: período acima do limite');
  perform pg_temp.expect('V02b receivables 367 dias => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_F + 366, 'OPEN', 50), '22023', 'rg: período acima do limite');
  perform pg_temp.expect('V02c cash_entries 367 dias => 22023', 'owner', pg_temp.ce(org, null, M_F, M_F + 366, 50), '22023', 'rg: período acima do limite');
  perform pg_temp.ok('V02d 366 dias é aceito', (pg_temp.call('owner', pg_temp.ov(org, null, M_F, M_F + 365))).state = 'OK', 'ok');
  perform pg_temp.expect('V03 ano 1999 => 22023', 'owner', pg_temp.ov(org, null, date '1999-12-31', date '2000-01-01'), '22023', 'rg: período inválido');
  perform pg_temp.expect('V03b ano 2101 => 22023', 'owner', pg_temp.ov(org, null, date '2100-12-31', date '2101-01-01'), '22023', 'rg: período inválido');
  perform pg_temp.expect('V04 comparação só com início => 22023', 'owner', pg_temp.ov(org, null, M_F, M_T, M_F - 41, null), '22023', 'rg: período de comparação inválido');
  perform pg_temp.expect('V04b comparação sobreposta (compare_to >= from) => 22023', 'owner', pg_temp.ov(org, null, M_F, M_T, M_F - 10, M_F), '22023', 'rg: período de comparação inválido');
  perform pg_temp.expect('V04c comparação invertida => 22023', 'owner', pg_temp.ov(org, null, M_F, M_T, M_F - 1, M_F - 5), '22023', 'rg: período de comparação inválido');
  perform pg_temp.expect('V04d comparação de 367 dias => 22023', 'owner', pg_temp.ov(org, null, M_F, M_T, M_F - 367, M_F - 1), '22023', 'rg: período de comparação inválido');
  perform pg_temp.expect('V04e comparação em 1999 => 22023', 'owner', pg_temp.ov(org, null, date '2000-02-01', date '2000-02-10', date '1999-12-30', date '2000-01-08'), '22023', 'rg: período de comparação inválido');
  perform pg_temp.expect('V05 filtro inválido => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_T, 'FOO', 50), '22023', 'rg: filtro inválido');
  perform pg_temp.expect('V05b filtro nulo => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_T, null, 50), '22023', 'rg: filtro inválido');
  perform pg_temp.expect('V06 limite 0 => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 0), '22023', 'rg: limite inválido');
  perform pg_temp.expect('V06b limite 201 => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 201), '22023', 'rg: limite inválido');
  perform pg_temp.expect('V06c cash_entries limite 0 => 22023', 'owner', pg_temp.ce(org, null, M_F, M_T, 0), '22023', 'rg: limite inválido');
  perform pg_temp.expect('V07 granularidade inválida => 22023', 'owner', pg_temp.cf(org, null, M_F, M_T, 'week'), '22023', 'rg: granularidade inválida');
  perform pg_temp.expect('V07b cashflow diário de 367 dias => 22023', 'owner', pg_temp.cf(org, null, M_F, M_F + 366, 'day'), '22023', 'rg: período acima do limite');
  perform pg_temp.expect('V07c cashflow mensal de 61 meses => 22023', 'owner', pg_temp.cf(org, null, date '2020-01-01', date '2025-01-01', 'month'), '22023', 'rg: período acima do limite');
  perform pg_temp.ok('V07d cashflow mensal de 60 meses é aceito', (pg_temp.call('owner', pg_temp.cf(org, null, date '2020-01-01', date '2024-12-31', 'month'))).state = 'OK', 'ok');
  perform pg_temp.expect('V07e cashflow anual de 11 anos => 22023', 'owner', pg_temp.cf(org, null, date '2015-01-01', date '2025-01-01', 'year'), '22023', 'rg: período acima do limite');
  perform pg_temp.expect('V08 receivables cursor incompleto => 22023', 'owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 50, now(), null), '22023', 'rg: cursor incompleto');
  perform pg_temp.expect('V08b cash_entries cursor incompleto => 22023', 'owner', pg_temp.ce(org, null, M_F, M_T, 50, null, gen_random_uuid()), '22023', 'rg: cursor incompleto');
end $$;

-- ----------------------------------------------------------------------------- P: paginação
do $$
declare
  org uuid := pg_temp.k('org'); M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20);
  r jsonb; e jsonb; v_s timestamptz; v_i uuid; v_pages int; v_ids uuid[]; v_keys text[]; v_all uuid[]; v_last_null boolean;
begin
  -- P01 A receber OPEN, 2 por página
  v_ids := '{}'; v_keys := '{}'; v_pages := 0; v_s := null; v_i := null;
  loop
    r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 2, v_s, v_i));
    for e in select * from jsonb_array_elements(r->'items') loop
      v_ids := v_ids || (e->>'reservation_id')::uuid;
      v_keys := v_keys || ((e->>'start_at')::timestamptz::text || '|' || (e->>'reservation_id'));
    end loop;
    v_pages := v_pages + 1;
    exit when jsonb_typeof(r->'next_cursor') = 'null' or v_pages > 50;
    v_s := (r->'next_cursor'->>'start_at')::timestamptz; v_i := (r->'next_cursor'->>'id')::uuid;
  end loop;
  select array_agg((i->>'reservation_id')::uuid order by n) into v_all
    from jsonb_array_elements(pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'OPEN', 200))->'items') with ordinality t(i, n);
  perform pg_temp.ok('P01 A receber paginado (2/página): sem repetir nem pular, ordem (start_at, id), igual à página única',
    cardinality(v_ids) = pg_temp.sel(9, 8) and v_ids = v_all
    and (select count(distinct x) from unnest(v_ids) x) = cardinality(v_ids)
    and v_ids = (select array_agg(f.reservation_id order by f.start_at, f.reservation_id)
                   from private.rg_fin_reservation_rows(org, null, M_F::timestamp at time zone 'America/Sao_Paulo', (M_T + 1)::timestamp at time zone 'America/Sao_Paulo') f
                  where f.collectible and f.amount_due is not null and f.collectible_balance > 0),
    format('%s itens em %s páginas', cardinality(v_ids), v_pages));

  -- P02 empate de start_at (r16/r17) com 1 por página: desempate por id, ninguém some
  v_ids := '{}'; v_pages := 0; v_s := null; v_i := null;
  loop
    r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, 'UPCOMING', 1, v_s, v_i));
    for e in select * from jsonb_array_elements(r->'items') loop v_ids := v_ids || (e->>'reservation_id')::uuid; end loop;
    v_pages := v_pages + 1;
    exit when jsonb_typeof(r->'next_cursor') = 'null' or v_pages > 50;
    v_s := (r->'next_cursor'->>'start_at')::timestamptz; v_i := (r->'next_cursor'->>'id')::uuid;
  end loop;
  perform pg_temp.ok('P02 empate de start_at: os dois aparecem, na ordem do id, 1 por página, última página sem cursor',
    cardinality(v_ids) = 4 and pg_temp.k('r16') = any(v_ids) and pg_temp.k('r17') = any(v_ids)
    and array_position(v_ids, least(pg_temp.k('r16'), pg_temp.k('r17'))) < array_position(v_ids, greatest(pg_temp.k('r16'), pg_temp.k('r17'))),
    format('%s itens em %s páginas', cardinality(v_ids), v_pages));

  -- P03 lançamentos de caixa, 3 por página, ordem desc
  v_ids := '{}'; v_keys := '{}'; v_pages := 0; v_s := null; v_i := null;
  loop
    r := pg_temp.do_('owner', pg_temp.ce(org, null, M_F, M_T, 3, v_s, v_i));
    for e in select * from jsonb_array_elements(r->'items') loop v_ids := v_ids || (e->>'payment_id')::uuid; end loop;
    v_pages := v_pages + 1;
    v_last_null := jsonb_typeof(r->'next_cursor') = 'null';
    exit when v_last_null or v_pages > 50;
    v_s := (r->'next_cursor'->>'received_at')::timestamptz; v_i := (r->'next_cursor'->>'id')::uuid;
  end loop;
  perform pg_temp.ok('P03 cash_entries paginado (3/página): sem anulado, sem repetir, ordem (received_at, id) desc, cursor nulo no fim',
    v_last_null and cardinality(v_ids) = pg_temp.sel(10, 9) and not (pg_temp.k('p11') = any(v_ids))
    and (select count(distinct x) from unnest(v_ids) x) = cardinality(v_ids)
    and v_ids = (select array_agg(p.id order by p.received_at desc, p.id desc) from public.reservation_payments p
                  where p.organization_id = org and p.voided_at is null
                    and p.received_at >= M_F::timestamp at time zone 'America/Sao_Paulo'
                    and p.received_at < (M_T + 1)::timestamp at time zone 'America/Sao_Paulo'),
    format('%s lançamentos em %s páginas', cardinality(v_ids), v_pages));
end $$;

-- ----------------------------------------------------------------------------- C: cashflow
do $$
declare
  org uuid := pg_temp.k('org'); M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20); L date := pg_temp.dd(-80);
  c jsonb; o jsonb; cm jsonb; cy jsonb; ct jsonb;
begin
  c := pg_temp.do_('owner', pg_temp.cf(org, null, M_F, M_T, 'day'));
  o := pg_temp.do_('owner', pg_temp.ov(org, null, M_F, M_T));
  perform pg_temp.ok('C01 cashflow diário: 41 buckets contínuos, com dias zerados, includes = reservation_payments',
    jsonb_array_length(c->'buckets') = 41
    and (select array_agg(b->>'bucket' order by n) from jsonb_array_elements(c->'buckets') with ordinality t(b, n))
        = (select array_agg(to_char(d, 'YYYY-MM-DD') order by d) from generate_series(M_F, M_T, interval '1 day') d)
    and exists (select 1 from jsonb_array_elements(c->'buckets') b where (b->>'in_gross')::bigint = 0 and (b->>'refunds')::bigint = 0)
    and c->'includes' = '["reservation_payments"]'::jsonb and c->>'granularity' = 'day'
    and (select bool_and((b->>'in_net')::bigint = (b->>'in_gross')::bigint - (b->>'refunds')::bigint) from jsonb_array_elements(c->'buckets') b),
    jsonb_array_length(c->'buckets')::text);
  perform pg_temp.ok('C02 totais do cashflow = cash_in da visão geral = soma dos buckets',
    (c->'totals'->>'in_gross')::bigint = (o->'cash_in'->>'gross')::bigint
    and (c->'totals'->>'refunds')::bigint = (o->'cash_in'->>'refunds')::bigint
    and (c->'totals'->>'in_net')::bigint = (o->'cash_in'->>'net')::bigint
    and (c->'totals'->>'in_gross')::bigint = (select sum((b->>'in_gross')::bigint) from jsonb_array_elements(c->'buckets') b),
    format('%s x %s', c->'totals', o->'cash_in'));
  cm := pg_temp.do_('owner', pg_temp.cf(org, null, pg_temp.dd(-100), M_T, 'month'));
  cy := pg_temp.do_('owner', pg_temp.cf(org, null, pg_temp.dd(-100), M_T, 'year'));
  ct := pg_temp.do_('owner', pg_temp.cf(org, null, L, L + 1, 'day'));
  perform pg_temp.ok('C03 formato dos buckets (dia/mês/ano) e fuso: pagamento das 23:30 locais no bucket do dia local',
    jsonb_array_length(cm->'buckets') = ((extract(year from M_T) * 12 + extract(month from M_T)) - (extract(year from pg_temp.dd(-100)) * 12 + extract(month from pg_temp.dd(-100))) + 1)::int
    and (select bool_and(b->>'bucket' ~ '^\d{4}-\d{2}-01$') from jsonb_array_elements(cm->'buckets') b)
    and jsonb_array_length(cy->'buckets') = (extract(year from M_T) - extract(year from pg_temp.dd(-100)) + 1)::int
    and (select bool_and(b->>'bucket' ~ '^\d{4}-01-01$') from jsonb_array_elements(cy->'buckets') b)
    and (cm->'totals'->>'in_gross')::bigint = (cy->'totals'->>'in_gross')::bigint
    and ct->'buckets'->0->>'bucket' = to_char(L, 'YYYY-MM-DD') and (ct->'buckets'->0->>'in_gross')::bigint = 11111
    and (ct->'buckets'->1->>'in_gross')::bigint = 0,
    format('mês=%s ano=%s fuso=%s', jsonb_array_length(cm->'buckets'), jsonb_array_length(cy->'buckets'), ct->'buckets'));
end $$;

-- ----------------------------------------------------------------------------- K: consistência A receber x visão geral
do $$
declare
  org uuid := pg_temp.k('org'); M_F date := pg_temp.dd(-20); M_T date := pg_temp.dd(20);
  o jsonb; v_f text; v_sum bigint; v_cnt int; r jsonb; e jsonb; v_s timestamptz; v_i uuid; v_pages int; v_ok boolean := true; v_txt text := '';
begin
  o := pg_temp.do_('owner', pg_temp.ov(org, null, M_F, M_T));
  foreach v_f in array array['OPEN', 'OVERDUE', 'UPCOMING'] loop
    v_sum := 0; v_cnt := 0; v_pages := 0; v_s := null; v_i := null;
    loop
      r := pg_temp.do_('owner', pg_temp.rcv(org, null, M_F, M_T, v_f, 3, v_s, v_i));
      for e in select * from jsonb_array_elements(r->'items') loop v_sum := v_sum + (e->>'balance')::bigint; v_cnt := v_cnt + 1; end loop;
      v_pages := v_pages + 1;
      exit when jsonb_typeof(r->'next_cursor') = 'null' or v_pages > 50;
      v_s := (r->'next_cursor'->>'start_at')::timestamptz; v_i := (r->'next_cursor'->>'id')::uuid;
    end loop;
    v_txt := v_txt || format('%s=%s/%s ', v_f, v_sum, v_cnt);
    v_ok := v_ok and v_sum = case v_f when 'OPEN' then (o->'receivables'->>'open')::bigint
                                      when 'OVERDUE' then (o->'receivables'->>'overdue')::bigint
                                      else (o->'receivables'->>'upcoming')::bigint end
                 and (v_f = 'OPEN' or v_cnt = case v_f when 'OVERDUE' then (o->'receivables'->>'overdue_count')::int
                                                       else (o->'receivables'->>'upcoming_count')::int end);
  end loop;
  perform pg_temp.ok('K01 soma dos saldos de todas as páginas de A receber = open / overdue / upcoming da visão geral (e contagens)',
    v_ok, v_txt || (o->>'receivables'));
end $$;

-- ----------------------------------------------------------------------------- S e G
do $$
declare v_bad text;
begin
  perform pg_temp.ok('S01 nenhuma linha alterada por nenhuma RPC da 03B.1 (hash das orgs de fixture + contagens globais)',
    pg_temp.snap() = (select v from fs where k = 'snap0'), 'antes/depois');
  perform pg_temp.ok('S01b session_replication_role = origin logo após o fixture PAID e no fim do teste',
    (select v from fs where k = 'srr_after_paid') = 'origin' and current_setting('session_replication_role') = 'origin',
    format('após fixture=%s fim=%s', (select v from fs where k = 'srr_after_paid'), current_setting('session_replication_role')));

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname, p.proname) in (('public', 'rg_fin_overview'), ('public', 'rg_fin_receivables'), ('public', 'rg_fin_cashflow'), ('public', 'rg_fin_cash_entries'))
     and not (p.prosecdef and p.provolatile = 's' and 'search_path=""' = any(p.proconfig) and 'TimeZone=UTC' = any(p.proconfig)
              and pg_get_userbyid(p.proowner) = 'postgres'
              and has_function_privilege('authenticated', p.oid, 'EXECUTE')
              and not has_function_privilege('anon', p.oid, 'EXECUTE')
              and not has_function_privilege('service_role', p.oid, 'EXECUTE')
              and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0));
  perform pg_temp.ok('G01a RPCs públicas: SECURITY DEFINER, stable, search_path vazio, TimeZone UTC, owner postgres, EXECUTE só authenticated',
    v_bad is null and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname in ('rg_fin_overview', 'rg_fin_receivables', 'rg_fin_cashflow', 'rg_fin_cash_entries')) = 4,
    coalesce(v_bad, 'ok'));

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname in ('rg_fin_scope', 'rg_fin_reservation_rows')
     and not (p.prosecdef and 'search_path=""' = any(p.proconfig) and pg_get_userbyid(p.proowner) = 'postgres'
              and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
              and not has_function_privilege('anon', p.oid, 'EXECUTE')
              and not has_function_privilege('service_role', p.oid, 'EXECUTE')
              and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0));
  perform pg_temp.ok('G01b funções privadas: SECURITY DEFINER, search_path vazio, sem EXECUTE para nenhum papel de API',
    v_bad is null and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'private' and p.proname in ('rg_fin_scope', 'rg_fin_reservation_rows')) = 2,
    coalesce(v_bad, 'ok'));
  perform pg_temp.expect('G01c authenticated não chama private.rg_fin_scope diretamente => 42501', 'owner',
    format('select to_jsonb(s) from private.rg_fin_scope(%L::uuid, null, current_date, current_date, 1) s', pg_temp.k('org')), '42501');
  perform pg_temp.expect('G01d authenticated não chama private.rg_fin_reservation_rows diretamente => 42501', 'owner',
    format('select to_jsonb(array_agg(f)) from private.rg_fin_reservation_rows(%L::uuid, null, now() - interval ''1 day'', now()) f', pg_temp.k('org')), '42501');
  perform pg_temp.ok('G01e índices de período presentes com as colunas do contrato',
    exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'idx_reservations_org_start' and indexdef like '%(organization_id, start_at)%')
    and exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'idx_reservations_arena_start' and indexdef like '%(arena_id, start_at)%'),
    'ok');
end $$;

-- ----------------------------------------------------------------------------- resultado
-- Falha => erro (exit != 0, sem COMMIT). Sucesso => resumo determinístico (só nomes; sem UUIDs/datas) + ROLLBACK.
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from rr;
  if v_fail > 0 then
    select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from rr;
    raise exception E'P3B1_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.\n%',
      v_total - v_fail, v_fail, v_total, v_txt;
  end if;
end $$;

select format('P3B1_RESULTS OK — %s PASS / 0 FAIL (total %s; PAID legado: %s)',
              count(*), count(*), case when pg_temp.paid() then 'coberto' else 'N/A' end)
       || E'\n' || string_agg('PASS ' || name, E'\n' order by seq) as p3b1_results
  from rr;

rollback;
