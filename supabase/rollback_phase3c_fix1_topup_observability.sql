-- =============================================================================
-- RESERVA GOL — FASE 03C · FIX 1 — ROLLBACK
-- Restaura BYTE A BYTE os corpos 03C de private.rg_topup_series (md5 f07b11be…) e
-- private.rg_recurring_topup_batch (md5 1f498809…), desfazendo a troca cirúrgica do FIX 1.
-- Recusa rodar se os corpos atuais não forem exatamente os do FIX 1. Owner/ACL/atributos preservados (conferido).
-- Não toca em dados (auditorias e runs já gravados permanecem como estão).
-- =============================================================================
begin;

do $fix1rb$
declare
  v_fn regprocedure;
  v_def text;
  v_before record;
  v_after record;
  v_pairs text[];
  v_needle text;
  v_repl text;
  v_expect_before text;
  v_expect_after text;
begin
  for v_i in 1..2 loop
    if v_i = 1 then
      v_fn := 'private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint)'::regprocedure;
      v_expect_before := '61cf25332b9c329c67bbff2540895ed4';
      v_expect_after := 'f07b11bea91e2371f24ece2b567c47ce';
      v_pairs := array[
        $s$'already_count', v_already,$s$,
        $s$'already_count', v_already - v_created,$s$];
    else
      v_fn := 'private.rg_recurring_topup_batch(integer, uuid[])'::regprocedure;
      v_expect_before := '0f8080e661045f943a24297424fe3744';
      v_expect_after := '1f49880999f467cb726644675bd5b59d';
      v_pairs := array[
        $s$insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date, series_filter, started_at)$s$ || chr(10)
          || $s$  values ('MANUAL', 'SYSTEM_OPERATOR', v_horizon, private.rg_today() + v_horizon, p_series, clock_timestamp())$s$,
        $s$insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date, series_filter)$s$ || chr(10)
          || $s$  values ('MANUAL', 'SYSTEM_OPERATOR', v_horizon, private.rg_today() + v_horizon, p_series)$s$,
        $s$set status = v_status, finished_at = clock_timestamp(), counts$s$,
        $s$set status = v_status, finished_at = now(), counts$s$];
    end if;

    select md5(p.prosrc) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
           p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
      into v_before from pg_proc p where p.oid = v_fn;
    if v_before.body <> v_expect_before then
      raise exception 'FIX1 rollback: % difere do corpo FIX 1 esperado (md5 % <> %) — rollback manual necessário', v_fn, v_before.body, v_expect_before;
    end if;

    select pg_get_functiondef(v_fn) into v_def;
    for v_i2 in 1..(cardinality(v_pairs) / 2) loop
      v_needle := v_pairs[2 * v_i2 - 1];
      v_repl := v_pairs[2 * v_i2];
      if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
        raise exception 'FIX1 rollback: trecho esperado não encontrado exatamente uma vez em %: %', v_fn, v_needle;
      end if;
      v_def := replace(v_def, v_needle, v_repl);
    end loop;
    execute v_def;

    select md5(p.prosrc) as body, p.proowner, p.proacl::text as acl, p.prosecdef, p.proconfig::text as cfg,
           p.provolatile, p.prokind, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
      into v_after from pg_proc p where p.oid = v_fn;
    if v_after.body <> v_expect_after then
      raise exception 'FIX1 rollback: % restaurado difere do corpo 03C (md5 % <> %)', v_fn, v_after.body, v_expect_after;
    end if;
    if row(v_after.proowner, v_after.acl, v_after.prosecdef, v_after.cfg, v_after.provolatile, v_after.prokind, v_after.args, v_after.prorettype)
       is distinct from row(v_before.proowner, v_before.acl, v_before.prosecdef, v_before.cfg, v_before.provolatile, v_before.prokind, v_before.args, v_before.prorettype) then
      raise exception 'FIX1 rollback: atributos de % mudaram', v_fn;
    end if;
  end loop;
end $fix1rb$;

commit;
