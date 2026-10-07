-- =============================================================================
-- RESERVA GOL — FASE 03C · FIX 1 — observabilidade do top-up (G3C-2A)
-- Incremental sobre migration_phase3c_recurring_deterministic.sql (já aplicada). NÃO altera regra de negócio.
--
-- Bug 1 — auditoria RECURRING_OCCURRENCES_GENERATED: 'already_count' gravava v_already - v_created, mas
--   v_already é contado ANTES da materialização (linhas da série com occurrence_date em [hoje, horizonte]),
--   ou seja, já representa só as ocorrências pré-existentes. Correção: gravar v_already.
--   (private.rg_topup_series — usada pelo job, pelo lote do operador e por public.rg_recurring_topup)
-- Bug 2 — private.rg_recurring_topup_batch: o run era aberto com started_at = now() (default) e fechado com
--   finished_at = now(); numa função transacional now() é o início da transação => duração sempre 0.
--   Correção: started_at/finished_at do run do lote usam clock_timestamp() (relógio real).
--   Inalterados: SKIPPED_CONCURRENT, ABORTED de órfãos, o JOB (procedure com COMMIT por série) e o default da coluna.
--
-- Troca cirúrgica (exatamente uma ocorrência de cada trecho) sobre pg_get_functiondef: assinatura, owner,
-- ACL, SECURITY DEFINER, search_path e todo o resto do corpo ficam idênticos (conferido dentro da transação).
-- md5 conferido antes (corpo 03C) e depois (corpo FIX 1). Reaplicar => recusa (md5 já é o do FIX 1).
-- Rollback: supabase/rollback_phase3c_fix1_topup_observability.sql.
-- =============================================================================
begin;

do $fix1$
declare
  v_fn regprocedure;
  v_def text;
  v_before record;
  v_after record;
  v_pairs text[];
  v_i int;
  v_needle text;
  v_repl text;
  v_expect_before text;
  v_expect_after text;
begin
  for v_i in 1..2 loop
    if v_i = 1 then
      v_fn := 'private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)'::regprocedure;
      v_expect_before := 'f07b11bea91e2371f24ece2b567c47ce';
      v_expect_after := '61cf25332b9c329c67bbff2540895ed4';
      v_pairs := array[
        $s$'already_count', v_already - v_created,$s$,
        $s$'already_count', v_already,$s$];
    else
      v_fn := 'private.rg_recurring_topup_batch(integer, uuid[])'::regprocedure;
      v_expect_before := '1f49880999f467cb726644675bd5b59d';
      v_expect_after := '0f8080e661045f943a24297424fe3744';
      v_pairs := array[
        $s$insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date, series_filter)$s$ || chr(10)
          || $s$  values ('MANUAL', 'SYSTEM_OPERATOR', v_horizon, private.rg_today() + v_horizon, p_series)$s$,
        $s$insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date, series_filter, started_at)$s$ || chr(10)
          || $s$  values ('MANUAL', 'SYSTEM_OPERATOR', v_horizon, private.rg_today() + v_horizon, p_series, clock_timestamp())$s$,
        $s$set status = v_status, finished_at = now(), counts$s$,
        $s$set status = v_status, finished_at = clock_timestamp(), counts$s$];
    end if;

    select md5(p.prosrc) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
           p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
      into v_before from pg_proc p where p.oid = v_fn;
    if v_before.body <> v_expect_before then
      raise exception 'FIX1: % difere do corpo 03C esperado (md5 % <> %)', v_fn, v_before.body, v_expect_before;
    end if;

    select pg_get_functiondef(v_fn) into v_def;
    for v_i2 in 1..(cardinality(v_pairs) / 2) loop
      v_needle := v_pairs[2 * v_i2 - 1];
      v_repl := v_pairs[2 * v_i2];
      if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
        raise exception 'FIX1: trecho esperado não encontrado exatamente uma vez em %: %', v_fn, v_needle;
      end if;
      v_def := replace(v_def, v_needle, v_repl);
    end loop;
    execute v_def;

    select md5(p.prosrc) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
           p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
      into v_after from pg_proc p where p.oid = v_fn;
    if v_after.body <> v_expect_after then
      raise exception 'FIX1: % resultou em corpo inesperado (md5 % <> %)', v_fn, v_after.body, v_expect_after;
    end if;
    if row(v_after.proowner, v_after.acl, v_after.prosecdef, v_after.cfg, v_after.provolatile, v_after.prokind, v_after.args, v_after.prorettype)
       is distinct from row(v_before.proowner, v_before.acl, v_before.prosecdef, v_before.cfg, v_before.provolatile, v_before.prokind, v_before.args, v_before.prorettype) then
      raise exception 'FIX1: atributos de % mudaram (owner/ACL/definer/search_path/assinatura)', v_fn;
    end if;
  end loop;
end $fix1$;

commit;
