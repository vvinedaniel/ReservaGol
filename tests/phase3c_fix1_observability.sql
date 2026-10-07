-- =============================================================================
-- RESERVA GOL — FASE 03C · FIX 1 — testes SQL da observabilidade do top-up (G3C-2A)
-- Requer a cadeia até 03C (+ opcionalmente migration_phase3c_fix1_topup_observability.sql).
-- Banco de TESTE local, nunca Production. SEM o FIX 1 os testes F01/F02/F06/D01/G01 FALHAM (bugs reproduzidos);
-- com o FIX 1 todos passam.
--
-- Como rodar:
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3c_fix1_observability.sql
-- Sucesso: "P3CF1_RESULTS OK ..." + ROLLBACK explícito. Falha: erro "P3CF1_RESULTS FAIL ..." (exit != 0). ZERO RESÍDUO.
--
-- F: already_count (auditoria RECURRING_OCCURRENCES_GENERATED) · D: duração do run do lote do operador ·
-- G: atributos das funções (owner/ACL/definer/search_path) · R: planner/materialização/job inalterados (md5).
-- =============================================================================
begin;
set local statement_timeout = '120s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
create temp table kv (k text primary key, v jsonb) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3cf1: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)') is null then
    raise exception 'p3cf1: migration 03C não aplicada';
  end if;
end $$;

create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.v(p text) returns jsonb language sql stable as $$ select v from kv where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- âncoras de uma série em [de, até]
create function pg_temp.anchors(p_series uuid, p_from date, p_to date) returns date[] language sql stable as $$
  select coalesce(array_agg(g::date order by g), '{}') from generate_series(p_from, p_to, interval '1 day') g,
         public.recurring_reservations s where s.id = p_series and private.rg_is_anchor(s, g::date) $$;
-- linhas da série na janela [hoje, hoje+h]
create function pg_temp.inwin(p_series uuid, p_h int) returns bigint language sql stable as $$
  select count(*) from public.reservations r where r.recurring_reservation_id = p_series
     and r.occurrence_date between private.rg_today() and private.rg_today() + p_h $$;
-- auditoria de geração mais recente da série (nesta transação)
create function pg_temp.audit(p_series uuid) returns jsonb language sql stable as $$
  select a.metadata from public.audit_logs a where a.entity_id = p_series and a.action = 'RECURRING_OCCURRENCES_GENERATED'
   order by a.created_at desc, a.id desc limit 1 $$;
create function pg_temp.naudit(p_series uuid) returns bigint language sql stable as $$
  select count(*) from public.audit_logs a where a.entity_id = p_series and a.action = 'RECURRING_OCCURRENCES_GENERATED' $$;
-- dry-run de UMA série (classe => quantidade)
create function pg_temp.plan(p_series uuid, p_h int, p_class text) returns bigint language sql stable as $$
  select count(*) from private.rg_recurring_topup_plan(p_h, array[p_series]) where classification = p_class $$;
create function pg_temp.topup(p_series uuid, p_h int) returns jsonb language sql volatile as $$
  select private.rg_topup_series(p_series, p_h, 'MANUAL', 'SYSTEM_OPERATOR', null, null, false, 1::smallint) $$;

-- ----------------------------------------------------------------------------- fixtures
-- Série semanal no dia da semana de hoje+1: âncoras em hoje+1, +8, +15, ... (+71 = 11ª, +78 = 12ª).
-- Horizonte 45 => 7 âncoras; 72 => 11; 79 => 12.
do $$
declare
  v_tag text := 'p3cf1-' || substr(md5(clock_timestamp()::text), 1, 8);
  v_today date := private.rg_today();
  v_wd int := extract(dow from v_today + 1)::int;
  v_org uuid; v_a uuid; w int; v_s public.recurring_reservations; v_b record;
begin
  insert into public.organizations (name, is_demo) values ('P3CF1 ' || v_tag, true) returning id into v_org;
  insert into public.arenas (organization_id, name) values (v_org, 'A ' || v_tag) returning id into v_a;
  for w in 0..6 loop
    insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
    values (v_org, v_a, w, '06:00', '23:00', false);
  end loop;
  insert into fx values ('org', v_org), ('a', v_a);
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a, 'QA') returning id) insert into fx select 'cA', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a, 'QB') returning id) insert into fx select 'cB', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a, 'QC') returning id) insert into fx select 'cC', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a, 'QN') returning id) insert into fx select 'cN', id from x;
  insert into kv values ('wd', to_jsonb(v_wd));

  -- Caso C: avulsa LEGADA ocupando a 12ª âncora (hoje+78), criada ANTES da série (a proteção de horário não se aplica)
  select b.start_at, b.end_at into v_b from private.rg_occurrence_bounds(v_today + 78, '19:00', '20:00') b;
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, notes)
  values (v_org, v_a, pg_temp.k('cC'), v_b.start_at, v_b.end_at, 'CONFIRMED', 'INTERNAL', 'p3cf1 legado');

  -- séries (setup como postgres)
  insert into public.recurring_reservations (organization_id, arena_id, court_id, frequency, weekday, start_time, end_time,
                                             start_date, has_no_end_date, default_price, is_demo)
  select v_org, v_a, pg_temp.k(c), 'WEEKLY', v_wd, '19:00', '20:00', v_today, true, 10000, true
    from unnest(array['cA', 'cB', 'cC', 'cN']) c;
  insert into fx select 'S' || substr(c.name, 2), s.id from public.recurring_reservations s join public.courts c on c.id = s.court_id
   where s.organization_id = v_org;   -- SA, SB, SC, SN

  -- pré-existentes: B = 4 primeiras âncoras; C = 11 primeiras; N = 11 primeiras (pela autoridade única, janela B3)
  select * into v_s from public.recurring_reservations where id = pg_temp.k('SB');
  perform private.rg_materialize(v_s, (pg_temp.anchors(v_s.id, v_today, v_today + 22)), false, null);
  select * into v_s from public.recurring_reservations where id = pg_temp.k('SC');
  perform private.rg_materialize(v_s, (pg_temp.anchors(v_s.id, v_today, v_today + 71)), false, null);
  select * into v_s from public.recurring_reservations where id = pg_temp.k('SN');
  perform private.rg_materialize(v_s, (pg_temp.anchors(v_s.id, v_today, v_today + 71)), false, null);
end $$;

-- ----------------------------------------------------------------------------- F: already_count
do $$
declare r jsonb; a jsonb; p_exist bigint; p_create bigint; p_conf bigint;
begin
  -- pré-condições do cenário
  perform pg_temp.ok('F00 fixture: A=0, B=4, C=11, N=11 ocorrências pré-existentes; avulsa legada na 12ª âncora de C',
    pg_temp.inwin(pg_temp.k('SA'), 120) = 0 and pg_temp.inwin(pg_temp.k('SB'), 120) = 4
    and pg_temp.inwin(pg_temp.k('SC'), 120) = 11 and pg_temp.inwin(pg_temp.k('SN'), 120) = 11);

  -- Caso A: 0 existentes + 7 criadas
  p_exist := pg_temp.plan(pg_temp.k('SA'), 45, 'ALREADY_MATERIALIZED'); p_create := pg_temp.plan(pg_temp.k('SA'), 45, 'CREATE');
  r := pg_temp.topup(pg_temp.k('SA'), 45); a := pg_temp.audit(pg_temp.k('SA'));
  perform pg_temp.ok('F01 caso A (0 existentes + 7 criadas): outcome CREATED, created 7, already_count = 0',
    r->>'outcome' = 'CREATED' and (r->>'created_count')::int = 7 and (a->>'already_count')::int = 0
    and jsonb_array_length(a->'created') = 7 and (a->'counts'->>'created')::int = 7, format('r=%s audit=%s', r, a));
  perform pg_temp.ok('F01b caso A bate com o dry-run anterior (ALREADY_MATERIALIZED=0, CREATE=7)', p_exist = 0 and p_create = 7,
    format('plan exist=%s create=%s', p_exist, p_create));
  insert into kv values ('A', jsonb_build_object('exist', p_exist, 'create', p_create, 'audit', a));

  -- Caso B: 4 existentes + 7 criadas
  p_exist := pg_temp.plan(pg_temp.k('SB'), 72, 'ALREADY_MATERIALIZED'); p_create := pg_temp.plan(pg_temp.k('SB'), 72, 'CREATE');
  r := pg_temp.topup(pg_temp.k('SB'), 72); a := pg_temp.audit(pg_temp.k('SB'));
  perform pg_temp.ok('F02 caso B (4 existentes + 7 criadas): outcome CREATED, created 7, already_count = 4',
    r->>'outcome' = 'CREATED' and (r->>'created_count')::int = 7 and (a->>'already_count')::int = 4, format('r=%s audit=%s', r, a));
  perform pg_temp.ok('F02b caso B bate com o dry-run anterior (ALREADY_MATERIALIZED=4, CREATE=7)', p_exist = 4 and p_create = 7,
    format('plan exist=%s create=%s', p_exist, p_create));
  insert into kv values ('B', jsonb_build_object('exist', p_exist, 'create', p_create, 'audit', a));

  -- Caso C: 11 existentes + 0 criadas, com auditoria (lacuna CONFLICT aberta na 12ª âncora => gaps_changed)
  p_exist := pg_temp.plan(pg_temp.k('SC'), 79, 'ALREADY_MATERIALIZED'); p_conf := pg_temp.plan(pg_temp.k('SC'), 79, 'CONFLICT');
  r := pg_temp.topup(pg_temp.k('SC'), 79); a := pg_temp.audit(pg_temp.k('SC'));
  perform pg_temp.ok('F03 caso C (11 existentes + 0 criadas, lacuna aberta): outcome NOOP, created 0, already_count = 11, conflict 1',
    r->>'outcome' = 'NOOP' and (r->>'created_count')::int = 0 and (r->>'gaps_changed')::boolean
    and (a->>'already_count')::int = 11 and (a->'counts'->>'conflict')::int = 1
    and jsonb_array_length(a->'created') = 0, format('r=%s audit=%s', r, a));
  perform pg_temp.ok('F03b caso C bate com o dry-run anterior (ALREADY_MATERIALIZED=11, CONFLICT=1)', p_exist = 11 and p_conf = 1,
    format('plan exist=%s conflict=%s', p_exist, p_conf));

  -- Caso C2: 11 existentes + 0 criadas, SEM mudança de lacuna => NOOP sem auditoria (freeze: audita só se algo mudou)
  r := pg_temp.topup(pg_temp.k('SN'), 72);
  perform pg_temp.ok('F04 NOOP puro (11 existentes, nada a criar, nenhuma lacuna): outcome NOOP e NENHUMA auditoria',
    r->>'outcome' = 'NOOP' and (r->>'created_count')::int = 0 and not (r->>'gaps_changed')::boolean
    and pg_temp.naudit(pg_temp.k('SN')) = 0, r::text);

  -- Invariante: already_count + created = linhas da série na janela depois da chamada
  perform pg_temp.ok('F05 invariante already_count + created = ocorrências na janela após a chamada (A, B, C)',
    (pg_temp.v('A')->'audit'->>'already_count')::int + 7 = pg_temp.inwin(pg_temp.k('SA'), 45)
    and (pg_temp.v('B')->'audit'->>'already_count')::int + 7 = pg_temp.inwin(pg_temp.k('SB'), 72)
    and (a->>'already_count')::int + 0 = pg_temp.inwin(pg_temp.k('SC'), 79));

  -- Segunda passada em C (lacuna já aberta, nada mudou) => NOOP sem nova auditoria; already_count anterior preservado
  r := pg_temp.topup(pg_temp.k('SC'), 79);
  perform pg_temp.ok('F06 nova passada em C sem mudança: NOOP, sem auditoria nova (1 linha no total)',
    r->>'outcome' = 'NOOP' and pg_temp.naudit(pg_temp.k('SC')) = 1, r::text);
end $$;

-- ----------------------------------------------------------------------------- D: duração do run do lote
do $$
declare v_tx timestamptz := now(); v_res jsonb; v_run public.recurring_generation_runs; v_before timestamptz; v_after timestamptz;
begin
  -- now() fica preso no início da transação; o relógio real anda (pg_sleep APENAS no teste)
  perform pg_sleep(0.25);
  v_before := clock_timestamp();
  v_res := private.rg_recurring_topup_batch(3, array[pg_temp.k('SA'), pg_temp.k('SB'), pg_temp.k('SN')]);
  v_after := clock_timestamp();
  select * into v_run from public.recurring_generation_runs where id = (v_res->>'run_id')::uuid;
  insert into kv values ('run', to_jsonb(v_run));
  perform pg_temp.ok('D00 lote executado: SUCCEEDED, 3 séries examinadas',
    v_run.status = 'SUCCEEDED' and (v_res->'counts'->>'examined')::int = 3, v_res::text);
  perform pg_temp.ok('D01 started_at NÃO fica preso ao início da transação (relógio real): started_at >= início + 0,25 s',
    v_run.started_at >= v_tx + interval '0.25 seconds' and v_run.started_at >= v_before,
    format('tx=%s started=%s', v_tx, v_run.started_at));
  perform pg_temp.ok('D02 finished_at > started_at (duração real > 0) e dentro da janela medida externamente',
    v_run.finished_at > v_run.started_at and v_run.finished_at <= v_after and v_run.started_at >= v_before,
    format('started=%s finished=%s before=%s after=%s', v_run.started_at, v_run.finished_at, v_before, v_after));
  perform pg_temp.ok('D03 duração do run = finished_at - started_at <= duração medida externamente',
    (v_run.finished_at - v_run.started_at) <= (v_after - v_before), format('run=%s ext=%s', v_run.finished_at - v_run.started_at, v_after - v_before));
end $$;

-- ----------------------------------------------------------------------------- G: atributos preservados
do $$ begin
  perform pg_temp.ok('G01 corpos FIX 1 (md5): rg_topup_series 61cf2533…, rg_recurring_topup_batch 0f8080e6…',
    (select md5(prosrc) from pg_proc where oid = 'private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)'::regprocedure) = '61cf25332b9c329c67bbff2540895ed4'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_recurring_topup_batch(integer, uuid[])'::regprocedure) = '0f8080e661045f943a24297424fe3744');
  perform pg_temp.ok('G02 atributos: owner postgres, SECURITY DEFINER, search_path vazio, EXECUTE só para postgres (as duas funções)',
    (select bool_and(p.proowner = 'postgres'::regrole and p.prosecdef and p.proconfig = array['search_path=""']
                     and p.proacl::text = '{postgres=X/postgres}')
       from pg_proc p where p.oid in ('private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)'::regprocedure,
                                      'private.rg_recurring_topup_batch(integer, uuid[])'::regprocedure)));
  perform pg_temp.ok('G03 nenhum papel da API executa as funções corrigidas',
    not has_function_privilege('anon', 'private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)', 'EXECUTE')
    and not has_function_privilege('service_role', 'private.rg_recurring_topup_batch(integer, uuid[])', 'EXECUTE')
    and not has_function_privilege('authenticated', 'private.rg_recurring_topup_batch(integer, uuid[])', 'EXECUTE'));
end $$;

-- ----------------------------------------------------------------------------- R: nada mais mudou
do $$ begin
  perform pg_temp.ok('R01 planner/dry-run/candidatos/materialização inalterados (md5 03C)',
    (select md5(prosrc) from pg_proc where oid = 'private.rg_plan_series(uuid, date, date)'::regprocedure) = 'ff9d1a1caf9e031a01db42f1b805a13c'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_recurring_topup_plan(integer, uuid[])'::regprocedure) = 'c3c4f39f0345b9456cb44a48d0e75e32'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_topup_candidates(integer, uuid[])'::regprocedure) = '30bac7e932326b4662392cc8e04d4fa6'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid)'::regprocedure) = '586cbc97b0f1a840aed77bd885c7ae43'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_materialize(public.recurring_reservations, date[], boolean, uuid)'::regprocedure) = '595ee52c3be25bf50ab4b44fb1e5683c');
  perform pg_temp.ok('R02 job (procedure), RPCs públicas, trigger de proteção e helpers inalterados (md5 03C)',
    (select md5(prosrc) from pg_proc where oid = 'private.rg_recurring_topup_job(text)'::regprocedure) = '1d3091c712cea7b4bdaa5436c7a4169f'
    and (select md5(prosrc) from pg_proc where oid = 'public.rg_recurring_topup(uuid)'::regprocedure) = '299b40d1299313cbce6aced86b433e71'
    and (select md5(prosrc) from pg_proc where oid = 'public.rg_recurring_gaps(uuid, uuid)'::regprocedure) = '12581ef67ef9c91dbd4077d47e74801d'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_protect_series_slot()'::regprocedure) = '3b58975cd02c50293a8e1ccb77724537'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_gap_open(public.recurring_reservations, date, text, uuid, text, uuid, uuid)'::regprocedure) = '47640e8c7bdb4cb95df3c82d0da2ef4f'
    and (select md5(prosrc) from pg_proc where oid = 'private.rg_fits_business_hours(uuid, date, time, time)'::regprocedure) = 'ece53965e8ce574329790b84ee17fd07');
  perform pg_temp.ok('R03 contratos 03B.3A (6 RPCs) e B3 create/reschedule/reactivate/generate inalterados (md5)',
    (select string_agg(md5(replace(p.prosrc, chr(13), '')), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail',
            'rg_recurring_month_payment_record', 'rg_recurring_link_customer', 'rg_recurring_month_apply_series_price'))
    = 'ef638d905dcf0ae4072e7c601172e57b,dfbe684f4f49f5c0c77f14cff70f70bb,099860fb4081811b4ff6823dfeac937c,8061cb47215e805fa0eed28295c13078,fbeeaf4bc38f93fa6481b1daff3e0f13,a1c0277a18f9a5146e370a8c5684aa4e'
    and (select md5(prosrc) from pg_proc where oid = 'public.rg_recurring_create'::regproc) = '2aae1120c6e600989e6e990f7146c84f'
    and (select md5(prosrc) from pg_proc where oid = 'public.rg_recurring_reschedule'::regproc) = '520ab107c6b41e853c7f5d440b93fc92'
    and (select md5(prosrc) from pg_proc where oid = 'public.rg_recurring_reactivate'::regproc) = '2990704afae3823d88d51348df616d66'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_recurring_generate'::regproc) = '76efe0f4059d4a0e1c9908ec2dd6ea08');
end $$;

-- ----------------------------------------------------------------------------- resultado
do $$
declare v_fail int; v_total int; v_list text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from rr;
  for v_list in select format('%s %s%s', case when ok then 'PASS' else 'FAIL' end, name, coalesce(' [' || left(detail, 400) || ']', ''))
                  from rr order by seq loop
    raise notice '%', v_list;
  end loop;
  if v_fail > 0 then
    raise exception 'P3CF1_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.', v_total - v_fail, v_fail, v_total;
  end if;
  raise notice 'P3CF1_RESULTS OK — % PASS / 0 FAIL (total %)', v_total, v_total;
end $$;
rollback;
