-- =============================================================================
-- RESERVA GOL — CLIENTES C2D — classificação da busca de clientes (nome × telefone)
-- Incremental sobre migration_customers_c2a_identity.sql (aplicar DEPOIS dela). NÃO edita a migration C2A.
--
-- Defeito: public.rg_customer_list usava o modo TELEFONE sempre que a consulta tivesse >= 4 dígitos em
--   qualquer lugar — "Cliente 008" / "C2C Cliente 008" (4 dígitos no total) virava busca por telefone e
--   não achava nada.
-- Correção: modo telefone SOMENTE quando a consulta INTEIRA tem formato de telefone (^\+?[0-9 ().-]+$) E
--   pelo menos 4 dígitos; caso contrário, a busca por nome já existente (lower(name) LIKE, com escape).
--   v_q já é btrim(coalesce(p_q, '')) — a consulta inteira, sem espaços nas pontas.
-- Inalterados: assinatura, owner, ACL/grants, SECURITY DEFINER, search_path = '', volatilidade (STABLE),
--   checagens de autenticação/vínculo/gestor (fin_flag), filtros, ordenação, cursor, limites, o modo
--   telefone em si (com/sem 55), a regra canônica de identidade, o tratamento de acentos (lower()).
--   Nenhuma escrita. Nada da 03B.3 / 03C é tocado.
--
-- Troca cirúrgica (exatamente uma ocorrência) sobre pg_get_functiondef. md5 do corpo (CR normalizado)
-- conferido antes (corpo C2A) e depois (corpo C2D); atributos conferidos na mesma transação.
-- Reaplicar => recusa (md5 já é o do C2D). Rollback: supabase/rollback_customers_c2d_search.sql.
-- =============================================================================
begin;
do $c2d$
declare
  v_fn regprocedure := 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure;
  v_expect_before constant text := 'fb743a428ead37ca1fbccf8011eb8032';
  v_expect_after constant text := '335bcf83465140e02b3fd6a69e1a6028';
  v_needle constant text := $s$if length(v_digits) >= 4 then$s$;
  v_repl constant text := $s$if length(v_digits) >= 4 and v_q ~ '^\+?[0-9 ().-]+$' then$s$;
  v_def text;
  v_before record;
  v_after record;
begin
  select md5(replace(p.prosrc, chr(13), '')) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
         p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    into v_before from pg_proc p where p.oid = v_fn;
  if v_before.body <> v_expect_before then
    raise exception 'C2D: % difere do corpo C2A esperado (md5 % <> %)', v_fn, v_before.body, v_expect_before;
  end if;

  v_def := pg_get_functiondef(v_fn);
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'C2D: trecho esperado não encontrado exatamente uma vez em %', v_fn;
  end if;
  execute replace(v_def, v_needle, v_repl);

  select md5(replace(p.prosrc, chr(13), '')) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
         p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    into v_after from pg_proc p where p.oid = v_fn;
  if v_after.body <> v_expect_after then
    raise exception 'C2D: % resultou em corpo inesperado (md5 % <> %)', v_fn, v_after.body, v_expect_after;
  end if;
  if row(v_after.proowner, v_after.acl, v_after.prosecdef, v_after.cfg, v_after.provolatile, v_after.prokind, v_after.args, v_after.prorettype)
     is distinct from row(v_before.proowner, v_before.acl, v_before.prosecdef, v_before.cfg, v_before.provolatile, v_before.prokind, v_before.args, v_before.prorettype) then
    raise exception 'C2D: atributos de % mudaram (owner/ACL/definer/search_path/volatilidade/assinatura)', v_fn;
  end if;
end $c2d$;

commit;
