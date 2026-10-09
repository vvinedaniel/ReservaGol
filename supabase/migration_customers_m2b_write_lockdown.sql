-- =============================================================================
-- RESERVA GOL — CLIENTES M2-B — bloqueio de escritas diretas em public.customers
-- Aplicar DEPOIS de migration_customers_c2a_identity.sql e migration_customers_c2d_search.sql.
--
-- Única alteração: REVOKE INSERT, UPDATE ON TABLE public.customers FROM authenticated;
--   Todas as escritas legítimas já passam por RPCs SECURITY DEFINER (owner postgres, search_path vazio):
--   rg_customer_resolve / rg_customer_resolve_public / rg_customer_update / rg_recurring_create /
--   rg_recurring_link_customer (via helpers privados) — inalteradas. SELECT e MAINTAIN de authenticated ficam.
--   Nada de funções, triggers, RLS (policies de INSERT/UPDATE ficam, apenas sem efeito), índices,
--   constraints ou dados. Contratos 03B.3 / 03C conferidos por fingerprint e intocados.
--
-- Preflight (recusa sem alterar nada): C2A + C2D aplicados; ACL exata da tabela; nenhuma ACL por coluna;
--   authenticated sem papéis herdados e pg_write_all_data sem membros; RPCs com atributos/grants esperados;
--   helpers privados sem EXECUTE para papéis da API; fingerprints congelados.
-- Postflight: ACL exata pós-M2-B; privilégios EFETIVOS (has_table_privilege, inclui herança) — só
--   authenticated (e quem herdava SOMENTE dele) perde INSERT/UPDATE; ninguém ganha; anon segue sem nada;
--   service_role inalterado; dados intactos (contagem + md5).
-- Reaplicar => recusa (ACL já não é a de antes). Rollback: supabase/rollback_customers_m2b_write_lockdown.sql.
-- =============================================================================
begin;
do $m2b$
declare
  c_acl_before constant text := '{postgres=arwdDxtm/postgres,authenticated=arwm/postgres,service_role=arwdDxtm/postgres}';
  c_acl_after  constant text := '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}';
  v_acl text;
  v_writers_before text[];
  v_writers_after text[];
  v_removed text[];
  v_allowed_removed text[];
  v_data_before text;
  v_data_after text;
  v_svc_before text;
  v_svc_after text;
begin
  -- ------------------------------------------------------------------ preflight: dependências C2A + C2D
  if to_regprocedure('public.rg_customer_resolve(uuid, text, text, text, uuid, text)') is null
     or to_regprocedure('public.rg_customer_resolve_public(uuid, uuid, text, text, text)') is null
     or to_regprocedure('public.rg_customer_update(uuid, jsonb, timestamptz)') is null
     or to_regprocedure('public.rg_customer_list(uuid, text, text, integer, text, uuid)') is null
     or to_regprocedure('public.rg_customer_detail(uuid, timestamptz, integer)') is null
     or to_regprocedure('public.rg_reservation_change_customer(uuid, uuid, uuid)') is null then
    raise exception 'M2-B: migration C2A não aplicada';
  end if;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure)
     <> '335bcf83465140e02b3fd6a69e1a6028' then
    raise exception 'M2-B: migration C2D não aplicada (rg_customer_list com corpo inesperado)';
  end if;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure) <> '0e70211cb4d03be0e9925de46a6deeee'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure) <> '5ce683d04fd7bda5a3ec42c18c71de6f' then
    raise exception 'M2-B: helpers B3 de cliente com corpo diferente do C2A';
  end if;

  -- ------------------------------------------------------------------ preflight: permissões da tabela
  select relacl::text into v_acl from pg_class where oid = 'public.customers'::regclass;
  if v_acl is distinct from c_acl_before then
    raise exception 'M2-B: ACL de public.customers diferente da esperada (% <> %)', v_acl, c_acl_before;
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.customers'::regclass and attnum > 0 and not attisdropped and attacl is not null) then
    raise exception 'M2-B: public.customers tem ACL por coluna — revogação de tabela não bastaria';
  end if;
  if exists (select 1 from pg_auth_members a join pg_roles m on m.oid = a.member where m.rolname = 'authenticated') then
    raise exception 'M2-B: authenticated é membro de outro papel (privilégio herdado possível)';
  end if;
  if exists (select 1 from pg_auth_members a join pg_roles r on r.oid = a.roleid where r.rolname = 'pg_write_all_data') then
    raise exception 'M2-B: pg_write_all_data tem membros (escrita fora das RPCs possível)';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.customers'::regclass) then
    raise exception 'M2-B: RLS desligada em public.customers';
  end if;

  -- ------------------------------------------------------------------ preflight: RPCs (atributos e grants)
  if (select count(*) from pg_proc p
       where p.oid in ('public.rg_customer_resolve(uuid, text, text, text, uuid, text)'::regprocedure,
                       'public.rg_customer_resolve_public(uuid, uuid, text, text, text)'::regprocedure,
                       'public.rg_customer_update(uuid, jsonb, timestamptz)'::regprocedure,
                       'public.rg_reservation_change_customer(uuid, uuid, uuid)'::regprocedure,
                       'public.rg_recurring_create(uuid, uuid, uuid, uuid, jsonb, text, integer, integer, time, time, date, date, boolean, integer, text, boolean, boolean, date[])'::regprocedure,
                       'public.rg_recurring_link_customer(uuid, uuid, jsonb)'::regprocedure)
         and p.prosecdef and p.proowner = 'postgres'::regrole and p.proconfig = array['search_path=""']) <> 6 then
    raise exception 'M2-B: RPC de escrita de cliente sem SECURITY DEFINER/owner postgres/search_path vazio';
  end if;
  if not (has_function_privilege('authenticated', 'public.rg_customer_resolve(uuid, text, text, text, uuid, text)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.rg_customer_update(uuid, jsonb, timestamptz)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.rg_reservation_change_customer(uuid, uuid, uuid)', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.rg_recurring_create(uuid, uuid, uuid, uuid, jsonb, text, integer, integer, time, time, date, date, boolean, integer, text, boolean, boolean, date[])', 'EXECUTE')
          and has_function_privilege('authenticated', 'public.rg_recurring_link_customer(uuid, uuid, jsonb)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.rg_customer_resolve_public(uuid, uuid, text, text, text)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.rg_customer_resolve(uuid, text, text, text, uuid, text)', 'EXECUTE')) then
    raise exception 'M2-B: grants das RPCs de cliente diferentes do esperado';
  end if;
  if exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r,
                           unnest(array['private.rg_customer_resolve_core(uuid, uuid, text, text, text)',
                                        'private.rg_customer_resolve_audited(uuid, uuid, text, text, text, uuid, text)',
                                        'private.rg_resolve_customer(uuid, uuid, jsonb)', 'private.rg_customer_request(uuid, jsonb)']) f
              where has_function_privilege(r, f, 'EXECUTE')) then
    raise exception 'M2-B: helper privado de cliente executável por papel da API';
  end if;

  -- ------------------------------------------------------------------ preflight: contratos congelados 03B.3 / 03C
  if (select string_agg(md5(replace(p.prosrc, chr(13), '')), ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search', 'rg_recurring_month_detail',
             'rg_recurring_month_payment_record', 'rg_recurring_link_customer', 'rg_recurring_month_apply_series_price'))
     <> 'ef638d905dcf0ae4072e7c601172e57b,dfbe684f4f49f5c0c77f14cff70f70bb,099860fb4081811b4ff6823dfeac937c,8061cb47215e805fa0eed28295c13078,fbeeaf4bc38f93fa6481b1daff3e0f13,a1c0277a18f9a5146e370a8c5684aa4e'
     or (select string_agg(x.k || '=' || md5(replace(p.prosrc, chr(13), '')), ',' order by x.k)
           from (values ('a', 'public.rg_recurring_create'), ('b', 'public.rg_recurring_generate'), ('c', 'private.enforce_recurring_occurrence'),
                        ('d', 'private.enforce_reservation_tenant'), ('e', 'private.protect_structural_links'), ('f', 'private.rg_fin_reservation_rows'),
                        ('g', 'public.rg_payment_register'), ('h', 'private.rg_materialize_ex'), ('i', 'private.rg_topup_series'),
                        ('j', 'private.rg_recurring_topup_batch'), ('k', 'private.rg_plan_series'), ('l', 'private.rg_protect_series_slot'),
                        ('m', 'public.rg_fin_overview'), ('n', 'public.rg_fin_receivables')) x(k, f)
           join pg_proc p on p.oid = x.f::regproc)
     <> 'a=2aae1120c6e600989e6e990f7146c84f,b=76efe0f4059d4a0e1c9908ec2dd6ea08,c=abc31e62476fce8231504ac6ab08426e,d=802aaffab18c9cd364e9deb7da860480,e=c50be816b59dcf74bfb2d17d85435496,f=0b1659ed026745a6718ecdd722925d8a,g=459e7a1f05c22110d2f0e23f543e4a70,h=586cbc97b0f1a840aed77bd885c7ae43,i=61cf25332b9c329c67bbff2540895ed4,j=0f8080e661045f943a24297424fe3744,k=ff9d1a1caf9e031a01db42f1b805a13c,l=3b58975cd02c50293a8e1ccb77724537,m=6a0cba0c41ff8ed9f6703ca26172a27d,n=fc3e8e1ac2d5e56af0580c6d7363bc64'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_recurring_topup_job(text)'::regprocedure) <> '1d3091c712cea7b4bdaa5436c7a4169f' then
    raise exception 'M2-B: contrato congelado 03B.3/03C com fingerprint diferente';
  end if;

  -- ------------------------------------------------------------------ estado antes (efetivo, com herança) + dados
  select array_agg(rolname order by rolname) into v_writers_before from pg_roles
   where has_table_privilege(oid, 'public.customers', 'INSERT') or has_table_privilege(oid, 'public.customers', 'UPDATE');
  select string_agg(p || '=' || has_table_privilege('service_role', 'public.customers', p)::text, ',' order by p) into v_svc_before
    from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p;
  select count(*) || '/' || coalesce(md5(string_agg(c::text, ',' order by c.id)), '') into v_data_before from public.customers c;

  -- ------------------------------------------------------------------ a ÚNICA alteração
  revoke insert, update on table public.customers from authenticated;

  -- ------------------------------------------------------------------ postflight
  select relacl::text into v_acl from pg_class where oid = 'public.customers'::regclass;
  if v_acl is distinct from c_acl_after then
    raise exception 'M2-B: ACL resultante inesperada (% <> %)', v_acl, c_acl_after;
  end if;
  if has_table_privilege('authenticated', 'public.customers', 'INSERT') or has_table_privilege('authenticated', 'public.customers', 'UPDATE')
     or has_table_privilege('authenticated', 'public.customers', 'DELETE') or not has_table_privilege('authenticated', 'public.customers', 'SELECT')
     or has_any_column_privilege('authenticated', 'public.customers', 'INSERT') or has_any_column_privilege('authenticated', 'public.customers', 'UPDATE') then
    raise exception 'M2-B: privilégios efetivos de authenticated inesperados após o REVOKE';
  end if;
  if has_table_privilege('anon', 'public.customers', 'SELECT') or has_table_privilege('anon', 'public.customers', 'INSERT')
     or has_table_privilege('anon', 'public.customers', 'UPDATE') or has_table_privilege('anon', 'public.customers', 'DELETE') then
    raise exception 'M2-B: anon com privilégio em public.customers';
  end if;
  select array_agg(rolname order by rolname) into v_writers_after from pg_roles
   where has_table_privilege(oid, 'public.customers', 'INSERT') or has_table_privilege(oid, 'public.customers', 'UPDATE');
  if exists (select 1 from unnest(v_writers_after) w where w <> all (v_writers_before)) then
    raise exception 'M2-B: algum papel GANHOU escrita em public.customers';
  end if;
  select array_agg(w) into v_removed from unnest(v_writers_before) w where w <> all (coalesce(v_writers_after, '{}'));
  select array_agg(m.rolname) || array['authenticated'] into v_allowed_removed
    from pg_auth_members a join pg_roles r on r.oid = a.roleid join pg_roles m on m.oid = a.member
   where r.rolname = 'authenticated' and a.inherit_option;
  if not ('authenticated' = any (v_removed)) or exists (select 1 from unnest(v_removed) w where w <> all (v_allowed_removed)) then
    raise exception 'M2-B: papéis que perderam escrita fora do esperado: %', v_removed;
  end if;
  select string_agg(p || '=' || has_table_privilege('service_role', 'public.customers', p)::text, ',' order by p) into v_svc_after
    from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p;
  if v_svc_after is distinct from v_svc_before then
    raise exception 'M2-B: privilégios de service_role mudaram';
  end if;
  select count(*) || '/' || coalesce(md5(string_agg(c::text, ',' order by c.id)), '') into v_data_after from public.customers c;
  if v_data_after is distinct from v_data_before then
    raise exception 'M2-B: dados de public.customers mudaram';
  end if;
  raise notice 'M2-B aplicada: escrita efetiva antes=% depois=% (removidos=%)', v_writers_before, v_writers_after, v_removed;
end $m2b$;

commit;
