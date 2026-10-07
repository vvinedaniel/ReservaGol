-- =============================================================================
-- RESERVA GOL — FASE 03C — RECORRÊNCIA DETERMINÍSTICA (banco)
-- Contrato: Freeze funcional + técnico 03C aprovado (D1–D9, ajustes 1–8) e G0 (desenho transacional A).
--
-- Objetivo: materialização determinística, explícita e auditada; leituras sem efeito colateral;
-- proteção estrutural dos horários de séries ACTIVE; nenhuma ocorrência esperada some em silêncio.
--
-- Cria:
--   tabelas  public.recurring_generation_runs         (uma linha por execução do job/lote; retenção 90 d)
--            public.recurring_generation_run_series   (resultado por série quando != NOOP; retenção 90 d)
--            public.recurring_occurrence_gaps         (ESTADO: data esperada e não materializada; nunca purgada aberta)
--   helpers  private.rg_materialization_horizon / rg_fits_business_hours / rg_occurrence_blocker /
--            rg_conflicting_reservation / rg_gap_open / rg_gap_resolve / rg_materialize_ex /
--            rg_plan_series / rg_topup_series / rg_topup_candidates
--   dry-run  private.rg_recurring_topup_plan       (STABLE, sem escrita; só postgres)
--   manual   private.rg_recurring_topup_batch      (função transacional; operador SQL; SYSTEM_OPERATOR/MANUAL)
--   job      private.rg_recurring_topup_job        (PROCEDURE, SECURITY INVOKER, sem SET, COMMIT por série; pg_cron)
--   RPCs     public.rg_recurring_topup (OWNER/MANAGER) · public.rg_recurring_gaps (OWNER/MANAGER, leitura)
--   trigger  validate_reservation_zz_series_slot (BEFORE INSERT/UPDATE em reservations, todo papel)
--   view     private.v_recurring_horizon_status (observabilidade do operador)
--   extensão pg_cron (SEM nenhum cron.schedule)
-- Altera (objetos existentes):
--   private.rg_materialize  -> passa a delegar à autoridade única rg_materialize_ex (horário de
--                              funcionamento + quadra ativa + lacunas persistidas; janela 90 inalterada).
--                              Corpo original restaurado byte a byte pelo rollback (md5 conferido).
--   public.rg_recurring_create / rg_recurring_reschedule / rg_recurring_reactivate
--                           -> auditoria ganha a chave 'gaps' (aditivo, troca cirúrgica de UM trecho;
--                              md5 conferido antes; rollback desfaz e confere o md5 original).
-- Preserva: 03B.3A inteira; assinaturas públicas da B3; rg_in_window (90); janelas de 90 do JS e da
--   reserva pública; D7 (enforce_recurring_occurrence); reservations_no_overlap; ledger financeiro.
--
-- Disciplina (G0): a PROCEDURE do job é SECURITY INVOKER, sem cláusula SET, com TODO objeto qualificado
-- por schema, sem SQL dinâmico, laço sobre array, COMMIT fora de bloco EXCEPTION; a unidade por série
-- captura as próprias exceções e reaplica lock_timeout a cada transação. Toda rotina interna é revogada
-- de public/anon/authenticated/service_role (rotina nova nasce executável por PUBLIC).
--
-- Uma transação. Sem IF NOT EXISTS nos objetos novos: reaplicar => 42710 antes de qualquer efeito.
-- Rollback: supabase/rollback_phase3c_recurring_deterministic.sql.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 0) Dependências
-- -----------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.recurring_reservations') is null or to_regclass('public.reservations') is null
     or to_regclass('public.business_hours') is null or to_regclass('public.courts') is null
     or to_regclass('public.audit_logs') is null or to_regclass('public.organization_members') is null
     or to_regclass('public.idx_res_series_anchor') is null
     or to_regprocedure('private.rg_materialize(public.recurring_reservations, date[], boolean, uuid)') is null
     or to_regprocedure('private.rg_is_anchor(public.recurring_reservations, date)') is null
     or to_regprocedure('private.rg_occurrence_bounds(date, time, time)') is null
     or to_regprocedure('private.rg_today()') is null
     or to_regprocedure('private.rg_in_window(date)') is null
     or to_regprocedure('private.rg_fault(text)') is null
     or to_regprocedure('private.rg_exp_is_manager(uuid, uuid)') is null
     or to_regprocedure('public.rg_recurring_month_detail(uuid, date)') is null
     or not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise exception '03C: dependência ausente (B3 / 03B.3A / pg_cron disponível)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1) Preflight de colisão: TODOS os objetos novos, nominalmente
-- -----------------------------------------------------------------------------
do $$
declare
  v_found text[] := '{}';
  v_name text;
begin
  foreach v_name in array array['public.recurring_generation_runs', 'public.recurring_generation_run_series',
      'public.recurring_occurrence_gaps', 'private.v_recurring_horizon_status',
      'public.idx_rog_open_series_date', 'public.idx_rog_org_open', 'public.idx_rog_series',
      'public.idx_rgr_started', 'public.idx_rgrs_series', 'public.idx_recurring_court_active'] loop
    if to_regclass(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  select v_found || coalesce(array_agg(distinct n.nspname || '.' || p.proname || '(*)'), '{}') into v_found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname = 'public' and p.proname in ('rg_recurring_topup', 'rg_recurring_gaps'))
      or (n.nspname = 'private' and p.proname in ('rg_materialization_horizon', 'rg_fits_business_hours',
            'rg_occurrence_blocker', 'rg_conflicting_reservation', 'rg_gap_open', 'rg_gap_resolve',
            'rg_materialize_ex', 'rg_plan_series', 'rg_topup_series', 'rg_topup_candidates',
            'rg_recurring_topup_plan', 'rg_recurring_topup_batch', 'rg_recurring_topup_job',
            'rg_protect_series_slot', 'rg_topup_lock_key'));
  if exists (select 1 from pg_trigger where tgrelid = 'public.reservations'::regclass
              and tgname = 'validate_reservation_zz_series_slot') then
    v_found := array_append(v_found, 'trigger validate_reservation_zz_series_slot');
  end if;
  if cardinality(v_found) > 0 then
    raise exception '03C: objeto de destino já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;
end $$;

-- Corpos esperados das funções existentes que serão alteradas (depois da colisão: reaplicar => 42710)
do $$
begin
  if (select md5(p.prosrc) from pg_proc p
       where p.oid = 'private.rg_materialize(public.recurring_reservations, date[], boolean, uuid)'::regprocedure)
     <> '8df3f54e9b70d82a568e02bd5eeb7e9d' then
    raise exception '03C: private.rg_materialize difere do corpo B3 esperado (md5)';
  end if;
  if (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_create'::regproc) <> '66c035d0faca110ea05a87ac7ac39b92'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reschedule'::regproc) <> '66b3acc3796bf27781e81c3916225466'
     or (select md5(p.prosrc) from pg_proc p where p.oid = 'public.rg_recurring_reactivate'::regproc) <> '972fdf38c696cb07b44c9e9ce052ba32' then
    raise exception '03C: RPC B3 (create/reschedule/reactivate) difere do corpo esperado (md5)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2) Extensão do agendador (NENHUM job é agendado por esta migration)
-- -----------------------------------------------------------------------------
create extension if not exists pg_cron;

-- -----------------------------------------------------------------------------
-- 3) Tabelas (RLS ligada, sem políticas, sem grants: leitura só por RPC/operador)
-- -----------------------------------------------------------------------------
-- Uma linha por execução do job (CRON) ou do lote do operador (MANUAL). Histórico técnico: 90 dias.
create table public.recurring_generation_runs (
  id uuid not null default gen_random_uuid(),
  origin text not null,
  actor text not null,
  status text not null default 'RUNNING',
  horizon_days integer not null,
  horizon_date date not null,
  series_filter uuid[],
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  counts jsonb not null default '{}'::jsonb,
  constraint recurring_generation_runs_pkey primary key (id),
  constraint recurring_generation_runs_origin_chk check (origin in ('CRON', 'MANUAL')),
  constraint recurring_generation_runs_actor_chk check (
    (origin = 'CRON' and actor = 'SYSTEM') or (origin = 'MANUAL' and actor = 'SYSTEM_OPERATOR')),
  constraint recurring_generation_runs_status_chk check (
    status in ('RUNNING', 'SUCCEEDED', 'PARTIAL', 'FAILED', 'ABORTED', 'SKIPPED_CONCURRENT')),
  constraint recurring_generation_runs_finished_chk check ((status = 'RUNNING') = (finished_at is null))
);

-- Resultado de UMA série numa execução (gravado só quando != NOOP ou quando lacunas mudaram).
create table public.recurring_generation_run_series (
  run_id uuid not null,
  series_id uuid not null,
  attempt smallint not null default 1,
  organization_id uuid not null,
  outcome text not null,
  created_count integer not null default 0,
  gaps_changed boolean not null default false,
  sqlstate text,
  created_at timestamptz not null default now(),
  constraint recurring_generation_run_series_pkey primary key (run_id, series_id, attempt),
  constraint recurring_generation_run_series_run_fkey foreign key (run_id)
    references public.recurring_generation_runs (id) on delete cascade,
  -- SEM FK para a série: o registro de uma série ADIADA não pode depender de lock na linha da série
  -- (FK => FOR KEY SHARE, bloqueado pelo FOR UPDATE de quem a trava). Limpeza por organização/retenção.
  constraint recurring_generation_run_series_outcome_chk check (
    outcome in ('CREATED', 'NOOP', 'DEFERRED_LOCKED', 'ERROR', 'SKIPPED_NOT_ACTIVE')),
  constraint recurring_generation_run_series_attempt_chk check (attempt in (1, 2))
);

-- ESTADO operacional: uma ocorrência esperada (âncora de série ACTIVE dentro do horizonte) que NÃO
-- foi materializada. Aberta até resolução válida; nunca apagada por retenção enquanto aberta.
create table public.recurring_occurrence_gaps (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  arena_id uuid not null,
  court_id uuid not null,
  series_id uuid not null,
  occurrence_date date not null,
  reason text not null,
  conflict_reservation_id uuid,
  origin text not null,
  opened_by uuid,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_run_id uuid,
  resolved_at timestamptz,
  resolution text,
  constraint recurring_occurrence_gaps_pkey primary key (id),
  constraint recurring_occurrence_gaps_series_fkey foreign key (series_id)
    references public.recurring_reservations (id) on delete cascade,
  constraint recurring_occurrence_gaps_conflict_fkey foreign key (conflict_reservation_id)
    references public.reservations (id) on delete set null,
  constraint recurring_occurrence_gaps_run_fkey foreign key (last_run_id)
    references public.recurring_generation_runs (id) on delete set null,
  constraint recurring_occurrence_gaps_reason_chk check (reason in ('CONFLICT', 'OUTSIDE_BUSINESS_HOURS', 'COURT_INACTIVE')),
  constraint recurring_occurrence_gaps_origin_chk check (origin in ('CRON', 'MANUAL', 'SERIES_ACTION')),
  constraint recurring_occurrence_gaps_conflict_chk check (reason = 'CONFLICT' or conflict_reservation_id is null),
  constraint recurring_occurrence_gaps_resolution_chk check (
    resolution is null or resolution in ('MATERIALIZED', 'DATE_PASSED', 'SERIES_NOT_ACTIVE', 'NOT_ANCHOR_ANYMORE')),
  constraint recurring_occurrence_gaps_resolved_chk check ((resolved_at is null) = (resolution is null))
);

create unique index idx_rog_open_series_date on public.recurring_occurrence_gaps (series_id, occurrence_date)
  where resolved_at is null;
create index idx_rog_org_open on public.recurring_occurrence_gaps (organization_id, occurrence_date)
  where resolved_at is null;
create index idx_rog_series on public.recurring_occurrence_gaps (series_id);
create index idx_rgr_started on public.recurring_generation_runs (started_at desc);
create index idx_rgrs_series on public.recurring_generation_run_series (series_id, created_at desc);
-- Trigger de proteção: séries ACTIVE por quadra
create index idx_recurring_court_active on public.recurring_reservations (court_id) where status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- 4) Helpers (autoridade única de horário / quadra / conflito / lacuna)
-- -----------------------------------------------------------------------------
create function private.rg_materialization_horizon()
returns integer language sql immutable set search_path = '' as $$ select 120 $$;

-- Chave do advisory lock global do job/lote (constante; uma só fonte).
create function private.rg_topup_lock_key()
returns bigint language sql immutable set search_path = '' as $$ select 7303120120::bigint $$;

-- Espelho EXATO de route.js previewOccurrences (lib/reserva/time.js):
--   sem linha / closed / open|close nulos => fechado;
--   início = HH*60+MM; fim = idem, +1440 se fim <= início (cruza meia-noite);
--   fecha 00:00 => 1440; cabe se início >= abertura e fim <= fechamento. Dia da semana 0=domingo.
create function private.rg_fits_business_hours(p_arena uuid, p_date date, p_start time, p_end time)
returns boolean language sql stable set search_path = '' as $$
  with t as (
    select (extract(hour from p_start)::int * 60 + extract(minute from p_start)::int) as s,
           (extract(hour from p_end)::int * 60 + extract(minute from p_end)::int) as e0)
  select coalesce((
    select not bh.closed and bh.open_time is not null and bh.close_time is not null
       and t.s >= (extract(hour from bh.open_time)::int * 60 + extract(minute from bh.open_time)::int)
       and (case when t.e0 <= t.s then t.e0 + 1440 else t.e0 end)
           <= (case when (extract(hour from bh.close_time)::int * 60 + extract(minute from bh.close_time)::int) = 0
                    then 1440
                    else extract(hour from bh.close_time)::int * 60 + extract(minute from bh.close_time)::int end)
      from public.business_hours bh
     where bh.arena_id = p_arena and bh.weekday = extract(dow from p_date)::int), false)
    from t
$$;

-- Motivo que IMPEDE materializar uma âncora (NULL = pode tentar inserir).
create function private.rg_occurrence_blocker(p_series public.recurring_reservations, p_date date)
returns text language sql stable set search_path = '' as $$
  select case
    when not coalesce((select c.active from public.courts c where c.id = p_series.court_id), false) then 'COURT_INACTIVE'
    when not private.rg_fits_business_hours(p_series.arena_id, p_date, p_series.start_time, p_series.end_time)
      then 'OUTSIDE_BUSINESS_HOURS'
    else null end
$$;

-- Reserva ATIVA (mesmo conjunto de reservations_no_overlap) que ocupa o intervalo na quadra.
create function private.rg_conflicting_reservation(p_court uuid, p_start timestamptz, p_end timestamptz)
returns uuid language sql stable set search_path = '' as $$
  select r.id from public.reservations r
   where r.court_id = p_court and r.status in ('PENDING', 'CONFIRMED', 'PAID', 'BLOCKED')
     and tstzrange(r.start_at, r.end_at) && tstzrange(p_start, p_end)
   order by r.start_at, r.id limit 1
$$;

-- Abre/atualiza a lacuna aberta de (série, data). Devolve true se ABRIU ou MUDOU (motivo/conflito).
create function private.rg_gap_open(p_series public.recurring_reservations, p_date date, p_reason text,
                                    p_conflict uuid, p_origin text, p_run_id uuid, p_uid uuid)
returns boolean language plpgsql set search_path = '' as $$
declare
  v_gap public.recurring_occurrence_gaps;
begin
  select g.* into v_gap from public.recurring_occurrence_gaps g
   where g.series_id = p_series.id and g.occurrence_date = p_date and g.resolved_at is null for update;
  if not found then
    insert into public.recurring_occurrence_gaps (organization_id, arena_id, court_id, series_id, occurrence_date,
      reason, conflict_reservation_id, origin, opened_by, last_run_id)
    values (p_series.organization_id, p_series.arena_id, p_series.court_id, p_series.id, p_date,
      p_reason, case when p_reason = 'CONFLICT' then p_conflict end, p_origin, p_uid, p_run_id);
    return true;
  end if;
  update public.recurring_occurrence_gaps g
     set last_seen_at = now(), last_run_id = coalesce(p_run_id, g.last_run_id),
         reason = p_reason, conflict_reservation_id = case when p_reason = 'CONFLICT' then p_conflict end
   where g.id = v_gap.id;
  return v_gap.reason is distinct from p_reason
      or v_gap.conflict_reservation_id is distinct from (case when p_reason = 'CONFLICT' then p_conflict end);
end $$;

create function private.rg_gap_resolve(p_series_id uuid, p_date date, p_resolution text)
returns integer language sql volatile set search_path = '' as $$
  with u as (
    update public.recurring_occurrence_gaps g set resolved_at = now(), resolution = p_resolution
     where g.series_id = p_series_id and g.occurrence_date = p_date and g.resolved_at is null
    returning 1)
  select count(*)::integer from u
$$;

-- AUTORIDADE ÚNICA de materialização (ações B3, geração manual e job).
--   Valida TODAS as datas antes (âncora real, [hoje, p_max_date]) => 22023, como a B3.
--   Por data: existente -> 'existing' (resolve lacuna); quadra inativa / fora do horário -> lacuna
--   (não insere); INSERT; conflito (reservations_no_overlap): skip => lacuna CONFLICT + 'skipped',
--   senão propaga (D3 da B3). Nada some em silêncio.
create function private.rg_materialize_ex(
  p_series public.recurring_reservations, p_dates date[], p_skip_conflicts boolean, p_uid uuid,
  p_max_date date, p_origin text, p_run_id uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
  v_constraint text;
  v_reason text;
  v_conflict uuid;
  v_step integer := 0;
  v_created date[] := '{}';
  v_skipped date[] := '{}';
  v_existing date[] := '{}';
  v_gaps jsonb := '[]'::jsonb;
  v_changed boolean := false;
begin
  if p_origin is null or p_origin not in ('CRON', 'MANUAL', 'SERIES_ACTION') then
    raise exception 'rg: origem de materialização inválida' using errcode = '22023';
  end if;
  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    if v_date is null or v_date < private.rg_today() or v_date > p_max_date
       or not private.rg_is_anchor(p_series, v_date) then
      raise exception 'rg: data % não é uma ocorrência válida desta série na janela atual', v_date
        using errcode = '22023';
    end if;
  end loop;

  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    if exists (select 1 from public.reservations r
                where r.recurring_reservation_id = p_series.id and r.occurrence_date = v_date) then
      v_existing := array_append(v_existing, v_date);
      v_changed := (private.rg_gap_resolve(p_series.id, v_date, 'MATERIALIZED') > 0) or v_changed;
    else
      v_reason := private.rg_occurrence_blocker(p_series, v_date);
      if v_reason is not null then
        v_changed := private.rg_gap_open(p_series, v_date, v_reason, null, p_origin, p_run_id, p_uid) or v_changed;
        v_gaps := v_gaps || jsonb_build_object('date', v_date, 'reason', v_reason);
      else
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
          v_changed := (private.rg_gap_resolve(p_series.id, v_date, 'MATERIALIZED') > 0) or v_changed;
        exception
          when exclusion_violation then
            get stacked diagnostics v_constraint = constraint_name;
            if v_constraint = 'reservations_no_overlap' and coalesce(p_skip_conflicts, false) then
              v_conflict := private.rg_conflicting_reservation(p_series.court_id, v_start, v_end);
              v_skipped := array_append(v_skipped, v_date);
              v_changed := private.rg_gap_open(p_series, v_date, 'CONFLICT', v_conflict, p_origin, p_run_id, p_uid) or v_changed;
              v_gaps := v_gaps || jsonb_build_object('date', v_date, 'reason', 'CONFLICT',
                                                     'conflict_reservation_id', v_conflict);
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
      end if;
    end if;
    v_step := v_step + 1;
    perform private.rg_fault('materialize:' || v_step);
  end loop;

  return jsonb_build_object(
    'created', to_jsonb(v_created), 'skipped', to_jsonb(v_skipped), 'existing', to_jsonb(v_existing),
    'gaps', v_gaps, 'gaps_changed', v_changed);
end $$;

-- -----------------------------------------------------------------------------
-- 5) rg_materialize (B3): mesmo contrato e janela de 90; delega à autoridade única.
--    (corpo com CR removido => md5 determinístico independente do checkout)
-- -----------------------------------------------------------------------------
do $do$
begin
  execute replace($fn$
create or replace function private.rg_materialize(
  p_series public.recurring_reservations, p_dates date[], p_skip_conflicts boolean, p_uid uuid)
returns jsonb language plpgsql set search_path = '' as $$
begin
  -- 03C: autoridade única (horário de funcionamento, quadra ativa, lacunas). Janela B3 inalterada (90).
  return private.rg_materialize_ex(p_series, p_dates, p_skip_conflicts, p_uid,
                                   private.rg_today() + 90, 'SERIES_ACTION', null);
end $$$fn$, chr(13), '');
end $do$;

-- -----------------------------------------------------------------------------
-- 6) Auditoria das ações B3 ganha 'gaps' (troca cirúrgica de UM trecho idêntico nas três RPCs)
-- -----------------------------------------------------------------------------
do $do$
declare
  v_fn regprocedure;
  v_def text;
  v_needle constant text := $s$'existing', jsonb_array_length(v_mat->'existing')));$s$;
  v_repl constant text := $s$'existing', jsonb_array_length(v_mat->'existing'),$s$ || chr(10)
                          || $s$      'gaps', coalesce(v_mat->'gaps', '[]'::jsonb)));$s$;
begin
  foreach v_fn in array array['public.rg_recurring_create'::regproc::regprocedure,
                              'public.rg_recurring_reschedule'::regproc::regprocedure,
                              'public.rg_recurring_reactivate'::regproc::regprocedure] loop
    select pg_get_functiondef(v_fn) into v_def;
    if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
      raise exception '03C: trecho de auditoria esperado não encontrado exatamente uma vez em %', v_fn;
    end if;
    execute replace(v_def, v_needle, v_repl);
  end loop;
end $do$;

-- -----------------------------------------------------------------------------
-- 7) Planejador (puro) — base do dry-run
-- -----------------------------------------------------------------------------
-- Classifica cada âncora de UMA série em [p_from, p_to] (limitado a start_date/end_date e a hoje):
-- ALREADY_MATERIALIZED | COURT_INACTIVE | OUTSIDE_BUSINESS_HOURS | CONFLICT | CREATE.
create function private.rg_plan_series(p_series_id uuid, p_from date, p_to date)
returns table (occurrence_date date, start_at timestamptz, end_at timestamptz, classification text,
               conflict_reservation_id uuid)
language plpgsql stable set search_path = '' as $$
declare
  v_s public.recurring_reservations;
  v_d date;
  v_from date;
  v_to date;
  v_reason text;
begin
  select s.* into v_s from public.recurring_reservations s where s.id = p_series_id;
  if not found then return; end if;
  v_from := greatest(p_from, v_s.start_date, private.rg_today());
  v_to := case when v_s.has_no_end_date or v_s.end_date is null then p_to else least(p_to, v_s.end_date) end;
  if v_from > v_to then return; end if;
  for v_d in select g::date from generate_series(v_from, v_to, interval '1 day') g loop
    -- 03C fix 1: pré-filtro exato (WEEKLY/BIWEEKLY exigem o dia da semana; MONTHLY o dia do mês); NULL não descarta
    continue when (case v_s.frequency when 'MONTHLY' then extract(day from v_d)::int = v_s.day_of_month
                                      else extract(dow from v_d)::int = v_s.weekday end) is false;
    continue when not private.rg_is_anchor(v_s, v_d);
    select b.start_at, b.end_at into start_at, end_at
      from private.rg_occurrence_bounds(v_d, v_s.start_time, v_s.end_time) b;
    occurrence_date := v_d;
    conflict_reservation_id := null;
    if exists (select 1 from public.reservations r where r.recurring_reservation_id = v_s.id and r.occurrence_date = v_d) then
      classification := 'ALREADY_MATERIALIZED';
    else
      v_reason := private.rg_occurrence_blocker(v_s, v_d);
      if v_reason is not null then
        classification := v_reason;
      else
        conflict_reservation_id := private.rg_conflicting_reservation(v_s.court_id, start_at, end_at);
        classification := case when conflict_reservation_id is null then 'CREATE' else 'CONFLICT' end;
      end if;
    end if;
    return next;
  end loop;
end $$;

-- Séries que PODEM ter trabalho (sem lock): ACTIVE com âncora sem linha na janela, ou com lacuna aberta
-- (inclui não-ACTIVE com lacuna aberta, para resolver SERIES_NOT_ACTIVE). Ordem determinística por id.
create function private.rg_topup_candidates(p_horizon integer, p_series uuid[])
returns uuid[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(s.id order by s.id), '{}')
    from public.recurring_reservations s
   where (p_series is null or s.id = any(p_series))
     and ((s.status = 'ACTIVE' and exists (
             select 1 from generate_series(greatest(private.rg_today(), s.start_date),
                                           case when s.has_no_end_date or s.end_date is null
                                                then private.rg_today() + p_horizon
                                                else least(private.rg_today() + p_horizon, s.end_date) end,
                                           interval '1 day') g
              where (case s.frequency when 'MONTHLY' then extract(day from g)::int = s.day_of_month else extract(dow from g)::int = s.weekday end) is not false   -- 03C fix 1: pré-filtro exato (só descarta não-âncoras)
                and private.rg_is_anchor(s, g::date)
                and not exists (select 1 from public.reservations r
                                 where r.recurring_reservation_id = s.id and r.occurrence_date = g::date)))
          or exists (select 1 from public.recurring_occurrence_gaps x where x.series_id = s.id and x.resolved_at is null))
$$;

-- -----------------------------------------------------------------------------
-- 8) Unidade por série (compartilhada por job, lote do operador e RPC do gestor)
-- -----------------------------------------------------------------------------
-- Trava a série (p_wait=false: NOWAIT; true: espera até lock_timeout 5s), resolve lacunas obsoletas,
-- materializa até hoje+p_horizon pela autoridade única e audita SE algo mudou. Captura as próprias
-- exceções (subtransação): DEFERRED_LOCKED / ERROR nunca derrubam o chamador. Grava o resultado por
-- série quando há run_id e o resultado não é NOOP sem mudança.
create function private.rg_topup_series(p_series_id uuid, p_horizon integer, p_origin text, p_actor text,
                                        p_uid uuid, p_run_id uuid, p_wait boolean, p_attempt smallint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_s public.recurring_reservations;
  v_today date := private.rg_today();
  v_to date;
  v_dates date[];
  v_mat jsonb := '{}'::jsonb;
  v_outcome text := 'NOOP';
  v_state text;
  v_org uuid;
  v_resolved integer := 0;
  v_created integer := 0;
  v_changed boolean := false;
  v_already integer := 0;
  v_record_failed boolean := false;
begin
  if p_origin not in ('CRON', 'MANUAL') or p_actor not in ('SYSTEM', 'SYSTEM_OPERATOR', 'USER')
     or p_horizon is null or p_horizon < 1 or p_horizon > private.rg_materialization_horizon() then
    raise exception 'rg: parâmetros de geração inválidos' using errcode = '22023';
  end if;
  v_to := v_today + p_horizon;
  begin
    perform set_config('lock_timeout', '5s', true);
    perform private.rg_fault('topup:' || p_series_id::text);
    if p_wait then
      select s.* into v_s from public.recurring_reservations s where s.id = p_series_id for update;
    else
      select s.* into v_s from public.recurring_reservations s where s.id = p_series_id for update nowait;
    end if;
    if not found then
      v_outcome := 'SKIPPED_NOT_ACTIVE';
    else
      v_org := v_s.organization_id;
      if v_s.status <> 'ACTIVE' then
        with u as (
          update public.recurring_occurrence_gaps g set resolved_at = now(), resolution = 'SERIES_NOT_ACTIVE'
           where g.series_id = v_s.id and g.resolved_at is null returning 1)
        select count(*) into v_resolved from u;
        v_outcome := 'SKIPPED_NOT_ACTIVE';
      else
        with u as (
          update public.recurring_occurrence_gaps g
             set resolved_at = now(),
                 resolution = case
                   when g.occurrence_date < v_today then 'DATE_PASSED'
                   when not private.rg_is_anchor(v_s, g.occurrence_date) then 'NOT_ANCHOR_ANYMORE'
                   else 'MATERIALIZED' end
           where g.series_id = v_s.id and g.resolved_at is null
             and (g.occurrence_date < v_today or not private.rg_is_anchor(v_s, g.occurrence_date)
                  or exists (select 1 from public.reservations r
                              where r.recurring_reservation_id = v_s.id and r.occurrence_date = g.occurrence_date))
          returning 1)
        select count(*) into v_resolved from u;

        select coalesce(array_agg(g::date order by g), '{}') into v_dates
          from generate_series(greatest(v_today, v_s.start_date),
                               case when v_s.has_no_end_date or v_s.end_date is null then v_to
                                    else least(v_to, v_s.end_date) end, interval '1 day') g
         where (case v_s.frequency when 'MONTHLY' then extract(day from g)::int = v_s.day_of_month
                                   else extract(dow from g)::int = v_s.weekday end) is not false   -- 03C fix 1
           and private.rg_is_anchor(v_s, g::date)
           and not exists (select 1 from public.reservations r
                            where r.recurring_reservation_id = v_s.id and r.occurrence_date = g::date);
        select count(*) into v_already from public.reservations r
         where r.recurring_reservation_id = v_s.id and r.occurrence_date between v_today and v_to;

        if cardinality(v_dates) > 0 then
          v_mat := private.rg_materialize_ex(v_s, v_dates, true, p_uid, v_to, p_origin, p_run_id);
          v_created := jsonb_array_length(v_mat->'created');
          v_changed := coalesce((v_mat->>'gaps_changed')::boolean, false);
        end if;
        v_outcome := case when v_created > 0 then 'CREATED' else 'NOOP' end;

        if v_created > 0 or v_changed or v_resolved > 0 then
          insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
          values (v_s.organization_id, p_uid, 'RECURRING_OCCURRENCES_GENERATED', 'recurring_reservation', v_s.id,
            jsonb_build_object(
              'actor', p_actor, 'origin', p_origin, 'run_id', p_run_id,
              'horizon_days', p_horizon, 'horizon_date', v_to,
              'window_from', greatest(v_today, v_s.start_date), 'window_to', v_to,
              'created', coalesce(v_mat->'created', '[]'::jsonb),
              'skipped', coalesce(v_mat->'gaps', '[]'::jsonb),
              'already_count', v_already - v_created,
              'gaps_resolved', v_resolved,
              'counts', jsonb_build_object(
                'created', v_created,
                'conflict', (select count(*) from jsonb_array_elements(coalesce(v_mat->'gaps', '[]'::jsonb)) e where e->>'reason' = 'CONFLICT'),
                'outside_hours', (select count(*) from jsonb_array_elements(coalesce(v_mat->'gaps', '[]'::jsonb)) e where e->>'reason' = 'OUTSIDE_BUSINESS_HOURS'),
                'court_inactive', (select count(*) from jsonb_array_elements(coalesce(v_mat->'gaps', '[]'::jsonb)) e where e->>'reason' = 'COURT_INACTIVE'))));
        end if;
      end if;
    end if;
  exception
    when lock_not_available then
      v_outcome := 'DEFERRED_LOCKED'; v_state := '55P03'; v_created := 0; v_changed := false; v_resolved := 0;
      v_mat := '{}'::jsonb;
    when others then
      v_outcome := 'ERROR'; v_state := sqlstate; v_created := 0; v_changed := false; v_resolved := 0;
      v_mat := '{}'::jsonb;
  end;

  if p_run_id is not null and (v_outcome <> 'NOOP' or v_changed or v_resolved > 0) then
    begin
      insert into public.recurring_generation_run_series (run_id, series_id, attempt, organization_id, outcome,
        created_count, gaps_changed, sqlstate)
      select p_run_id, p_series_id, p_attempt, coalesce(v_org, s.organization_id), v_outcome, v_created,
             v_changed or v_resolved > 0, v_state
        from public.recurring_reservations s where s.id = p_series_id;
    exception when others then
      -- nunca derruba o job e nunca é silencioso: o chamador conta como erro (execução PARTIAL)
      v_record_failed := true;
    end;
  end if;

  return jsonb_build_object('series_id', p_series_id, 'outcome', v_outcome, 'sqlstate', v_state,
    'created', coalesce(v_mat->'created', '[]'::jsonb), 'gaps', coalesce(v_mat->'gaps', '[]'::jsonb),
    'created_count', v_created, 'gaps_changed', v_changed or v_resolved > 0, 'record_failed', v_record_failed);
end $$;

-- -----------------------------------------------------------------------------
-- 9) Dry-run (STABLE: nenhuma escrita). Só postgres/operador.
-- -----------------------------------------------------------------------------
create function private.rg_recurring_topup_plan(p_horizon integer default 120, p_series uuid[] default null)
returns table (organization_id uuid, arena_id uuid, court_id uuid, series_id uuid, series_status text,
               occurrence_date date, classification text, conflict_reservation_id uuid)
language sql stable security definer set search_path = '' as $$
  select s.organization_id, s.arena_id, s.court_id, s.id, s.status, p.occurrence_date, p.classification,
         p.conflict_reservation_id
    from public.recurring_reservations s
   cross join lateral private.rg_plan_series(s.id, private.rg_today(),
                                             private.rg_today() + least(greatest(coalesce(p_horizon, 120), 1),
                                                                        private.rg_materialization_horizon())) p
   where s.status = 'ACTIVE' and (p_series is null or s.id = any(p_series))
  union all
  -- lacunas abertas de séries não-ACTIVE: seriam resolvidas como SERIES_NOT_ACTIVE
  select g.organization_id, g.arena_id, g.court_id, g.series_id, s.status, g.occurrence_date,
         'GAP_RESOLVE_SERIES_NOT_ACTIVE', g.conflict_reservation_id
    from public.recurring_occurrence_gaps g join public.recurring_reservations s on s.id = g.series_id
   where g.resolved_at is null and s.status <> 'ACTIVE' and (p_series is null or s.id = any(p_series))
$$;

-- -----------------------------------------------------------------------------
-- 10) Execução MANUAL do operador (função transacional; atômica por chamada — usar lotes pequenos)
-- -----------------------------------------------------------------------------
create function private.rg_recurring_topup_batch(p_limit integer default 25, p_series uuid[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_horizon integer := private.rg_materialization_horizon();
  v_run uuid;
  v_ids uuid[];
  v_id uuid;
  v_res jsonb;
  v_deferred uuid[] := '{}';
  v_counts jsonb := jsonb_build_object('examined', 0, 'created', 0, 'deferred', 0, 'errors', 0,
                                       'skipped_not_active', 0, 'gaps_changed', 0);
  v_status text;
  v_remaining integer;
begin
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'rg: p_limit deve estar entre 1 e 500' using errcode = '22023';
  end if;
  if not pg_try_advisory_xact_lock(private.rg_topup_lock_key()) then
    insert into public.recurring_generation_runs (origin, actor, status, horizon_days, horizon_date, series_filter, finished_at)
    values ('MANUAL', 'SYSTEM_OPERATOR', 'SKIPPED_CONCURRENT', v_horizon, private.rg_today() + v_horizon, p_series, now())
    returning id into v_run;
    return jsonb_build_object('run_id', v_run, 'status', 'SKIPPED_CONCURRENT');
  end if;
  perform set_config('lock_timeout', '5s', true);
  update public.recurring_generation_runs set status = 'ABORTED', finished_at = now() where status = 'RUNNING';
  insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date, series_filter)
  values ('MANUAL', 'SYSTEM_OPERATOR', v_horizon, private.rg_today() + v_horizon, p_series)
  returning id into v_run;

  v_ids := private.rg_topup_candidates(v_horizon, p_series);
  v_ids := v_ids[1:p_limit];
  foreach v_id in array coalesce(v_ids, '{}') loop
    v_res := private.rg_topup_series(v_id, v_horizon, 'MANUAL', 'SYSTEM_OPERATOR', null, v_run, false, 1::smallint);
    v_counts := jsonb_set(v_counts, '{examined}', to_jsonb((v_counts->>'examined')::int + 1));
    v_counts := jsonb_set(v_counts, '{created}', to_jsonb((v_counts->>'created')::int + (v_res->>'created_count')::int));
    if (v_res->>'gaps_changed')::boolean then
      v_counts := jsonb_set(v_counts, '{gaps_changed}', to_jsonb((v_counts->>'gaps_changed')::int + 1));
    end if;
    case v_res->>'outcome'
      when 'DEFERRED_LOCKED' then v_deferred := v_deferred || v_id;
      when 'ERROR' then v_counts := jsonb_set(v_counts, '{errors}', to_jsonb((v_counts->>'errors')::int + 1));
      when 'SKIPPED_NOT_ACTIVE' then
        v_counts := jsonb_set(v_counts, '{skipped_not_active}', to_jsonb((v_counts->>'skipped_not_active')::int + 1));
      else null;
    end case;
    if (v_res->>'record_failed')::boolean then
      v_counts := jsonb_set(v_counts, '{errors}', to_jsonb((v_counts->>'errors')::int + 1));
    end if;
  end loop;
  foreach v_id in array v_deferred loop
    v_res := private.rg_topup_series(v_id, v_horizon, 'MANUAL', 'SYSTEM_OPERATOR', null, v_run, true, 2::smallint);
    v_counts := jsonb_set(v_counts, '{created}', to_jsonb((v_counts->>'created')::int + (v_res->>'created_count')::int));
    case v_res->>'outcome'
      when 'DEFERRED_LOCKED' then v_counts := jsonb_set(v_counts, '{deferred}', to_jsonb((v_counts->>'deferred')::int + 1));
      when 'ERROR' then v_counts := jsonb_set(v_counts, '{errors}', to_jsonb((v_counts->>'errors')::int + 1));
      else null;
    end case;
    if (v_res->>'record_failed')::boolean then
      v_counts := jsonb_set(v_counts, '{errors}', to_jsonb((v_counts->>'errors')::int + 1));
    end if;
  end loop;
  v_remaining := cardinality(private.rg_topup_candidates(v_horizon, p_series)) ;
  v_status := case when (v_counts->>'errors')::int > 0 or (v_counts->>'deferred')::int > 0 then 'PARTIAL' else 'SUCCEEDED' end;
  update public.recurring_generation_runs
     set status = v_status, finished_at = now(), counts = v_counts || jsonb_build_object('remaining_candidates', v_remaining)
   where id = v_run;
  return jsonb_build_object('run_id', v_run, 'status', v_status, 'counts', v_counts, 'remaining_candidates', v_remaining);
end $$;

-- -----------------------------------------------------------------------------
-- 11) JOB (pg_cron): PROCEDURE — SECURITY INVOKER, SEM cláusula SET, tudo qualificado, COMMIT por série.
--     Comando do cron: exatamente  CALL private.rg_recurring_topup_job('CRON')
-- -----------------------------------------------------------------------------
create procedure private.rg_recurring_topup_job(p_origin text default 'CRON')
language plpgsql as $$
declare
  v_horizon integer := private.rg_materialization_horizon();
  v_actor text;
  v_run uuid;
  v_ids uuid[];
  v_id uuid;
  v_res jsonb;
  v_deferred uuid[] := '{}';
  v_examined integer := 0;
  v_created integer := 0;
  v_errors integer := 0;
  v_still_deferred integer := 0;
  v_not_active integer := 0;
  v_gaps_changed integer := 0;
  v_status text;
begin
  if p_origin is null or p_origin not in ('CRON', 'MANUAL') then
    raise exception 'rg: origem do job inválida' using errcode = '22023';
  end if;
  v_actor := case when p_origin = 'CRON' then 'SYSTEM' else 'SYSTEM_OPERATOR' end;
  if not pg_catalog.pg_try_advisory_lock(private.rg_topup_lock_key()) then
    insert into public.recurring_generation_runs (origin, actor, status, horizon_days, horizon_date, finished_at)
    values (p_origin, v_actor, 'SKIPPED_CONCURRENT', v_horizon, private.rg_today() + v_horizon, pg_catalog.now());
    commit;
    return;
  end if;
  -- Com o lock global na mão, qualquer RUNNING é órfão (sessão anterior caiu).
  update public.recurring_generation_runs set status = 'ABORTED', finished_at = pg_catalog.now() where status = 'RUNNING';
  insert into public.recurring_generation_runs (origin, actor, horizon_days, horizon_date)
  values (p_origin, v_actor, v_horizon, private.rg_today() + v_horizon)
  returning id into v_run;
  commit;

  v_ids := private.rg_topup_candidates(v_horizon, null);
  foreach v_id in array v_ids loop
    -- lock_timeout é por transação: reaplicado AQUI a cada série, depois de cada COMMIT (G0 P7). Medido:
    -- dentro de função com cláusula SET chamada por procedure após COMMIT, o set_config local não arma o timer.
    perform pg_catalog.set_config('lock_timeout', '5s', true);
    v_res := private.rg_topup_series(v_id, v_horizon, p_origin, v_actor, null, v_run, false, 1::smallint);
    v_examined := v_examined + 1;
    v_created := v_created + (v_res->>'created_count')::integer;
    if (v_res->>'gaps_changed')::boolean then v_gaps_changed := v_gaps_changed + 1; end if;
    if v_res->>'outcome' = 'DEFERRED_LOCKED' then v_deferred := v_deferred || v_id;
    elsif v_res->>'outcome' = 'ERROR' then v_errors := v_errors + 1;
    elsif v_res->>'outcome' = 'SKIPPED_NOT_ACTIVE' then v_not_active := v_not_active + 1;
    end if;
    if (v_res->>'record_failed')::boolean then v_errors := v_errors + 1; end if;
    commit;
  end loop;
  -- Segunda passada (espera limitada) para as adiadas.
  foreach v_id in array v_deferred loop
    perform pg_catalog.set_config('lock_timeout', '5s', true);
    v_res := private.rg_topup_series(v_id, v_horizon, p_origin, v_actor, null, v_run, true, 2::smallint);
    v_created := v_created + (v_res->>'created_count')::integer;
    if v_res->>'outcome' = 'DEFERRED_LOCKED' then v_still_deferred := v_still_deferred + 1;
    elsif v_res->>'outcome' = 'ERROR' then v_errors := v_errors + 1;
    end if;
    if (v_res->>'record_failed')::boolean then v_errors := v_errors + 1; end if;
    commit;
  end loop;
  -- Retenção de 90 dias SOMENTE do histórico técnico (lacunas e audit_logs não entram).
  delete from public.recurring_generation_runs
   where started_at < pg_catalog.now() - interval '90 days' and status <> 'RUNNING' and id <> v_run;
  v_status := case when v_errors > 0 or v_still_deferred > 0 then 'PARTIAL' else 'SUCCEEDED' end;
  update public.recurring_generation_runs
     set status = v_status, finished_at = pg_catalog.now(),
         counts = pg_catalog.jsonb_build_object('examined', v_examined, 'created', v_created,
                    'deferred_first_pass', pg_catalog.cardinality(v_deferred), 'deferred', v_still_deferred,
                    'errors', v_errors, 'skipped_not_active', v_not_active, 'gaps_changed', v_gaps_changed)
   where id = v_run;
  commit;
  perform pg_catalog.pg_advisory_unlock(private.rg_topup_lock_key());
end $$;

-- -----------------------------------------------------------------------------
-- 12) RPCs públicas (OWNER/MANAGER com vínculo ATIVO; sem atalho de admin da plataforma)
-- -----------------------------------------------------------------------------
-- "Gerar próximas datas": mesma regra do job até hoje+120, origem MANUAL, usuário real.
create function public.rg_recurring_topup(p_series_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_status text;
  v_res jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select s.organization_id, s.status into v_org, v_status from public.recurring_reservations s where s.id = p_series_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para gerar datas' using errcode = '42501';
  end if;
  if v_status <> 'ACTIVE' then
    raise exception 'rg: a série precisa estar ativa para gerar novas reservas' using errcode = 'RGR01';
  end if;
  v_res := private.rg_topup_series(p_series_id, private.rg_materialization_horizon(), 'MANUAL', 'USER', v_uid,
                                   null, true, 1::smallint);
  if v_res->>'outcome' = 'DEFERRED_LOCKED' then
    raise exception 'rg: mensalista em uso; tente novamente' using errcode = '55P03';
  elsif v_res->>'outcome' = 'ERROR' then
    raise exception 'rg: não foi possível gerar as datas' using errcode = 'RGR03', hint = v_res->>'sqlstate';
  elsif v_res->>'outcome' = 'SKIPPED_NOT_ACTIVE' then
    raise exception 'rg: a série precisa estar ativa para gerar novas reservas' using errcode = 'RGR01';
  end if;
  return jsonb_build_object('series_id', p_series_id, 'outcome', v_res->>'outcome',
    'created', v_res->'created', 'gaps', v_res->'gaps',
    'horizon_date', private.rg_today() + private.rg_materialization_horizon());
end $$;

-- Lacunas abertas (leitura pura). OWNER/MANAGER da organização; opcionalmente de UMA série.
create function public.rg_recurring_gaps(p_org uuid, p_series uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão para ver as lacunas' using errcode = '42501';
  end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', g.id, 'series_id', g.series_id, 'occurrence_date', g.occurrence_date, 'reason', g.reason,
             'origin', g.origin, 'first_seen_at', g.first_seen_at, 'last_seen_at', g.last_seen_at,
             'conflict', case when r.id is null then null else jsonb_build_object(
               'reservation_id', r.id, 'start_at', r.start_at, 'end_at', r.end_at, 'status', r.status,
               'source', r.source, 'recurring', r.recurring_reservation_id is not null) end)
           order by g.occurrence_date, g.series_id)
      from public.recurring_occurrence_gaps g
      left join public.reservations r on r.id = g.conflict_reservation_id
     where g.organization_id = p_org and g.resolved_at is null
       and (p_series is null or g.series_id = p_series)), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- 13) Proteção estrutural do horário de séries ACTIVE (todo papel: rota, pública/service role,
--     PostgREST direto, BLOCKED). Uma reserva não pode ocupar a ocorrência FUTURA ainda não
--     materializada de OUTRA série ACTIVE. INSERT de ocorrência recorrente não passa por aqui
--     (série × série: reservations_no_overlap + lacuna CONFLICT). Erro 23P01 (o app atual já trata
--     como conflito), hint RECURRING_SLOT, sem dado do mensalista.
-- -----------------------------------------------------------------------------
create function private.rg_protect_series_slot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_s public.recurring_reservations;
  v_d date;
  v_from date;
  v_to date;
  v_start timestamptz;
  v_end timestamptz;
  v_dur numeric;
  v_rs numeric;
  v_re numeric;
begin
  if new.status not in ('PENDING', 'CONFIRMED', 'PAID', 'BLOCKED') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.recurring_reservation_id is not null then
      return new;
    end if;
  elsif old.status in ('PENDING', 'CONFIRMED', 'PAID', 'BLOCKED')
        and new.start_at = old.start_at and new.end_at = old.end_at and new.court_id = old.court_id then
    return new;
  end if;
  v_from := (new.start_at at time zone 'America/Sao_Paulo')::date - 1;
  v_to := (new.end_at at time zone 'America/Sao_Paulo')::date;
  -- 03C fix 2: janela do dia (minutos, offset FIXO -03:00 = rg_occurrence_bounds). Reserva [rs, re) e série
  -- [ss, se) (se += 1440 se cruza a meia-noite) só podem se sobrepor em algum dia se houver deslocamento
  -- k em {-1, 0, +1} com rs < se + k*1440 e ss + k*1440 < re (intervalos semiabertos; ambos < 24 h).
  -- Reserva com >= 24 h: sem atalho. O filtro só descarta séries que NÃO podem sobrepor em dia nenhum.
  v_dur := extract(epoch from (new.end_at - new.start_at)) / 60;
  v_rs := extract(epoch from (new.start_at at time zone interval '-03:00')::time) / 60;
  v_re := v_rs + v_dur;
  for v_s in
    select s.* from public.recurring_reservations s
     cross join lateral (
       select (extract(hour from s.start_time) * 60 + extract(minute from s.start_time))::numeric as ss,
              (extract(hour from s.end_time) * 60 + extract(minute from s.end_time)
               + case when extract(hour from s.end_time) * 60 + extract(minute from s.end_time)
                           <= extract(hour from s.start_time) * 60 + extract(minute from s.start_time)
                      then 1440 else 0 end)::numeric as se) m
     where s.court_id = new.court_id and s.status = 'ACTIVE'
       and s.id is distinct from new.recurring_reservation_id
       and s.start_date <= v_to and (s.has_no_end_date or s.end_date is null or s.end_date >= v_from)
       and (v_dur >= 1440
            or (v_rs < m.se - 1440 and m.ss - 1440 < v_re)
            or (v_rs < m.se and m.ss < v_re)
            or (v_rs < m.se + 1440 and m.ss + 1440 < v_re))
     order by s.id
     for share of s
  loop
    for v_d in select g::date from generate_series(greatest(v_from, v_s.start_date), v_to, interval '1 day') g loop
      continue when (case v_s.frequency when 'MONTHLY' then extract(day from v_d)::int = v_s.day_of_month
                                        else extract(dow from v_d)::int = v_s.weekday end) is false;   -- 03C fix 1
      continue when not private.rg_is_anchor(v_s, v_d);
      select b.start_at, b.end_at into v_start, v_end
        from private.rg_occurrence_bounds(v_d, v_s.start_time, v_s.end_time) b;
      if v_end > now() and v_start < new.end_at and v_end > new.start_at
         and not exists (select 1 from public.reservations r
                          where r.recurring_reservation_id = v_s.id and r.occurrence_date = v_d) then
        raise exception 'recurring_slot_reserved: horário reservado para mensalista'
          using errcode = '23P01', hint = 'RECURRING_SLOT', constraint = 'recurring_series_slot';
      end if;
    end loop;
  end loop;
  return new;
end $$;

create trigger validate_reservation_zz_series_slot
  before insert or update of start_at, end_at, court_id, status on public.reservations
  for each row execute function private.rg_protect_series_slot();

-- -----------------------------------------------------------------------------
-- 14) Observabilidade do operador (convergência ao horizonte)
-- -----------------------------------------------------------------------------
create view private.v_recurring_horizon_status as
  select s.id as series_id, s.organization_id, s.arena_id, s.court_id, s.status,
         (select max(r.occurrence_date) from public.reservations r where r.recurring_reservation_id = s.id) as materialized_until,
         private.rg_today() + private.rg_materialization_horizon() as target_date,
         (select count(*) from public.recurring_occurrence_gaps g where g.series_id = s.id and g.resolved_at is null) as open_gaps,
         (select x.outcome from public.recurring_generation_run_series x where x.series_id = s.id
           order by x.created_at desc limit 1) as last_outcome,
         (select count(*) from (select x.outcome from public.recurring_generation_run_series x
                                 where x.series_id = s.id order by x.created_at desc limit 3) t
           where t.outcome = 'ERROR') as recent_errors,
         s.id = any(private.rg_topup_candidates(private.rg_materialization_horizon(), array[s.id])) as needs_work
    from public.recurring_reservations s
   where s.status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- 15) Owner, RLS, grants
-- -----------------------------------------------------------------------------
alter table public.recurring_generation_runs owner to postgres;
alter table public.recurring_generation_run_series owner to postgres;
alter table public.recurring_occurrence_gaps owner to postgres;
alter table public.recurring_generation_runs enable row level security;
alter table public.recurring_generation_run_series enable row level security;
alter table public.recurring_occurrence_gaps enable row level security;
-- sem políticas: tudo negado; leitura só pelas RPCs/operador
revoke all on table public.recurring_generation_runs from public, anon, authenticated, service_role;
revoke all on table public.recurring_generation_run_series from public, anon, authenticated, service_role;
revoke all on table public.recurring_occurrence_gaps from public, anon, authenticated, service_role;
-- service_role: SELECT/DELETE apenas para limpeza de fixtures demo (lacunas caem em cascata com a série).
grant select, delete on table public.recurring_occurrence_gaps to service_role;
grant select, delete on table public.recurring_generation_run_series to service_role;
grant select, delete on table public.recurring_generation_runs to service_role;
alter view private.v_recurring_horizon_status owner to postgres;
revoke all on private.v_recurring_horizon_status from public, anon, authenticated, service_role;

alter function private.rg_materialization_horizon() owner to postgres;
alter function private.rg_topup_lock_key() owner to postgres;
alter function private.rg_fits_business_hours(uuid, date, time, time) owner to postgres;
alter function private.rg_occurrence_blocker(public.recurring_reservations, date) owner to postgres;
alter function private.rg_conflicting_reservation(uuid, timestamptz, timestamptz) owner to postgres;
alter function private.rg_gap_open(public.recurring_reservations, date, text, uuid, text, uuid, uuid) owner to postgres;
alter function private.rg_gap_resolve(uuid, date, text) owner to postgres;
alter function private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid) owner to postgres;
alter function private.rg_materialize(public.recurring_reservations, date[], boolean, uuid) owner to postgres;
alter function private.rg_plan_series(uuid, date, date) owner to postgres;
alter function private.rg_topup_candidates(integer, uuid[]) owner to postgres;
alter function private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint) owner to postgres;
alter function private.rg_recurring_topup_plan(integer, uuid[]) owner to postgres;
alter function private.rg_recurring_topup_batch(integer, uuid[]) owner to postgres;
alter procedure private.rg_recurring_topup_job(text) owner to postgres;
alter function private.rg_protect_series_slot() owner to postgres;
alter function public.rg_recurring_topup(uuid) owner to postgres;
alter function public.rg_recurring_gaps(uuid, uuid) owner to postgres;

revoke all on function private.rg_materialization_horizon() from public, anon, authenticated, service_role;
revoke all on function private.rg_topup_lock_key() from public, anon, authenticated, service_role;
revoke all on function private.rg_fits_business_hours(uuid, date, time, time) from public, anon, authenticated, service_role;
revoke all on function private.rg_occurrence_blocker(public.recurring_reservations, date) from public, anon, authenticated, service_role;
revoke all on function private.rg_conflicting_reservation(uuid, timestamptz, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.rg_gap_open(public.recurring_reservations, date, text, uuid, text, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_gap_resolve(uuid, date, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_materialize_ex(public.recurring_reservations, date[], boolean, uuid, date, text, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_materialize(public.recurring_reservations, date[], boolean, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_plan_series(uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function private.rg_topup_candidates(integer, uuid[]) from public, anon, authenticated, service_role;
revoke all on function private.rg_topup_series(uuid, integer, text, text, uuid, uuid, boolean, smallint) from public, anon, authenticated, service_role;
revoke all on function private.rg_recurring_topup_plan(integer, uuid[]) from public, anon, authenticated, service_role;
revoke all on function private.rg_recurring_topup_batch(integer, uuid[]) from public, anon, authenticated, service_role;
revoke all on procedure private.rg_recurring_topup_job(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_protect_series_slot() from public, anon, authenticated, service_role;

revoke all on function public.rg_recurring_topup(uuid) from public, anon, service_role;
revoke all on function public.rg_recurring_gaps(uuid, uuid) from public, anon, service_role;
grant execute on function public.rg_recurring_topup(uuid) to authenticated;
grant execute on function public.rg_recurring_gaps(uuid, uuid) to authenticated;

commit;
