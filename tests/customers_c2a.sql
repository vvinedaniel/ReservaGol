-- =============================================================================
-- RESERVA GOL — CLIENTES C2A — testes SQL (identidade, autoridades, troca explícita, proteção)
-- Requer a cadeia até 03C + FIX 1 + migration_customers_c2a_identity.sql. Banco de TESTE local, nunca Production.
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/customers_c2a.sql
-- Sucesso: "C2A_RESULTS OK ..." + ROLLBACK explícito. Falha: erro "C2A_RESULTS FAIL ..." (exit != 0). ZERO RESÍDUO.
-- P telefone/UNIQUE/CHECK · R resolve · U update · L list · D detail · X reserva/troca/proteção/W1 · G privilégios/fingerprints
-- Concorrência multi-sessão: tests/customers_c2a_concurrency.sh
-- =============================================================================
begin;
set local statement_timeout = '300s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
create temp table kv (k text primary key, v jsonb) on commit drop;

do $$ begin
  if session_user <> 'postgres' then raise exception 'c2a: execute como postgres'; end if;
  if to_regprocedure('public.rg_customer_resolve(uuid, text, text, text, uuid, text)') is null then
    raise exception 'c2a: migration C2A não aplicada';
  end if;
end $$;

create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.v(p text) returns jsonb language sql stable as $$ select v from kv where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.call(p_actor text, p_sql text, out state text, out result jsonb)
language plpgsql as $$
declare v_claims text; v_msg text; v_hint text; v_detail text;
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
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint, v_detail = pg_exception_detail;
    state := sqlstate || coalesce(':' || nullif(v_hint, ''), '');
    result := jsonb_build_object('msg', v_msg, 'hint', nullif(v_hint, ''), 'detail', nullif(v_detail, ''));
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function pg_temp.do_(p_actor text, p_sql text) returns jsonb language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.call(p_actor, p_sql);
  if v.state <> 'OK' then raise exception 'c2a (%): % % — %', p_actor, v.state, v.result, p_sql; end if;
  return v.result;
end $$;
create function pg_temp.st(p_actor text, p_sql text) returns text language sql as $$ select (pg_temp.call(p_actor, p_sql)).state $$;
create function pg_temp.canon(p text) returns text language plpgsql as $$
declare h text;
begin
  return coalesce(private.rg_phone_canonical(p), 'NULL');
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return 'ERR:' || sqlstate || ':' || coalesce(h, '');
end $$;
create function pg_temp.resolve_sql(p_org uuid, p_name text, p_phone text, p_email text default null, p_arena uuid default null,
                                    p_origin text default 'CUSTOMERS') returns text language sql stable as $$
  select format('select public.rg_customer_resolve(%L::uuid, %L, %L, %L, %L::uuid, %L)', p_org, p_name, p_phone, p_email, p_arena, p_origin) $$;
create function pg_temp.res(p_key text, p_court text, p_days int, p_customer text, p_status text default 'CONFIRMED',
                            p_price int default null) returns uuid language plpgsql as $$
declare v_id uuid; v_s timestamptz := date_trunc('hour', now()) + make_interval(days => p_days) + interval '1 hour';
begin
  insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source, notes, price)
  select c.organization_id, c.arena_id, c.id, pg_temp.k(p_customer), v_s, v_s + interval '1 hour', p_status, 'INTERNAL', 'c2a ' || p_key, p_price
    from public.courts c where c.id = pg_temp.k(p_court)
  returning id into v_id;
  insert into fx values (p_key, v_id);
  return v_id;
end $$;

-- ----------------------------------------------------------------------------- fixtures
do $$
declare
  u_owner uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_rec uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_a1 uuid; v_a2 uuid; v_b1 uuid;
  v_tag text := 'c2a-' || substr(md5(clock_timestamp()::text), 1, 8);
begin
  insert into auth.users (id, email) values (u_owner, v_tag || '-o@reservagol.test'), (u_mgr, v_tag || '-m@reservagol.test'),
                                            (u_rec, v_tag || '-r@reservagol.test'), (u_out, v_tag || '-x@reservagol.test');
  insert into public.organizations (name, is_demo) values ('C2A ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('C2A outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_owner, 'OWNER', 'ACTIVE'), (v_org, u_mgr, 'MANAGER', 'ACTIVE'), (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'), (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (v_org, 'A1 ' || v_tag) returning id into v_a1;
  insert into public.arenas (organization_id, name) values (v_org, 'A2 ' || v_tag) returning id into v_a2;
  insert into public.arenas (organization_id, name) values (v_org2, 'B1 ' || v_tag) returning id into v_b1;
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
  select v_org, v_a1, w, '06:00', '23:00', false from generate_series(0, 6) w;
  insert into fx values ('owner', u_owner), ('mgr', u_mgr), ('rec', u_rec), ('out', u_out), ('org', v_org), ('org2', v_org2),
                        ('a1', v_a1), ('a2', v_a2), ('b1', v_b1);
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q1') returning id) insert into fx select 'c1', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q2') returning id) insert into fx select 'c2', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org, v_a1, 'Q3') returning id) insert into fx select 'c3', id from x;
  with x as (insert into public.courts (organization_id, arena_id, name) values (v_org2, v_b1, 'QB') returning id) insert into fx select 'cb', id from x;
  -- clientes de setup (postgres)
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Maria Base', '41988880001') returning id) insert into fx select 'cuM', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Joao Base', '41988880002') returning id) insert into fx select 'cuJ', id from x;
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org2, v_b1, 'Fora', '41988880009') returning id) insert into fx select 'cuB', id from x;
  -- linha LEGADA de 11 dígitos não canônica (3º dígito ≠ 9), como as 15 de Production
  with x as (insert into public.customers (organization_id, arena_id, name, phone) values (v_org, v_a1, 'Legado 11', '11812345678') returning id) insert into fx select 'cuLeg', id from x;
end $$;

-- ----------------------------------------------------------------------------- P: telefone, UNIQUE, CHECK
do $$
declare v_bad int; v_rows int;
begin
  select count(*) into v_bad from (values
    ('(41) 99999-9999', '41999999999'), ('41999999999', '41999999999'), ('+55 41 99999-9999', '41999999999'),
    ('5541999999999', '41999999999'), ('+5541999999999', '41999999999'), ('041999999999', '41999999999'),
    ('(41) 3333-4444', '4133334444'), ('554133334444', '4133334444'), ('04133334444', '4133334444'),
    ('55999998888', '55999998888'), ('5555999998888', '55999998888'), ('+55 (55) 9 9999-8888', '55999998888'), ('5533334444', '5533334444'),
    ('', 'NULL'), ('   ', 'NULL'), (null, 'NULL'),
    ('99999-9999', 'ERR:22023:INVALID_PHONE'), ('(20) 99999-9999', 'ERR:22023:INVALID_PHONE'), ('41 89999-9999', 'ERR:22023:INVALID_PHONE'),
    ('4163334444', 'ERR:22023:INVALID_PHONE'), ('+1 415 555 0100', 'ERR:22023:INVALID_PHONE'), ('+44 20 7946 0958', 'ERR:22023:INVALID_PHONE'),
    ('0 21 41 99999-9999', 'ERR:22023:INVALID_PHONE'), ('41-99999-999a', 'ERR:22023:INVALID_PHONE'), ('+55 0 41 99999 9999', 'ERR:22023:INVALID_PHONE'),
    ('(  )', 'ERR:22023:INVALID_PHONE'), ('4199999999999999', 'ERR:22023:INVALID_PHONE'), ('41 9999 9999 ext 2', 'ERR:22023:INVALID_PHONE')) t(i, e)
  where pg_temp.canon(i) is distinct from e;
  perform pg_temp.ok('P01 tabela de exemplos (BR, +55/55, 0, DDD 55, fixo, vazio=NULL, estrangeiro/DDD/celular/operadora inválidos)', v_bad = 0, v_bad::text);

  -- propriedade (amostra determinística de 6000 entradas): sucesso => canônico idempotente, regex do UNIQUE e rg_phone_valid
  select count(*) into v_rows from (
    select x, pg_temp.canon(x) c from (
      select (array['', '+', '0', '55', '+55 ', '055'])[1 + (g % 6)] || lpad(((g * 7919) % 1000000000000)::text, 9 + (g % 5), '0') as x
        from generate_series(1, 6000) g) s) t
   where t.c not like 'ERR:%' and t.c <> 'NULL'
     and not (t.c ~ '^[0-9]{10,11}$' and private.rg_phone_valid(t.c) and private.rg_phone_canonical(t.c) = t.c);
  perform pg_temp.ok('P02 propriedade: todo canônico satisfaz o predicado do UNIQUE, o CHECK (rg_phone_valid) e é ponto fixo', v_rows = 0, v_rows::text);

  perform pg_temp.ok('P03 linha legada 11 dígitos não canônica: dentro do predicado do UNIQUE, fora do CHECK, nunca produzida pela canônica',
    '11812345678' ~ '^[0-9]{10,11}$' and not private.rg_phone_valid('11812345678')
    and pg_temp.canon('11812345678') = 'ERR:22023:INVALID_PHONE' and pg_temp.canon('(11) 81234-5678') = 'ERR:22023:INVALID_PHONE'
    and pg_temp.canon('+55 11 81234-5678') = 'ERR:22023:INVALID_PHONE');
  perform pg_temp.ok('P04 UNIQUE vale para legados de 10/11 dígitos (duplicar um legado => 23505)',
    pg_temp.st('postgres', format('insert into public.customers (organization_id, name, phone) values (%L, %L, %L) returning to_jsonb(id)',
                                  pg_temp.k('org'), 'dup legado', '11812345678')) = '23505');
  perform pg_temp.ok('P05 legados de 4 dígitos ficam fora do UNIQUE (duplicatas históricas preservadas, nada reescrito)',
    pg_temp.st('postgres', format('insert into public.customers (organization_id, name, phone) values (%L, ''a'', ''1173''), (%L, ''b'', ''1173'') returning to_jsonb(id)',
                                  pg_temp.k('org'), pg_temp.k('org'))) = 'OK');
end $$;

-- CHECK proposta para o M2 (NOT VALID) — compatibilidade provada aqui, revertida no savepoint
savepoint sp_check;
alter table public.customers add constraint c2a_probe_phone check (phone is null or private.rg_phone_valid(phone)) not valid;
do $$ begin
  perform pg_temp.ok('P06 CHECK(M2) aceita escrita canônica nova',
    pg_temp.st('postgres', format('insert into public.customers (organization_id, name, phone) values (%L, ''chk'', private.rg_phone_canonical(''+55 41 97777-0001'')) returning to_jsonb(id)', pg_temp.k('org'))) = 'OK');
  perform pg_temp.ok('P07 CHECK(M2) rejeita forma não canônica (5541…) e não valida legados existentes (NOT VALID)',
    pg_temp.st('postgres', format('insert into public.customers (organization_id, name, phone) values (%L, ''chk2'', ''5541977770002'') returning to_jsonb(id)', pg_temp.k('org'))) = '23514'
    and exists (select 1 from public.customers where id = pg_temp.k('cuLeg') and phone = '11812345678'));
end $$;
rollback to savepoint sp_check;

-- ----------------------------------------------------------------------------- R: resolve
do $$
declare r jsonb; r2 jsonb; v_id uuid; v_n int; v_a int; v_st text;
begin
  v_a := (select count(*) from public.audit_logs where organization_id = pg_temp.k('org') and action = 'CUSTOMER_CREATED');
  r := pg_temp.do_('owner', pg_temp.resolve_sql(pg_temp.k('org'), '  Ana   Paula ', '(41) 99999-1111', 'Ana@Exemplo.com', pg_temp.k('a1')));
  v_id := (r->>'customer_id')::uuid; insert into fx values ('cuA', v_id);
  perform pg_temp.ok('R01 cria: telefone canônico, nome normalizado, e-mail minúsculo, created=true',
    (r->>'created')::boolean and exists (select 1 from public.customers where id = v_id and phone = '41999991111'
                                         and name = 'Ana Paula' and email = 'ana@exemplo.com' and arena_id = pg_temp.k('a1')), r::text);
  select count(*) into v_n from (values ('41999991111'), ('+55 41 99999-1111'), ('5541999991111'), ('041 99999 1111'), ('41 9 9999 1111')) t(p)
   where (pg_temp.do_('rec', pg_temp.resolve_sql(pg_temp.k('org'), 'Ana Paula', p))->>'customer_id')::uuid = v_id;
  perform pg_temp.ok('R02 todas as formas do mesmo número reaproveitam o mesmo cliente (created=false), nenhuma linha nova',
    v_n = 5 and (select count(*) from public.customers where organization_id = pg_temp.k('org') and phone = '41999991111') = 1);
  r := pg_temp.do_('mgr', pg_temp.resolve_sql(pg_temp.k('org'), 'Outro Nome', '41999991111', 'x@y.com'));
  perform pg_temp.ok('R03 telefone existente com nome diferente: devolve o existente, name_differs=true, NÃO renomeia nem troca e-mail',
    not (r->>'created')::boolean and (r->>'name_differs')::boolean and r->'existing'->>'name' = 'Ana Paula'
    and exists (select 1 from public.customers where id = v_id and name = 'Ana Paula' and email = 'ana@exemplo.com'), r::text);
  r := pg_temp.do_('rec', pg_temp.resolve_sql(pg_temp.k('org'), 'Sem Fone', null));
  r2 := pg_temp.do_('rec', pg_temp.resolve_sql(pg_temp.k('org'), 'Sem Fone', ''));
  perform pg_temp.ok('R04 sem telefone: sempre cria (sem deduplicar por nome)',
    (r->>'created')::boolean and (r2->>'created')::boolean and r->>'customer_id' <> r2->>'customer_id');
  perform pg_temp.ok('R05 validação: telefone inválido / estrangeiro / nome vazio / e-mail inválido / arena de outra org / origem inválida',
    pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'X', '99999-9999')) = '22023:INVALID_PHONE'
    and pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'X', '+1 415 555 0100')) = '22023:INVALID_PHONE'
    and pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), '   ', '41999990000')) = '22023:INVALID_NAME'
    and pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'X', null, 'nao-e-email')) = '22023:INVALID_EMAIL'
    and pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'X', null, null, pg_temp.k('b1'))) = '22023:INVALID_ARENA'
    and pg_temp.st('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'X', null, null, null, 'PUBLIC')) = '22023:INVALID_ORIGIN');
  perform pg_temp.ok('R06 membro de outra organização => 42501; anon sem EXECUTE (42501)',
    pg_temp.st('out', pg_temp.resolve_sql(pg_temp.k('org'), 'X', '41999990000')) = '42501'
    and pg_temp.st('anon', pg_temp.resolve_sql(pg_temp.k('org'), 'X', '41999990000')) = '42501');
  perform pg_temp.ok('R07 auditoria CUSTOMER_CREATED: 1 por criação (2 sem telefone + 1 Ana), ator real, metadata SEM PII',
    (select count(*) from public.audit_logs where organization_id = pg_temp.k('org') and action = 'CUSTOMER_CREATED') = v_a + 3
    and exists (select 1 from public.audit_logs where entity_id = v_id and action = 'CUSTOMER_CREATED' and user_id = pg_temp.k('owner')
                and metadata->>'origin' = 'CUSTOMERS' and metadata->>'actor' = 'USER' and (metadata->>'has_phone')::boolean
                and (select array_agg(k order by k) from jsonb_object_keys(metadata) k) = array['actor', 'arena_id', 'has_email', 'has_phone', 'origin']
                and metadata::text !~ '99999|Ana|exemplo'));
  v_st := pg_temp.st('owner', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''P'', ''41999992222'')', pg_temp.k('org'), pg_temp.k('a1')));
  r := pg_temp.do_('service_role', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''Pub'', ''+55 41 99999-2222'')', pg_temp.k('org'), pg_temp.k('a1')));
  r2 := pg_temp.do_('service_role', format('select public.rg_customer_resolve_public(%L::uuid, %L::uuid, ''Pub2'', ''41999992222'')', pg_temp.k('org'), pg_temp.k('a1')));
  perform pg_temp.ok('R08 resolve_public: authenticated sem EXECUTE; service_role cria com ator PUBLIC (user_id NULL) e reaproveita por telefone',
    v_st = '42501' and (r->>'created')::boolean and not (r2->>'created')::boolean and r->>'customer_id' = r2->>'customer_id'
    and exists (select 1 from public.audit_logs a where a.entity_id = (r->>'customer_id')::uuid and a.action = 'CUSTOMER_CREATED'
                  and a.user_id is null and a.metadata->>'actor' = 'PUBLIC' and a.metadata->>'origin' = 'PUBLIC'),
    v_st || ' ' || r::text || ' ' || r2::text);
end $$;

-- ----------------------------------------------------------------------------- U: update
do $$
declare r jsonb; v_ts timestamptz; v_a int; v_st text; v_call record;
begin
  v_ts := (select updated_at from public.customers where id = pg_temp.k('cuM'));
  r := pg_temp.do_('rec', format('select public.rg_customer_update(%L::uuid, %L::jsonb, %L::timestamptz)', pg_temp.k('cuM'),
                                 '{"name":"Maria  Souza","email":"MARIA@x.com","phone":"+55 (41) 98888-0011"}', v_ts));
  perform pg_temp.ok('U01 RECEPTIONIST edita nome/e-mail/telefone (canonizados) e auditoria CUSTOMER_UPDATED mascarada',
    (r->>'changed')::boolean and exists (select 1 from public.customers where id = pg_temp.k('cuM') and name = 'Maria Souza'
                                         and email = 'maria@x.com' and phone = '41988880011')
    and exists (select 1 from public.audit_logs where entity_id = pg_temp.k('cuM') and action = 'CUSTOMER_UPDATED' and user_id = pg_temp.k('rec')
                and metadata->'changed' @> '["name","email","phone"]' and metadata->'phone_last4'->>'before' = '0001'
                and metadata->'phone_last4'->>'after' = '0011' and metadata->'email_domain'->>'after' = 'x.com'
                and metadata::text !~ 'Maria|4198888|maria@'), r::text);
  -- (dentro desta transação updated_at = now() é constante; versão obsoleta = qualquer valor diferente do atual)
  perform pg_temp.ok('U02 versão obsoleta => RGC02 STALE_UPDATE, nada muda',
    pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, ''{"name":"Z"}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'),
                               (select updated_at - interval '1 second' from public.customers where id = pg_temp.k('cuM')))) = 'RGC02:STALE_UPDATE'
    and (select name from public.customers where id = pg_temp.k('cuM')) = 'Maria Souza');
  v_ts := (select updated_at from public.customers where id = pg_temp.k('cuM'));
  select * into v_call from pg_temp.call('owner', format('select public.rg_customer_update(%L::uuid, ''{"phone":"(41) 98888-0002"}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts));
  perform pg_temp.ok('U03 telefone de outro cliente => RGC01 PHONE_IN_USE (detail = id do outro), nada muda, sem fusão',
    v_call.state = 'RGC01:PHONE_IN_USE' and v_call.result->>'detail' = pg_temp.k('cuJ')::text
    and exists (select 1 from public.customers where id = pg_temp.k('cuM') and phone = '41988880011'), v_call.result::text);
  r := pg_temp.do_('owner', format('select public.rg_customer_update(%L::uuid, ''{"phone":""}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts));
  perform pg_temp.ok('U04 telefone vazio => NULL', (r->>'changed')::boolean and (select phone from public.customers where id = pg_temp.k('cuM')) is null);
  v_ts := (select updated_at from public.customers where id = pg_temp.k('cuM'));
  perform pg_temp.ok('U05 outra organização / inexistente => P0002',
    pg_temp.st('out', format('select public.rg_customer_update(%L::uuid, ''{"name":"Z"}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts)) = 'P0002'
    and pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, ''{"name":"Z"}''::jsonb, %L::timestamptz)', gen_random_uuid(), v_ts)) = 'P0002');
  perform pg_temp.ok('U06 campos proibidos (id/organization_id/created_at/updated_at) => 22023 INVALID_FIELD',
    pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, %L::jsonb, %L::timestamptz)', pg_temp.k('cuM'), json_build_object('id', gen_random_uuid()), v_ts)) = '22023:INVALID_FIELD'
    and pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, %L::jsonb, %L::timestamptz)', pg_temp.k('cuM'), json_build_object('organization_id', pg_temp.k('org2')), v_ts)) = '22023:INVALID_FIELD'
    and pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, ''{"created_at":"2020-01-01"}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts)) = '22023:INVALID_FIELD'
    and pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, ''{}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts)) = '22023:INVALID_FIELD');
  v_a := (select count(*) from public.audit_logs where entity_id = pg_temp.k('cuM') and action = 'CUSTOMER_UPDATED');
  r := pg_temp.do_('owner', format('select public.rg_customer_update(%L::uuid, ''{"name":" Maria   Souza "}''::jsonb, %L::timestamptz)', pg_temp.k('cuM'), v_ts));
  perform pg_temp.ok('U07 sem mudança real => changed=false e nenhuma auditoria',
    not (r->>'changed')::boolean and (select count(*) from public.audit_logs where entity_id = pg_temp.k('cuM') and action = 'CUSTOMER_UPDATED') = v_a,
    r::text || ' audits=' || (select count(*) from public.audit_logs where entity_id = pg_temp.k('cuM') and action = 'CUSTOMER_UPDATED') || '/' || v_a);
  v_ts := (select updated_at from public.customers where id = pg_temp.k('cuLeg'));
  r := pg_temp.do_('owner', format('select public.rg_customer_update(%L::uuid, ''{"name":"Legado Renomeado"}''::jsonb, %L::timestamptz)', pg_temp.k('cuLeg'), v_ts));
  perform pg_temp.ok('U08 legado inválido: editar só o nome preserva o telefone legado intacto; regravar o telefone legado => INVALID_PHONE',
    (r->>'changed')::boolean and (select phone from public.customers where id = pg_temp.k('cuLeg')) = '11812345678'
    and pg_temp.st('owner', format('select public.rg_customer_update(%L::uuid, ''{"phone":"11812345678"}''::jsonb, %L::timestamptz)', pg_temp.k('cuLeg'),
                                   (select updated_at from public.customers where id = pg_temp.k('cuLeg')))) = '22023:INVALID_PHONE');
  v_ts := (select updated_at from public.customers where id = pg_temp.k('cuJ'));
  perform pg_temp.ok('U09 arena: outra org => INVALID_ARENA; uuid malformado => INVALID_ARENA; arena da org => ok',
    pg_temp.st('mgr', format('select public.rg_customer_update(%L::uuid, %L::jsonb, %L::timestamptz)', pg_temp.k('cuJ'), json_build_object('arena_id', pg_temp.k('b1')), v_ts)) = '22023:INVALID_ARENA'
    and pg_temp.st('mgr', format('select public.rg_customer_update(%L::uuid, ''{"arena_id":"xx"}''::jsonb, %L::timestamptz)', pg_temp.k('cuJ'), v_ts)) = '22023:INVALID_ARENA'
    and (pg_temp.do_('mgr', format('select public.rg_customer_update(%L::uuid, %L::jsonb, %L::timestamptz)', pg_temp.k('cuJ'), json_build_object('arena_id', pg_temp.k('a2')), v_ts))->>'changed')::boolean);
end $$;

-- ----------------------------------------------------------------------------- L: list
do $$
declare r jsonb; v_all uuid[] := '{}'; v_page jsonb; v_cur jsonb := null; v_pages int := 0; v_ok boolean := true; i int;
begin
  for i in 1..30 loop
    insert into public.customers (organization_id, name, phone) values (pg_temp.k('org'), 'Zeta ' || lpad(i::text, 2, '0'), '4197' || lpad((7000000 + i)::text, 7, '0'));
  end loop;
  insert into public.customers (organization_id, name) values (pg_temp.k('org'), 'Ana_100%'), (pg_temp.k('org'), 'Ana 1000');
  r := pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''zeta 3'', ''ALL'', 25)', pg_temp.k('org')));
  perform pg_temp.ok('L01 busca por nome encontra registro além dos 20 primeiros (filtro antes do LIMIT)',
    jsonb_array_length(r->'items') = 1 and r->'items'->0->>'name' = 'Zeta 30', r::text);
  r := pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''a_1'', ''ALL'', 25)', pg_temp.k('org')));
  perform pg_temp.ok('L02 curingas % e _ são literais', jsonb_array_length(r->'items') = 1 and r->'items'->0->>'name' = 'Ana_100%', r::text);
  perform pg_temp.ok('L03 busca por telefone (>= 4 dígitos), inclusive com +55',
    jsonb_array_length(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''7000030'', ''ALL'', 25)', pg_temp.k('org')))->'items') = 1
    and jsonb_array_length(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''+55 41 97700-0030'', ''ALL'', 25)', pg_temp.k('org')))->'items') = 1);
  loop
    v_page := pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, ''zeta'', ''ALL'', 7, %L, %L::uuid)', pg_temp.k('org'),
                                        v_cur->>'after_name', v_cur->>'after_id'));
    v_pages := v_pages + 1;
    v_all := v_all || array(select (e->>'id')::uuid from jsonb_array_elements(v_page->'items') e);
    v_cur := v_page->'next_cursor';
    exit when v_cur = 'null'::jsonb or v_cur is null or v_pages > 10;
  end loop;
  perform pg_temp.ok('L04 paginação por cursor: 30 resultados em 5 páginas, sem repetir nem pular, em ordem',
    v_pages = 5 and cardinality(v_all) = 30 and (select count(distinct x) from unnest(v_all) x) = 30
    and (select array_agg(c.id order by lower(c.name), c.id) from public.customers c where c.organization_id = pg_temp.k('org') and c.name like 'Zeta %') = v_all,
    v_pages::text || '/' || cardinality(v_all));
  perform pg_temp.ok('L05 validação: limite 0/51, filtro inválido, cursor pela metade => 22023',
    pg_temp.st('rec', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 0)', pg_temp.k('org'))) = '22023:INVALID_LIMIT'
    and pg_temp.st('rec', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 51)', pg_temp.k('org'))) = '22023:INVALID_LIMIT'
    and pg_temp.st('rec', format('select public.rg_customer_list(%L::uuid, null, ''VIP'', 10)', pg_temp.k('org'))) = '22023:INVALID_FILTER'
    and pg_temp.st('rec', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 10, ''a'', null)', pg_temp.k('org'))) = '22023:INVALID_CURSOR');
  perform pg_temp.ok('L06 membro de outra organização => 42501',
    pg_temp.st('out', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 10)', pg_temp.k('org'))) = '42501');
end $$;

-- reservas para L07+/D/X: cuA tem passada aberta (vencido), futura aberta, futura paga; cuJ só paga
do $$
declare v_pay jsonb;
begin
  perform pg_temp.res('rPast', 'c1', -3, 'cuA', 'CONFIRMED', 10000);
  perform pg_temp.res('rFut', 'c1', 5, 'cuA', 'CONFIRMED', 12000);
  perform pg_temp.res('rPaid', 'c2', 6, 'cuJ', 'CONFIRMED', 8000);
  perform pg_temp.res('rCanc', 'c2', 7, 'cuA', 'CANCELLED', 5000);
  perform pg_temp.res('rOld', 'c3', -40, 'cuA', 'CONFIRMED', null);
  perform pg_temp.res('rBlk', 'c3', 8, 'cuA', 'BLOCKED', null);  -- bloqueio (customer só para provar a recusa da troca)
  v_pay := pg_temp.do_('mgr', format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', 8000, now(), null)', gen_random_uuid(), pg_temp.k('rPaid')));
  v_pay := pg_temp.do_('mgr', format('select public.rg_payment_register(%L::uuid, %L::uuid, ''PIX'', 4000, now(), null)', gen_random_uuid(), pg_temp.k('rFut')));
end $$;

do $$
declare r jsonb; v_a jsonb; v_j jsonb; v_par int;
begin
  r := pg_temp.do_('mgr', format('select public.rg_customer_list(%L::uuid, ''ana paula'', ''ALL'', 10)', pg_temp.k('org')));
  v_a := r->'items'->0;
  r := pg_temp.do_('mgr', format('select public.rg_customer_list(%L::uuid, ''joao'', ''ALL'', 10)', pg_temp.k('org')));
  v_j := r->'items'->0;
  perform pg_temp.ok('L07 gestor: fin_flag OVERDUE (passada em aberto) / null (tudo pago); next_at e last_at corretos',
    v_a->>'fin_flag' = 'OVERDUE' and v_j->>'fin_flag' is null
    and (v_a->>'next_at')::timestamptz = (select start_at from public.reservations where id = pg_temp.k('rFut'))
    and (v_a->>'last_at')::timestamptz = (select start_at from public.reservations where id = pg_temp.k('rPast')), v_a::text);
  perform pg_temp.ok('L08 RECEPTIONIST: fin_flag ausente (null) para todos',
    (select bool_and(e->>'fin_flag' is null) from jsonb_array_elements(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 50)', pg_temp.k('org')))->'items') e));
  -- paridade com o 03A: fin_flag == agregação de rg_fin_reservation_rows (collectible_balance) por cliente
  select count(*) into v_par
    from jsonb_array_elements(pg_temp.do_('mgr', format('select public.rg_customer_list(%L::uuid, null, ''ALL'', 50)', pg_temp.k('org')))->'items') e
    left join lateral (select case when bool_or(f.collectible_balance > 0 and f.start_at < now()) then 'OVERDUE'
                                   when bool_or(f.collectible_balance > 0) then 'OPEN' end as flag
                         from private.rg_fin_reservation_rows(pg_temp.k('org'), null, '-infinity', 'infinity') f
                        where f.customer_id = (e->>'id')::uuid) x on true
   where (e->>'fin_flag') is distinct from x.flag;
  perform pg_temp.ok('L09 paridade 03A: fin_flag da lista == rg_fin_reservation_rows (collectible_balance) para todos os clientes', v_par = 0, v_par::text);
  perform pg_temp.ok('L10 filtros MENSALISTA (nenhum ainda) e INACTIVE_60D (exclui quem tem reserva recente/futura)',
    jsonb_array_length(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, null, ''MENSALISTA'', 50)', pg_temp.k('org')))->'items') = 0
    and not exists (select 1 from jsonb_array_elements(pg_temp.do_('rec', format('select public.rg_customer_list(%L::uuid, null, ''INACTIVE_60D'', 50)', pg_temp.k('org')))->'items') e
                     where (e->>'id')::uuid in (pg_temp.k('cuA'), pg_temp.k('cuJ'))));
end $$;

-- ----------------------------------------------------------------------------- D: detail
do $$
declare r jsonb; r2 jsonb; v_f record;
begin
  r := pg_temp.do_('rec', format('select public.rg_customer_detail(%L::uuid, null, 1)', pg_temp.k('cuA')));
  perform pg_temp.ok('D01 ficha: cadastro, próximas (sem cancelada/bloqueio), histórico paginado; RECEPTIONIST sem financeiro',
    r->'customer'->>'name' = 'Ana Paula' and r->'customer'->'arena'->>'id' = pg_temp.k('a1')::text
    and jsonb_array_length(r->'upcoming') = 1 and r->'upcoming'->0->>'id' = pg_temp.k('rFut')::text
    and jsonb_array_length(r->'history') = 1 and r->'history'->0->>'id' = pg_temp.k('rPast')::text
    and r->>'history_next_before' is not null and r->'finance' = 'null'::jsonb, r::text);
  r2 := pg_temp.do_('rec', format('select public.rg_customer_detail(%L::uuid, %L::timestamptz, 5)', pg_temp.k('cuA'), r->>'history_next_before'));
  perform pg_temp.ok('D02 histórico: segunda página continua sem sobrepor e sem cursor seguinte',
    jsonb_array_length(r2->'history') = 1 and r2->'history'->0->>'id' = pg_temp.k('rOld')::text and r2->'history_next_before' = 'null'::jsonb, r2::text);
  r := pg_temp.do_('mgr', format('select public.rg_customer_detail(%L::uuid)', pg_temp.k('cuA')));
  select coalesce(sum(amount_due) filter (where collectible and amount_due is not null), 0) as exp,
         count(*) filter (where collectible and amount_due is null) as unp,
         coalesce(sum(net_received), 0) as rec, coalesce(sum(collectible_balance), 0) as opn,
         coalesce(sum(collectible_balance) filter (where start_at < now()), 0) as ovd
    into v_f from private.rg_fin_reservation_rows(pg_temp.k('org'), null, now() - interval '365 days', now() + interval '120 days')
   where customer_id = pg_temp.k('cuA');
  perform pg_temp.ok('D03 financeiro (gestor) == agregação do rg_fin_reservation_rows (esperado/sem valor/recebido/em aberto/vencido)',
    (r->'finance'->>'expected')::bigint = v_f.exp and (r->'finance'->>'unpriced_count')::bigint = v_f.unp
    and (r->'finance'->>'received')::bigint = v_f.rec and (r->'finance'->>'open')::bigint = v_f.opn
    and (r->'finance'->>'overdue')::bigint = v_f.ovd and v_f.exp = 22000 and v_f.rec = 4000 and v_f.ovd = 10000, (r->'finance')::text);
  perform pg_temp.ok('D04 outra organização / inexistente => P0002; limite inválido => 22023',
    pg_temp.st('out', format('select public.rg_customer_detail(%L::uuid)', pg_temp.k('cuA'))) = 'P0002'
    and pg_temp.st('rec', format('select public.rg_customer_detail(%L::uuid)', gen_random_uuid())) = 'P0002'
    and pg_temp.st('rec', format('select public.rg_customer_detail(%L::uuid, null, 0)', pg_temp.k('cuA'))) = '22023:INVALID_LIMIT');
end $$;

-- ----------------------------------------------------------------------------- X: reserva — proteção, troca explícita, W1
do $$
declare v_before public.reservations; v_after public.reservations; r jsonb; v_a int; v_call record;
begin
  perform pg_temp.ok('X01 UPDATE direto de customer_id falha para authenticated (OWNER/RECEPTIONIST) e até para postgres (RGT02)',
    pg_temp.st('owner', format('update public.reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cuJ'), pg_temp.k('rFut'))) = 'RGT02:USE_CHANGE_CUSTOMER'
    and pg_temp.st('rec', format('update public.reservations set customer_id = null where id = %L returning to_jsonb(id)', pg_temp.k('rFut'))) = 'RGT02:USE_CHANGE_CUSTOMER'
    and pg_temp.st('postgres', format('update public.reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cuJ'), pg_temp.k('rFut'))) = 'RGT02:USE_CHANGE_CUSTOMER');
  -- editar data/horário/quadra/observação/status (authenticated) e preço (postgres) NÃO muda o cliente
  perform pg_temp.do_('owner', format('update public.reservations set start_at = start_at + interval ''1 day'', end_at = end_at + interval ''1 day'' where id = %L returning to_jsonb(id)', pg_temp.k('rFut')));
  perform pg_temp.do_('owner', format('update public.reservations set start_at = start_at + interval ''30 minutes'', end_at = end_at + interval ''30 minutes'' where id = %L returning to_jsonb(id)', pg_temp.k('rFut')));
  perform pg_temp.do_('rec', format('update public.reservations set court_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('c3'), pg_temp.k('rFut')));
  perform pg_temp.do_('rec', format('update public.reservations set notes = ''nova obs'', status = ''PENDING'' where id = %L returning to_jsonb(id)', pg_temp.k('rFut')));
  perform pg_temp.do_('postgres', format('update public.reservations set price = 12500 where id = %L returning to_jsonb(id)', pg_temp.k('rFut')));
  perform pg_temp.do_('owner', format('update public.reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cuA'), pg_temp.k('rFut')));
  perform pg_temp.ok('X02 data, horário, quadra, observação, status, preço e o PUT antigo com o MESMO cliente não alteram customer_id',
    (select customer_id from public.reservations where id = pg_temp.k('rFut')) = pg_temp.k('cuA')
    and exists (select 1 from public.reservations where id = pg_temp.k('rFut') and court_id = pg_temp.k('c3') and notes = 'nova obs'
                and status = 'PENDING' and price = 12500));

  select * into v_before from public.reservations where id = pg_temp.k('rFut');
  v_a := (select count(*) from public.audit_logs where entity_id = pg_temp.k('rFut') and action = 'RESERVATION_CUSTOMER_CHANGED');
  r := pg_temp.do_('rec', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuJ'), pg_temp.k('cuA')));
  select * into v_after from public.reservations where id = pg_temp.k('rFut');
  perform pg_temp.ok('X03 troca explícita (RECEPTIONIST): só customer_id muda; RESERVATION_CUSTOMER_CHANGED antes/depois na mesma transação',
    (r->>'changed')::boolean and v_after.customer_id = pg_temp.k('cuJ')
    and (to_jsonb(v_after) - 'customer_id' - 'updated_at') = (to_jsonb(v_before) - 'customer_id' - 'updated_at')
    and (select count(*) from public.audit_logs where entity_id = pg_temp.k('rFut') and action = 'RESERVATION_CUSTOMER_CHANGED'
           and user_id = pg_temp.k('rec') and metadata->>'before_customer_id' = pg_temp.k('cuA')::text
           and metadata->>'after_customer_id' = pg_temp.k('cuJ')::text) = v_a + 1, r::text);
  r := pg_temp.do_('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuJ'), pg_temp.k('cuA')));
  perform pg_temp.ok('X04 repetição (já é o cliente pedido) => changed=false, sem nova auditoria (antes da checagem de obsoleto)',
    not (r->>'changed')::boolean and (select count(*) from public.audit_logs where entity_id = pg_temp.k('rFut') and action = 'RESERVATION_CUSTOMER_CHANGED') = v_a + 1);
  perform pg_temp.ok('X05 estado obsoleto (expected ≠ atual) => RGC02, nada muda',
    pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuA'), pg_temp.k('cuM'))) = 'RGC02:STALE_UPDATE'
    and (select customer_id from public.reservations where id = pg_temp.k('rFut')) = pg_temp.k('cuJ'));
  perform pg_temp.ok('X06 cliente de outra organização => P0002; membro de outra organização => P0002; destino NULL => 22023',
    pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuB'), pg_temp.k('cuJ'))) = 'P0002:CUSTOMER_NOT_FOUND'
    and pg_temp.st('out', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuA'), pg_temp.k('cuJ'))) = 'P0002'
    and pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, null, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuJ'))) = '22023:CUSTOMER_REQUIRED');
  perform pg_temp.ok('X07 bloqueio => RGC04; cancelada => RGC05',
    pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rBlk'), pg_temp.k('cuJ'), pg_temp.k('cuA'))) = 'RGC04:BLOCKED_SLOT'
    and pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rCanc'), pg_temp.k('cuJ'), pg_temp.k('cuA'))) = 'RGC05:CANCELLED_RESERVATION');
  perform pg_temp.ok('X08 marcador não vaza: depois da RPC (mesma transação) o UPDATE direto continua bloqueado',
    pg_temp.st('postgres', format('update public.reservations set customer_id = %L where id = %L returning to_jsonb(id)', pg_temp.k('cuA'), pg_temp.k('rFut'))) = 'RGT02:USE_CHANGE_CUSTOMER');
end $$;

-- X09 atomicidade: falha na auditoria => troca desfeita (trigger de teste, só nesta transação)
create function private.c2a_test_fail_audit() returns trigger language plpgsql as $$
begin
  if new.action = 'RESERVATION_CUSTOMER_CHANGED' then raise exception 'c2a falha injetada na auditoria'; end if;
  return new;
end $$;
create trigger c2a_test_fail_audit before insert on public.audit_logs for each row execute function private.c2a_test_fail_audit();
do $$ begin
  perform pg_temp.ok('X09 atomicidade: auditoria falha => erro e customer_id inalterado',
    pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)', pg_temp.k('rFut'), pg_temp.k('cuA'), pg_temp.k('cuJ'))) = 'P0001'
    and (select customer_id from public.reservations where id = pg_temp.k('rFut')) = pg_temp.k('cuJ'));
end $$;
drop trigger c2a_test_fail_audit on public.audit_logs;
drop function private.c2a_test_fail_audit();

do $$
declare v_cu uuid; v_cnt int;
begin
  v_cu := (pg_temp.do_('owner', pg_temp.resolve_sql(pg_temp.k('org'), 'Apagavel', '41966660001'))->>'customer_id')::uuid;
  insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source)
  values (pg_temp.k('org'), pg_temp.k('a1'), pg_temp.k('c2'), v_cu, now() + interval '20 days', now() + interval '20 days 1 hour', 'CONFIRMED', 'INTERNAL');
  delete from public.audit_logs where entity_id = v_cu;
  delete from public.customers where id = v_cu;
  get diagnostics v_cnt = row_count;
  perform pg_temp.ok('X10 ON DELETE SET NULL do cliente continua funcionando (reserva fica sem cliente)',
    v_cnt = 1 and not exists (select 1 from public.reservations where customer_id = v_cu)
    and exists (select 1 from public.reservations where start_at = (now() + interval '20 days') and customer_id is null and court_id = pg_temp.k('c2')));
end $$;

-- W1 / rg_recurring_create herdando a regra canônica
do $$
declare r jsonb; v_s uuid; v_s2 uuid; v_dow int := extract(dow from private.rg_today() + 10)::int; v_series public.recurring_reservations;
  v_dates date[]; v_occ int; v_cu uuid; v_call record;
begin
  r := pg_temp.do_('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, null, ''WEEKLY'', %s, null, ''19:00'', ''20:00'', %L::date, null, true, 10000, null, false, false, ''{}''::date[])',
                                   gen_random_uuid(), pg_temp.k('a1'), pg_temp.k('c1'), v_dow, private.rg_today() - 7));
  v_s := (r->>'series_id')::uuid; insert into fx values ('S1', v_s);
  select * into v_series from public.recurring_reservations where id = v_s;
  v_dates := array(select g::date from generate_series(private.rg_today(), private.rg_today() + 30, interval '1 day') g where private.rg_is_anchor(v_series, g::date));
  perform private.rg_materialize(v_series, v_dates, false, null);
  -- ocorrência: UPDATE direto para cliente diferente do da série (NULL) => bloqueado
  perform pg_temp.ok('X11 ocorrência sem cliente: UPDATE direto para um cliente qualquer => RGT02',
    pg_temp.st('owner', format('update public.reservations set customer_id = %L where recurring_reservation_id = %L returning to_jsonb(id)', pg_temp.k('cuJ'), v_s)) like 'RGT02%');
  -- W1 com telefone em formato +55 reaproveita o cliente canônico existente (Ana) e alinha as ocorrências
  r := pg_temp.do_('owner', format('select public.rg_recurring_link_customer(%L::uuid, null, %L::jsonb)', v_s, '{"name":"Ana W1","phone":"+55 (41) 99999-1111"}'));
  select count(*) into v_occ from public.reservations where recurring_reservation_id = v_s and customer_id = pg_temp.k('cuA');
  perform pg_temp.ok('X12 W1 herda a regra canônica: +55 reaproveita o cliente existente; ocorrências NULL -> cliente da série passam pela proteção',
    (r->>'changed')::boolean and (r->>'customer_id')::uuid = pg_temp.k('cuA') and v_occ = cardinality(v_dates) and v_occ > 0
    and (select customer_id from public.recurring_reservations where id = v_s) = pg_temp.k('cuA'), r::text);
  perform pg_temp.ok('X13 W1: X -> Y continua recusado (RGR01 CUSTOMER_ALREADY_SET); RECEPTIONIST continua sem W1 (42501)',
    pg_temp.st('owner', format('select public.rg_recurring_link_customer(%L::uuid, %L::uuid, null)', v_s, pg_temp.k('cuJ'))) = 'RGR01:CUSTOMER_ALREADY_SET'
    and pg_temp.st('rec', format('select public.rg_recurring_link_customer(%L::uuid, %L::uuid, null)', v_s, pg_temp.k('cuJ'))) = '42501');
  perform pg_temp.ok('X14 troca explícita em ocorrência de série => RGC03',
    pg_temp.st('owner', format('select public.rg_reservation_change_customer(%L::uuid, %L::uuid, %L::uuid)',
      (select id from public.reservations where recurring_reservation_id = v_s limit 1), pg_temp.k('cuJ'), pg_temp.k('cuA'))) = 'RGC03:RECURRING_OCCURRENCE');
  -- rg_recurring_create com dados do cliente: '5541…' reaproveita; telefone inválido => 22023 (nada criado)
  r := pg_temp.do_('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', %s, null, ''21:00'', ''22:00'', %L::date, null, true, 10000, null, false, false, ''{}''::date[])',
                                   gen_random_uuid(), pg_temp.k('a1'), pg_temp.k('c2'), '{"name":"Joao via serie","phone":"5541988880002"}', v_dow, private.rg_today() - 7));
  v_s2 := (r->>'series_id')::uuid;
  select * into v_call from pg_temp.call('owner', format('select public.rg_recurring_create(%L::uuid, %L::uuid, %L::uuid, null, %L::jsonb, ''WEEKLY'', %s, null, ''21:00'', ''22:00'', %L::date, null, true, 10000, null, false, false, ''{}''::date[])',
                                   gen_random_uuid(), pg_temp.k('a1'), pg_temp.k('c3'), '{"name":"Ruim","phone":"99999-9999"}', v_dow, private.rg_today() - 7));
  perform pg_temp.ok('X15 rg_recurring_create herda: 5541… reaproveita o cliente canônico; telefone inválido => 22023 sem criar nada',
    (select customer_id from public.recurring_reservations where id = v_s2) = pg_temp.k('cuJ')
    and v_call.state = '22023:INVALID_PHONE' and not exists (select 1 from public.customers where name = 'Ruim'), v_call.state);
  -- pausa com cancelamento futuro e reagendamento não mexem em customer_id (status) — passam pela proteção
  perform pg_temp.do_('owner', format('select public.rg_recurring_pause(%L::uuid, true)', v_s));
  perform pg_temp.ok('X16 pausa com cancel_future (UPDATE de status das ocorrências) passa pela proteção e mantém customer_id',
    not exists (select 1 from public.reservations where recurring_reservation_id = v_s and customer_id is distinct from pg_temp.k('cuA'))
    and (select status from public.recurring_reservations where id = v_s) = 'PAUSED');
end $$;

-- ----------------------------------------------------------------------------- G: privilégios e fingerprints
do $$ begin
  perform pg_temp.ok('G01 RPCs públicas: EXECUTE só authenticated (resolve_public: só service_role); helpers privados sem papel da API',
    (select bool_and(has_function_privilege('authenticated', f, 'EXECUTE') and not has_function_privilege('anon', f, 'EXECUTE')
                     and not has_function_privilege('service_role', f, 'EXECUTE'))
       from unnest(array['public.rg_customer_resolve(uuid, text, text, text, uuid, text)', 'public.rg_customer_update(uuid, jsonb, timestamptz)',
                         'public.rg_customer_list(uuid, text, text, integer, text, uuid)', 'public.rg_customer_detail(uuid, timestamptz, integer)',
                         'public.rg_reservation_change_customer(uuid, uuid, uuid)']) f)
    and has_function_privilege('service_role', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
    and (select bool_and(not has_function_privilege(r, f, 'EXECUTE'))
           from unnest(array['anon', 'authenticated', 'service_role']) r,
                unnest(array['private.rg_phone_canonical(text)', 'private.rg_phone_valid(text)', 'private.rg_customer_resolve_core(uuid, uuid, text, text, text)',
                             'private.rg_customer_resolve_audited(uuid, uuid, text, text, text, uuid, text)', 'private.rg_protect_reservation_customer()']) f));
  perform pg_temp.ok('G02 RPCs públicas SECURITY DEFINER com search_path vazio, owner postgres',
    (select bool_and(p.prosecdef and p.proconfig = array['search_path=""'] and p.proowner = 'postgres'::regrole)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_customer_resolve', 'rg_customer_resolve_public', 'rg_customer_update', 'rg_customer_list',
                                                   'rg_customer_detail', 'rg_reservation_change_customer')));
  perform pg_temp.ok('G03 helpers B3 trocados com os md5 C2A esperados',
    (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure) = '0e70211cb4d03be0e9925de46a6deeee'
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure) = '5ce683d04fd7bda5a3ec42c18c71de6f');
  perform pg_temp.ok('G04 congelados intactos: 6 RPCs 03B.3A (inclui W1), create/generate B3, D7, tenant, links, 03A, 03C (md5)',
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
    and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_recurring_topup_job(text)'::regprocedure) = '1d3091c712cea7b4bdaa5436c7a4169f');
  perform pg_temp.ok('G05 escrita direta em customers AINDA permitida (M2 fica para depois do app novo)',
    has_table_privilege('authenticated', 'public.customers', 'INSERT') and has_table_privilege('authenticated', 'public.customers', 'UPDATE'));
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
    raise exception 'C2A_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.', v_total - v_fail, v_fail, v_total;
  end if;
  raise notice 'C2A_RESULTS OK — % PASS / 0 FAIL (total %)', v_total, v_total;
end $$;
rollback;
