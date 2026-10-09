-- =============================================================================
-- RESERVA GOL — CLIENTES C2D — ROLLBACK da classificação da busca
-- Restaura o corpo C2A de public.rg_customer_list. Só age se o corpo atual for EXATAMENTE o do C2D
-- (md5 com CR normalizado); qualquer outro corpo => recusa sem alterar nada. Atributos (owner, ACL,
-- SECURITY DEFINER, search_path, volatilidade, assinatura) conferidos na mesma transação.
-- =============================================================================
begin;
do $c2d_rb$
declare
  v_fn regprocedure := 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure;
  v_expect_current constant text := '335bcf83465140e02b3fd6a69e1a6028';
  v_expect_restored constant text := 'fb743a428ead37ca1fbccf8011eb8032';
  v_needle constant text := $s$if length(v_digits) >= 4 and v_q ~ '^\+?[0-9 ().-]+$' then$s$;
  v_repl constant text := $s$if length(v_digits) >= 4 then$s$;
  v_def text;
  v_before record;
  v_after record;
begin
  select md5(replace(p.prosrc, chr(13), '')) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
         p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    into v_before from pg_proc p where p.oid = v_fn;
  if v_before.body <> v_expect_current then
    raise exception 'C2D rollback: % não está com o corpo C2D (md5 % <> %) — nada alterado', v_fn, v_before.body, v_expect_current;
  end if;

  v_def := pg_get_functiondef(v_fn);
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'C2D rollback: trecho C2D não encontrado exatamente uma vez em %', v_fn;
  end if;
  execute replace(v_def, v_needle, v_repl);

  select md5(replace(p.prosrc, chr(13), '')) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
         p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    into v_after from pg_proc p where p.oid = v_fn;
  if v_after.body <> v_expect_restored then
    raise exception 'C2D rollback: % restaurado com corpo inesperado (md5 % <> %)', v_fn, v_after.body, v_expect_restored;
  end if;
  if row(v_after.proowner, v_after.acl, v_after.prosecdef, v_after.cfg, v_after.provolatile, v_after.prokind, v_after.args, v_after.prorettype)
     is distinct from row(v_before.proowner, v_before.acl, v_before.prosecdef, v_before.cfg, v_before.provolatile, v_before.prokind, v_before.args, v_before.prorettype) then
    raise exception 'C2D rollback: atributos de % mudaram', v_fn;
  end if;
end $c2d_rb$;

commit;
