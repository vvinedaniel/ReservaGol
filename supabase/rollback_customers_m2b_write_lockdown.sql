-- =============================================================================
-- RESERVA GOL — CLIENTES M2-B — ROLLBACK do bloqueio de escritas diretas em public.customers
-- Só age se a ACL atual for EXATAMENTE a deixada pela M2-B (e sem ACL por coluna); qualquer outro estado =>
-- recusa sem alterar nada. Restaura SOMENTE INSERT, UPDATE para authenticated e confere que a ACL e os
-- privilégios efetivos voltaram ao estado anterior à M2-B. Nada de funções, triggers, RLS ou dados.
-- =============================================================================
begin;
do $m2b_rb$
declare
  c_acl_m2b      constant text := '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}';
  c_acl_restored constant text := '{postgres=arwdDxtm/postgres,authenticated=arwm/postgres,service_role=arwdDxtm/postgres}';
  v_acl text;
  v_data_before text;
  v_data_after text;
  v_svc_before text;
  v_svc_after text;
begin
  select relacl::text into v_acl from pg_class where oid = 'public.customers'::regclass;
  if v_acl is distinct from c_acl_m2b then
    raise exception 'M2-B rollback: ACL de public.customers não é a da M2-B (% <> %) — nada alterado', v_acl, c_acl_m2b;
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.customers'::regclass and attnum > 0 and not attisdropped and attacl is not null) then
    raise exception 'M2-B rollback: ACL por coluna inesperada em public.customers — nada alterado';
  end if;
  if has_table_privilege('authenticated', 'public.customers', 'INSERT') or has_table_privilege('authenticated', 'public.customers', 'UPDATE') then
    raise exception 'M2-B rollback: authenticated já escreve em public.customers — nada alterado';
  end if;
  select string_agg(p || '=' || has_table_privilege('service_role', 'public.customers', p)::text, ',' order by p) into v_svc_before
    from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p;
  select count(*) || '/' || coalesce(md5(string_agg(c::text, ',' order by c.id)), '') into v_data_before from public.customers c;

  grant insert, update on table public.customers to authenticated;

  select relacl::text into v_acl from pg_class where oid = 'public.customers'::regclass;
  if v_acl is distinct from c_acl_restored then
    raise exception 'M2-B rollback: ACL restaurada inesperada (% <> %)', v_acl, c_acl_restored;
  end if;
  if not (has_table_privilege('authenticated', 'public.customers', 'INSERT') and has_table_privilege('authenticated', 'public.customers', 'UPDATE')
          and has_table_privilege('authenticated', 'public.customers', 'SELECT'))
     or has_table_privilege('authenticated', 'public.customers', 'DELETE')
     or has_table_privilege('anon', 'public.customers', 'SELECT') or has_table_privilege('anon', 'public.customers', 'INSERT') then
    raise exception 'M2-B rollback: privilégios efetivos restaurados inesperados';
  end if;
  select string_agg(p || '=' || has_table_privilege('service_role', 'public.customers', p)::text, ',' order by p) into v_svc_after
    from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p;
  if v_svc_after is distinct from v_svc_before then
    raise exception 'M2-B rollback: privilégios de service_role mudaram';
  end if;
  select count(*) || '/' || coalesce(md5(string_agg(c::text, ',' order by c.id)), '') into v_data_after from public.customers c;
  if v_data_after is distinct from v_data_before then
    raise exception 'M2-B rollback: dados de public.customers mudaram';
  end if;
end $m2b_rb$;

commit;
