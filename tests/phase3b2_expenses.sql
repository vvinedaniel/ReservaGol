-- =============================================================================
-- RESERVA GOL — FASE 03B.2 — testes SQL de Despesas & Caixa
-- Requer 03A + 03B.1 + migration_phase3b2_expenses.sql aplicadas. Banco de TESTE local, nunca Production.
--
-- Como rodar:
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3b2_expenses.sql
-- Sucesso: imprime "P3B2_RESULTS OK ..." e faz ROLLBACK explícito (exit 0). Falha: erro
-- "P3B2_RESULTS FAIL ..." (exit != 0), transação nunca confirmada. ZERO RESÍDUO nos dois caminhos.
--
-- Cobertura (Freeze 2): T01–T18, T24–T51, T58–T60 aqui. T19 (corrida do mesmo operation_id),
-- T20–T23 (sessões concorrentes reais) e T52–T57 (colisão, rollback, fingerprint, diff 03A/03B.1)
-- precisam de várias sessões/transações e ficam em tests/phase3b2_concurrency.sh.
-- Datas relativas a hoje (America/Sao_Paulo). Período de caixa: hoje-20 .. hoje. Período de
-- despesas: vencimento hoje-20 .. hoje+20. Cenários isolados usam movimentos em hoje-60
-- (fora dos períodos acima) para não alterar os números dos blocos de semântica.
-- =============================================================================
begin;
set local statement_timeout = '180s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table fd (k text primary key, d date not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3b2: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text)') is null then
    raise exception 'p3b2: migration 03B.2 não aplicada';
  end if;
  if to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is null then raise exception 'p3b2: 03B.1 ausente'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.today() returns date language sql stable as $$ select d from fd where k = 'today' $$;
create function pg_temp.dd(p_day integer) returns date language sql stable as $$ select pg_temp.today() + p_day $$;
create function pg_temp.ts(p_day integer, p_hhmm text) returns timestamptz language sql stable as $$
  select ((pg_temp.today() + p_day)::text || ' ' || p_hhmm || ':00-03:00')::timestamptz $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- Hash de TODAS as linhas da 03B.2 + audit (checagem de "nada mudou" nos erros)
create function pg_temp.snap() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 'ec:' || row_to_json(r)::text as x from public.expense_categories r
    union all select 'ex:' || row_to_json(r)::text from public.expenses r
    union all select 'ep:' || row_to_json(r)::text from public.expense_payments r
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r
    union all select 'rp:' || row_to_json(r)::text from public.reservation_payments r
  ) s), '')) $$;

-- Executa SQL como ator (JWT simulado + papel), devolvendo estado, mensagem e hint.
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
  if v.state <> 'OK' then raise exception 'p3b2 (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

-- Erro esperado: estado (+ hint opcional) e NENHUMA alteração.
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
create function pg_temp.q_create(p_op uuid, p_org uuid, p_arena uuid, p_cat uuid, p_desc text, p_amount integer, p_due date)
returns text language sql stable as $$
  select format('select public.rg_expense_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, %L, %s, %L::date, null)',
    p_op, p_org, p_arena, p_cat, p_desc, p_amount, p_due) $$;
create function pg_temp.q_pay(p_op uuid, p_exp uuid, p_amount integer, p_at timestamptz, p_method text default 'PIX')
returns text language sql stable as $$
  select format('select public.rg_expense_payment_register(%L::uuid, %L::uuid, %L, %s, %L::timestamptz, null)',
    p_op, p_exp, p_method, p_amount, p_at) $$;
create function pg_temp.q_rev(p_op uuid, p_pay uuid, p_amount integer, p_at timestamptz)
returns text language sql stable as $$
  select format('select public.rg_expense_payment_reverse(%L::uuid, %L::uuid, ''PIX'', %s, %L::timestamptz, null)',
    p_op, p_pay, p_amount, p_at) $$;
create function pg_temp.q_void(p_pay uuid) returns text language sql stable as $$
  select format('select public.rg_expense_payment_void(%L::uuid, ''lançamento errado'')', p_pay) $$;
create function pg_temp.q_cancel(p_exp uuid) returns text language sql stable as $$
  select format('select public.rg_expense_cancel(%L::uuid, ''não é mais devida'')', p_exp) $$;
create function pg_temp.q_upd(p_exp uuid, p_changes text) returns text language sql stable as $$
  select format('select public.rg_expense_update(%L::uuid, %L::jsonb)', p_exp, p_changes) $$;
create function pg_temp.q_det(p_exp uuid) returns text language sql stable as $$
  select format('select public.rg_expense_detail(%L::uuid)', p_exp) $$;
create function pg_temp.q_list(p_org uuid, p_arena uuid, p_cat uuid, p_from date, p_to date, p_status text, p_limit integer,
  p_ad date default null, p_ai uuid default null) returns text language sql stable as $$
  select format('select public.rg_expenses(%L::uuid, %L::uuid, %L::uuid, %L::date, %L::date, %L, %s, %L::date, %L::uuid)',
    p_org, p_arena, p_cat, p_from, p_to, p_status, p_limit, p_ad, p_ai) $$;
create function pg_temp.q_ov(p_org uuid, p_arena uuid, p_cat uuid, p_from date, p_to date, p_cf date default null, p_ct date default null)
returns text language sql stable as $$
  select format('select public.rg_expense_overview(%L::uuid, %L::uuid, %L::uuid, %L::date, %L::date, %L::date, %L::date)',
    p_org, p_arena, p_cat, p_from, p_to, p_cf, p_ct) $$;
create function pg_temp.q_cr(p_org uuid, p_arena uuid, p_from date, p_to date, p_gran text) returns text language sql stable as $$
  select format('select public.rg_fin_cash_result(%L::uuid, %L::uuid, %L::date, %L::date, %L)', p_org, p_arena, p_from, p_to, p_gran) $$;
create function pg_temp.q_mv(p_org uuid, p_arena uuid, p_from date, p_to date, p_limit integer,
  p_aa timestamptz default null, p_as smallint default null, p_ai uuid default null) returns text language sql stable as $$
  select format('select public.rg_fin_cash_movements(%L::uuid, %L::uuid, %L::date, %L::date, %s, %L::timestamptz, %L::smallint, %L::uuid)',
    p_org, p_arena, p_from, p_to, p_limit, p_aa, p_as, p_ai) $$;

-- Fixtures pelas RPCs reais
create function pg_temp.mk(p_key text, p_actor text, p_org text, p_arena text, p_cat text, p_desc text, p_amount integer, p_due integer)
returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_(p_actor, pg_temp.q_create(gen_random_uuid(), pg_temp.k(p_org),
         case when p_arena is null then null else pg_temp.k(p_arena) end, pg_temp.k(p_cat), p_desc, p_amount, pg_temp.dd(p_due)));
  insert into fx values (p_key, (r->>'expense_id')::uuid);
  return (r->>'expense_id')::uuid;
end $$;
create function pg_temp.epay(p_key text, p_actor text, p_exp text, p_amount integer, p_at timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_(p_actor, pg_temp.q_pay(gen_random_uuid(), pg_temp.k(p_exp), p_amount, p_at));
  insert into fx values (p_key, (r->>'payment_id')::uuid);
  return (r->>'payment_id')::uuid;
end $$;
create function pg_temp.erev(p_key text, p_actor text, p_pay text, p_amount integer, p_at timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_(p_actor, pg_temp.q_rev(gen_random_uuid(), pg_temp.k(p_pay), p_amount, p_at));
  insert into fx values (p_key, (r->>'payment_id')::uuid);
  return (r->>'payment_id')::uuid;
end $$;
create function pg_temp.det(p_exp text) returns jsonb language sql as $$ select pg_temp.do_('owner', pg_temp.q_det(pg_temp.k(p_exp))) $$;
-- Reserva + recebimento pela 03A (para Entradas)
create function pg_temp.res(p_key text, p_org text, p_arena text, p_court text, p_start timestamptz, p_price integer) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, price, created_by)
  values (pg_temp.k(p_org), pg_temp.k(p_arena), pg_temp.k(p_court), p_start, p_start + interval '1 hour', 'CONFIRMED', 'TESTE_P3B2',
          p_price, pg_temp.k('owner'))
  returning id into v_id;
  insert into fx values (p_key, v_id);
  return v_id;
end $$;
create function pg_temp.rpay(p_key text, p_actor text, p_res text, p_amount integer, p_at timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_(p_actor, format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', %s, %L::timestamptz, null)',
    gen_random_uuid(), pg_temp.k(p_res), p_amount, p_at));
  insert into fx values (p_key, (r->>'payment_id')::uuid);
  return (r->>'payment_id')::uuid;
end $$;

-- ----------------------------------------------------------------------------- fixtures (desfeitas no fim)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_out uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); u_str uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_a2 uuid; v_b1 uuid; v_c1 uuid; v_c2 uuid; v_c4 uuid;
  v_tag text := 'p3b2-' || substr(md5(clock_timestamp()::text), 1, 8);
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'), (u_rec, v_tag || '-rec@reservagol.test'),
    (u_out, v_tag || '-out@reservagol.test'), (u_adm, v_tag || '-adm@reservagol.test'), (u_str, v_tag || '-str@reservagol.test');
  insert into public.profiles (id) values (u_adm) on conflict (id) do nothing;
  update public.profiles set is_platform_admin = true where id = u_adm;
  -- organizações criadas pelo caminho normal: o trigger semeia as 10 categorias
  insert into public.organizations (name, is_demo) values ('P3B2 ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3B2 outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;
  insert into public.arenas (organization_id, name) values (v_org, 'A2 ' || v_tag) returning id into v_a2;
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a2, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'Q4') returning id into v_c4;
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('adm', u_adm), ('str', u_str),
    ('org', v_org), ('org2', v_org2), ('a1', v_a1), ('a2', v_a2), ('b1', v_b1), ('c1', v_c1), ('c2', v_c2), ('c4', v_c4);
  insert into fx select 'cat_' || lower(translate(c.name, 'ÁáçãéêíóôõúÍ ', 'aacaeeiooouI_')), c.id
    from public.expense_categories c where c.organization_id = v_org;
  insert into fx select 'cat2_outros', c.id from public.expense_categories c where c.organization_id = v_org2 and c.name = 'Outros';
  insert into fd values ('today', (now() at time zone 'America/Sao_Paulo')::date);
end $$;

-- Despesas e lançamentos da semântica
do $$
begin
  perform pg_temp.mk('e_open', 'mgr', 'org', 'a1', 'cat_aluguel', 'Aluguel do mês', 10000, 5);
  perform pg_temp.mk('e_over', 'mgr', 'org', null, 'cat_energia', 'Conta de luz', 20000, -3);            -- geral (sem arena)
  perform pg_temp.mk('e_paid', 'mgr', 'org', 'a1', 'cat_outros', 'Paga', 15000, -1);
  perform pg_temp.epay('p_paid', 'mgr', 'e_paid', 15000, pg_temp.ts(-1, '10:00'));
  perform pg_temp.mk('e_part', 'mgr', 'org', 'a2', 'cat_outros', 'Parcial', 30000, -2);
  perform pg_temp.epay('p_part', 'mgr', 'e_part', 10000, pg_temp.ts(-2, '10:00'));
  perform pg_temp.mk('e_canc', 'mgr', 'org', 'a1', 'cat_outros', 'Cancelada', 5000, 0);
  perform pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_canc')));
  perform pg_temp.mk('e_rev', 'mgr', 'org', 'a1', 'cat_outros', 'Devolvida', 12000, 1);
  perform pg_temp.epay('p_rev', 'mgr', 'e_rev', 12000, pg_temp.ts(-2, '11:00'));
  perform pg_temp.erev('r_rev', 'mgr', 'p_rev', 12000, pg_temp.ts(-1, '09:00'));
  perform pg_temp.mk('e_void', 'mgr', 'org', 'a1', 'cat_outros', 'Anulada', 8000, 2);
  perform pg_temp.epay('p_void', 'mgr', 'e_void', 8000, pg_temp.ts(-3, '10:00'));
  perform pg_temp.do_('mgr', pg_temp.q_void(pg_temp.k('p_void')));
  perform pg_temp.mk('e_tie', 'mgr', 'org', 'a1', 'cat_outros', 'Empate de horário', 7000, -4);
  perform pg_temp.epay('p_tie', 'mgr', 'e_tie', 7000, pg_temp.ts(-4, '12:00'));
  perform pg_temp.mk('e_late', 'mgr', 'org', null, 'cat_outros', 'Vencida antes, paga no período', 4000, -30);
  perform pg_temp.epay('p_late', 'mgr', 'e_late', 4000, pg_temp.ts(-5, '10:00'));
  -- empate de vencimento (paginação), criadas pelo OWNER
  perform pg_temp.mk('e_t1', 'owner', 'org', 'a1', 'cat_aluguel', 'T1', 100, 10);
  perform pg_temp.mk('e_t2', 'owner', 'org', 'a1', 'cat_aluguel', 'T2', 200, 10);
  perform pg_temp.mk('e_t3', 'owner', 'org', 'a1', 'cat_aluguel', 'T3', 300, 10);
  perform pg_temp.mk('e_t4', 'owner', 'org', 'a1', 'cat_aluguel', 'T4', 400, 10);
  perform pg_temp.mk('e_t5', 'owner', 'org', 'a1', 'cat_aluguel', 'T5', 500, 10);
  -- outra organização (isolamento)
  perform pg_temp.mk('e_o2', 'out', 'org2', 'b1', 'cat2_outros', 'Org2', 99999, 0);
  perform pg_temp.epay('p_o2', 'out', 'e_o2', 1000, pg_temp.ts(-1, '10:00'));
  -- Entradas (03A)
  perform pg_temp.res('r1', 'org', 'a1', 'c1', pg_temp.ts(-2, '18:00'), 50000);
  perform pg_temp.rpay('rp1', 'rec', 'r1', 30000, pg_temp.ts(-2, '20:00'));
  perform pg_temp.do_('mgr', format('select public.rg_payment_refund(%L::uuid, %L::uuid, ''PIX'', 5000, %L::timestamptz, null)',
    gen_random_uuid(), pg_temp.k('rp1'), pg_temp.ts(-1, '08:00')));
  perform pg_temp.res('r2', 'org', 'a2', 'c2', pg_temp.ts(-1, '18:00'), 20000);
  perform pg_temp.rpay('rp2', 'rec', 'r2', 20000, pg_temp.ts(-1, '20:00'));
  perform pg_temp.res('r_tie', 'org', 'a1', 'c1', pg_temp.ts(-4, '09:00'), 7000);
  perform pg_temp.rpay('rp_tie', 'rec', 'r_tie', 7000, pg_temp.ts(-4, '12:00'));                     -- MESMO instante de p_tie
  perform pg_temp.res('r_o2', 'org2', 'b1', 'c4', pg_temp.ts(-1, '18:00'), 9000);
  perform pg_temp.rpay('rp_o2', 'out', 'r_o2', 9000, pg_temp.ts(-1, '20:00'));
end $$;

-- ============================================================================= T01–T07 autorização / tenant
do $$
declare
  v_reads text[]; v_writes text[]; v_sql text; v record; v_bad text := ''; v_bad2 text := ''; v_ok boolean;
begin
  v_reads := array[
    format('select public.rg_expense_categories(%L::uuid, false)', pg_temp.k('org')),
    pg_temp.q_ov(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20)),
    pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'ACTIVE', 50),
    pg_temp.q_det(pg_temp.k('e_open')),
    pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 'day'),
    pg_temp.q_mv(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 50)];
  foreach v_sql in array v_reads loop
    select * into v from pg_temp.call('owner', v_sql); if v.state <> 'OK' then v_bad := v_bad || v.state || ' '; end if;
    select * into v from pg_temp.call('mgr', v_sql); if v.state <> 'OK' then v_bad2 := v_bad2 || v.state || ' '; end if;
  end loop;
  perform pg_temp.ok('T01 OWNER: 6 leituras OK; despesas T1..T5 criadas pelo OWNER', v_bad = '' and pg_temp.k('e_t5') is not null, v_bad);
  perform pg_temp.ok('T02 MANAGER: 6 leituras OK; escritas da fixture feitas pelo MANAGER', v_bad2 = '', v_bad2);

  v_writes := array[
    format('select public.rg_expense_category_create(%L::uuid, ''Nova'')', pg_temp.k('org')),
    format('select public.rg_expense_category_update(%L::uuid, ''{"name":"X"}'')', pg_temp.k('cat_outros')),
    pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), null, pg_temp.k('cat_outros'), 'x', 100, pg_temp.dd(0)),
    pg_temp.q_upd(pg_temp.k('e_open'), '{"description":"y"}'),
    pg_temp.q_cancel(pg_temp.k('e_open')),
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_open'), 100, now() - interval '1 minute'),
    pg_temp.q_rev(gen_random_uuid(), pg_temp.k('p_part'), 100, now() - interval '1 minute'),
    pg_temp.q_void(pg_temp.k('p_part'))];
  v_ok := true; v_bad := '';
  foreach v_sql in array v_reads || v_writes loop
    select * into v from pg_temp.call('rec', v_sql);
    if v.state <> '42501' then v_ok := false; v_bad := v_bad || v.state || ':' || left(v_sql, 40) || ' '; end if;
  end loop;
  perform pg_temp.ok('T03 RECEPTIONIST: 42501 nas 14 RPCs (banco, não só UI)', v_ok and cardinality(v_reads || v_writes) = 14, v_bad);

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like 'rg_expense%' or p.proname in ('rg_fin_cash_result', 'rg_fin_cash_movements'))
     and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('service_role', p.oid, 'EXECUTE')
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0));
  v_ok := true;
  foreach v_sql in array v_reads || v_writes loop
    select * into v from pg_temp.call('anon', v_sql); if v.state <> '42501' then v_ok := false; end if;
  end loop;
  perform pg_temp.ok('T04a anon e service_role sem EXECUTE nas 14; anon chamando => 42501', v_bad is null and v_ok, coalesce(v_bad, 'ok'));

  v_ok := true; v_bad := '';
  foreach v_sql in array v_reads || v_writes loop
    select * into v from pg_temp.call('adm', v_sql);
    if v.state not in ('42501', 'P0002') then v_ok := false; v_bad := v_bad || v.state || ' '; end if;
  end loop;
  select * into v from pg_temp.call('adm', format('select public.rg_fin_overview(%L::uuid, null, %L::date, %L::date)', pg_temp.k('org'), pg_temp.dd(-20), pg_temp.dd(0)));
  perform pg_temp.ok('T04b admin da plataforma sem vínculo negado nas 14; RPC 03B.1 inalterada (admin ainda lê)',
    v_ok and v.state = 'OK', v_bad || ' 03B.1=' || v.state);

  v_ok := true; v_bad := '';
  foreach v_sql in array v_reads || v_writes loop
    select * into v from pg_temp.call('out', v_sql);
    if v.state not in ('42501', 'P0002') then v_ok := false; v_bad := v_bad || v.state || ' '; end if;
  end loop;
  select * into v from pg_temp.call('str', pg_temp.q_det(pg_temp.k('e_open')));
  perform pg_temp.ok('T05 OWNER de outro tenant e usuário sem vínculo: negados (42501 / P0002), sem vazar dados',
    v_ok and v.state = 'P0002', v_bad || ' str=' || v.state);
end $$;

do $$ begin
  perform pg_temp.expect('T06a criar com categoria de outra organização => 22023', 'mgr',
    pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), null, pg_temp.k('cat2_outros'), 'x', 100, pg_temp.dd(0)), '22023');
  perform pg_temp.expect('T06b criar com arena de outra organização => 22023', 'mgr',
    pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), pg_temp.k('b1'), pg_temp.k('cat_outros'), 'x', 100, pg_temp.dd(0)), '22023');
  perform pg_temp.expect('T06c editar para categoria de outra organização => 22023', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_open'), format('{"category_id":"%s"}', pg_temp.k('cat2_outros'))), '22023');
  perform pg_temp.expect('T06d editar para arena de outra organização => 22023', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_open'), format('{"arena_id":"%s"}', pg_temp.k('b1'))), '22023');
  perform pg_temp.expect('T06e pagar despesa de outra organização => P0002', 'mgr',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_o2'), 100, now() - interval '1 minute'), 'P0002');
end $$;

do $$
declare a record; b record;
begin
  select * into a from pg_temp.call('owner', pg_temp.q_det(gen_random_uuid()));
  select * into b from pg_temp.call('owner', pg_temp.q_det(pg_temp.k('e_o2')));
  perform pg_temp.ok('T07 id inexistente e id de outro tenant: mesmo estado e mesma mensagem',
    a.state = 'P0002' and b.state = 'P0002' and a.result->>'msg' = b.result->>'msg', a.state || '/' || b.state);
end $$;

-- ============================================================================= T08–T12 status
do $$
declare d jsonb;
begin
  d := pg_temp.det('e_open');
  perform pg_temp.ok('T08 aberta: OPEN, sem overdue, a pagar = valor', d->>'status' = 'OPEN' and not (d->>'overdue')::boolean
    and (d->>'amount_due')::bigint = 10000 and (d->>'net_paid')::bigint = 0, d::text);
  d := pg_temp.det('e_over');
  perform pg_temp.ok('T09 vencida: OPEN + overdue (flag derivada)', d->>'status' = 'OPEN' and (d->>'overdue')::boolean, d::text);
  d := pg_temp.det('e_paid');
  perform pg_temp.ok('T10 paga: PAID com a pagar exatamente 0', d->>'status' = 'PAID' and (d->>'amount_due')::bigint = 0
    and (d->>'net_paid')::bigint = 15000 and not (d->>'overdue')::boolean, d::text);
  d := pg_temp.det('e_part');
  perform pg_temp.ok('T11 parcial vencida: PARTIAL + overdue, a pagar = 20000', d->>'status' = 'PARTIAL' and (d->>'overdue')::boolean
    and (d->>'amount_due')::bigint = 20000, d::text);
  d := pg_temp.det('e_canc');
  perform pg_temp.ok('T12 cancelada: CANCELLED, a pagar = 0, net = 0, sem overdue, motivo gravado', d->>'status' = 'CANCELLED'
    and (d->>'amount_due')::bigint = 0 and (d->>'net_paid')::bigint = 0 and not (d->>'overdue')::boolean
    and d->>'cancel_reason' = 'não é mais devida' and not (d->>'can_cancel')::boolean, d::text);
end $$;

-- ============================================================================= cards / caixa (antes dos cenários)
do $$
declare o jsonb; c jsonb; c1 jsonb; f jsonb; v_in bigint; v_in_a1 bigint;
begin
  o := pg_temp.do_('owner', pg_temp.q_ov(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), pg_temp.dd(-41), pg_temp.dd(-21)));
  perform pg_temp.ok('K01 previstas = 103500 (12 despesas não canceladas); comparação = 4000 (1)',
    (o->'expected'->>'current')::bigint = 103500 and (o->'expected'->>'count')::int = 12
    and (o->'expected'->>'compare')::bigint = 4000 and (o->'expected'->>'compare_count')::int = 1, o::text);
  perform pg_temp.ok('K02 pago das despesas do período = 32000; a pagar = 71500 (10); vencidas = 40000 (2); canceladas = 1',
    (o->'paid_of_period'->>'current')::bigint = 32000 and (o->'payable'->>'total')::bigint = 71500
    and (o->'payable'->>'count')::int = 10 and (o->'overdue'->>'total')::bigint = 40000 and (o->'overdue'->>'count')::int = 2
    and (o->>'cancelled_count')::int = 1 and not (o->>'excludes_general')::boolean, o::text);

  c := pg_temp.do_('owner', pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 'day'));
  f := pg_temp.do_('owner', format('select public.rg_fin_overview(%L::uuid, null, %L::date, %L::date)', pg_temp.k('org'), pg_temp.dd(-20), pg_temp.dd(0)));
  v_in := (f->'cash_in'->>'net')::bigint;
  perform pg_temp.ok('T38 Entradas = rg_fin_overview.cash_in.net (52000)', (c->'totals'->>'in_net')::bigint = v_in and v_in = 52000,
    format('cash_result=%s overview=%s', c->'totals'->>'in_net', v_in));
  perform pg_temp.ok('T39 Saídas pela data do movimento: inclui despesa vencida fora do período paga dentro dele (out 48000 - 12000 = 36000)',
    (c->'totals'->>'out_gross')::bigint = 48000 and (c->'totals'->>'out_reversals')::bigint = 12000 and (c->'totals'->>'out_net')::bigint = 36000,
    (c->'totals')::text);
  perform pg_temp.ok('T40a Resultado = Entradas − Saídas (16000); soma dos buckets = totais',
    (c->'totals'->>'result')::bigint = 16000
    and (select sum((b->>'result')::bigint) from jsonb_array_elements(c->'buckets') b) = 16000
    and (select sum((b->>'in_net')::bigint) from jsonb_array_elements(c->'buckets') b) = 52000
    and (select sum((b->>'out_net')::bigint) from jsonb_array_elements(c->'buckets') b) = 36000
    and jsonb_array_length(c->'buckets') = 21, (c->'totals')::text);
  c := pg_temp.do_('owner', pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 'month'));
  perform pg_temp.ok('T40b granularidade mês: mesmos totais', (c->'totals'->>'result')::bigint = 16000
    and (select sum((b->>'result')::bigint) from jsonb_array_elements(c->'buckets') b) = 16000, (c->'totals')::text);

  c1 := pg_temp.do_('owner', pg_temp.q_cr(pg_temp.k('org'), pg_temp.k('a1'), pg_temp.dd(-20), pg_temp.dd(0), 'day'));
  f := pg_temp.do_('owner', format('select public.rg_fin_overview(%L::uuid, %L::uuid, %L::date, %L::date)', pg_temp.k('org'), pg_temp.k('a1'), pg_temp.dd(-20), pg_temp.dd(0)));
  v_in_a1 := (f->'cash_in'->>'net')::bigint;
  perform pg_temp.ok('T42a arena A1: excludes_general = true; Entradas = 03B.1 (32000); Saídas sem despesas gerais (22000); resultado 10000',
    (c1->>'excludes_general')::boolean and (c1->'totals'->>'in_net')::bigint = v_in_a1 and v_in_a1 = 32000
    and (c1->'totals'->>'out_net')::bigint = 22000 and (c1->'totals'->>'result')::bigint = 10000, (c1->'totals')::text);
  -- conferência independente com SQL direto das duas tabelas
  perform pg_temp.ok('K03 conferência independente das Saídas com SQL direto',
    (c->'totals'->>'out_net')::bigint = (select sum(case when kind = 'PAYMENT' then amount else -amount end) from public.expense_payments
      where organization_id = pg_temp.k('org') and voided_at is null
        and paid_at >= (pg_temp.dd(-20)::timestamp at time zone 'America/Sao_Paulo') and paid_at < (pg_temp.dd(1)::timestamp at time zone 'America/Sao_Paulo')),
    'ok');
end $$;

-- ============================================================================= T35–T37, T42b paginação e filtros
do $$
declare
  r jsonb; v_all jsonb; v_ids uuid[] := '{}'; v_cur jsonb; v_pages int := 0; v_full uuid[];
  v_mv uuid[] := '{}'; v_mvfull uuid[]; v_srcs text[] := '{}';
begin
  r := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'ACTIVE', 200));
  select array_agg((e->>'expense_id')::uuid order by i) into v_full from jsonb_array_elements(r->'items') with ordinality t(e, i);
  loop
    r := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'ACTIVE', 2,
           (v_cur->>'due_date')::date, (v_cur->>'id')::uuid));
    v_ids := v_ids || coalesce((select array_agg((e->>'expense_id')::uuid order by i) from jsonb_array_elements(r->'items') with ordinality t(e, i)), '{}');
    v_pages := v_pages + 1;
    v_cur := r->'next_cursor';
    exit when v_cur is null or jsonb_typeof(v_cur) = 'null' or v_pages > 20;
  end loop;
  perform pg_temp.ok('T35 paginação (due_date, id) com 5 empates de vencimento: sem pular nem repetir (12 em 6 páginas)',
    v_ids = v_full and cardinality(v_full) = 12 and v_pages = 6
    and cardinality(v_ids) = (select count(distinct x) from unnest(v_ids) x), format('pages=%s n=%s', v_pages, cardinality(v_ids)));

  r := pg_temp.do_('owner', pg_temp.q_mv(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 200));
  select array_agg((e->>'id')::uuid order by i) into v_mvfull from jsonb_array_elements(r->'items') with ordinality t(e, i);
  v_cur := null; v_pages := 0;
  loop
    r := pg_temp.do_('owner', pg_temp.q_mv(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 1,
           (v_cur->>'occurred_at')::timestamptz, (v_cur->>'source_kind')::smallint, (v_cur->>'id')::uuid));
    v_mv := v_mv || coalesce((select array_agg((e->>'id')::uuid) from jsonb_array_elements(r->'items') e), '{}');
    v_srcs := v_srcs || coalesce((select array_agg(e->>'source') from jsonb_array_elements(r->'items') e), '{}');
    v_pages := v_pages + 1;
    v_cur := r->'next_cursor';
    exit when v_cur is null or jsonb_typeof(v_cur) = 'null' or v_pages > 30;
  end loop;
  perform pg_temp.ok('T36 movimentos: cursor (occurred_at, source_kind, id) total entre as fontes, com timestamp igual nas duas (10 itens)',
    v_mv = v_mvfull and cardinality(v_mv) = 10
    and array_position(v_mv, pg_temp.k('p_tie')) = array_position(v_mv, pg_temp.k('rp_tie')) - 1,
    format('n=%s pos_exp=%s pos_res=%s', cardinality(v_mv), array_position(v_mv, pg_temp.k('p_tie')), array_position(v_mv, pg_temp.k('rp_tie'))));

  perform pg_temp.ok('T37 filtros: ACTIVE 12 / OPEN 10 / OVERDUE 2 / PAID 2 / CANCELLED 1; padrão (NULL) = ACTIVE',
    jsonb_array_length(pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'ACTIVE', 200))->'items') = 12
    and jsonb_array_length(pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'OPEN', 200))->'items') = 10
    and jsonb_array_length(pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'OVERDUE', 200))->'items') = 2
    and jsonb_array_length(pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'PAID', 200))->'items') = 2
    and jsonb_array_length(pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), 'CANCELLED', 200))->'items') = 1
    and (pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(20), null, 200))->>'status') = 'ACTIVE',
    'ok');

  r := pg_temp.do_('owner', pg_temp.q_list(pg_temp.k('org'), pg_temp.k('a1'), null, pg_temp.dd(-40), pg_temp.dd(20), 'ACTIVE', 200));
  perform pg_temp.ok('T42b arena A1: lista sem despesas gerais (e_over/e_late fora), excludes_general = true',
    (r->>'excludes_general')::boolean
    and not exists (select 1 from jsonb_array_elements(r->'items') e where (e->>'expense_id')::uuid in (pg_temp.k('e_over'), pg_temp.k('e_late'), pg_temp.k('e_part')))
    and exists (select 1 from jsonb_array_elements(r->'items') e where (e->>'expense_id')::uuid = pg_temp.k('e_open')), r::text);

  perform pg_temp.expect('V01 lista: filtro inválido => 22023', 'owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-1), pg_temp.dd(1), 'ALL', 10), '22023');
  perform pg_temp.expect('V02 lista: cursor incompleto => 22023', 'owner',
    pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-1), pg_temp.dd(1), 'ACTIVE', 10, pg_temp.dd(0), null), '22023');
  perform pg_temp.expect('V03 período acima de 366 dias => 22023', 'owner', pg_temp.q_list(pg_temp.k('org'), null, null, pg_temp.dd(-400), pg_temp.dd(0), 'ACTIVE', 10), '22023');
  perform pg_temp.expect('V04 caixa por dia com 367 dias => 22023', 'owner', pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-366), pg_temp.dd(0), 'day'), '22023');
  perform pg_temp.ok('V05 caixa: mês até 60 meses e ano até 10 anos aceitos; 61 meses / 11 anos rejeitados',
    (select state from pg_temp.call('owner', pg_temp.q_cr(pg_temp.k('org'), null, '2026-01-01', '2030-12-31', 'month'))) = 'OK'
    and (select state from pg_temp.call('owner', pg_temp.q_cr(pg_temp.k('org'), null, '2026-01-01', '2031-01-01', 'month'))) = '22023'
    and (select state from pg_temp.call('owner', pg_temp.q_cr(pg_temp.k('org'), null, '2026-01-01', '2035-12-31', 'year'))) = 'OK'
    and (select state from pg_temp.call('owner', pg_temp.q_cr(pg_temp.k('org'), null, '2026-01-01', '2036-01-01', 'year'))) = '22023'
    and (select state from pg_temp.call('owner', pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-1), pg_temp.dd(0), 'week'))) = '22023', 'ok');
  perform pg_temp.expect('V06 movimentos: cursor incompleto => 22023', 'owner',
    pg_temp.q_mv(pg_temp.k('org'), null, pg_temp.dd(-1), pg_temp.dd(0), 10, now(), null, gen_random_uuid()), '22023');
  perform pg_temp.expect('V07 comparação sobreposta ao período => 22023', 'owner',
    pg_temp.q_ov(pg_temp.k('org'), null, null, pg_temp.dd(-20), pg_temp.dd(0), pg_temp.dd(-30), pg_temp.dd(-20)), '22023');
  perform pg_temp.expect('V08 categoria de outra organização no filtro => 22023', 'owner',
    pg_temp.q_ov(pg_temp.k('org'), null, pg_temp.k('cat2_outros'), pg_temp.dd(-20), pg_temp.dd(0)), '22023');
end $$;

-- ============================================================================= T13–T18 pagamento / idempotência
do $$
declare v_p uuid; r jsonb; r2 jsonb; v_n bigint; v_op uuid := gen_random_uuid(); v_op2 uuid := gen_random_uuid(); v_op3 uuid := gen_random_uuid();
begin
  perform pg_temp.mk('e_s13', 'mgr', 'org', 'a1', 'cat_outros', 'S13', 1000, -60);
  v_p := pg_temp.epay('p_s13', 'mgr', 'e_s13', 600, pg_temp.ts(-60, '10:00'));
  perform pg_temp.expect('T13 pagar acima do que falta => RGP03 OVER_BALANCE', 'mgr',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_s13'), 500, pg_temp.ts(-60, '11:00')), 'RGP03', 'OVER_BALANCE');
  perform pg_temp.expect('T14 pagar despesa cancelada => RGP01 EXPENSE_CANCELLED', 'mgr',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_canc'), 100, pg_temp.ts(-60, '11:00')), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.expect('T15 devolver acima do pago => RGP03 OVER_REVERSIBLE', 'mgr',
    pg_temp.q_rev(gen_random_uuid(), v_p, 700, pg_temp.ts(-60, '12:00')), 'RGP03', 'OVER_REVERSIBLE');

  perform pg_temp.mk('e_s16', 'mgr', 'org', 'a1', 'cat_outros', 'S16', 10000, -60);
  perform pg_temp.epay('p_s16a', 'mgr', 'e_s16', 10000, pg_temp.ts(-60, '10:00'));
  perform pg_temp.erev('r_s16', 'mgr', 'p_s16a', 10000, pg_temp.ts(-60, '11:00'));
  perform pg_temp.epay('p_s16b', 'mgr', 'e_s16', 10000, pg_temp.ts(-60, '12:00'));
  perform pg_temp.expect('T16 anular devolução que deixaria a despesa paga acima do valor => RGP03 OVER_BALANCE', 'mgr',
    pg_temp.q_void(pg_temp.k('r_s16')), 'RGP03', 'OVER_BALANCE');

  -- T17 replay: create / register / reverse
  r := pg_temp.do_('mgr', pg_temp.q_create(v_op, pg_temp.k('org'), null, pg_temp.k('cat_outros'), 'Replay', 777, pg_temp.dd(-60)));
  select count(*) into v_n from public.expenses;
  r2 := pg_temp.do_('mgr', pg_temp.q_create(v_op, pg_temp.k('org'), null, pg_temp.k('cat_outros'), '  Replay ', 777, pg_temp.dd(-60)));
  perform pg_temp.ok('T17a mesmo operation_id + mesma intenção (descrição normalizada igual) => replay da despesa',
    (r2->>'idempotent')::boolean and r2->>'expense_id' = r->>'expense_id' and not (r->>'idempotent')::boolean
    and (select count(*) from public.expenses) = v_n, r2::text);
  insert into fx values ('e_s17', (r->>'expense_id')::uuid);
  r := pg_temp.do_('mgr', pg_temp.q_pay(v_op2, pg_temp.k('e_s17'), 300, pg_temp.ts(-60, '10:00')));
  r2 := pg_temp.do_('mgr', pg_temp.q_pay(v_op2, pg_temp.k('e_s17'), 300, pg_temp.ts(-60, '10:00')));
  perform pg_temp.ok('T17b pagamento repetido => replay (mesmo payment_id, sem novo lançamento)',
    (r2->>'idempotent')::boolean and r2->>'payment_id' = r->>'payment_id'
    and (select count(*) from public.expense_payments where expense_id = pg_temp.k('e_s17')) = 1, r2::text);
  insert into fx values ('p_s17', (r->>'payment_id')::uuid);
  r := pg_temp.do_('mgr', pg_temp.q_rev(v_op3, pg_temp.k('p_s17'), 100, pg_temp.ts(-60, '11:00')));
  r2 := pg_temp.do_('mgr', pg_temp.q_rev(v_op3, pg_temp.k('p_s17'), 100, pg_temp.ts(-60, '11:00')));
  perform pg_temp.ok('T17c devolução repetida => replay', (r2->>'idempotent')::boolean and r2->>'payment_id' = r->>'payment_id'
    and (select count(*) from public.expense_payments where expense_id = pg_temp.k('e_s17')) = 2, r2::text);

  perform pg_temp.expect('T18a mesmo operation_id na criação com outro valor => RGP02', 'mgr',
    pg_temp.q_create(v_op, pg_temp.k('org'), null, pg_temp.k('cat_outros'), 'Replay', 778, pg_temp.dd(-60)), 'RGP02');
  perform pg_temp.expect('T18b mesmo operation_id no pagamento com outro valor => RGP02', 'mgr',
    pg_temp.q_pay(v_op2, pg_temp.k('e_s17'), 200, pg_temp.ts(-60, '10:00')), 'RGP02');
  perform pg_temp.expect('T18c mesmo operation_id na devolução com outro valor => RGP02', 'mgr',
    pg_temp.q_rev(v_op3, pg_temp.k('p_s17'), 50, pg_temp.ts(-60, '11:00')), 'RGP02');
  perform pg_temp.expect('T18d operation_id de pagamento reutilizado em OUTRA despesa => RGP02', 'mgr',
    pg_temp.q_pay(v_op2, pg_temp.k('e_s13'), 300, pg_temp.ts(-60, '10:00')), 'RGP02');
end $$;

-- ============================================================================= T24–T31 edição / cancelamento
do $$
declare d jsonb;
begin
  perform pg_temp.mk('e_s24', 'mgr', 'org', 'a1', 'cat_outros', 'S24', 1000, -60);
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), '{"amount": 2000}'));
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), format('{"arena_id":"%s"}', pg_temp.k('a2'))));
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), '{"arena_id": null}'));
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), format('{"arena_id":"%s"}', pg_temp.k('a1'))));
  d := pg_temp.det('e_s24');
  perform pg_temp.ok('T24 antes do primeiro pagamento: valor e arena editáveis (inclusive arena -> geral -> arena)',
    (d->>'amount')::int = 2000 and (d->>'arena_id')::uuid = pg_temp.k('a1') and not (d->>'amount_locked')::boolean, d::text);

  perform pg_temp.epay('p_s24', 'mgr', 'e_s24', 500, pg_temp.ts(-60, '10:00'));
  perform pg_temp.expect('T25a com PAYMENT válido: mudar valor => RGP01 AMOUNT_LOCKED', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_s24'), '{"amount": 3000}'), 'RGP01', 'AMOUNT_LOCKED');
  perform pg_temp.expect('T25b com PAYMENT válido: mudar arena => RGP01 ARENA_LOCKED', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_s24'), format('{"arena_id":"%s"}', pg_temp.k('a2'))), 'RGP01', 'ARENA_LOCKED');
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), format('{"description":"S24 editada","category_id":"%s","due_date":"%s","notes":"obs"}',
    pg_temp.k('cat_aluguel'), pg_temp.dd(-59))));
  d := pg_temp.det('e_s24');
  perform pg_temp.ok('T25c com pagamento: descrição, categoria, vencimento e observação continuam editáveis',
    d->>'description' = 'S24 editada' and (d->>'category_id')::uuid = pg_temp.k('cat_aluguel') and d->>'notes' = 'obs', d::text);

  perform pg_temp.erev('r_s24', 'mgr', 'p_s24', 500, pg_temp.ts(-60, '11:00'));
  perform pg_temp.expect('T26a totalmente devolvido: valor continua travado', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_s24'), '{"amount": 3000}'), 'RGP01', 'AMOUNT_LOCKED');
  perform pg_temp.expect('T26b totalmente devolvido: arena continua travada', 'mgr',
    pg_temp.q_upd(pg_temp.k('e_s24'), '{"arena_id": null}'), 'RGP01', 'ARENA_LOCKED');

  perform pg_temp.do_('mgr', pg_temp.q_void(pg_temp.k('r_s24')));
  perform pg_temp.do_('mgr', pg_temp.q_void(pg_temp.k('p_s24')));
  perform pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_s24'), '{"amount": 3000, "arena_id": null}'));
  d := pg_temp.det('e_s24');
  perform pg_temp.ok('T27 todos os pagamentos anulados: valor e arena voltam a ser editáveis',
    (d->>'amount')::int = 3000 and d->>'arena_id' is null and not (d->>'amount_locked')::boolean, d::text);

  perform pg_temp.mk('e_s28', 'mgr', 'org', 'a1', 'cat_outros', 'S28', 1000, -60);
  perform pg_temp.ok('T28 cancelar sem pagamentos => OK', (pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_s28')))->>'changed')::boolean, 'ok');
  perform pg_temp.mk('e_s29', 'mgr', 'org', 'a1', 'cat_outros', 'S29', 1000, -60);
  perform pg_temp.epay('p_s29', 'mgr', 'e_s29', 100, pg_temp.ts(-60, '10:00'));
  perform pg_temp.do_('mgr', pg_temp.q_void(pg_temp.k('p_s29')));
  perform pg_temp.ok('T29 cancelar com pagamentos só anulados => OK', (pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_s29')))->>'changed')::boolean, 'ok');
  perform pg_temp.ok('T30 cancelar pagamento totalmente devolvido (e_rev) => OK', (pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_rev')))->>'changed')::boolean, 'ok');
  perform pg_temp.expect('T31a cancelar com pago líquido > 0 => RGP01 NET_PAID', 'mgr', pg_temp.q_cancel(pg_temp.k('e_part')), 'RGP01', 'NET_PAID');
  perform pg_temp.expect('T31b cancelada: editar => EXPENSE_CANCELLED', 'mgr', pg_temp.q_upd(pg_temp.k('e_s28'), '{"description":"x"}'), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.expect('T31c cancelada: pagar => EXPENSE_CANCELLED', 'mgr',
    pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_s28'), 10, pg_temp.ts(-60, '10:00')), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.expect('T31d cancelada: anular devolução => EXPENSE_CANCELLED (ledger congelado)', 'mgr',
    pg_temp.q_void(pg_temp.k('r_rev')), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.expect('T31e cancelada: anular pagamento => EXPENSE_CANCELLED', 'mgr', pg_temp.q_void(pg_temp.k('p_rev')), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.expect('T31f cancelada: devolver => EXPENSE_CANCELLED', 'mgr',
    pg_temp.q_rev(gen_random_uuid(), pg_temp.k('p_rev'), 1, pg_temp.ts(-60, '10:00')), 'RGP01', 'EXPENSE_CANCELLED');
  perform pg_temp.ok('T31g cancelar de novo => changed=false (idempotente, sem nova auditoria)',
    not (pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_rev')))->>'changed')::boolean
    and (select count(*) from public.audit_logs where entity_id = pg_temp.k('e_rev') and action = 'EXPENSE_CANCELLED') = 1, 'ok');
  perform pg_temp.expect('T31h UPDATE direto numa cancelada também é barrado pelo trigger', 'postgres',
    format('update public.expenses set description = ''z'' where id = %L returning to_jsonb(id)', pg_temp.k('e_s28')), 'RGP01', 'EXPENSE_CANCELLED');
end $$;

-- ============================================================================= T32–T34 anulação
do $$
declare d jsonb; v1 jsonb; v2 jsonb; v_row public.expense_payments;
begin
  perform pg_temp.mk('e_s32', 'mgr', 'org', 'a1', 'cat_outros', 'S32', 1000, -60);
  perform pg_temp.epay('p_s32', 'mgr', 'e_s32', 300, pg_temp.ts(-60, '10:00'));
  v1 := pg_temp.do_('mgr', pg_temp.q_void(pg_temp.k('p_s32')));
  select * into v_row from public.expense_payments where id = pg_temp.k('p_s32');
  v2 := pg_temp.do_('owner', format('select public.rg_expense_payment_void(%L::uuid, ''outro motivo'')', pg_temp.k('p_s32')));
  perform pg_temp.ok('T32 anular uma vez (changed) e de novo (changed=false), dados da 1ª anulação preservados, auditoria única',
    (v1->>'changed')::boolean and not (v2->>'changed')::boolean
    and v_row.voided_at is not null and v_row.voided_by = pg_temp.k('mgr') and v_row.void_reason = 'lançamento errado'
    and (select void_reason = 'lançamento errado' and voided_by = pg_temp.k('mgr') from public.expense_payments where id = pg_temp.k('p_s32'))
    and (select count(*) from public.audit_logs where entity_id = pg_temp.k('p_s32') and action = 'EXPENSE_PAYMENT_VOIDED') = 1,
    format('v1=%s v2=%s', v1, v2));
  perform pg_temp.mk('e_s33', 'mgr', 'org', 'a1', 'cat_outros', 'S33', 1000, -60);
  perform pg_temp.epay('p_s33', 'mgr', 'e_s33', 400, pg_temp.ts(-60, '10:00'));
  perform pg_temp.erev('r_s33', 'mgr', 'p_s33', 100, pg_temp.ts(-60, '11:00'));
  perform pg_temp.expect('T33 anular PAYMENT com REVERSAL válida => RGP01 HAS_REVERSALS', 'mgr', pg_temp.q_void(pg_temp.k('p_s33')), 'RGP01', 'HAS_REVERSALS');
  d := pg_temp.det('e_void');
  perform pg_temp.ok('T34 lançamento anulado sai dos totais (e_void: net 0, OPEN, entrada visível como anulada)',
    (d->>'net_paid')::bigint = 0 and d->>'status' = 'OPEN' and not (d->>'amount_locked')::boolean
    and jsonb_array_length(d->'entries') = 1 and d->'entries'->0->>'voided_at' is not null, d::text);
  d := pg_temp.det('e_s33');
  perform pg_temp.ok('T34b detalhe: devolvido por pagamento e net = 300', (d->>'net_paid')::bigint = 300
    and (select (e->>'reversed')::bigint from jsonb_array_elements(d->'entries') e where (e->>'payment_id')::uuid = pg_temp.k('p_s33')) = 100, d::text);
end $$;

-- ============================================================================= T41 cancelada continua no Caixa
do $$
declare c jsonb; m jsonb;
begin
  c := pg_temp.do_('owner', pg_temp.q_cr(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 'day'));
  m := pg_temp.do_('owner', pg_temp.q_mv(pg_temp.k('org'), null, pg_temp.dd(-20), pg_temp.dd(0), 200));
  perform pg_temp.ok('T41 despesa cancelada (e_rev): pagamento e devolução continuam no Caixa pelas datas reais; totais inalterados',
    (c->'totals'->>'out_net')::bigint = 36000 and (c->'totals'->>'result')::bigint = 16000
    and exists (select 1 from jsonb_array_elements(m->'items') e where (e->>'id')::uuid = pg_temp.k('p_rev') and (e->>'signed_amount')::bigint = -12000)
    and exists (select 1 from jsonb_array_elements(m->'items') e where (e->>'id')::uuid = pg_temp.k('r_rev') and (e->>'signed_amount')::bigint = 12000),
    (c->'totals')::text);
end $$;

-- ============================================================================= T43–T50 seed / categorias / privilégios
do $$
declare v_o3 uuid; v_n int; r jsonb; v_lid uuid; v_bad text; v_cnt int;
begin
  select count(*) into v_n from public.organizations o
   where (select count(*) from public.expense_categories c where c.organization_id = o.id
            and c.name in ('Aluguel', 'Energia', 'Água', 'Internet', 'Funcionários', 'Manutenção', 'Materiais', 'Marketing', 'Impostos e taxas', 'Outros')) <> 10;
  perform pg_temp.ok('T43 toda organização tem as 10 categorias padrão (existentes pelo seed, novas pelo trigger)', v_n = 0, v_n::text);
  perform pg_temp.ok('T44 seed repetido não duplica (0 inseridas)', private.rg_exp_seed_default_categories(pg_temp.k('org')) = 0, 'ok');

  insert into public.organizations (name, is_demo) values ('P3B2 o3 ' || gen_random_uuid(), true) returning id into v_o3;
  delete from public.expense_categories where organization_id = v_o3 and name = 'Água';
  -- categoria do cliente com nome equivalente a uma padrão (grafia diferente)
  insert into public.expense_categories (organization_id, name) values (v_o3, 'ÁGUA');
  select count(*) into v_cnt from public.expense_categories where organization_id = v_o3;
  perform pg_temp.ok('T45 categoria equivalente do cliente ("ÁGUA") não é sobrescrita nem duplicada pelo seed',
    private.rg_exp_seed_default_categories(v_o3) = 0
    and (select count(*) from public.expense_categories where organization_id = v_o3) = v_cnt and v_cnt = 10
    and (select count(*) from public.expense_categories where organization_id = v_o3 and name_key = 'agua') = 1
    and exists (select 1 from public.expense_categories where organization_id = v_o3 and name = 'ÁGUA'),
    format('cats=%s', v_cnt));
  begin
    insert into public.expense_categories (organization_id, name) values (v_o3, '  Internet ');
    v_bad := 'aceitou';
  exception when check_violation then
    v_bad := null;
  end;
  perform pg_temp.ok('T45b nome não normalizado é rejeitado pela constraint (o banco guarda nomes normalizados)', v_bad is null, coalesce(v_bad, 'ok'));
  update public.expense_categories set is_active = false where organization_id = v_o3 and name = 'Energia';
  perform pg_temp.ok('T46 categoria padrão inativa não é reativada pelo seed',
    private.rg_exp_seed_default_categories(v_o3) = 0
    and not (select is_active from public.expense_categories where organization_id = v_o3 and name = 'Energia'), 'ok');

  perform pg_temp.ok('T47a name_key: acentos, maiúsculas e espaços equivalentes geram a mesma chave',
    private.rg_exp_name_key('Água') = 'agua' and private.rg_exp_name_key('  ÁGUA  ') = 'agua' and private.rg_exp_name_key('Agua') = 'agua'
    and private.rg_exp_name_key('água') = 'agua' and private.rg_exp_name_key('Impostos   e  taxas') = 'impostos e taxas'
    and private.rg_exp_name_key('MANUTENÇÃO') = 'manutencao' and private.rg_exp_name_key('Funcionários') = 'funcionarios'
    and private.rg_exp_name_key(E'Água') = 'agua' and private.rg_exp_name_key(E'MANUTENÇÃO') = 'manutencao', 'ok');
  r := pg_temp.do_('mgr', format('select public.rg_expense_category_create(%L::uuid, %L)', pg_temp.k('org'), E'ÁGUA'));
  perform pg_temp.ok('T47a2 Unicode decomposto (NFD: letra + acento combinante) também cai na categoria existente',
    not (r->>'created')::boolean and (r->>'category_id')::uuid = pg_temp.k('cat_agua'), r::text);
  r := pg_temp.do_('mgr', format('select public.rg_expense_category_create(%L::uuid, %L)', pg_temp.k('org'), '  ÁGUA  '));
  perform pg_temp.ok('T47b criar nome equivalente a existente ativa => devolve a existente (created=false)',
    not (r->>'created')::boolean and (r->>'category_id')::uuid = pg_temp.k('cat_agua'), r::text);
  r := pg_temp.do_('mgr', format('select public.rg_expense_category_create(%L::uuid, %L)', pg_temp.k('org'), 'Limpeza   da  quadra'));
  v_lid := (r->>'category_id')::uuid;
  perform pg_temp.ok('T47c criar categoria nova => created=true, nome normalizado', (r->>'created')::boolean and r->>'name' = 'Limpeza da quadra', r::text);
  perform pg_temp.expect('T47d renomear para nome equivalente a outra => RGP01 CATEGORY_NAME_EXISTS', 'mgr',
    format('select public.rg_expense_category_update(%L::uuid, ''{"name":"ENERGIA"}'')', v_lid), 'RGP01', 'CATEGORY_NAME_EXISTS');
  perform pg_temp.do_('mgr', format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":false}'')', v_lid));
  perform pg_temp.expect('T47e criar equivalente a categoria inativa => RGP01 CATEGORY_INACTIVE_EXISTS', 'mgr',
    format('select public.rg_expense_category_create(%L::uuid, ''limpeza da QUADRA'')', pg_temp.k('org')), 'RGP01', 'CATEGORY_INACTIVE_EXISTS');
  perform pg_temp.expect('T47f criar despesa em categoria inativa => RGP01 CATEGORY_INACTIVE', 'mgr',
    pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), null, v_lid, 'x', 100, pg_temp.dd(0)), 'RGP01', 'CATEGORY_INACTIVE');
  perform pg_temp.do_('mgr', format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":true}'')', v_lid));
  perform pg_temp.ok('T47g categorias: leitura padrão só ativas; com inativas mostra todas',
    jsonb_array_length(pg_temp.do_('owner', format('select public.rg_expense_categories(%L::uuid, false)', pg_temp.k('org')))->'items')
      = (select count(*) from public.expense_categories where organization_id = pg_temp.k('org') and is_active)
    and jsonb_array_length(pg_temp.do_('owner', format('select public.rg_expense_categories(%L::uuid, true)', pg_temp.k('org')))->'items')
      = (select count(*) from public.expense_categories where organization_id = pg_temp.k('org')), 'ok');

  -- T48 privilégios / segurança das funções e tabelas
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and (p.proname like 'rg_exp\_%' or p.proname in ('enforce_expense_integrity', 'protect_expense_record',
           'enforce_expense_payment_integrity', 'protect_expense_payment_ledger'))
     and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')
          or has_function_privilege('service_role', p.oid, 'EXECUTE') or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
          or pg_get_userbyid(p.proowner) <> 'postgres' or not ('search_path=""' = any(coalesce(p.proconfig, '{}'))));
  perform pg_temp.ok('T48a 13 funções privadas: sem EXECUTE para public/anon/authenticated/service_role, owner postgres, search_path vazio',
    v_bad is null and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private'
      and (p.proname like 'rg_exp\_%' or p.proname in ('enforce_expense_integrity', 'protect_expense_record',
           'enforce_expense_payment_integrity', 'protect_expense_payment_ledger'))) = 13, coalesce(v_bad, 'ok'));
  perform pg_temp.ok('T48b seed: SECURITY DEFINER e sem EXECUTE para nenhum papel de API',
    (select bool_and(p.prosecdef) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'private' and p.proname in ('rg_exp_seed_default_categories', 'rg_exp_seed_org_categories')), 'ok');
  perform pg_temp.expect('T48c authenticated chamando o seed diretamente => 42501', 'owner',
    format('select to_jsonb(private.rg_exp_seed_default_categories(%L::uuid))', pg_temp.k('org')), '42501');
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like 'rg_expense%' or p.proname in ('rg_fin_cash_result', 'rg_fin_cash_movements'))
     and not (p.prosecdef and 'search_path=""' = any(coalesce(p.proconfig, '{}')) and pg_get_userbyid(p.proowner) = 'postgres'
              and has_function_privilege('authenticated', p.oid, 'EXECUTE')
              and ((p.proname in ('rg_expense_categories', 'rg_expense_overview', 'rg_expenses', 'rg_expense_detail', 'rg_fin_cash_result',
                                   'rg_fin_cash_movements') and p.provolatile = 's' and 'TimeZone=UTC' = any(p.proconfig))
                   or (p.proname not in ('rg_expense_categories', 'rg_expense_overview', 'rg_expenses', 'rg_expense_detail', 'rg_fin_cash_result',
                                   'rg_fin_cash_movements') and p.provolatile = 'v')));
  perform pg_temp.ok('T48d 14 RPCs: SECURITY DEFINER, search_path vazio, owner postgres, EXECUTE authenticated; leituras STABLE (sem write possível)',
    v_bad is null and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
      and (p.proname like 'rg_expense%' or p.proname in ('rg_fin_cash_result', 'rg_fin_cash_movements'))) = 14, coalesce(v_bad, 'ok'));
  perform pg_temp.ok('T48e tabelas: RLS ligado, nenhuma política; authenticated/anon sem privilégio; service_role só SELECT/DELETE em despesas/lançamentos e NADA em categorias',
    (select bool_and(c.relrowsecurity) from pg_class c where c.oid in ('public.expense_categories'::regclass, 'public.expenses'::regclass, 'public.expense_payments'::regclass))
    and not exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('expense_categories', 'expenses', 'expense_payments'))
    and not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                     and table_name in ('expense_categories', 'expenses', 'expense_payments') and grantee in ('anon', 'authenticated', 'PUBLIC'))
    and (select string_agg(distinct privilege_type, ',' order by privilege_type) from information_schema.role_table_grants
          where table_schema = 'public' and table_name in ('expenses', 'expense_payments') and grantee = 'service_role') = 'DELETE,SELECT'
    and not exists (select 1 from information_schema.role_table_grants
                     where table_schema = 'public' and table_name = 'expense_categories' and grantee = 'service_role')
    and not has_table_privilege('service_role', 'public.expense_categories', 'DELETE')
    and not has_table_privilege('service_role', 'public.expense_categories', 'SELECT'),
    'ok');
  perform pg_temp.expect('T48f authenticated não lê a tabela diretamente => 42501', 'owner', 'select to_jsonb(count(*)) from public.expenses', '42501');
  perform pg_temp.expect('T48g service_role não insere despesa diretamente => 42501', 'service_role',
    format('insert into public.expense_categories (organization_id, name) values (%L, ''Hack'') returning to_jsonb(id)', pg_temp.k('org')), '42501');

  -- T49 / T50 onboarding simulado
  r := pg_temp.do_('service_role', 'insert into public.organizations (name, is_demo) values (''P3B2 onboarding'', true) returning jsonb_build_object(''id'', id)');
  perform pg_temp.ok('T49 service_role cria organização (como o POST /api/onboarding) => 10 categorias pelo trigger',
    (select count(*) from public.expense_categories where organization_id = (r->>'id')::uuid and is_active) = 10, r::text);
  perform pg_temp.do_('service_role', format('delete from public.organizations where id = %L returning to_jsonb(id)', r->>'id'));
  perform pg_temp.ok('T50 DELETE de organização pelo harness funciona; categorias saem em cascata',
    not exists (select 1 from public.organizations where id = (r->>'id')::uuid)
    and not exists (select 1 from public.expense_categories where organization_id = (r->>'id')::uuid), 'ok');
end $$;

-- ============================================================================= T61 categorias sem DELETE direto do service_role
do $$
declare
  r jsonb; v_demo uuid; v_real uuid; u_real uuid := gen_random_uuid(); v_cat_real uuid; v_exp_real uuid; v record;
begin
  -- (a) DELETE direto na tabela filha => permission denied (organização demo e real)
  perform pg_temp.expect('T61a service_role: DELETE direto em expense_categories (org demo) => 42501 permission denied', 'service_role',
    format('delete from public.expense_categories where organization_id = %L returning to_jsonb(id)', pg_temp.k('org')), '42501');
  perform pg_temp.expect('T61b service_role: nem SELECT direto em expense_categories => 42501', 'service_role',
    format('select to_jsonb(count(*)) from public.expense_categories where organization_id = %L', pg_temp.k('org')), '42501');

  -- (b) cleanup de organização demo pelo caminho autorizado continua funcionando; categorias saem pela FK
  r := pg_temp.do_('service_role', 'insert into public.organizations (name, is_demo) values (''P3B2 T61 demo'', true) returning jsonb_build_object(''id'', id)');
  v_demo := (r->>'id')::uuid;
  perform pg_temp.ok('T61c onboarding/seed sem regressão: organização criada pelo service_role recebe as 10 categorias padrão',
    (select count(*) from public.expense_categories where organization_id = v_demo
       and name in ('Aluguel', 'Energia', 'Água', 'Internet', 'Funcionários', 'Manutenção', 'Materiais', 'Marketing', 'Impostos e taxas', 'Outros')
       and is_active and created_at = updated_at) = 10, r::text);
  select * into v from pg_temp.call('service_role', format('delete from public.organizations where id = %L returning to_jsonb(id)', v_demo));
  perform pg_temp.ok('T61d service_role apaga organização demo (caminho autorizado) => OK; as 10 categorias saem por ON DELETE CASCADE',
    v.state = 'OK' and not exists (select 1 from public.organizations where id = v_demo)
    and not exists (select 1 from public.expense_categories where organization_id = v_demo), v.state);

  -- (c) organização REAL (não-demo) com despesa continua protegida pelos guards existentes
  insert into auth.users (id, email) values (u_real, 'p3b2-t61-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
  insert into public.organizations (name, is_demo) values ('P3B2 T61 real', false) returning id into v_real;
  insert into public.organization_members (organization_id, user_id, role, status) values (v_real, u_real, 'OWNER', 'ACTIVE');
  insert into fx values ('t61_owner', u_real);
  select id into v_cat_real from public.expense_categories where organization_id = v_real and name = 'Outros';
  r := pg_temp.do_('t61_owner', pg_temp.q_create(gen_random_uuid(), v_real, null, v_cat_real, 'Despesa real', 1000, pg_temp.dd(0)));
  v_exp_real := (r->>'expense_id')::uuid;
  perform pg_temp.expect('T61e organização real: service_role não apaga a despesa (guard_finance_delete) => 42501', 'service_role',
    format('delete from public.expenses where id = %L returning to_jsonb(id)', v_exp_real), '42501');
  perform pg_temp.expect('T61f organização real com despesa: DELETE da organização é barrado (FK RESTRICT); nada some', 'service_role',
    format('delete from public.organizations where id = %L returning to_jsonb(id)', v_real), '23503');
  perform pg_temp.ok('T61g organização real intacta: organização, despesa e as 10 categorias continuam',
    exists (select 1 from public.organizations where id = v_real) and exists (select 1 from public.expenses where id = v_exp_real)
    and (select count(*) from public.expense_categories where organization_id = v_real) = 10, 'ok');
end $$;

-- ============================================================================= T51 auditoria + atomicidade
do $$
declare
  v_cat uuid; v_exp uuid; v_pay uuid; v_rev uuid; r jsonb; v record; v_ok boolean := true; v_detail text := '';
begin
  r := pg_temp.do_('owner', format('select public.rg_expense_category_create(%L::uuid, ''Auditoria'')', pg_temp.k('org'))); v_cat := (r->>'category_id')::uuid;
  perform pg_temp.do_('owner', format('select public.rg_expense_category_update(%L::uuid, ''{"name":"Auditoria 2"}'')', v_cat));
  r := pg_temp.do_('owner', pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), null, v_cat, 'Aud', 1000, pg_temp.dd(-60))); v_exp := (r->>'expense_id')::uuid;
  perform pg_temp.do_('owner', pg_temp.q_upd(v_exp, '{"description":"Aud 2"}'));
  r := pg_temp.do_('owner', pg_temp.q_pay(gen_random_uuid(), v_exp, 400, pg_temp.ts(-60, '10:00'))); v_pay := (r->>'payment_id')::uuid;
  r := pg_temp.do_('owner', pg_temp.q_rev(gen_random_uuid(), v_pay, 400, pg_temp.ts(-60, '11:00'))); v_rev := (r->>'payment_id')::uuid;
  perform pg_temp.do_('owner', pg_temp.q_void(v_rev));
  perform pg_temp.do_('owner', pg_temp.q_void(v_pay));
  perform pg_temp.do_('owner', pg_temp.q_cancel(v_exp));
  perform pg_temp.do_('owner', format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":false}'')', v_cat));
  perform pg_temp.do_('owner', format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":true}'')', v_cat));
  for v in select * from (values
      (v_cat, 'EXPENSE_CATEGORY_CREATED'), (v_cat, 'EXPENSE_CATEGORY_UPDATED'), (v_cat, 'EXPENSE_CATEGORY_DEACTIVATED'),
      (v_cat, 'EXPENSE_CATEGORY_REACTIVATED'), (v_exp, 'EXPENSE_CREATED'), (v_exp, 'EXPENSE_UPDATED'), (v_exp, 'EXPENSE_CANCELLED'),
      (v_pay, 'EXPENSE_PAYMENT_RECORDED'), (v_rev, 'EXPENSE_PAYMENT_REVERSED'), (v_rev, 'EXPENSE_PAYMENT_VOIDED'), (v_pay, 'EXPENSE_PAYMENT_VOIDED')) t(eid, act)
  loop
    if (select count(*) from public.audit_logs a where a.entity_id = v.eid and a.action = v.act and a.user_id = pg_temp.k('owner')
          and a.organization_id = pg_temp.k('org')) <> 1 then
      v_ok := false; v_detail := v_detail || v.act || ' ';
    end if;
  end loop;
  perform pg_temp.ok('T51a cada escrita grava exatamente uma ação de auditoria (11 ações, 8 RPCs)', v_ok, v_detail);

  -- falha injetada depois do INSERT e antes da auditoria: nada persiste
  perform set_config('rg.fault_at', 'expense_payment:after_insert', true);
  perform pg_temp.mk('e_s51', 'owner', 'org', null, 'cat_outros', 'S51', 1000, -60);
  select * into v from pg_temp.call('owner', pg_temp.q_pay(gen_random_uuid(), pg_temp.k('e_s51'), 100, pg_temp.ts(-60, '10:00')));
  perform set_config('rg.fault_at', '', true);
  perform pg_temp.ok('T51b falha injetada após o INSERT do pagamento: nem lançamento nem auditoria persistem',
    v.state = 'RGF01' and not exists (select 1 from public.expense_payments where expense_id = pg_temp.k('e_s51'))
    and not exists (select 1 from public.audit_logs a where a.action = 'EXPENSE_PAYMENT_RECORDED' and a.metadata->>'expense_id' = pg_temp.k('e_s51')::text),
    v.state);
  perform set_config('rg.fault_at', 'expense_create:after_insert', true);
  select * into v from pg_temp.call('owner', pg_temp.q_create(gen_random_uuid(), pg_temp.k('org'), null, pg_temp.k('cat_outros'), 'Falha', 100, pg_temp.dd(-60)));
  perform set_config('rg.fault_at', '', true);
  perform pg_temp.ok('T51c falha injetada após o INSERT da despesa: nada persiste',
    v.state = 'RGF01' and not exists (select 1 from public.expenses where description = 'Falha'), v.state);
end $$;

-- ============================================================================= T58 FK relacional da devolução
do $$
declare v_state text; v_constraint text;
begin
  alter table public.expense_payments disable trigger enforce_expense_payment_integrity;
  begin
    insert into public.expense_payments (organization_id, expense_id, kind, reversal_of, method, amount, paid_at,
      operation_id, operation_fingerprint)
    values (pg_temp.k('org'), pg_temp.k('e_s13'), 'REVERSAL', pg_temp.k('p_o2'), 'PIX', 1, now() - interval '1 minute',
      gen_random_uuid(), sha256('x'::bytea));
    v_state := 'OK';
  exception when foreign_key_violation then
    get stacked diagnostics v_constraint = constraint_name;
    v_state := sqlstate;
  end;
  alter table public.expense_payments enable trigger enforce_expense_payment_integrity;
  perform pg_temp.ok('T58 devolução apontando para lançamento de outra organização é barrada pela FK composta (sem depender do trigger/RPC)',
    v_state = '23503' and v_constraint = 'expense_payments_reversal_org_fkey', coalesce(v_state, '') || ' ' || coalesce(v_constraint, ''));
  perform pg_temp.ok('T58b trigger reabilitado', (select tgenabled from pg_trigger where tgname = 'enforce_expense_payment_integrity') = 'O', 'ok');
end $$;

-- ============================================================================= T59 replay depois de mudança de estado
do $$
declare v_opw uuid := gen_random_uuid(); v_opy uuid := gen_random_uuid(); v_opz uuid := gen_random_uuid(); v_opv uuid := gen_random_uuid();
        r jsonb; r2 jsonb; v_cat uuid; v_pay uuid;
begin
  perform pg_temp.mk('e_s59', 'mgr', 'org', 'a1', 'cat_outros', 'S59', 2000, -60);
  r := pg_temp.do_('mgr', pg_temp.q_pay(v_opw, pg_temp.k('e_s59'), 2000, pg_temp.ts(-60, '10:00')));
  perform pg_temp.do_('mgr', pg_temp.q_void((r->>'payment_id')::uuid));
  r2 := pg_temp.do_('mgr', pg_temp.q_pay(v_opw, pg_temp.k('e_s59'), 2000, pg_temp.ts(-60, '10:00')));
  perform pg_temp.ok('T59a pagamento repetido após anulação do original => replay (não registra de novo)',
    (r2->>'idempotent')::boolean and r2->>'payment_id' = r->>'payment_id'
    and (select count(*) from public.expense_payments where expense_id = pg_temp.k('e_s59')) = 1, r2::text);

  r := pg_temp.do_('mgr', format('select public.rg_expense_category_create(%L::uuid, ''Temporária'')', pg_temp.k('org'))); v_cat := (r->>'category_id')::uuid;
  r := pg_temp.do_('mgr', pg_temp.q_create(v_opy, pg_temp.k('org'), null, v_cat, 'S59 cat', 500, pg_temp.dd(-60)));
  perform pg_temp.do_('mgr', format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":false}'')', v_cat));
  r2 := pg_temp.do_('mgr', pg_temp.q_create(v_opy, pg_temp.k('org'), null, v_cat, 'S59 cat', 500, pg_temp.dd(-60)));
  perform pg_temp.ok('T59b criação repetida após inativar a categoria => replay (não CATEGORY_INACTIVE)',
    (r2->>'idempotent')::boolean and r2->>'expense_id' = r->>'expense_id', r2::text);

  perform pg_temp.mk('e_s59b', 'mgr', 'org', 'a1', 'cat_outros', 'S59b', 1000, -60);
  v_pay := pg_temp.epay('p_s59b', 'mgr', 'e_s59b', 1000, pg_temp.ts(-60, '10:00'));
  r := pg_temp.do_('mgr', pg_temp.q_rev(v_opz, v_pay, 400, pg_temp.ts(-60, '11:00')));
  perform pg_temp.do_('mgr', pg_temp.q_void((r->>'payment_id')::uuid));
  r2 := pg_temp.do_('mgr', pg_temp.q_rev(v_opz, v_pay, 400, pg_temp.ts(-60, '11:00')));
  perform pg_temp.ok('T59c devolução repetida após anular a devolução => replay', (r2->>'idempotent')::boolean and r2->>'payment_id' = r->>'payment_id', r2::text);

  perform pg_temp.mk('e_s59c', 'mgr', 'org', 'a1', 'cat_outros', 'S59c', 700, -60);
  r := pg_temp.do_('mgr', pg_temp.q_pay(v_opv, pg_temp.k('e_s59c'), 700, pg_temp.ts(-60, '10:00')));
  perform pg_temp.do_('mgr', pg_temp.q_rev(gen_random_uuid(), (r->>'payment_id')::uuid, 700, pg_temp.ts(-60, '11:00')));
  perform pg_temp.do_('mgr', pg_temp.q_cancel(pg_temp.k('e_s59c')));
  r2 := pg_temp.do_('mgr', pg_temp.q_pay(v_opv, pg_temp.k('e_s59c'), 700, pg_temp.ts(-60, '10:00')));
  perform pg_temp.ok('T59d pagamento repetido após cancelar a despesa => replay (não EXPENSE_CANCELLED)',
    (r2->>'idempotent')::boolean and r2->>'payment_id' = r->>'payment_id', r2::text);
end $$;

-- ============================================================================= T60 p_changes estrito
do $$ begin
  perform pg_temp.expect('T60a chave desconhecida (typo "amout") => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"amout": 1}'), '22023');
  perform pg_temp.expect('T60b chave válida + desconhecida => 22023 (nada aplicado)', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"description":"novo","x":1}'), '22023');
  perform pg_temp.expect('T60c amount como string => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"amount": "100"}'), '22023');
  perform pg_temp.expect('T60d amount fracionário => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"amount": 1.5}'), '22023');
  perform pg_temp.expect('T60e amount acima do teto => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"amount": 100000001}'), '22023');
  perform pg_temp.expect('T60f objeto vazio => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{}'), '22023');
  perform pg_temp.expect('T60g não-objeto (array) => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '[1]'), '22023');
  perform pg_temp.expect('T60h data inexistente => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"due_date":"2026-02-30"}'), '22023');
  perform pg_temp.expect('T60i arena com tipo errado => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"arena_id": 123}'), '22023');
  perform pg_temp.expect('T60j descrição vazia => 22023', 'mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"description":"   "}'), '22023');
  perform pg_temp.expect('T60k categoria: chave desconhecida => 22023', 'mgr',
    format('select public.rg_expense_category_update(%L::uuid, ''{"nome":"x"}'')', pg_temp.k('cat_outros')), '22023');
  perform pg_temp.expect('T60l categoria: is_active como string => 22023', 'mgr',
    format('select public.rg_expense_category_update(%L::uuid, ''{"is_active":"false"}'')', pg_temp.k('cat_outros')), '22023');
  perform pg_temp.expect('T60m categoria: objeto vazio => 22023', 'mgr',
    format('select public.rg_expense_category_update(%L::uuid, ''{}'')', pg_temp.k('cat_outros')), '22023');
  perform pg_temp.ok('T60n update sem mudança real => changed=false e nenhuma auditoria nova',
    not (pg_temp.do_('mgr', pg_temp.q_upd(pg_temp.k('e_open'), '{"description":"Aluguel do mês"}'))->>'changed')::boolean
    and (select count(*) from public.audit_logs where entity_id = pg_temp.k('e_open') and action = 'EXPENSE_UPDATED') = 0, 'ok');
end $$;

-- ============================================================================= resultado
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from rr;
  if v_fail > 0 then
    select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from rr;
    raise exception E'P3B2_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.\n%',
      v_total - v_fail, v_fail, v_total, v_txt;
  end if;
end $$;

select format('P3B2_RESULTS OK — %s PASS / 0 FAIL (total %s)', count(*), count(*))
       || E'\n' || string_agg('PASS ' || name, E'\n' order by seq) as p3b2_results
  from rr;

rollback;
