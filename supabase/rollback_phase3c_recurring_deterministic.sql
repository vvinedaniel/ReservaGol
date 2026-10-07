-- =============================================================================
-- RESERVA GOL — FASE 03C — ROLLBACK da recorrência determinística
-- Desfaz supabase/migration_phase3c_recurring_deterministic.sql:
--   1. desagenda (defensivo) qualquer job 'rg-recurring-topup%' do pg_cron;
--   2. remove trigger de proteção de horário, view, RPCs, procedure e helpers da 03C;
--   3. restaura BYTE A BYTE o corpo original (B3) de private.rg_materialize (md5 8df3f54e…);
--   4. desfaz a troca cirúrgica da auditoria em rg_recurring_create/reschedule/reactivate (md5 originais);
--   5. remove as tabelas de execução e de lacunas (estado operacional derivado; não financeiro).
-- Mantém: a extensão pg_cron (sem jobs) e as ocorrências já materializadas (válidas pela D7).
-- Recusa rodar se os corpos atuais não forem exatamente os da 03C (md5).
-- Uma transação.
-- =============================================================================
begin;

do $$
begin
  if to_regclass('public.recurring_occurrence_gaps') is null
     or to_regprocedure('private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid)') is null then
    raise exception '03C rollback: migration 03C não está aplicada';
  end if;
  if (select md5(p.prosrc) from pg_proc p
       where p.oid = 'private.rg_materialize(public.recurring_reservations, date[], boolean, uuid)'::regprocedure)
     <> '595ee52c3be25bf50ab4b44fb1e5683c'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_create'::regproc) <> '2aae1120c6e600989e6e990f7146c84f'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reschedule'::regproc) <> '520ab107c6b41e853c7f5d440b93fc92'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reactivate'::regproc) <> '2990704afae3823d88d51348df616d66' then
    raise exception '03C rollback: corpo atual difere do corpo 03C esperado (md5) — rollback manual necessário';
  end if;
end $$;

-- 1) Desagenda jobs da 03C (se o pg_cron existir)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname like 'rg-recurring-topup%';
  end if;
end $$;

-- 2) Objetos novos
drop trigger validate_reservation_zz_series_slot on public.reservations;
drop view private.v_recurring_horizon_status;
drop function public.rg_recurring_topup(uuid);
drop function public.rg_recurring_gaps(uuid, uuid);
drop procedure private.rg_recurring_topup_job(text);
drop function private.rg_recurring_topup_batch(integer, uuid[]);
drop function private.rg_recurring_topup_plan(integer, uuid[]);
drop function private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint);
drop function private.rg_topup_candidates(integer, uuid[]);
drop function private.rg_plan_series(uuid, date, date);
drop function private.rg_protect_series_slot();

-- 3) Corpo original B3 de private.rg_materialize (texto idêntico ao de migration_security_b3.sql; CR removido)
do $do$
begin
  execute replace($fn$
create or replace function private.rg_materialize(
  p_series public.recurring_reservations, p_dates date[], p_skip_conflicts boolean, p_uid uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
  v_constraint text;
  v_step integer := 0;
  v_created date[] := '{}';
  v_skipped date[] := '{}';
  v_existing date[] := '{}';
begin
  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    if v_date is null or not private.rg_in_window(v_date) or not private.rg_is_anchor(p_series, v_date) then
      raise exception 'rg: data % não é uma ocorrência válida desta série na janela atual', v_date
        using errcode = '22023';
    end if;
  end loop;

  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    select b.start_at, b.end_at into v_start, v_end
      from private.rg_occurrence_bounds(v_date, p_series.start_time, p_series.end_time) as b;
    begin
      insert into public.reservations (
        organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source,
        notes, price, recurring_reservation_id, occurrence_date, is_exception, created_by)
      values (
        p_series.organization_id, p_series.arena_id, p_series.court_id, p_series.customer_id,
        v_start, v_end, 'CONFIRMED', 'RECORRENTE',
        p_series.notes, p_series.default_price, p_series.id, v_date, false, p_uid);
      v_created := array_append(v_created, v_date);
    exception
      when exclusion_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'reservations_no_overlap' and coalesce(p_skip_conflicts, false) then
          v_skipped := array_append(v_skipped, v_date);
        else
          raise;
        end if;
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'idx_res_series_anchor' then
          v_existing := array_append(v_existing, v_date);
        else
          raise;
        end if;
    end;
    v_step := v_step + 1;
    perform private.rg_fault('materialize:' || v_step);
  end loop;

  return jsonb_build_object(
    'created', to_jsonb(v_created), 'skipped', to_jsonb(v_skipped), 'existing', to_jsonb(v_existing));
end $$;
$fn$, chr(13), '');
end $do$;

do $$
begin
  if (select md5(p.prosrc) from pg_proc p
       where p.oid = 'private.rg_materialize(public.recurring_reservations, date[], boolean, uuid)'::regprocedure)
     <> '8df3f54e9b70d82a568e02bd5eeb7e9d' then
    raise exception '03C rollback: rg_materialize restaurado difere do corpo B3 original (md5)';
  end if;
end $$;

-- 4) Desfaz a troca cirúrgica da auditoria nas RPCs B3 e confere os md5 originais
do $do$
declare
  v_fn regprocedure;
  v_def text;
  v_orig constant text := $s$'existing', jsonb_array_length(v_mat->'existing')));$s$;
  v_03c constant text := $s$'existing', jsonb_array_length(v_mat->'existing'),$s$ || chr(10)
                         || $s$      'gaps', coalesce(v_mat->'gaps', '[]'::jsonb)));$s$;
begin
  foreach v_fn in array array['public.rg_recurring_create'::regproc::regprocedure,
                              'public.rg_recurring_reschedule'::regproc::regprocedure,
                              'public.rg_recurring_reactivate'::regproc::regprocedure] loop
    select pg_get_functiondef(v_fn) into v_def;
    if (length(v_def) - length(replace(v_def, v_03c, ''))) / length(v_03c) <> 1 then
      raise exception '03C rollback: trecho 03C não encontrado exatamente uma vez em %', v_fn;
    end if;
    execute replace(v_def, v_03c, v_orig);
  end loop;
  if (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_create'::regproc) <> '66c035d0faca110ea05a87ac7ac39b92'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reschedule'::regproc) <> '66b3acc3796bf27781e81c3916225466'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reactivate'::regproc) <> '972fdf38c696cb07b44c9e9ce052ba32' then
    raise exception '03C rollback: RPC B3 restaurada difere do corpo original (md5)';
  end if;
end $do$;

-- 5) Helpers restantes (sem uso após a restauração) e tabelas
drop function private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid);
drop function private.rg_gap_open(public.recurring_reservations, date, text, uuid, text, uuid, uuid);
drop function private.rg_gap_resolve(uuid, date, text);
drop function private.rg_conflicting_reservation(uuid, timestamptz, timestamptz);
drop function private.rg_occurrence_blocker(public.recurring_reservations, date);
drop function private.rg_fits_business_hours(uuid, date, time, time);
drop function private.rg_topup_lock_key();
drop function private.rg_materialization_horizon();
drop table public.recurring_occurrence_gaps;
drop table public.recurring_generation_run_series;
drop table public.recurring_generation_runs;
drop index public.idx_recurring_court_active;

commit;
