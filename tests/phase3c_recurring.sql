-- =============================================================================
-- RESERVA GOL — FASE 03C — testes SQL da recorrência determinística
-- Requer B3 + 03A + 03B.x + 03B.3A + migration_phase3c_recurring_deterministic.sql aplicadas.
-- Banco de TESTE local, nunca Production.
--
-- Como rodar:
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/phase3c_recurring.sql
-- Sucesso: imprime "P3C_RESULTS OK ..." e faz ROLLBACK explícito. Falha: erro "P3C_RESULTS FAIL ..."
-- (exit != 0), transação nunca confirmada. ZERO RESÍDUO nos dois caminhos.
--
-- Blocos: H horário de funcionamento (espelho JS) · M autoridade única (rg_materialize/_ex, janela B3) ·
--         P dry-run (puro) · T geração (RPC do gestor + lote do operador, lacunas, convergência, falha) ·
--         S proteção de horário (trigger; todos os papéis) · A auditoria · G privilégios/estrutura ·
--         R regressão (contratos preservados).
-- O JOB (procedure com COMMIT por série) não roda dentro de transação: coberto em tests/phase3c_concurrency.sh.
-- =============================================================================
begin;
set local statement_timeout = '300s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table fd (k text primary key, d date not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
create temp table kv (k text primary key, v jsonb) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3c: execute como postgres (session_user=%)', session_user; end if;
  if to_regprocedure('private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid)') is null then
    raise exception 'p3c: migration 03C não aplicada';
  end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.d(p text) returns date language sql stable as $$ select d from fd where k = p $$;
create function pg_temp.v(p text) returns jsonb language sql stable as $$ select v from kv where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

create function pg_temp.snap() returns text language sql volatile as $$
  select md5(coalesce((select string_agg(x, '|' order by x) from (
    select 're:' || row_to_json(r)::text as x from public.reservations r
    union all select 'rs:' || row_to_json(r)::text from public.recurring_reservations r
    union all select 'au:' || row_to_json(r)::text from public.audit_logs r
    union all select 'gp:' || row_to_json(r)::text from public.recurring_occurrence_gaps r
    union all select 'ru:' || row_to_json(r)::text from public.recurring_generation_runs r
    union all select 'rx:' || row_to_json(r)::text from public.recurring_generation_run_series r
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
  if v.state <> 'OK' then raise exception 'p3c (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;

-- data do próximo dia da semana p_dow a partir de p_from (inclusive)
create function pg_temp.next_dow(p_from date, p_dow int) returns date language sql immutable as $$
  select p_from + ((p_dow - extract(dow from p_from)::int + 7) % 7) $$;
create function pg_temp.anchors(p_series uuid, p_from date, p_to date) returns date[] language sql stable as $$
  select coalesce(array_agg(g::date order by g), '{}') from generate_series(p_from, p_to, interval '1 day') g,
         public.recurring_reservations s where s.id = p_series and private.rg_is_anchor(s, g::date) $$;
create function pg_temp.nres(p_series uuid) returns bigint language sql stable as $$
  select count(*) from public.reservations where recurring_reservation_id = p_series $$;
create function pg_temp.has_occ(p_series uuid, p_d date) returns boolean language sql stable as $$
  select exists (select 1 from public.reservations where recurring_reservation_id = p_series and occurrence_date = p_d) $$;
create function pg_temp.open_gap(p_series uuid, p_d date) returns public.recurring_occurrence_gaps language sql stable as $$
  select g.* from public.recurring_occurrence_gaps g where g.series_id = p_series and g.occurrence_date = p_d and g.resolved_at is null $$;
create function pg_temp.series(p_key text, p_arena text, p_court text, p_dow int, p_st time, p_et time, p_price int,
                               p_end date default null) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, null, ''WEEKLY'', %s, null, %L::time, %L::time, %L::date, %L::date, %s, %s, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k(p_arena), pg_temp.k(p_court), pg_temp.k('cu1'), p_dow, p_st, p_et, pg_temp.d('start'),
    p_end, case when p_end is null then 'true' else 'false' end, coalesce(p_price::text, 'null')));
  insert into fx values (p_key, (r->>'series_id')::uuid);
  return (r->>'series_id')::uuid;
end $$;
-- reserva avulsa (como postgres: setup)
create function pg_temp.avulsa(p_key text, p_court text, p_d date, p_st time, p_et time, p_status text default 'CONFIRMED')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, notes)
  select c.organization_id, c.arena_id, c.id, b.start_at, b.end_at, p_status, 'INTERNAL', 'p3c ' || p_key
    from public.courts c, private.rg_occurrence_bounds(p_d, p_st, p_et) b where c.id = pg_temp.k(p_court)
  returning id into v_id;
  insert into fx values (p_key, v_id);
  return v_id;
end $$;
-- SQL de INSERT de avulsa para pg_temp.call (como papel da API)
create function pg_temp.ins_sql(p_court text, p_d date, p_st time, p_et time, p_status text default 'CONFIRMED') returns text
language plpgsql stable as $$
declare v_s timestamptz; v_e timestamptz;
begin
  -- horários calculados AQUI (postgres); o SQL enviado ao papel da API só usa literais e public.courts
  select b.start_at, b.end_at into v_s, v_e from private.rg_occurrence_bounds(p_d, p_st, p_et) b;
  return format('insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source, notes) '
             || 'select c.organization_id, c.arena_id, c.id, %L::timestamptz, %L::timestamptz, %L, ''INTERNAL'', ''p3c api'' '
             || 'from public.courts c where c.id = %L::uuid returning jsonb_build_object(''id'', id)', v_s, v_e, p_status, pg_temp.k(p_court));
end $$;

-- ----------------------------------------------------------------------------- datas
do $$
declare v_today date := private.rg_today();
begin
  insert into fd values ('today', v_today), ('start', v_today - 7);
  -- W = dia da semana de hoje+10 (âncoras em hoje+3, hoje+10, hoje+17, ...); WC = dia fechado
  insert into kv values ('W', to_jsonb(extract(dow from v_today + 10)::int)), ('WC', to_jsonb(extract(dow from v_today + 12)::int));
  insert into fd values ('d3', v_today + 3), ('d10', v_today + 10), ('d17', v_today + 17), ('d24', v_today + 24),
                        ('dm4', v_today - 4), ('d12', v_today + 12);
end $$;

-- ----------------------------------------------------------------------------- fixtures
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_out uuid := gen_random_uuid(); u_adm uuid := gen_random_uuid(); u_str uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_a2 uuid; v_ah uuid; v_b1 uuid;
  v_tag text := 'p3c-' || substr(md5(clock_timestamp()::text), 1, 8);
  w int;
begin
  insert into auth.users (id, email) values
    (u_owner, v_tag || '-owner@reservagol.test'), (u_mgr, v_tag || '-mgr@reservagol.test'), (u_rec, v_tag || '-rec@reservagol.test'),
    (u_out, v_tag || '-out@reservagol.test'), (u_adm, v_tag || '-adm@reservagol.test'), (u_str, v_tag || '-str@reservagol.test');
  insert into public.profiles (id) values (u_adm) on conflict (id) do nothing;
  update public.profiles set is_platform_admin = true where id = u_adm;
  insert into public.organizations (name, is_demo) values ('P3C ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('P3C outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org2, u_out, 'OWNER', 'ACTIVE'), (v_org, u_str, 'MANAGER', 'SUSPENDED');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;   -- 08–22, WC fechado
  insert into public.arenas (organization_id, name) values (v_org, 'A2 ' || v_tag) returning id into v_a2;   -- SEM business_hours
  insert into public.arenas (organization_id, name) values (v_org, 'AH ' || v_tag) returning id into v_ah;   -- matriz de horário
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  for w in 0..6 loop
    insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
    values (v_org, v_a1, w, '08:00', '22:00', w = (pg_temp.v('WC'))::int);
  end loop;
  -- matriz: 0 sem linha; 1 fechado; 2 open nulo; 3 08–22; 4 08–00:00; 5 00:00–00:00; 6 10:00–10:30
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed) values
    (v_org, v_ah, 1, '08:00', '22:00', true), (v_org, v_ah, 2, null, '22:00', false), (v_org, v_ah, 3, '08:00', '22:00', false),
    (v_org, v_ah, 4, '08:00', '00:00', false), (v_org, v_ah, 5, '00:00', '00:00', false), (v_org, v_ah, 6, '10:00', '10:30', false);
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('adm', u_adm), ('str', u_str),
    ('org', v_org), ('org2', v_org2), ('a1', v_a1), ('a2', v_a2), ('ah', v_ah), ('b1', v_b1);
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q1') returning id) insert into fx select 'c1', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q2') returning id) insert into fx select 'c2', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name, active) values (v_org, v_a1, 'Q inativa', false) returning id) insert into fx select 'cin', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a2, 'Q4') returning id) insert into fx select 'c4', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'QB') returning id) insert into fx select 'd1', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Cliente P3C', '11990003001') returning id) insert into fx select 'cu1', id from x;
end $$;

-- Avulsa LEGADA criada ANTES de qualquer série (c1, hoje+10, 20–21): vira conflito real da série SB.
select pg_temp.avulsa('X', 'c1', pg_temp.d('d10'), '20:00', '21:00');

do $$
declare w int := (pg_temp.v('W'))::int;
begin
  perform pg_temp.series('SA', 'a1', 'c1', w, '19:00', '20:00', 10000);              -- materialização normal
  perform pg_temp.series('SB', 'a1', 'c1', w, '20:00', '21:00', 10000);              -- conflito com X em hoje+10
  perform pg_temp.series('SQ', 'a1', 'c2', w, '19:00', '20:00', 9000);               -- proteção (nunca materializada até S11)
  perform pg_temp.series('SP', 'a1', 'c2', w, '21:00', '22:00', 9000);               -- será pausada
  perform pg_temp.series('SE', 'a1', 'c2', w, '10:00', '11:00', 9000, pg_temp.d('today') + 5);  -- encerrada antes de hoje+10
  perform pg_temp.series('SH', 'a2', 'c4', w, '19:00', '20:00', 9000);               -- arena SEM horário
  perform pg_temp.series('SI', 'a1', 'cin', w, '19:00', '20:00', 9000);              -- quadra inativa
  perform pg_temp.series('SM', 'a1', 'c2', w, '23:00', '00:30', 9000);               -- cruza a meia-noite
  perform pg_temp.series('SF', 'a1', 'c1', w, '09:00', '10:00', 9000);               -- falha injetada
  perform pg_temp.series('SN', 'a1', 'c1', w, '16:00', '17:00', 9000);               -- segunda série do lote com falha
  perform pg_temp.series('SO', 'a1', 'c1', w, '13:00', '14:00', 9000);               -- alvo de "mover ocorrência" (nunca materializada)
  perform pg_temp.series('SC', 'a1', 'c1', (pg_temp.v('WC'))::int, '10:00', '11:00', 9000);  -- dia fechado
  perform pg_temp.do_('owner', format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.k('SP')));
end $$;

-- ============================================================================= H — horário de funcionamento
do $$
declare
  t date := pg_temp.d('today');
  ah uuid := pg_temp.k('ah');
  f boolean;
begin
  perform pg_temp.ok('H01 sem linha para o dia => fechado', not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 0), '10:00', '11:00'));
  perform pg_temp.ok('H02 closed=true => fechado', not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 1), '10:00', '11:00'));
  perform pg_temp.ok('H03 open_time nulo => fechado', not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 2), '10:00', '11:00'));
  perform pg_temp.ok('H04 08–22: limites exatos cabem (08:00–09:00, 21:00–22:00)',
    private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 3), '08:00', '09:00')
    and private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 3), '21:00', '22:00'));
  perform pg_temp.ok('H05 08–22: 07:59 e 22:01 não cabem',
    not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 3), '07:59', '09:00')
    and not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 3), '21:30', '22:01'));
  perform pg_temp.ok('H06 fecha 00:00 = 1440: 23:00–00:00 cabe; 23:00–00:30 (cruza) não',
    private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 4), '23:00', '00:00')
    and not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 4), '23:00', '00:30'));
  perform pg_temp.ok('H07 00:00–00:00: 00:00–01:00 e 22:00–23:59 cabem; 22:00–01:00 (cruza) NÃO (não é 24 h)',
    private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 5), '00:00', '01:00')
    and private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 5), '22:00', '23:59')
    and not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 5), '22:00', '01:00'));
  perform pg_temp.ok('H08 janela curta 10:00–10:30: 10:00–10:30 cabe; 10:00–10:31 não',
    private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 6), '10:00', '10:30')
    and not private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 6), '10:00', '10:31'));
  perform pg_temp.ok('H09 dia da semana do calendário (0=domingo) e segundos ignorados (HH:MM)',
    private.rg_fits_business_hours(ah, pg_temp.next_dow(t, 3), '08:00:59', '09:00:30')
    and extract(dow from pg_temp.next_dow(t, 0))::int = 0);
end $$;

-- ============================================================================= M — autoridade única
do $$
declare
  r jsonb; v jsonb; g public.recurring_occurrence_gaps; v_sh1 date; v_far date; v_before bigint;
begin
  -- M01 geração B3 normal (janela 90)
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SA'), array[pg_temp.d('d10')]));
  perform pg_temp.ok('M01 rg_recurring_generate cria a âncora válida, sem lacuna',
    r->'created' = to_jsonb(array[pg_temp.d('d10')]) and r->'skipped' = '[]'::jsonb and pg_temp.has_occ(pg_temp.k('SA'), pg_temp.d('d10'))
    and not exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SA')), r::text);

  -- M02 arena SEM business_hours => fechada: não cria, OUTSIDE_BUSINESS_HOURS, lacuna persistida
  v_sh1 := (pg_temp.anchors(pg_temp.k('SH'), pg_temp.d('today'), pg_temp.d('today') + 90))[1];
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SH'), array[v_sh1]));
  g := pg_temp.open_gap(pg_temp.k('SH'), v_sh1);
  perform pg_temp.ok('M02 arena sem horário: nada criado; resultado OUTSIDE_BUSINESS_HOURS; lacuna persistida (SERIES_ACTION, por quem pediu)',
    r->'created' = '[]'::jsonb and pg_temp.nres(pg_temp.k('SH')) = 0
    and g.reason = 'OUTSIDE_BUSINESS_HOURS' and g.origin = 'SERIES_ACTION' and g.opened_by = pg_temp.k('owner')
    and g.conflict_reservation_id is null, r::text);

  -- M03 quadra inativa
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SI'), array[pg_temp.d('d10')]));
  perform pg_temp.ok('M03 quadra inativa: nada criado; COURT_INACTIVE persistido',
    r->'created' = '[]'::jsonb and pg_temp.nres(pg_temp.k('SI')) = 0
    and (pg_temp.open_gap(pg_temp.k('SI'), pg_temp.d('d10'))).reason = 'COURT_INACTIVE', r::text);

  -- M04 conflito real (X) com skip => CONFLICT persistido com a reserva que ocupa (fim do silêncio)
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SB'), array[pg_temp.d('d10')]));
  g := pg_temp.open_gap(pg_temp.k('SB'), pg_temp.d('d10'));
  perform pg_temp.ok('M04 conflito: skipped (retorno B3 inalterado) + lacuna CONFLICT persistida com conflict_reservation_id = X',
    r->'skipped' = to_jsonb(array[pg_temp.d('d10')]) and not (r ? 'gaps')
    and g.reason = 'CONFLICT' and g.conflict_reservation_id = pg_temp.k('X'), r::text);

  -- M05 cruza meia-noite => sempre fora do horário (espelho JS)
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SM'), array[pg_temp.d('d10')]));
  perform pg_temp.ok('M05 série que cruza a meia-noite: OUTSIDE_BUSINESS_HOURS',
    r->'created' = '[]'::jsonb and (pg_temp.open_gap(pg_temp.k('SM'), pg_temp.d('d10'))).reason = 'OUTSIDE_BUSINESS_HOURS', r::text);

  -- M06 dia fechado (closed=true)
  insert into fd values ('sc1', (pg_temp.anchors(pg_temp.k('SC'), pg_temp.d('today') + 1, pg_temp.d('today') + 90))[1]);
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SC'), array[pg_temp.d('sc1')]));
  perform pg_temp.ok('M06 dia fechado: nada criado; lacuna OUTSIDE_BUSINESS_HOURS persistida', r->'created' = '[]'::jsonb
    and pg_temp.nres(pg_temp.k('SC')) = 0 and (pg_temp.open_gap(pg_temp.k('SC'), pg_temp.d('sc1'))).reason = 'OUTSIDE_BUSINESS_HOURS', r::text);

  -- M07 janela B3 continua 90 (rg_in_window intocada)
  v_far := (pg_temp.anchors(pg_temp.k('SA'), pg_temp.d('today') + 91, pg_temp.d('today') + 120))[1];
  v := to_jsonb(pg_temp.call('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SA'), array[v_far])));
  perform pg_temp.ok('M07 B3 recusa âncora > hoje+90 (22023); rg_in_window(90) intacta',
    v->>'state' = '22023' and private.rg_in_window(pg_temp.d('today') + 90) and not private.rg_in_window(pg_temp.d('today') + 91), v::text);

  -- M08 existente
  r := pg_temp.do_('owner', format('select public.rg_recurring_generate(%L::uuid, %L::date[])', pg_temp.k('SA'), array[pg_temp.d('d10')]));
  perform pg_temp.ok('M08 âncora já materializada => existing (idempotente)', r->'existing' = to_jsonb(array[pg_temp.d('d10')])
    and r->'created' = '[]'::jsonb, r::text);

  -- M09 auditoria B3 ganha 'gaps' (create com data fora do horário)
  select count(*) into v_before from public.audit_logs where action = 'RECURRING_RESERVATION_CREATED';
  r := pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, %L::uuid, null, ''WEEKLY'', %s, null, ''19:00''::time, ''20:00''::time, %L::date, null, true, 9000, null, false, false, %L::date[])',
    gen_random_uuid(), pg_temp.k('a2'), pg_temp.k('c4'), pg_temp.k('cu1'), (pg_temp.v('W'))::int + 0, pg_temp.d('start'),
    array[pg_temp.d('d17')]));
  insert into fx values ('SZ', (r->>'series_id')::uuid);
  perform pg_temp.ok('M09 auditoria de RECURRING_RESERVATION_CREATED tem gaps (aditivo) e contagens antigas intactas',
    exists (select 1 from public.audit_logs a where a.action = 'RECURRING_RESERVATION_CREATED' and a.entity_id = pg_temp.k('SZ')
             and a.metadata->'gaps'->0->>'reason' = 'OUTSIDE_BUSINESS_HOURS' and (a.metadata->>'created')::int = 0
             and a.metadata ? 'skipped' and a.metadata ? 'existing'), r::text);
end $$;

-- ============================================================================= P — dry-run (puro)
do $$
declare v_before text; v jsonb; n_sa int;
begin
  v_before := pg_temp.snap();
  select jsonb_object_agg(k, c) into v from (
    select p.series_id::text || ':' || p.classification as k, count(*) as c
      from private.rg_recurring_topup_plan(120, array[pg_temp.k('SA'), pg_temp.k('SB'), pg_temp.k('SH'), pg_temp.k('SI'), pg_temp.k('SM')]) p
     group by 1) x;
  insert into kv values ('plan', v);
  n_sa := cardinality(pg_temp.anchors(pg_temp.k('SA'), pg_temp.d('today'), pg_temp.d('today') + 120));
  insert into kv values ('n_sa', to_jsonb(n_sa));
  perform pg_temp.ok('P01 dry-run não escreve nada (snapshot idêntico)', pg_temp.snap() = v_before);
  perform pg_temp.ok('P02 SA: 1 ALREADY + (n-1) CREATE em [hoje, hoje+120]',
    (v->>(pg_temp.k('SA')::text || ':ALREADY_MATERIALIZED'))::int = 1
    and (v->>(pg_temp.k('SA')::text || ':CREATE'))::int = n_sa - 1, v::text);
  perform pg_temp.ok('P03 SB: CONFLICT (X) em hoje+10 com a reserva que ocupa',
    exists (select 1 from private.rg_recurring_topup_plan(120, array[pg_temp.k('SB')]) p
             where p.occurrence_date = pg_temp.d('d10') and p.classification = 'CONFLICT' and p.conflict_reservation_id = pg_temp.k('X')), v::text);
  perform pg_temp.ok('P04 SH tudo OUTSIDE_BUSINESS_HOURS; SI tudo COURT_INACTIVE; SM tudo OUTSIDE',
    (v->>(pg_temp.k('SH')::text || ':OUTSIDE_BUSINESS_HOURS'))::int = n_sa
    and (v->>(pg_temp.k('SI')::text || ':COURT_INACTIVE'))::int = n_sa
    and (v->>(pg_temp.k('SM')::text || ':OUTSIDE_BUSINESS_HOURS'))::int = n_sa, v::text);
  perform pg_temp.ok('P05 série PAUSED não aparece no plano (job ignora pausadas)',
    not exists (select 1 from private.rg_recurring_topup_plan(120, array[pg_temp.k('SP')])));
end $$;

-- ============================================================================= T — geração (RPC do gestor + lote do operador)
do $$
declare
  r jsonb; v jsonb; n_audit bigint; v_run uuid; n int; v_max date;
begin
  -- T01 gestor: até hoje+120, mesma regra do job, origem MANUAL, usuário real
  select count(*) into n_audit from public.audit_logs where action = 'RECURRING_OCCURRENCES_GENERATED';
  r := pg_temp.do_('mgr', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')));
  select max(occurrence_date) into v_max from public.reservations where recurring_reservation_id = pg_temp.k('SA');
  perform pg_temp.ok('T01 RPC do gestor materializa até hoje+120 (n-1 novas) e audita com o usuário real',
    r->>'outcome' = 'CREATED' and jsonb_array_length(r->'created') = (pg_temp.v('n_sa'))::int - 1
    and v_max > pg_temp.d('today') + 113 and v_max <= pg_temp.d('today') + 120
    and exists (select 1 from public.audit_logs a where a.action = 'RECURRING_OCCURRENCES_GENERATED' and a.entity_id = pg_temp.k('SA')
                 and a.user_id = pg_temp.k('mgr') and a.metadata->>'actor' = 'USER' and a.metadata->>'origin' = 'MANUAL'
                 and a.metadata->'run_id' = 'null'::jsonb and (a.metadata->'counts'->>'created')::int = (pg_temp.v('n_sa'))::int - 1
                 and a.metadata->>'horizon_date' = to_char(pg_temp.d('today') + 120, 'YYYY-MM-DD')), r::text);
  perform pg_temp.ok('T01b ocorrências do gestor: created_by = gestor, CONFIRMED/RECORRENTE, preço da série',
    not exists (select 1 from public.reservations x where x.recurring_reservation_id = pg_temp.k('SA') and x.occurrence_date > pg_temp.d('d10')
                 and (x.created_by is distinct from pg_temp.k('mgr') or x.status <> 'CONFIRMED' or x.source <> 'RECORRENTE' or x.price <> 10000)));
  -- T02 idempotente: NOOP, sem auditoria nova
  select count(*) into n_audit from public.audit_logs where action = 'RECURRING_OCCURRENCES_GENERATED';
  r := pg_temp.do_('mgr', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')));
  perform pg_temp.ok('T02 segunda geração = NOOP, nenhuma auditoria nova',
    r->>'outcome' = 'NOOP' and r->'created' = '[]'::jsonb
    and (select count(*) from public.audit_logs where action = 'RECURRING_OCCURRENCES_GENERATED') = n_audit, r::text);
  -- T03 permissões da RPC
  perform pg_temp.ok('T03 RECEPTIONIST => 42501',
    (pg_temp.call('rec', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = '42501');
  perform pg_temp.ok('T03b outro tenant / admin da plataforma sem vínculo / gestor SUSPENDED => P0002',
    (pg_temp.call('out', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = 'P0002'
    and (pg_temp.call('adm', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = 'P0002'
    and (pg_temp.call('str', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = 'P0002');
  perform pg_temp.ok('T03c anon / service_role sem EXECUTE (42501)',
    (pg_temp.call('anon', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = '42501'
    and (pg_temp.call('service_role', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SA')))).state = '42501');
  perform pg_temp.ok('T04 série PAUSED => RGR01',
    (pg_temp.call('owner', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('SP')))).state = 'RGR01');

  -- T05 lote do operador (postgres): run MANUAL/SYSTEM_OPERATOR; lacunas com last_run_id
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SB'), pg_temp.k('SH'), pg_temp.k('SI')]);
  v_run := (r->>'run_id')::uuid;
  insert into fx values ('run1', v_run);
  perform pg_temp.ok('T05 lote: SUCCEEDED; run MANUAL/SYSTEM_OPERATOR; SB criada exceto hoje+10 (CONFLICT); SH/SI só lacunas',
    r->>'status' = 'SUCCEEDED'
    and exists (select 1 from public.recurring_generation_runs x where x.id = v_run and x.origin = 'MANUAL'
                 and x.actor = 'SYSTEM_OPERATOR' and x.status = 'SUCCEEDED' and x.horizon_days = 120 and x.finished_at is not null)
    and pg_temp.nres(pg_temp.k('SB')) = (pg_temp.v('n_sa'))::int - 1 and not pg_temp.has_occ(pg_temp.k('SB'), pg_temp.d('d10'))
    and (pg_temp.open_gap(pg_temp.k('SB'), pg_temp.d('d10'))).last_run_id = v_run
    and pg_temp.nres(pg_temp.k('SH')) = 0 and pg_temp.nres(pg_temp.k('SI')) = 0
    and (select count(*) from public.recurring_occurrence_gaps g where g.series_id = pg_temp.k('SH') and g.resolved_at is null) = (pg_temp.v('n_sa'))::int
    and (select count(*) from public.recurring_occurrence_gaps g where g.series_id = pg_temp.k('SI') and g.resolved_at is null) = (pg_temp.v('n_sa'))::int, r::text);
  perform pg_temp.ok('T05b auditoria do operador: user_id NULL, actor SYSTEM_OPERATOR, origin MANUAL, run_id válido',
    (select count(*) from public.audit_logs a where a.action = 'RECURRING_OCCURRENCES_GENERATED' and a.user_id is null
       and a.metadata->>'actor' = 'SYSTEM_OPERATOR' and a.metadata->>'origin' = 'MANUAL' and (a.metadata->>'run_id')::uuid = v_run
       and a.entity_id in (pg_temp.k('SB'), pg_temp.k('SH'), pg_temp.k('SI'))) = 3
    and exists (select 1 from public.audit_logs a where a.entity_id = pg_temp.k('SB') and (a.metadata->>'run_id')::uuid = v_run
                 and a.metadata->'skipped' @> jsonb_build_array(jsonb_build_object('reason', 'CONFLICT', 'conflict_reservation_id', pg_temp.k('X')))));
  perform pg_temp.ok('T05c ocorrências de sistema: created_by NULL (nenhum usuário fictício)',
    not exists (select 1 from public.reservations x where x.recurring_reservation_id = pg_temp.k('SB') and x.created_by is not null));
  perform pg_temp.ok('T05d resultado por série gravado (CREATED SB; NOOP+lacunas SH/SI)',
    exists (select 1 from public.recurring_generation_run_series x where x.run_id = v_run and x.series_id = pg_temp.k('SB') and x.outcome = 'CREATED')
    and exists (select 1 from public.recurring_generation_run_series x where x.run_id = v_run and x.series_id = pg_temp.k('SH') and x.outcome = 'NOOP' and x.gaps_changed));

  -- T06 lote sem mudança: nada auditado, nenhuma linha por série
  select count(*) into n_audit from public.audit_logs where action = 'RECURRING_OCCURRENCES_GENERATED';
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SB'), pg_temp.k('SH'), pg_temp.k('SI')]);
  perform pg_temp.ok('T06 lote repetido: SUCCEEDED, 0 criadas, 0 auditorias, 0 linhas por série',
    r->>'status' = 'SUCCEEDED' and (r->'counts'->>'created')::int = 0
    and (select count(*) from public.audit_logs where action = 'RECURRING_OCCURRENCES_GENERATED') = n_audit
    and not exists (select 1 from public.recurring_generation_run_series x where x.run_id = (r->>'run_id')::uuid), r::text);
  perform pg_temp.ok('T07 lote valida p_limit (22023)',
    (pg_temp.call('postgres', 'select private.rg_recurring_topup_batch(0)')).state = '22023');

  -- T08 falha injetada numa série: isolada, ERROR registrado, execução PARTIAL, demais seguem
  perform set_config('rg.fault_at', 'topup:' || pg_temp.k('SF')::text, true);
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SF'), pg_temp.k('SN')]);
  perform set_config('rg.fault_at', '', true);
  perform pg_temp.ok('T08 falha numa série: ERROR (RGF01) só nela; PARTIAL; a outra série (SN) materializou',
    r->>'status' = 'PARTIAL' and (r->'counts'->>'errors')::int = 1 and pg_temp.nres(pg_temp.k('SF')) = 0
    and pg_temp.nres(pg_temp.k('SN')) = (pg_temp.v('n_sa'))::int
    and exists (select 1 from public.recurring_generation_run_series x where x.run_id = (r->>'run_id')::uuid
                 and x.series_id = pg_temp.k('SF') and x.outcome = 'ERROR' and x.sqlstate = 'RGF01')
    and (select status from public.recurring_generation_runs where id = (r->>'run_id')::uuid) = 'PARTIAL', r::text);
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SF')]);
  perform pg_temp.ok('T08b retry sem falha: série converge (CREATED)', r->>'status' = 'SUCCEEDED'
    and pg_temp.nres(pg_temp.k('SF')) = (pg_temp.v('n_sa'))::int, r::text);
end $$;

-- ============================================================================= S — proteção do horário (trigger)
do $$
declare v jsonb; v_id uuid; n bigint;
begin
  -- S01..S03 todos os papéis: avulsa / BLOCKED / service_role sobre âncora futura NÃO materializada de SQ
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '19:00', '20:00')));
  perform pg_temp.ok('S01 RECEPTIONIST: avulsa sobre horário de série ACTIVE => 23P01 RECURRING_SLOT',
    v->>'state' = '23P01' and v->'result'->>'hint' = 'RECURRING_SLOT', v::text);
  v := to_jsonb(pg_temp.call('mgr', pg_temp.ins_sql('c2', pg_temp.d('d10'), '19:00', '20:00', 'BLOCKED')));
  perform pg_temp.ok('S02 gestor: BLOCKED também é barrado (D2)', v->>'state' = '23P01' and v->'result'->>'hint' = 'RECURRING_SLOT', v::text);
  v := to_jsonb(pg_temp.call('service_role', pg_temp.ins_sql('c2', pg_temp.d('d10'), '19:00', '20:00', 'PENDING')));
  perform pg_temp.ok('S03 service_role (caminho da reserva pública) => 23P01', v->>'state' = '23P01', v::text);
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '19:30', '20:30')));
  perform pg_temp.ok('S03b sobreposição parcial => 23P01', v->>'state' = '23P01', v::text);
  perform pg_temp.ok('S03c mensagem não expõe dados do mensalista', position('Cliente P3C' in coalesce(v->'result'->>'msg', '')) = 0);

  -- S04 mover avulsa existente para o horário (UPDATE direto, como pelo PostgREST)
  v := pg_temp.do_('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '12:00', '13:00'));
  v_id := (v->>'id')::uuid;
  insert into fx values ('Y', v_id);
  v := to_jsonb(pg_temp.call('rec', format(
    'update public.reservations set start_at = start_at + interval ''7 hours'', end_at = end_at + interval ''7 hours'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id)));
  perform pg_temp.ok('S04 UPDATE direto movendo avulsa para o horário => 23P01', v->>'state' = '23P01' and v->'result'->>'hint' = 'RECURRING_SLOT', v::text);
  v := to_jsonb(pg_temp.call('rec', format('update public.reservations set notes = ''nota'' where id = %L::uuid returning jsonb_build_object(''id'', id)', v_id)));
  perform pg_temp.ok('S04b UPDATE só de observação não é afetado', v->>'state' = 'OK', v::text);
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '20:00', '21:00')));
  perform pg_temp.ok('S05 adjacente (termina/começa no limite) é permitido', v->>'state' = 'OK', v::text);

  -- S06 avulsa LEGADA (X, anterior à série SB): editar observação OK; cancelar OK; reviver => barrado
  v := to_jsonb(pg_temp.call('rec', format('update public.reservations set notes = ''legado'' where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.k('X'))));
  perform pg_temp.ok('S06 legado: editar observação não dispara a proteção', v->>'state' = 'OK', v::text);
  v := to_jsonb(pg_temp.call('rec', format('update public.reservations set status = ''CANCELLED'' where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.k('X'))));
  perform pg_temp.ok('S06b legado: cancelar é permitido', v->>'state' = 'OK', v::text);
  v := to_jsonb(pg_temp.call('rec', format('update public.reservations set status = ''CONFIRMED'' where id = %L::uuid returning jsonb_build_object(''id'', id)', pg_temp.k('X'))));
  perform pg_temp.ok('S06c legado: reviver sobre horário de série ACTIVE ainda não materializado => 23P01', v->>'state' = '23P01'
    and v->'result'->>'hint' = 'RECURRING_SLOT', v::text);

  -- S07 ocorrência materializada: ativa => conflito da constraint; cancelada ("apenas esta") => horário livre
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c1', pg_temp.d('d17'), '19:00', '20:00')));
  perform pg_temp.ok('S07 ocorrência materializada ativa: 23P01 da reservations_no_overlap (não da trigger)',
    v->>'state' = '23P01' and coalesce(v->'result'->>'hint', '') <> 'RECURRING_SLOT', v::text);
  update public.reservations set status = 'CANCELLED', is_exception = true
   where recurring_reservation_id = pg_temp.k('SA') and occurrence_date = pg_temp.d('d10');
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c1', pg_temp.d('d10'), '19:00', '20:00')));
  perform pg_temp.ok('S07b ocorrência cancelada explicitamente libera o horário', v->>'state' = 'OK', v::text);

  -- S08..S10
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '21:00', '22:00')));
  perform pg_temp.ok('S08 série PAUSED não protege (D3)', v->>'state' = 'OK', v::text);
  v := to_jsonb(pg_temp.call('rec', pg_temp.ins_sql('c2', pg_temp.d('d10'), '10:00', '11:00')));
  perform pg_temp.ok('S09 série encerrada (end_date antes) não protege', v->>'state' = 'OK', v::text);
  v := to_jsonb(pg_temp.call('postgres', pg_temp.ins_sql('c2', pg_temp.d('dm4'), '19:00', '20:00')));
  perform pg_temp.ok('S10 âncora passada não é protegida', v->>'state' = 'OK', v::text);

  -- S12 mover uma ocorrência recorrente (exceção) para âncora não materializada de OUTRA série
  v := to_jsonb(pg_temp.call('rec', format(
    'update public.reservations set start_at = start_at - interval ''6 hours'', end_at = end_at - interval ''6 hours'', is_exception = true where recurring_reservation_id = %L::uuid and occurrence_date = %L::date returning jsonb_build_object(''id'', id)',
    pg_temp.k('SA'), pg_temp.d('d24'))));
  perform pg_temp.ok('S12 ocorrência recorrente (SA) movida para âncora NÃO materializada de OUTRA série ACTIVE (SO 13–14) => RECURRING_SLOT',
    v->>'state' = '23P01' and v->'result'->>'hint' = 'RECURRING_SLOT' and pg_temp.nres(pg_temp.k('SO')) = 0, v::text);

  -- S13 meia-noite: série SM (23:00–00:30) é protegida mesmo sem materializar (lacuna OUTSIDE)
  v := to_jsonb(pg_temp.call('rec', format(
    'insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source) '
    || 'select organization_id, arena_id, id, %L::timestamptz, %L::timestamptz, ''CONFIRMED'', ''INTERNAL'' from public.courts where id = %L::uuid returning jsonb_build_object(''id'', id)',
    to_char(pg_temp.d('d10') + 1, 'YYYY-MM-DD') || ' 00:00:00-03:00', to_char(pg_temp.d('d10') + 1, 'YYYY-MM-DD') || ' 00:20:00-03:00', pg_temp.k('c2'))));
  perform pg_temp.ok('S13 madrugada do dia seguinte coberta pela âncora da véspera (23:00–00:30) => 23P01', v->>'state' = '23P01'
    and v->'result'->>'hint' = 'RECURRING_SLOT', v::text);

  -- S11 série × série: inserção recorrente não é barrada pela trigger; a outra série registra CONFLICT
  perform pg_temp.series('ST', 'a1', 'c2', (pg_temp.v('W'))::int, '19:00', '20:00', 9000);
  v := pg_temp.do_('mgr', format('select public.rg_recurring_topup(%L::uuid)', pg_temp.k('ST')));
  v := private.rg_recurring_topup_batch(25, array[pg_temp.k('SQ')]);
  perform pg_temp.ok('S11 série × série: ST materializa; SQ fica com lacunas CONFLICT apontando ocorrências de ST (explícito)',
    pg_temp.nres(pg_temp.k('ST')) > 0 and pg_temp.nres(pg_temp.k('SQ')) = 0
    and not exists (select 1 from public.recurring_occurrence_gaps g where g.series_id = pg_temp.k('SQ') and g.resolved_at is null
                     and (g.reason <> 'CONFLICT' or not exists (select 1 from public.reservations r where r.id = g.conflict_reservation_id
                                                                   and r.recurring_reservation_id = pg_temp.k('ST'))))
    and exists (select 1 from public.recurring_occurrence_gaps g where g.series_id = pg_temp.k('SQ') and g.resolved_at is null), v::text);
end $$;

-- ============================================================================= T (cont.) — convergência e resolução de lacunas
do $$
declare r jsonb; g public.recurring_occurrence_gaps;
begin
  -- T09 X já cancelada (S06b): o próximo lote materializa SB em hoje+10 e resolve a lacuna
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SB')]);
  select * into g from public.recurring_occurrence_gaps where series_id = pg_temp.k('SB') and occurrence_date = pg_temp.d('d10');
  perform pg_temp.ok('T09 conflito sumiu => SB materializa hoje+10; lacuna resolvida MATERIALIZED',
    pg_temp.has_occ(pg_temp.k('SB'), pg_temp.d('d10')) and g.resolution = 'MATERIALIZED' and g.resolved_at is not null, r::text);

  -- T10 lacuna de data passada => DATE_PASSED
  insert into public.recurring_occurrence_gaps (organization_id, arena_id, court_id, series_id, occurrence_date, reason, origin)
  select organization_id, arena_id, court_id, id, pg_temp.d('dm4'), 'OUTSIDE_BUSINESS_HOURS', 'CRON'
    from public.recurring_reservations where id = pg_temp.k('SF');
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SF')]);
  perform pg_temp.ok('T10 lacuna de data passada => DATE_PASSED',
    exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SF') and occurrence_date = pg_temp.d('dm4')
             and resolution = 'DATE_PASSED'), r::text);

  -- T11 série deixou de estar ACTIVE => SERIES_NOT_ACTIVE (lote encontra pela lacuna aberta)
  perform pg_temp.do_('owner', format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.k('SH')));
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SH')]);
  perform pg_temp.ok('T11 série pausada com lacunas => todas resolvidas SERIES_NOT_ACTIVE; resultado SKIPPED_NOT_ACTIVE',
    not exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SH') and resolved_at is null)
    and exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SH') and resolution = 'SERIES_NOT_ACTIVE')
    and exists (select 1 from public.recurring_generation_run_series x where x.run_id = (r->>'run_id')::uuid and x.outcome = 'SKIPPED_NOT_ACTIVE'), r::text);

  -- T12 end_date encurtado => lacunas após o fim viram NOT_ANCHOR_ANYMORE; as anteriores continuam abertas
  perform pg_temp.do_('owner', format('select public.rg_recurring_update(%L::uuid, %L::jsonb)', pg_temp.k('SI'),
    jsonb_build_object('end_date', pg_temp.d('today') + 20, 'has_no_end_date', false)));
  r := private.rg_recurring_topup_batch(25, array[pg_temp.k('SI')]);
  perform pg_temp.ok('T12 encurtar end_date: lacunas além do fim => NOT_ANCHOR_ANYMORE; dentro do prazo seguem abertas',
    not exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SI') and resolved_at is null and occurrence_date > pg_temp.d('today') + 20)
    and exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SI') and resolution = 'NOT_ANCHOR_ANYMORE')
    and exists (select 1 from public.recurring_occurrence_gaps where series_id = pg_temp.k('SI') and resolved_at is null), r::text);
end $$;

-- ============================================================================= RPC de leitura das lacunas
do $$
declare v jsonb; v_before text;
begin
  v_before := pg_temp.snap();
  v := pg_temp.do_('mgr', format('select public.rg_recurring_gaps(%L::uuid, null)', pg_temp.k('org')));
  perform pg_temp.ok('L01 gestor lê lacunas abertas (com reserva conflitante) e a leitura é pura',
    jsonb_array_length(v->'items') > 0 and pg_temp.snap() = v_before
    and exists (select 1 from jsonb_array_elements(v->'items') e where e->>'reason' = 'CONFLICT' and e->'conflict'->>'reservation_id' is not null), left(v::text, 300));
  perform pg_temp.ok('L02 RECEPTIONIST / outro tenant / admin sem vínculo => 42501 (lacunas só OWNER/MANAGER, D7)',
    (pg_temp.call('rec', format('select public.rg_recurring_gaps(%L::uuid, null)', pg_temp.k('org')))).state = '42501'
    and (pg_temp.call('out', format('select public.rg_recurring_gaps(%L::uuid, null)', pg_temp.k('org')))).state = '42501'
    and (pg_temp.call('adm', format('select public.rg_recurring_gaps(%L::uuid, null)', pg_temp.k('org')))).state = '42501');
  v := pg_temp.do_('owner', format('select public.rg_recurring_gaps(%L::uuid, %L::uuid)', pg_temp.k('org'), pg_temp.k('SQ')));
  perform pg_temp.ok('L03 filtro por série', jsonb_array_length(v->'items') > 0
    and not exists (select 1 from jsonb_array_elements(v->'items') e where (e->>'series_id')::uuid <> pg_temp.k('SQ')));
end $$;

-- ============================================================================= E — equivalência dos fixes de performance (1 e 2)
-- Referência = algoritmo EXATO da trigger antes dos fixes (sem pré-filtro de dia nem de janela horária).
create function pg_temp.ref_blocks(p_court uuid, p_start timestamptz, p_end timestamptz, p_own uuid) returns boolean
language plpgsql stable as $$
declare v_s public.recurring_reservations; v_d date; v_from date; v_to date; v_bs timestamptz; v_be timestamptz;
begin
  v_from := (p_start at time zone 'America/Sao_Paulo')::date - 1;
  v_to := (p_end at time zone 'America/Sao_Paulo')::date;
  for v_s in select s.* from public.recurring_reservations s
              where s.court_id = p_court and s.status = 'ACTIVE' and s.id is distinct from p_own
                and s.start_date <= v_to and (s.has_no_end_date or s.end_date is null or s.end_date >= v_from) loop
    for v_d in select g::date from generate_series(greatest(v_from, v_s.start_date), v_to, interval '1 day') g loop
      continue when not private.rg_is_anchor(v_s, v_d);
      select b.start_at, b.end_at into v_bs, v_be from private.rg_occurrence_bounds(v_d, v_s.start_time, v_s.end_time) b;
      if v_be > now() and v_bs < p_end and v_be > p_start
         and not exists (select 1 from public.reservations r where r.recurring_reservation_id = v_s.id and r.occurrence_date = v_d) then
        return true;
      end if;
    end loop;
  end loop;
  return false;
end $$;
-- Sonda: tenta o INSERT/UPDATE real e desfaz sempre (subtransação). 'BLOCKED' = a trigger barrou (RECURRING_SLOT).
create function pg_temp.probe(p_court uuid, p_start timestamptz, p_end timestamptz, p_update_id uuid default null) returns text
language plpgsql as $$
declare v_hint text;
begin
  begin
    if p_update_id is null then
      insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
      select c.organization_id, c.arena_id, c.id, p_start, p_end, 'CONFIRMED', 'INTERNAL' from public.courts c where c.id = p_court;
    else
      update public.reservations set start_at = p_start, end_at = p_end where id = p_update_id;
    end if;
    raise exception 'probe_rollback' using errcode = 'P0009';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    return case when v_hint = 'RECURRING_SLOT' then 'BLOCKED' else 'PASS' end;
  end;
end $$;

do $$
declare
  t date := pg_temp.d('today'); w int; x int; r record; v_court uuid; v_mis int := 0; v_blk int := 0; v_n int := 0;
  v_st timestamptz; v_en timestamptz; v_dur int; v_upd uuid; v_mis_u int := 0; v_blk_u int := 0; v_n_u int := 0; v_ref boolean;
  durs int[] := array[5, 30, 59, 60, 61, 90, 120, 180, 300, 600, 1439, 1440, 1441, 1500, 2000];
begin
  with c as (insert into public.courts (organization_id, arena_id, name) values (pg_temp.k('org'), pg_temp.k('a1'), 'Q equivalência') returning id)
  insert into fx select 'ce', id from c;
  v_court := pg_temp.k('ce');
  w := extract(dow from t + 2)::int; x := extract(dow from t + 4)::int;
  perform pg_temp.series('E1', 'a1', 'ce', w, '19:00', '20:00', 100);                         -- semanal
  perform pg_temp.series('E2', 'a1', 'ce', x, '23:30', '01:00', 100);                         -- cruza meia-noite
  perform pg_temp.series('E3', 'a1', 'ce', w, '22:00', '22:30', 100, t + 20);                 -- com fim
  perform pg_temp.series('E5', 'a1', 'ce', x, '12:00', '13:00', 100);                         -- será pausada
  perform pg_temp.do_('owner', format('select public.rg_recurring_pause(%L::uuid, false)', pg_temp.k('E5')));
  insert into fx select 'E4', (pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, ''{"name":"e"}''::jsonb, ''BIWEEKLY'', %s, null, ''10:00''::time, ''11:00''::time, %L::date, null, true, 100, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k('a1'), v_court, extract(dow from t + 1)::int, t - 3))->>'series_id')::uuid;
  insert into fx select 'E6', (pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, ''{"name":"e"}''::jsonb, ''MONTHLY'', null, 31, ''08:00''::time, ''09:00''::time, %L::date, null, true, 100, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k('a1'), v_court, t - 40))->>'series_id')::uuid;
  insert into fx select 'E7', (pg_temp.do_('owner', format(
    'select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, ''{"name":"e"}''::jsonb, ''MONTHLY'', null, 15, ''23:00''::time, ''00:30''::time, %L::date, null, true, 100, null, false, false, ''{}''::date[])',
    gen_random_uuid(), pg_temp.k('a1'), v_court, t - 40))->>'series_id')::uuid;
  perform pg_temp.series('E8', 'a1', 'ce', extract(dow from t + 3)::int, '14:00', '15:00', 100);
  -- âncoras materializadas (ativa e cancelada) para cobrir o ramo "existe linha"
  perform private.rg_materialize_ex(s, array[t + 2, t + 9], true, null, t + 120, 'MANUAL', null)
    from public.recurring_reservations s where s.id = pg_temp.k('E1');
  update public.reservations set status = 'CANCELLED', is_exception = true
   where recurring_reservation_id = pg_temp.k('E1') and occurrence_date = t + 9;
  -- linha existente para sondar o caminho de UPDATE
  insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
  select organization_id, arena_id, id, (to_char(t + 70, 'YYYY-MM-DD') || ' 05:00:00-03:00')::timestamptz,
         (to_char(t + 70, 'YYYY-MM-DD') || ' 05:10:00-03:00')::timestamptz, 'CONFIRMED', 'INTERNAL'
    from public.courts where id = v_court returning id into v_upd;

  perform setseed(0.4242);
  for i in 1..700 loop
    v_st := (to_char(t + floor(random() * 75)::int, 'YYYY-MM-DD') || ' 00:00:00-03:00')::timestamptz
            + make_interval(mins => floor(random() * 1440)::int, secs => case when random() < 0.2 then floor(random() * 60) else 0 end);
    v_dur := durs[1 + floor(random() * array_length(durs, 1))::int];
    v_en := v_st + make_interval(mins => v_dur);
    v_n := v_n + 1;
    v_ref := pg_temp.ref_blocks(v_court, v_st, v_en, null);
    if (pg_temp.probe(v_court, v_st, v_en) = 'BLOCKED') is distinct from v_ref then v_mis := v_mis + 1; end if;
    if v_ref then v_blk := v_blk + 1; end if;
  end loop;
  -- limites exatos (toque / 1 minuto) em torno de cada série, inclusive meia-noite
  for r in select d, st, en from (values
      (2, '18:00', '19:00'), (2, '20:00', '21:00'), (2, '18:01', '19:01'), (2, '19:59', '20:30'), (2, '19:00', '20:00'),
      (4, '22:30', '23:30'), (5, '01:00', '02:00'), (5, '00:59', '01:30'), (4, '23:29', '23:31'), (5, '00:00', '00:01'),
      (3, '13:00', '14:00'), (3, '15:00', '16:00'), (3, '14:30', '14:31'), (1, '09:00', '10:00'), (1, '11:00', '12:00'),
      (1, '10:59', '11:00'), (15, '22:59', '23:00'), (16, '00:30', '01:00'), (16, '00:29', '00:31')) v(d, st, en) loop
    for i in 0..3 loop
      v_st := (to_char(t + r.d + 7 * i, 'YYYY-MM-DD') || ' ' || r.st || ':00-03:00')::timestamptz;
      v_en := (to_char(t + r.d + 7 * i, 'YYYY-MM-DD') || ' ' || r.en || ':00-03:00')::timestamptz;
      if v_en <= v_st then v_en := v_en + interval '1 day'; end if;
      v_n := v_n + 1;
      v_ref := pg_temp.ref_blocks(v_court, v_st, v_en, null);
      if (pg_temp.probe(v_court, v_st, v_en) = 'BLOCKED') is distinct from v_ref then v_mis := v_mis + 1; end if;
      if v_ref then v_blk := v_blk + 1; end if;
    end loop;
  end loop;
  for i in 1..150 loop
    v_st := (to_char(t + floor(random() * 75)::int, 'YYYY-MM-DD') || ' 00:00:00-03:00')::timestamptz + make_interval(mins => floor(random() * 1440)::int);
    v_en := v_st + make_interval(mins => durs[1 + floor(random() * array_length(durs, 1))::int]);
    v_n_u := v_n_u + 1;
    v_ref := pg_temp.ref_blocks(v_court, v_st, v_en, null);
    if (pg_temp.probe(v_court, v_st, v_en, v_upd) = 'BLOCKED') is distinct from v_ref then v_mis_u := v_mis_u + 1; end if;
    if v_ref then v_blk_u := v_blk_u + 1; end if;
  end loop;
  perform pg_temp.ok(format('E01 trigger otimizada == algoritmo de referência em %s INSERTs (%s barrados pela referência)', v_n, v_blk),
    v_mis = 0 and v_blk > 20 and v_blk < v_n - 20, format('divergências=%s', v_mis));
  perform pg_temp.ok(format('E02 idem no caminho de UPDATE: %s movimentos (%s barrados)', v_n_u, v_blk_u),
    v_mis_u = 0 and v_blk_u > 5, format('divergências=%s', v_mis_u));
end $$;

do $$
declare v_bad int; v_series uuid[];
begin
  v_series := array[pg_temp.k('E1'), pg_temp.k('E2'), pg_temp.k('E3'), pg_temp.k('E4'), pg_temp.k('E6'), pg_temp.k('E7'), pg_temp.k('E8'), pg_temp.k('SA'), pg_temp.k('SQ')];
  select count(*) into v_bad from unnest(v_series) sid
   where (select coalesce(array_agg(p.occurrence_date order by p.occurrence_date), '{}') from private.rg_plan_series(sid, pg_temp.d('today'), pg_temp.d('today') + 120) p)
      <> (select coalesce(array_agg(g::date order by g), '{}') from public.recurring_reservations s,
                generate_series(greatest(pg_temp.d('today'), s.start_date),
                                case when s.has_no_end_date or s.end_date is null then pg_temp.d('today') + 120 else least(pg_temp.d('today') + 120, s.end_date) end,
                                interval '1 day') g
           where s.id = sid and private.rg_is_anchor(s, g::date));
  perform pg_temp.ok('E03 planejador com pré-filtro == âncoras de referência (semanal, quinzenal, mensal 31/15, meia-noite, com fim)', v_bad = 0, v_bad::text);
  perform pg_temp.ok('E04 candidatos com pré-filtro == referência (sem pré-filtro)',
    private.rg_topup_candidates(120, v_series)
    = (select coalesce(array_agg(s.id order by s.id), '{}') from public.recurring_reservations s
        where s.id = any(v_series)
          and ((s.status = 'ACTIVE' and exists (
                 select 1 from generate_series(greatest(private.rg_today(), s.start_date),
                        case when s.has_no_end_date or s.end_date is null then private.rg_today() + 120 else least(private.rg_today() + 120, s.end_date) end,
                        interval '1 day') g
                  where private.rg_is_anchor(s, g::date)
                    and not exists (select 1 from public.reservations r where r.recurring_reservation_id = s.id and r.occurrence_date = g::date)))
               or exists (select 1 from public.recurring_occurrence_gaps x where x.series_id = s.id and x.resolved_at is null))));
end $$;

-- ============================================================================= K — histórico por série sem FK (sem lixo silencioso)
do $$
declare r jsonb; v_run uuid; n bigint; v jsonb;
begin
  perform pg_temp.ok('K01 run_series: series_id / organization_id / run_id / outcome NOT NULL',
    (select count(*) = 4 and bool_and(attnotnull) from pg_attribute
      where attrelid = 'public.recurring_generation_run_series'::regclass and attname in ('series_id', 'organization_id', 'run_id', 'outcome')));
  v := to_jsonb(pg_temp.call('rec', format('insert into public.recurring_generation_run_series (run_id, series_id, organization_id, outcome) values (%L, %L, %L, ''NOOP'') returning jsonb_build_object(''x'', 1)',
         pg_temp.k('run1'), pg_temp.k('SA'), pg_temp.k('org'))));
  perform pg_temp.ok('K02 cliente autenticado não escreve no histórico (42501)', v->>'state' = '42501', v::text);
  v := to_jsonb(pg_temp.call('service_role', format('insert into public.recurring_generation_run_series (run_id, series_id, organization_id, outcome) values (%L, %L, %L, ''NOOP'') returning jsonb_build_object(''x'', 1)',
         pg_temp.k('run1'), pg_temp.k('SA'), pg_temp.k('org'))));
  perform pg_temp.ok('K02b service_role só SELECT/DELETE (INSERT negado)', v->>'state' = '42501', v::text);
  r := private.rg_topup_series(gen_random_uuid(), 120, 'MANUAL', 'SYSTEM_OPERATOR', null, pg_temp.k('run1'), false, 1::smallint);
  perform pg_temp.ok('K03 série inexistente: SKIPPED_NOT_ACTIVE sem criar registro com series_id inexistente',
    r->>'outcome' = 'SKIPPED_NOT_ACTIVE'
    and not exists (select 1 from public.recurring_generation_run_series x where x.run_id = pg_temp.k('run1') and x.series_id = (r->>'series_id')::uuid), r::text);
  perform pg_temp.ok('K04 nenhum registro de histórico aponta série inexistente após as execuções normais',
    not exists (select 1 from public.recurring_generation_run_series x where not exists (select 1 from public.recurring_reservations s where s.id = x.series_id)));
  perform pg_temp.series('SK', 'a1', 'c1', (pg_temp.v('W'))::int, '06:00', '07:00', 100);
  r := private.rg_recurring_topup_batch(10, array[pg_temp.k('SK')]);
  v_run := (r->>'run_id')::uuid;
  select count(*) into n from public.recurring_generation_run_series where run_id = v_run and series_id = pg_temp.k('SK');
  delete from public.reservations where recurring_reservation_id = pg_temp.k('SK');
  delete from public.recurring_reservations where id = pg_temp.k('SK');
  r := private.rg_recurring_topup_batch(10, null);
  perform pg_temp.ok('K05 série apagada (limpeza demo): histórico da execução legível (LEFT JOIN) e o job segue sem erro',
    n = 1 and (select count(*) from public.recurring_generation_run_series x left join public.recurring_reservations s on s.id = x.series_id
                where x.run_id = v_run and x.series_id = pg_temp.k('SK') and s.id is null) = 1
    and r->>'status' in ('SUCCEEDED', 'PARTIAL') and (r->'counts'->>'errors')::int = 0, r::text);
end $$;

-- ============================================================================= G — privilégios e estrutura
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname in ('rg_materialization_horizon', 'rg_topup_lock_key', 'rg_fits_business_hours',
         'rg_occurrence_blocker', 'rg_conflicting_reservation', 'rg_gap_open', 'rg_gap_resolve', 'rg_materialize_ex', 'rg_materialize',
         'rg_plan_series', 'rg_topup_candidates', 'rg_topup_series', 'rg_recurring_topup_plan', 'rg_recurring_topup_batch',
         'rg_recurring_topup_job', 'rg_protect_series_slot')
     and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE')
          or has_function_privilege('service_role', p.oid, 'EXECUTE')
          or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0));
  perform pg_temp.ok('G01 nenhuma rotina interna da 03C executável por PUBLIC/anon/authenticated/service_role', v_bad is null, v_bad);
  perform pg_temp.ok('G02 tabelas da 03C: authenticated/anon sem privilégio; service_role só SELECT/DELETE',
    not exists (select 1 from information_schema.role_table_grants g
                 where g.table_schema = 'public' and g.table_name in ('recurring_generation_runs', 'recurring_generation_run_series', 'recurring_occurrence_gaps')
                   and (g.grantee in ('authenticated', 'anon', 'PUBLIC') or (g.grantee = 'service_role' and g.privilege_type not in ('SELECT', 'DELETE')))));
  perform pg_temp.ok('G03 RPCs públicas: EXECUTE só para authenticated',
    has_function_privilege('authenticated', 'public.rg_recurring_topup(uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.rg_recurring_gaps(uuid, uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.rg_recurring_topup(uuid)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.rg_recurring_gaps(uuid, uuid)', 'EXECUTE'));
  perform pg_temp.ok('G04 disciplina G0: procedure do job SECURITY INVOKER, SEM cláusula SET, owner postgres',
    (select not prosecdef and proconfig is null and prokind = 'p' and pg_get_userbyid(proowner) = 'postgres'
       from pg_proc where oid = 'private.rg_recurring_topup_job(text)'::regprocedure));
  perform pg_temp.ok('G04b rotinas DEFINER da 03C com search_path vazio',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname in ('private', 'public') and p.prosecdef and p.proname in ('rg_topup_series', 'rg_recurring_topup_plan',
                       'rg_recurring_topup_batch', 'rg_protect_series_slot', 'rg_recurring_topup', 'rg_recurring_gaps')
                   and coalesce(p.proconfig, '{}') <> array['search_path=""']));
  perform pg_temp.ok('G05 trigger BEFORE INSERT/UPDATE OF (start_at,end_at,court_id,status), FOR EACH ROW',
    exists (select 1 from pg_trigger t where t.tgrelid = 'public.reservations'::regclass and t.tgname = 'validate_reservation_zz_series_slot'
             and t.tgtype & 1 = 1 and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 and t.tgtype & 16 = 16
             and (select array_agg(a.attname::text order by a.attname) from unnest(t.tgattr) k join pg_attribute a
                   on a.attrelid = t.tgrelid and a.attnum = k) = array['court_id', 'end_at', 'start_at', 'status']));
  perform pg_temp.ok('G06 nenhum agendamento no pg_cron (cron.schedule só em etapa autorizada)',
    to_regnamespace('cron') is not null and not exists (select 1 from cron.job));
  perform pg_temp.ok('G07 BEFORE UPDATE de reservations = lista 03A na mesma ordem + a trigger 03C por último',
    (select array_agg(t.tgname::text order by t.tgname) from pg_trigger t where t.tgrelid = 'public.reservations'::regclass and not t.tgisinternal
       and t.tgtype & 2 = 2 and t.tgtype & 16 = 16)
    = array['enforce_reservation_tenant', 'enforce_reservation_zz_price_guard', 'enforce_reservation_zz_price_origin_guard',
            'enforce_reservation_zz_price_reprice', 'protect_occurrence_anchor', 'protect_reservation_links', 'trg_reservations_updated',
            'validate_reservation_recurring', 'validate_reservation_zz_series_slot']);
  perform pg_temp.ok('G08 RLS ligada e sem políticas nas tabelas novas',
    (select bool_and(c.relrowsecurity) from pg_class c where c.oid in ('public.recurring_generation_runs'::regclass,
       'public.recurring_generation_run_series'::regclass, 'public.recurring_occurrence_gaps'::regclass))
    and not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename in ('recurring_generation_runs', 'recurring_generation_run_series', 'recurring_occurrence_gaps')));
end $$;

-- ============================================================================= R — contratos preservados
-- (corpo comparado SEM CR: reaplicar localmente a partir de um checkout CRLF não muda o conteúdo da função)
do $$
begin
  perform pg_temp.ok('R01 rg_materialize = wrapper 03C (md5) e B3 create/reschedule/reactivate = versões 03C (md5)',
    (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_materialize'::regproc) = '595ee52c3be25bf50ab4b44fb1e5683c'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_recurring_create'::regproc) = '2aae1120c6e600989e6e990f7146c84f'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_recurring_reschedule'::regproc) = '520ab107c6b41e853c7f5d440b93fc92'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_recurring_reactivate'::regproc) = '2990704afae3823d88d51348df616d66');
  perform pg_temp.ok('R02 03B.3A intocada: as 6 RPCs mensais e rg_in_window com corpo inalterado',
    (select string_agg(md5(replace(p.prosrc, chr(13), '')), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail',
            'rg_recurring_month_payment_record', 'rg_recurring_link_customer', 'rg_recurring_month_apply_series_price'))
    = 'ef638d905dcf0ae4072e7c601172e57b,dfbe684f4f49f5c0c77f14cff70f70bb,099860fb4081811b4ff6823dfeac937c,8061cb47215e805fa0eed28295c13078,fbeeaf4bc38f93fa6481b1daff3e0f13,a1c0277a18f9a5146e370a8c5684aa4e'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_in_window(date)'::regprocedure) = 'd44810e75150823d4126d12c784681cb');
  perform pg_temp.ok('R03 D7 (enforce_recurring_occurrence) e B3 generate/pause/cancel/update intocados (md5)',
    (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.enforce_recurring_occurrence'::regproc) = 'abc31e62476fce8231504ac6ab08426e'
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
    raise exception 'P3C_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.', v_total - v_fail, v_fail, v_total;
  end if;
  raise notice 'P3C_RESULTS OK — % PASS / 0 FAIL (total %)', v_total, v_total;
end $$;
rollback;
