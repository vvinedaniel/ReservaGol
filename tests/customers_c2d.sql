-- =============================================================================
-- RESERVA GOL — CLIENTES C2D — testes SQL da classificação da busca (rg_customer_list)
-- Requer C2A + migration_customers_c2d_search.sql. Banco de TESTE local, nunca Production.
--   psql -U postgres -v ON_ERROR_STOP=1 -f tests/customers_c2d.sql
-- Sucesso: "C2D_RESULTS OK ..." + ROLLBACK explícito. Falha: erro "C2D_RESULTS FAIL ..." (exit != 0). ZERO RESÍDUO.
-- A atributos/fingerprints · N nomes com dígitos · T telefone · I inválidos/acentos · P paginação · O organizações · Z congelados
-- Ciclo migration -> rollback -> reaplicar: tests/customers_c2d_lifecycle.sh
-- =============================================================================
begin;
set local statement_timeout = '120s';
set local lock_timeout = '5s';
create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
do $$ begin
  if session_user <> 'postgres' then raise exception 'c2d: execute como postgres'; end if;
  if to_regprocedure('public.rg_customer_list(uuid, text, text, integer, text, uuid)') is null then
    raise exception 'c2d: migration C2A não aplicada';
  end if;
end $$;
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;
-- executa como membro (JWT simulado no próprio banco: role authenticated + sub), devolve estado e resultado
create function pg_temp.call(p_actor text, p_sql text, out state text, out result jsonb) language plpgsql as $$
declare v_hint text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.k(p_actor), 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql into result;
    state := 'OK';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    state := sqlstate || coalesce(':' || nullif(v_hint, ''), '');
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
-- nomes devolvidos (ordem da RPC) para uma busca
create function pg_temp.names(p_actor text, p_org text, p_q text, p_limit int default 50) returns text language plpgsql as $$
declare v record;
begin
  select * into v from pg_temp.call(p_actor, format('select public.rg_customer_list(%L::uuid, %L, ''ALL'', %s)', pg_temp.k(p_org), p_q, p_limit));
  if v.state <> 'OK' then return 'ERR:' || v.state; end if;
  return coalesce((select string_agg(e->>'name', '|' order by o) from jsonb_array_elements(v.result->'items') with ordinality t(e, o)), '');
end $$;

-- ----------------------------------------------------------------------------- fixtures
do $$
declare
  u_rec uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_org uuid; v_org2 uuid; v_tag text := 'c2d-' || substr(md5(clock_timestamp()::text), 1, 8);
begin
  insert into auth.users (id, email) values (u_rec, v_tag || '-r@reservagol.test'), (u_out, v_tag || '-x@reservagol.test');
  insert into public.organizations (name, is_demo) values ('C2D ' || v_tag, true) returning id into v_org;
  insert into public.organizations (name, is_demo) values ('C2D outra ' || v_tag, true) returning id into v_org2;
  insert into public.organization_members (organization_id, user_id, role, status) values
    (v_org, u_rec, 'RECEPTIONIST', 'ACTIVE'), (v_org2, u_out, 'OWNER', 'ACTIVE');
  insert into fx values ('rec', u_rec), ('out', u_out), ('org', v_org), ('org2', v_org2);
  insert into public.customers (organization_id, name, phone) values
    (v_org, 'Cliente 008', '41988000008'),
    (v_org, 'Cliente 0081', '41988000081'),
    (v_org, 'C2C Cliente 2008', '41988002008'),
    (v_org, 'João 1990', '11999990001'),
    (v_org, 'Sul DDD55', '55999991111'),
    (v_org, 'Árvore Ômega', '41977770001'),
    (v_org, 'Sem Telefone 2024', null),
    (v_org2, 'Cliente 008 Outra Org', '41988000008'),
    (v_org2, 'João 1990 Outra Org', '11999990001');
end $$;

-- ----------------------------------------------------------------------------- A: atributos e fingerprint
do $$ begin
  perform pg_temp.ok('A01 corpo C2D aplicado (md5 335bcf83…, CR normalizado) e trecho de classificação presente uma vez',
    (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure)
      = '335bcf83465140e02b3fd6a69e1a6028'
    and (select (length(prosrc) - length(replace(prosrc, $s$if length(v_digits) >= 4 and v_q ~ '^\+?[0-9 ().-]+$' then$s$, '')))
                / length($s$if length(v_digits) >= 4 and v_q ~ '^\+?[0-9 ().-]+$' then$s$)
           from pg_proc where oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure) = 1);
  perform pg_temp.ok('A02 atributos preservados: SECURITY DEFINER, search_path vazio, STABLE, owner postgres, mesma assinatura',
    (select p.prosecdef and p.proconfig = array['search_path=""'] and p.provolatile = 's' and p.proowner = 'postgres'::regrole
            and pg_get_function_identity_arguments(p.oid) = 'p_org uuid, p_q text, p_filter text, p_limit integer, p_after_name text, p_after_id uuid'
            and p.prorettype = 'jsonb'::regtype
       from pg_proc p where p.oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure));
  perform pg_temp.ok('A03 grants preservados: EXECUTE só authenticated (anon/service_role/PUBLIC sem)',
    has_function_privilege('authenticated', 'public.rg_customer_list(uuid, text, text, integer, text, uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.rg_customer_list(uuid, text, text, integer, text, uuid)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.rg_customer_list(uuid, text, text, integer, text, uuid)', 'EXECUTE')
    and not exists (select 1 from information_schema.routine_privileges
                     where routine_schema = 'public' and routine_name = 'rg_customer_list' and grantee = 'PUBLIC'));
end $$;

-- ----------------------------------------------------------------------------- N: nomes com dígitos (o defeito)
do $$ begin
  perform pg_temp.ok('N01 "Cliente 008" (4 dígitos no total) => busca por NOME: Cliente 008 e Cliente 0081, nada da outra org',
    pg_temp.names('rec', 'org', 'Cliente 008') = 'Cliente 008|Cliente 0081', pg_temp.names('rec', 'org', 'Cliente 008'));
  perform pg_temp.ok('N02 "C2C Cliente 2008" => nome', pg_temp.names('rec', 'org', 'C2C Cliente 2008') = 'C2C Cliente 2008');
  perform pg_temp.ok('N03 "joão 1990" (minúsculas, acento, 4 dígitos) => nome', pg_temp.names('rec', 'org', 'joão 1990') = 'João 1990');
  perform pg_temp.ok('N04 "Sem Telefone 2024" => nome (cliente sem telefone é encontrado)', pg_temp.names('rec', 'org', 'Sem Telefone 2024') = 'Sem Telefone 2024');
  perform pg_temp.ok('N05 poucos dígitos "008" (3) => nome contém 008 (inclui "C2C Cliente 2008")',
    pg_temp.names('rec', 'org', '008') = 'C2C Cliente 2008|Cliente 008|Cliente 0081', pg_temp.names('rec', 'org', '008'));
end $$;

-- ----------------------------------------------------------------------------- T: telefone (preservado)
do $$ begin
  perform pg_temp.ok('T01 telefone formatado "(41) 98800-0008" => telefone', pg_temp.names('rec', 'org', '(41) 98800-0008') = 'Cliente 008');
  perform pg_temp.ok('T02 telefone sem formatação "41988000008" => telefone', pg_temp.names('rec', 'org', '41988000008') = 'Cliente 008');
  perform pg_temp.ok('T03 prefixo +55 "+55 41 98800-0008" => telefone (13 dígitos, 55 removido)', pg_temp.names('rec', 'org', '+55 41 98800-0008') = 'Cliente 008');
  perform pg_temp.ok('T04 "5541988000008" (sem +) => telefone, 55 removido', pg_temp.names('rec', 'org', '5541988000008') = 'Cliente 008');
  perform pg_temp.ok('T05 DDD 55 legítimo "(55) 99999-1111" (11 dígitos) => telefone, 55 mantido', pg_temp.names('rec', 'org', '(55) 99999-1111') = 'Sul DDD55');
  perform pg_temp.ok('T06 trecho "0008" (4 dígitos) => telefone contém', pg_temp.names('rec', 'org', '0008') = 'Cliente 008|Cliente 0081', pg_temp.names('rec', 'org', '0008'));
  perform pg_temp.ok('T07 pontos "41.98800.0008" e espaços nas pontas => telefone', pg_temp.names('rec', 'org', '  41.98800.0008  ') = 'Cliente 008');
end $$;

-- ----------------------------------------------------------------------------- I: caracteres inválidos e acentos
do $$ begin
  perform pg_temp.ok('I01 "41#98800" (caractere fora do formato) => nome, sem erro e sem resultado', pg_temp.names('rec', 'org', '41#98800') = '');
  perform pg_temp.ok('I02 "+1 202 555 0100" tem formato de telefone => telefone, sem resultado (estrangeiro não existe)', pg_temp.names('rec', 'org', '+1 202 555 0100') = '');
  perform pg_temp.ok('I03 curingas "%" e "_" são literais (nada expande)', pg_temp.names('rec', 'org', '%') = '' and pg_temp.names('rec', 'org', '_') = '');
  perform pg_temp.ok('I04 acentos como antes: "árvore" encontra; "arvore" (sem acento) não', pg_temp.names('rec', 'org', 'árvore') = 'Árvore Ômega' and pg_temp.names('rec', 'org', 'arvore') = '');
  perform pg_temp.ok('I05 "Ana 4199" (nome + dígitos) => nome (sem resultado), sem erro', pg_temp.names('rec', 'org', 'Ana 4199') = '');
end $$;

-- ----------------------------------------------------------------------------- P: paginação por cursor com nome numérico
do $$
declare v jsonb; v_names text := ''; v_after_name text; v_after_id uuid; i int := 0;
begin
  loop
    select result into v from pg_temp.call('rec', format('select public.rg_customer_list(%L::uuid, %L, ''ALL'', 1, %L, %L::uuid)',
      pg_temp.k('org'), 'cliente 0', v_after_name, v_after_id));
    v_names := v_names || coalesce((select string_agg(e->>'name', '|') from jsonb_array_elements(v->'items') e), '') || ';';
    exit when v->'next_cursor' = 'null'::jsonb or i > 5;
    v_after_name := v->'next_cursor'->>'after_name'; v_after_id := (v->'next_cursor'->>'after_id')::uuid; i := i + 1;
  end loop;
  perform pg_temp.ok('P01 "cliente 0" (nome) com limite 1: cursor percorre as 2 páginas em ordem, sem repetir', v_names = 'Cliente 008;Cliente 0081;', v_names);
end $$;

-- ----------------------------------------------------------------------------- O: isolamento entre organizações
do $$ begin
  perform pg_temp.ok('O01 recepção da org A na org B => 42501 (vínculo checado antes da busca)',
    (pg_temp.call('rec', format('select public.rg_customer_list(%L::uuid, %L, ''ALL'', 10)', pg_temp.k('org2'), 'Cliente 008'))).state = '42501');
  perform pg_temp.ok('O02 membro da org B vê só a B, por nome e por telefone',
    pg_temp.names('out', 'org2', 'Cliente 008') = 'Cliente 008 Outra Org' and pg_temp.names('out', 'org2', '(41) 98800-0008') = 'Cliente 008 Outra Org'
    and pg_temp.names('out', 'org2', 'joão 1990') = 'João 1990 Outra Org');
end $$;

-- ----------------------------------------------------------------------------- Z: congelados 03B.3 / 03C intactos
do $$ begin
  perform pg_temp.ok('Z01 congelados intactos: 6 RPCs 03B.3A, create/generate B3, D7, tenant, links, 03A, 03C (md5, mesmo conjunto do G04 C2A)',
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
  perform pg_temp.ok('Z02 demais RPCs C2A inalteradas pelo C2D (detail/resolve/update/troca: SECURITY DEFINER + search_path vazio)',
    (select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('rg_customer_detail', 'rg_customer_resolve', 'rg_customer_update', 'rg_reservation_change_customer')));
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
    raise exception 'C2D_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.', v_total - v_fail, v_fail, v_total;
  end if;
  raise notice 'C2D_RESULTS OK — % PASS / 0 FAIL (total %)', v_total, v_total;
end $$;
rollback;
