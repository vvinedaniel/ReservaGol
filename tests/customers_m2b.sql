-- =============================================================================
-- RESERVA GOL — CLIENTES M2-B — testes SQL do bloqueio de escritas diretas em public.customers
-- Requer C2A + C2D + migration_customers_m2b_write_lockdown.sql. Banco de TESTE local, nunca Production.
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/customers_m2b.sql
-- Sucesso: "M2B_RESULTS OK ..." + ROLLBACK explícito. Falha: erro "M2B_RESULTS FAIL ..." (exit != 0). ZERO RESÍDUO.
-- Atores: owner, mgr, rec (org A) · sus (vínculo SUSPENDED na A) · out (owner da org B) · anon · service_role
-- G grants/efetivos · W escrita direta · S leitura · R RPCs de cliente · F fluxos (reserva interna/pública, W1,
-- série, troca) · I isolamento · A auditoria · Z congelados
-- Ciclo migration -> rollback -> reaplicar: tests/customers_m2b_lifecycle.sh
-- =============================================================================
begin;
set local statement_timeout = '300s';
set local lock_timeout = '5s';
create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
do $$ begin
  if session_user <> 'postgres' then raise exception 'm2b: execute como postgres'; end if;
  if (select relacl::text from pg_class where oid = 'public.customers'::regclass)
     <> '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'm2b: migration M2-B não aplicada';
  end if;
end $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- executa como o ator (como o PostgREST: SET LOCAL ROLE + request.jwt.claims); efeitos PERMANECEM na transação
create function pg_temp.call(p_actor text, p_sql text, out state text, out result jsonb) language plpgsql as $$
declare v_claims text; v_hint text; v_msg text;
begin
  v_claims := case when p_actor in ('anon', 'service_role') then json_build_object('role', p_actor)::text
                   else json_build_object('sub', pg_temp.k(p_actor), 'role', 'authenticated')::text end;
  perform set_config('request.jwt.claims', v_claims, true);
  execute format('set local role %I', case when p_actor in ('anon', 'service_role') then p_actor else 'authenticated' end);
  begin
    execute p_sql into result;
    state := 'OK';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    state := sqlstate || coalesce(':' || nullif(v_hint, ''), '');
    result := jsonb_build_object('msg', v_msg);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function pg_temp.st(p_actor text, p_sql text) returns text language sql as $$ select (pg_temp.call(p_actor, p_sql)).state $$;
create function pg_temp.do_(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.call(p_actor, p_sql);
  if v.state <> 'OK' then raise exception 'm2b (%): % % — %', p_actor, v.state, v.result, left(p_sql, 200); end if;
  return v.result;
end $$;
create function pg_temp.audits(p_action text, p_entity uuid) returns int language sql stable as $$
  select count(*)::int from public.audit_logs where action = p_action and entity_id = p_entity $$;

-- ----------------------------------------------------------------------------- fixtures (postgres)
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid();
  u_sus uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_b1 uuid; v_c1 uuid; v_c2 uuid; v_cb uuid; v_cu uuid;
  v_tag text := 'm2b-' || substr(md5(clock_timestamp()::text), 1, 8); v_id uuid; i int;
  v_day date := current_date + 300;
begin
  insert into auth.users (id, email) values (u_owner, v_tag || '-o@reservagol.test'), (u_mgr, v_tag || '-m@reservagol.test'),
    (u_rec, v_tag || '-r@reservagol.test'), (u_sus, v_tag || '-s@reservagol.test'), (u_out, v_tag || '-x@reservagol.test');
  insert into public.organizations (name, is_demo) values ('M2B ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('M2B outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'),
    (v_org, u_sus, 'MANAGER', 'SUSPENDED'), (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select v_org, v_a1, w, '06:00', '23:00', false from generate_series(0, 6) w;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q1') returning id into v_c1;
  insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q2') returning id into v_c2;
  insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'QB') returning id into v_cb;
  insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Base M2B', '41966660001') returning id into v_cu;
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('sus', u_sus), ('out', u_out), ('org', v_org), ('org2', v_org2),
                        ('a1', v_a1), ('b1', v_b1), ('c1', v_c1), ('c2', v_c2), ('cb', v_cb), ('cuBase', v_cu);
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org2, v_b1, 'Fora M2B', '41966660009') returning id)
  insert into fx select 'cuB', id from x;
  -- uma reserva avulsa por ator (troca), um cliente alvo, e uma série sem cliente por ator gestor/recepção (W1)
  with x as (insert into public.customers (organization_id, name, phone) values (v_org, 'Alvo M2B', '41966660002') returning id)
  insert into fx select 'cuAlvo', id from x;
  for i in 0..4 loop
    insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source)
    values (v_org, v_a1, v_c1, v_cu, (v_day + i + time '07:00') at time zone 'America/Sao_Paulo', (v_day + i + time '08:00') at time zone 'America/Sao_Paulo', 'CONFIRMED', 'RECEPÇÃO')
    returning id into v_id;
    insert into fx values ('res_' || (array['owner', 'mgr', 'rec', 'sus', 'out'])[i + 1], v_id);
  end loop;
  for i in 0..2 loop
    insert into public.recurring_reservations (organization_id, arena_id, court_id, customer_id, frequency, weekday, start_time, end_time, start_date, has_no_end_date, status, is_demo)
    values (v_org, v_a1, v_c2, null, 'WEEKLY', extract(dow from v_day + 40 + i)::int, '21:00', '22:00', v_day + 40 + i, true, 'ACTIVE', true)
    returning id into v_id;
    insert into fx values ('ser_' || (array['owner', 'mgr', 'rec'])[i + 1], v_id);
  end loop;
end $$;

-- ----------------------------------------------------------------------------- G: grants e privilégios efetivos
do $$ begin
  perform pg_temp.ok('G01 ACL exata pós-M2-B: authenticated só SELECT (+MAINTAIN), service_role/postgres inalterados, anon ausente',
    (select relacl::text from pg_class where oid = 'public.customers'::regclass) = '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}');
  perform pg_temp.ok('G02 efetivo (com herança): authenticated sem INSERT/UPDATE/DELETE em tabela e em QUALQUER coluna; SELECT mantido',
    not has_table_privilege('authenticated', 'public.customers', 'INSERT') and not has_table_privilege('authenticated', 'public.customers', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.customers', 'DELETE') and has_table_privilege('authenticated', 'public.customers', 'SELECT')
    and not has_any_column_privilege('authenticated', 'public.customers', 'INSERT') and not has_any_column_privilege('authenticated', 'public.customers', 'UPDATE'));
  perform pg_temp.ok('G03 anon sem nenhum privilégio; authenticator (NOINHERIT) sem escrita; nenhum papel não-superuser além de postgres/service_role/pg_write_all_data escreve',
    not has_table_privilege('anon', 'public.customers', 'SELECT') and not has_table_privilege('anon', 'public.customers', 'INSERT')
    and not has_table_privilege('authenticator', 'public.customers', 'INSERT') and not has_table_privilege('authenticator', 'public.customers', 'UPDATE')
    and (select coalesce(array_agg(rolname order by rolname), '{}') from pg_roles where not rolsuper
          and (has_table_privilege(oid, 'public.customers', 'INSERT') or has_table_privilege(oid, 'public.customers', 'UPDATE')))
        = array['pg_write_all_data', 'postgres', 'service_role']::name[]
    and not exists (select 1 from pg_auth_members a join pg_roles r on r.oid = a.roleid where r.rolname = 'pg_write_all_data'),
    (select array_agg(rolname order by rolname)::text from pg_roles where not rolsuper and (has_table_privilege(oid, 'public.customers', 'INSERT') or has_table_privilege(oid, 'public.customers', 'UPDATE'))));
  perform pg_temp.ok('G04 RLS, policies, triggers e índices de customers intactos (M2-B não os toca)',
    (select relrowsecurity and not relforcerowsecurity from pg_class where oid = 'public.customers'::regclass)
    and (select string_agg(policyname || ':' || cmd, ',' order by policyname) from pg_policies where schemaname = 'public' and tablename = 'customers')
        = 'customers insert member:INSERT,customers read:SELECT,customers update member:UPDATE'
    and (select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid = 'public.customers'::regclass and not tgisinternal)
        = 'enforce_customer_tenant,protect_customer_links,trg_customers_updated'
    and exists (select 1 from pg_indexes where tablename = 'customers' and indexname = 'ux_customers_org_phone'));
end $$;

-- ----------------------------------------------------------------------------- W: escrita direta (bloqueada para authenticated e anon)
do $$
declare a text; v_ins text; v_upd text; v_ups text; v_del text;
begin
  foreach a in array array['owner', 'mgr', 'rec', 'sus', 'out', 'anon'] loop
    v_ins := pg_temp.st(a, format('insert into public.customers (organization_id, name, phone) values (%L, ''direto'', ''qualquer'') returning to_jsonb(id)', pg_temp.k('org')));
    v_upd := pg_temp.st(a, format('with u as (update public.customers set name = ''hack'', phone = ''x'', created_at = ''2000-01-01'' where id = %L returning id) select to_jsonb(count(*)) from u', pg_temp.k('cuBase')));
    v_ups := pg_temp.st(a, format('insert into public.customers (id, organization_id, name) values (%L, %L, ''upsert'') on conflict (id) do update set name = excluded.name returning to_jsonb(id)', pg_temp.k('cuBase'), pg_temp.k('org')));
    v_del := pg_temp.st(a, format('with d as (delete from public.customers where id = %L returning id) select to_jsonb(count(*)) from d', pg_temp.k('cuBase')));
    perform pg_temp.ok(format('W %s: INSERT/UPDATE/UPSERT/DELETE diretos => 42501', a),
      split_part(v_ins, ':', 1) = '42501' and split_part(v_upd, ':', 1) = '42501' and split_part(v_ups, ':', 1) = '42501' and split_part(v_del, ':', 1) = '42501', concat_ws(' ', v_ins, v_upd, v_ups, v_del));
  end loop;
  perform pg_temp.ok('W99 cliente base intacto após as tentativas (nome/telefone/created_at)',
    (select name = 'Base M2B' and phone = '41966660001' and created_at > '2001-01-01' from public.customers where id = pg_temp.k('cuBase')));
end $$;

-- ----------------------------------------------------------------------------- S: leitura legítima preservada
do $$ begin
  perform pg_temp.ok('S01 membros ativos (owner/mgr/rec) leem os clientes da própria org via SELECT direto',
    (pg_temp.do_('owner', format('select to_jsonb(count(*)) from public.customers where organization_id = %L', pg_temp.k('org'))))::int >= 2
    and (pg_temp.do_('mgr', format('select to_jsonb(count(*)) from public.customers where organization_id = %L', pg_temp.k('org'))))::int >= 2
    and (pg_temp.do_('rec', format('select to_jsonb(count(*)) from public.customers where organization_id = %L', pg_temp.k('org'))))::int >= 2);
  perform pg_temp.ok('S02 SUSPENDED e membro de outra org não veem clientes da org A (RLS); anon sem SELECT (42501)',
    (pg_temp.do_('sus', format('select to_jsonb(count(*)) from public.customers where organization_id = %L', pg_temp.k('org'))))::int = 0
    and (pg_temp.do_('out', format('select to_jsonb(count(*)) from public.customers where organization_id = %L', pg_temp.k('org'))))::int = 0
    and split_part(pg_temp.st('anon', 'select to_jsonb(count(*)) from public.customers'), ':', 1) = '42501');
  perform pg_temp.ok('S03 rg_customer_list/detail seguem funcionando para a recepção',
    jsonb_array_length(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''M2B'', ''ALL'', 10)', pg_temp.k('org')))->'items') >= 1
    and (pg_temp.do_('rec', format('select public.rg_customer_detail(%L::uuid)', pg_temp.k('cuBase')))->'customer'->>'name') = 'Base M2B');
end $$;

-- ----------------------------------------------------------------------------- R: RPCs de cliente
do $$
declare a text; r jsonb; v_id uuid; i int := 0;
begin
  foreach a in array array['owner', 'mgr', 'rec'] loop
    i := i + 1;
    r := pg_temp.do_(a, format('select public.rg_customer_resolve(%L::uuid, %L, %L, null, null, ''CUSTOMERS'')', pg_temp.k('org'), 'Criado ' || a, '4196667000' || i));
    v_id := (r->>'customer_id')::uuid;
    insert into fx values ('new_' || a, v_id);
    perform pg_temp.ok(format('R01 %s cria via rg_customer_resolve (telefone canônico) + CUSTOMER_CREATED', a),
      (r->>'created')::boolean and (select phone from public.customers where id = v_id) = '4196667000' || i and pg_temp.audits('CUSTOMER_CREATED', v_id) = 1);
    r := pg_temp.do_(a, format('select public.rg_customer_update(%L::uuid, ''{"email":"%s@m2b.test","phone":"(41) 96666-8%s00"}''::jsonb, %L::timestamptz)',
           v_id, a, i, (select updated_at from public.customers where id = v_id)));
    perform pg_temp.ok(format('R02 %s edita via rg_customer_update + CUSTOMER_UPDATED', a),
      (r->>'changed')::boolean and (select email from public.customers where id = v_id) = a || '@m2b.test'
      and (select phone from public.customers where id = v_id) = '41966668' || i || '00' and pg_temp.audits('CUSTOMER_UPDATED', v_id) = 1,
      (select phone || ' ' || coalesce(email, '') from public.customers where id = v_id));
  end loop;
  perform pg_temp.ok('R03 resolve existente (mesmo telefone, outro nome) devolve o existente sem renomear',
    (pg_temp.do_('rec', format('select public.rg_customer_resolve(%L::uuid, ''Outro Nome'', ''41966660001'', null, null, ''CUSTOMERS'')', pg_temp.k('org')))->>'customer_id')::uuid = pg_temp.k('cuBase')
    and (select name from public.customers where id = pg_temp.k('cuBase')) = 'Base M2B');
  perform pg_temp.ok('R04 SUSPENDED e outra org: resolve 42501, update P0002',
    pg_temp.st('sus', format('select public.rg_customer_resolve(%L::uuid, ''x'', null, null, null, ''CUSTOMERS'')', pg_temp.k('org'))) = '42501'
    and pg_temp.st('out', format('select public.rg_customer_resolve(%L::uuid, ''x'', null, null, null, ''CUSTOMERS'')', pg_temp.k('org'))) = '42501'
    and pg_temp.st('sus', format('select public.rg_customer_update(%L::uuid, ''{"name":"x"}''::jsonb, now())', pg_temp.k('cuBase'))) like 'P0002%'
    and pg_temp.st('out', format('select public.rg_customer_update(%L::uuid, ''{"name":"x"}''::jsonb, now())', pg_temp.k('cuBase'))) like 'P0002%');
  perform pg_temp.ok('R05 anon sem EXECUTE nas RPCs de cliente (42501)',
    pg_temp.st('anon', format('select public.rg_customer_resolve(%L::uuid, ''x'', null, null, null, ''CUSTOMERS'')', pg_temp.k('org'))) = '42501'
    and pg_temp.st('anon', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''x'', ''41966669999'', null)', pg_temp.k('org'), pg_temp.k('a1'))) = '42501');
end $$;

-- ----------------------------------------------------------------------------- F: fluxos (reserva interna, pública, W1, série, troca)
do $$
declare a text; r jsonb; v_id uuid; i int := 0; v_day date := current_date + 320;
begin
  foreach a in array array['owner', 'mgr', 'rec'] loop
    i := i + 1;
    r := pg_temp.do_(a, format($q$with c as (select (public.rg_customer_resolve(%1$L::uuid, %2$L, %3$L, null, %4$L::uuid, 'RESERVATION')->>'customer_id')::uuid id)
      insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source)
      select %1$L::uuid, %4$L::uuid, %5$L::uuid, c.id, (date %6$L + time '09:00') at time zone 'America/Sao_Paulo', (date %6$L + time '10:00') at time zone 'America/Sao_Paulo', 'CONFIRMED', 'RECEPÇÃO'
      from c returning to_jsonb(customer_id)$q$, pg_temp.k('org'), 'Reserva ' || a, '4196669000' || i, pg_temp.k('a1'), pg_temp.k('c1'), v_day + i));
    perform pg_temp.ok(format('F01 %s: reserva interna com cliente novo (resolve RESERVATION + INSERT reservations) + CUSTOMER_CREATED origin RESERVATION', a),
      (select name from public.customers where id = (r #>> '{}')::uuid) = 'Reserva ' || a
      and exists (select 1 from public.audit_logs where entity_id = (r #>> '{}')::uuid and action = 'CUSTOMER_CREATED' and metadata->>'origin' = 'RESERVATION'));
  end loop;
  r := pg_temp.do_('service_role', format($q$with c as (select (public.rg_customer_resolve_public(%1$L::uuid, %2$L::uuid, 'Publico M2B', '41966661111', null)->>'customer_id')::uuid id)
      insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, public_code)
      select %1$L::uuid, %2$L::uuid, %3$L::uuid, c.id, (date %4$L + time '11:00') at time zone 'America/Sao_Paulo', (date %4$L + time '12:00') at time zone 'America/Sao_Paulo', 'CONFIRMED', 'PUBLIC_WEB', 'RG-M2BTESTE00001'
      from c returning to_jsonb(customer_id)$q$, pg_temp.k('org'), pg_temp.k('a1'), pg_temp.k('c2'), v_day + 10));
  perform pg_temp.ok('F02 reserva pública (service_role): rg_customer_resolve_public + INSERT reservations + CUSTOMER_CREATED actor PUBLIC',
    (select phone from public.customers where id = (r #>> '{}')::uuid) = '41966661111'
    and exists (select 1 from public.audit_logs where entity_id = (r #>> '{}')::uuid and action = 'CUSTOMER_CREATED' and metadata->>'actor' = 'PUBLIC'));
  perform pg_temp.ok('F03 reserva pública reaproveita telefone existente sem renomear; authenticated não executa resolve_public',
    (pg_temp.do_('service_role', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''Nome Novo'', ''(41) 96666-0001'', null)', pg_temp.k('org'), pg_temp.k('a1')))->>'customer_id')::uuid = pg_temp.k('cuBase')
    and (select name from public.customers where id = pg_temp.k('cuBase')) = 'Base M2B'
    and pg_temp.st('owner', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''x'', ''41966669998'', null)', pg_temp.k('org'), pg_temp.k('a1'))) = '42501');
  foreach a in array array['owner', 'mgr'] loop
    r := pg_temp.do_(a, format('select public.rg_recurring_link_customer(%L::uuid, null, ''{"name":"W1 %s","phone":"4196664%s000"}''::jsonb)', pg_temp.k('ser_' || a), a, case a when 'owner' then 1 else 2 end));
    perform pg_temp.ok(format('F04 %s: W1 cria e vincula cliente novo à série + RECURRING_CUSTOMER_LINKED', a),
      (r->>'changed')::boolean and (select c.name from public.recurring_reservations s join public.customers c on c.id = s.customer_id where s.id = pg_temp.k('ser_' || a)) = 'W1 ' || a
      and pg_temp.audits('RECURRING_CUSTOMER_LINKED', pg_temp.k('ser_' || a)) = 1);
  end loop;
  perform pg_temp.ok('F05 W1 continua só gestor: recepção 42501; SUSPENDED/outra org P0002',
    pg_temp.st('rec', format('select public.rg_recurring_link_customer(%L::uuid, null, ''{"name":"x","phone":"41966645000"}''::jsonb)', pg_temp.k('ser_rec'))) like '42501%'
    and pg_temp.st('sus', format('select public.rg_recurring_link_customer(%L::uuid, null, ''{"name":"x","phone":"41966645001"}''::jsonb)', pg_temp.k('ser_rec'))) like 'P0002%'
    and pg_temp.st('out', format('select public.rg_recurring_link_customer(%L::uuid, null, ''{"name":"x","phone":"41966645002"}''::jsonb)', pg_temp.k('ser_rec'))) like 'P0002%');
  i := 0;
  foreach a in array array['owner', 'mgr'] loop
    i := i + 1;
    r := pg_temp.do_(a, format($q$select public.rg_recurring_create(gen_random_uuid(), %1$L::uuid, %2$L::uuid, null, '{"name":"Serie %3$s","phone":"4196665%4$s000"}'::jsonb,
      'WEEKLY', extract(dow from date %5$L)::int, null, '06:00', '07:00', date %5$L, null, true, 15000, null, true, true, null)$q$,
      pg_temp.k('a1'), pg_temp.k('c2'), a, i, v_day + 60 + i));
    perform pg_temp.ok(format('F06 %s: criação de série (Mensalistas) com cliente novo + RECURRING_RESERVATION_CREATED', a),
      (select c.name from public.recurring_reservations s join public.customers c on c.id = s.customer_id where s.id = (r->>'series_id')::uuid) = 'Serie ' || a
      and pg_temp.audits('RECURRING_RESERVATION_CREATED', (r->>'series_id')::uuid) = 1);
  end loop;
  perform pg_temp.ok('F07 criação de série continua só gestor: recepção 42501',
    pg_temp.st('rec', format($q$select public.rg_recurring_create(gen_random_uuid(), %1$L::uuid, %2$L::uuid, null, '{"name":"x","phone":"41966659000"}'::jsonb,
      'WEEKLY', 1, null, '06:00', '07:00', current_date + 500, null, true, null, null, true, true, null)$q$, pg_temp.k('a1'), pg_temp.k('c2'))) like '42501%');
  foreach a in array array['owner', 'mgr', 'rec'] loop
    r := pg_temp.do_(a, format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('res_' || a), pg_temp.k('cuAlvo'), pg_temp.k('cuBase')));
    perform pg_temp.ok(format('F08 %s: troca explícita de cliente + RESERVATION_CUSTOMER_CHANGED', a),
      (r->>'changed')::boolean and (select customer_id from public.reservations where id = pg_temp.k('res_' || a)) = pg_temp.k('cuAlvo')
      and pg_temp.audits('RESERVATION_CUSTOMER_CHANGED', pg_temp.k('res_' || a)) = 1);
  end loop;
  perform pg_temp.ok('F09 troca por SUSPENDED/outra org => P0002, reserva intacta',
    pg_temp.st('sus', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('res_sus'), pg_temp.k('cuAlvo'), pg_temp.k('cuBase'))) like 'P0002%'
    and pg_temp.st('out', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('res_out'), pg_temp.k('cuAlvo'), pg_temp.k('cuBase'))) like 'P0002%'
    and (select customer_id from public.reservations where id = pg_temp.k('res_sus')) = pg_temp.k('cuBase'));
end $$;

-- ----------------------------------------------------------------------------- I: isolamento entre organizações
do $$
declare r jsonb;
begin
  r := pg_temp.do_('out', format('select public.rg_customer_resolve(%L::uuid, ''Cliente da B'', ''41966660001'', null, null, ''CUSTOMERS'')', pg_temp.k('org2')));
  perform pg_temp.ok('I01 outra org cria cliente na PRÓPRIA org via RPC (mesmo telefone da A => cadastro separado, sem tocar a A)',
    (r->>'created')::boolean and (r->>'customer_id')::uuid <> pg_temp.k('cuBase')
    and (select organization_id from public.customers where id = (r->>'customer_id')::uuid) = pg_temp.k('org2'));
  perform pg_temp.ok('I02 org A não vê o cliente da B; troca para cliente de outra org => P0002 CUSTOMER_NOT_FOUND',
    (pg_temp.do_('owner', format('select to_jsonb(count(*)) from public.customers where id = %L', (r->>'customer_id'))))::int = 0
    and pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('res_owner'), pg_temp.k('cuB'), pg_temp.k('cuAlvo'))) = 'P0002:CUSTOMER_NOT_FOUND');
end $$;

-- ----------------------------------------------------------------------------- A: auditoria preservada (contagens da transação)
do $$ begin
  perform pg_temp.ok('A01 auditoria por ação nesta suíte: CUSTOMER_CREATED >= 7, CUSTOMER_UPDATED = 3, RESERVATION_CUSTOMER_CHANGED = 3, RECURRING_CUSTOMER_LINKED = 2, RECURRING_RESERVATION_CREATED = 2',
    (select count(*) from public.audit_logs a where a.created_at = now() and a.action = 'CUSTOMER_CREATED') >= 7
    and (select count(*) from public.audit_logs a where a.created_at = now() and a.action = 'CUSTOMER_UPDATED') = 3
    and (select count(*) from public.audit_logs a where a.created_at = now() and a.action = 'RESERVATION_CUSTOMER_CHANGED') = 3
    and (select count(*) from public.audit_logs a where a.created_at = now() and a.action = 'RECURRING_CUSTOMER_LINKED') = 2
    and (select count(*) from public.audit_logs a where a.created_at = now() and a.action = 'RECURRING_RESERVATION_CREATED') = 2,
    (select string_agg(action || '=' || n, ',' order by action) from (select action, count(*) n from public.audit_logs where created_at = now() group by action) s));
end $$;

-- ----------------------------------------------------------------------------- Z: congelados e C2A/C2D intactos
do $$ begin
  perform pg_temp.ok('Z01 congelados 03B.3/03C intactos (mesmo conjunto do G04 C2A) e corpos C2A/C2D esperados',
    (select string_agg(md5(replace(p.prosrc, chr(13), '')), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail',
            'rg_recurring_month_payment_record', 'rg_recurring_link_customer', 'rg_recurring_month_apply_series_price'))
      = 'ef638d905dcf0ae4072e7c601172e57b,dfbe684f4f49f5c0c77f14cff70f70bb,099860fb4081811b4ff6823dfeac937c,8061cb47215e805fa0eed28295c13078,fbeeaf4bc38f93fa6481b1daff3e0f13,a1c0277a18f9a5146e370a8c5684aa4e'
    and (select string_agg(x.k || '=' || md5(replace(p.prosrc, chr(13), '')), ',' order by x.k)
           from (values ('a', 'public.rg_recurring_create'), ('b', 'public.rg_recurring_generate'), ('c', 'private.enforce_recurring_occurrence'),
                        ('d', 'private.enforce_reservation_tenant'), ('e', 'private.protect_structural_links'), ('f', 'private.rg_fin_reservation_rows'),
                        ('g', 'public.rg_payment_register'), ('h', 'private.rg_materialize_ex'), ('i', 'private.rg_topup_series'),
                        ('j', 'private.rg_recurring_topup_batch'), ('k', 'private.rg_plan_series'), ('l', 'private.rg_protect_series_slot'),
                        ('m', 'public.rg_fin_overview'), ('n', 'public.rg_fin_receivables')) x(k, f)
           join pg_proc p on p.oid = x.f::regproc)
      = 'a=2aae1120c6e600989e6e990f7146c84f,b=76efe0f4059d4a0e1c9908ec2dd6ea08,c=abc31e62476fce8231504ac6ab08426e,d=802aaffab18c9cd364e9deb7da860480,e=c50be816b59dcf74bfb2d17d85435496,f=0b1659ed026745a6718ecdd722925d8a,g=459e7a1f05c22110d2f0e23f543e4a70,h=586cbc97b0f1a840aed77bd885c7ae43,i=61cf25332b9c329c67bbff2540895ed4,j=0f8080e661045f943a24297424fe3744,k=ff9d1a1caf9e031a01db42f1b805a13c,l=3b58975cd02c50293a8e1ccb77724537,m=6a0cba0c41ff8ed9f6703ca26172a27d,n=fc3e8e1ac2d5e56af0580c6d7363bc64'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_recurring_topup_job(text)'::regprocedure) = '1d3091c712cea7b4bdaa5436c7a4169f'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure) = '335bcf83465140e02b3fd6a69e1a6028'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure) = '0e70211cb4d03be0e9925de46a6deeee'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure) = '5ce683d04fd7bda5a3ec42c18c71de6f');
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
    raise exception 'M2B_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.', v_total - v_fail, v_fail, v_total;
  end if;
  raise notice 'M2B_RESULTS OK — % PASS / 0 FAIL (total %)', v_total, v_total;
end $$;
rollback;
