-- =============================================================================
-- RESERVA GOL — FASE 02C — Mensalistas + Reservas Recorrentes
-- Rodar no SQL Editor do Supabase.
-- IDEMPOTENTE, NÃO DESTRUTIVA e segura para reaplicar (mesmo após tentativa parcial).
-- Preserva integralmente: RLS existente, constraint anti-overlap de reservations,
-- Realtime, reservas públicas, Agenda DIA/SEMANA e as Fases 01 / 02A / 02B.
-- Sem seed em contas reais (dados demo ficam só na conta agenda.test, fora daqui).
-- =============================================================================

-- 1) Tabela de séries recorrentes (mensalistas) -------------------------------
create table if not exists public.recurring_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  arena_id uuid not null references public.arenas(id) on delete restrict,
  court_id uuid not null references public.courts(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete set null,
  frequency text not null,
  weekday int,                                 -- 0=domingo .. 6=sábado (WEEKLY/BIWEEKLY)
  day_of_month int,                            -- (MONTHLY)
  start_time time not null,
  end_time time not null,
  start_date date not null,
  end_date date,
  has_no_end_date boolean not null default false,
  status text not null default 'ACTIVE',
  default_price integer,                        -- valor de referência EM CENTAVOS (ainda não é financeiro)
  notes text,
  is_demo boolean not null default false,
  -- created_by preserva a série mesmo que o usuário seja removido depois.
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 1.a) Colunas idempotentes (cobre tabela criada parcialmente em tentativa anterior).
alter table public.recurring_reservations add column if not exists organization_id uuid references public.organizations(id) on delete restrict;
alter table public.recurring_reservations add column if not exists arena_id uuid references public.arenas(id) on delete restrict;
alter table public.recurring_reservations add column if not exists court_id uuid references public.courts(id) on delete restrict;
alter table public.recurring_reservations add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter table public.recurring_reservations add column if not exists frequency text;
alter table public.recurring_reservations add column if not exists weekday int;
alter table public.recurring_reservations add column if not exists day_of_month int;
alter table public.recurring_reservations add column if not exists start_time time;
alter table public.recurring_reservations add column if not exists end_time time;
alter table public.recurring_reservations add column if not exists start_date date;
alter table public.recurring_reservations add column if not exists end_date date;
alter table public.recurring_reservations add column if not exists has_no_end_date boolean not null default false;
alter table public.recurring_reservations add column if not exists status text not null default 'ACTIVE';
alter table public.recurring_reservations add column if not exists default_price integer;
alter table public.recurring_reservations add column if not exists notes text;
alter table public.recurring_reservations add column if not exists is_demo boolean not null default false;
alter table public.recurring_reservations add column if not exists created_by uuid references auth.users(id) on delete set null;
alter table public.recurring_reservations add column if not exists created_at timestamptz not null default now();
alter table public.recurring_reservations add column if not exists updated_at timestamptz not null default now();

-- 1.a.1) NOT NULL dos campos estruturalmente obrigatórios + defaults sensatos.
-- SET NOT NULL FALHA de forma clara se existirem linhas antigas incompatíveis
-- (não inventamos valores para organization_id/arena_id/court_id/etc).
alter table public.recurring_reservations alter column has_no_end_date set default false;
alter table public.recurring_reservations alter column status set default 'ACTIVE';
alter table public.recurring_reservations alter column is_demo set default false;
alter table public.recurring_reservations alter column created_at set default now();
alter table public.recurring_reservations alter column updated_at set default now();
alter table public.recurring_reservations alter column organization_id set not null;
alter table public.recurring_reservations alter column arena_id set not null;
alter table public.recurring_reservations alter column court_id set not null;
alter table public.recurring_reservations alter column frequency set not null;
alter table public.recurring_reservations alter column start_time set not null;
alter table public.recurring_reservations alter column end_time set not null;
alter table public.recurring_reservations alter column start_date set not null;
alter table public.recurring_reservations alter column has_no_end_date set not null;
alter table public.recurring_reservations alter column status set not null;
alter table public.recurring_reservations alter column is_demo set not null;
alter table public.recurring_reservations alter column created_at set not null;
alter table public.recurring_reservations alter column updated_at set not null;

-- 1.a.2) Preservação de histórico: FKs de org/arena/court em RESTRICT (nunca CASCADE),
-- normalizado de forma idempotente (cobre tentativa anterior que tenha usado CASCADE).
-- Impede exclusão física de arena/quadra apagar silenciosamente o histórico das séries.
do $$ begin
  alter table public.recurring_reservations drop constraint if exists recurring_reservations_organization_id_fkey;
  alter table public.recurring_reservations add constraint recurring_reservations_organization_id_fkey
    foreign key (organization_id) references public.organizations(id) on delete restrict;
  alter table public.recurring_reservations drop constraint if exists recurring_reservations_arena_id_fkey;
  alter table public.recurring_reservations add constraint recurring_reservations_arena_id_fkey
    foreign key (arena_id) references public.arenas(id) on delete restrict;
  alter table public.recurring_reservations drop constraint if exists recurring_reservations_court_id_fkey;
  alter table public.recurring_reservations add constraint recurring_reservations_court_id_fkey
    foreign key (court_id) references public.courts(id) on delete restrict;
end $$;

-- 1.b) Constraints (idempotentes, escopadas por conrelid) ---------------------
do $$ begin
  if not exists (select 1 from pg_constraint where conname='recurring_frequency_chk' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_frequency_chk check (frequency in ('WEEKLY','BIWEEKLY','MONTHLY'));
  end if;
  if not exists (select 1 from pg_constraint where conname='recurring_status_chk' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_status_chk check (status in ('ACTIVE','PAUSED','CANCELLED'));
  end if;
  if not exists (select 1 from pg_constraint where conname='recurring_weekday_range' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_weekday_range check (weekday is null or weekday between 0 and 6);
  end if;
  if not exists (select 1 from pg_constraint where conname='recurring_dom_range' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_dom_range check (day_of_month is null or day_of_month between 1 and 31);
  end if;
  -- Horário: end_time = start_time é INVÁLIDO; end_time < start_time = termina no dia seguinte (madrugada).
  alter table public.recurring_reservations drop constraint if exists recurring_time_valid;
  alter table public.recurring_reservations add constraint recurring_time_valid check (end_time <> start_time);
  -- Campos por frequência coerentes.
  if not exists (select 1 from pg_constraint where conname='recurring_freq_fields' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_freq_fields check (
      (frequency in ('WEEKLY','BIWEEKLY') and weekday is not null and day_of_month is null)
      or (frequency = 'MONTHLY' and day_of_month is not null and weekday is null)
    );
  end if;
  -- Datas coerentes.
  if not exists (select 1 from pg_constraint where conname='recurring_end_after_start' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_end_after_start check (end_date is null or end_date >= start_date);
  end if;
  if not exists (select 1 from pg_constraint where conname='recurring_end_consistency' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_end_consistency check (
      (has_no_end_date = true and end_date is null) or (has_no_end_date = false and end_date is not null)
    );
  end if;
  -- Preço de referência não-negativo (em centavos) ou nulo.
  if not exists (select 1 from pg_constraint where conname='recurring_price_nonneg' and conrelid='public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_price_nonneg check (default_price is null or default_price >= 0);
  end if;
end $$;

create index if not exists idx_recurring_org on public.recurring_reservations (organization_id);
create index if not exists idx_recurring_arena on public.recurring_reservations (arena_id);
create index if not exists idx_recurring_status on public.recurring_reservations (organization_id, status);
create index if not exists idx_recurring_court on public.recurring_reservations (court_id);
create index if not exists idx_recurring_customer on public.recurring_reservations (customer_id);

-- updated_at automático (reaproveita função existente).
drop trigger if exists set_recurring_updated_at on public.recurring_reservations;
create trigger set_recurring_updated_at before update on public.recurring_reservations
  for each row execute function public.set_updated_at();

-- 1.c) Integridade multi-tenant NO BANCO (não confiar só na API) --------------
-- Garante que arena/court/customer pertencem à MESMA organização (e court à arena).
create or replace function private.validate_recurring_tenant()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.arenas a where a.id = new.arena_id and a.organization_id = new.organization_id) then
    raise exception 'arena_id não pertence à organização informada';
  end if;
  if not exists (select 1 from public.courts c where c.id = new.court_id and c.organization_id = new.organization_id and c.arena_id = new.arena_id) then
    raise exception 'court_id não pertence à organização/arena informada';
  end if;
  if new.customer_id is not null and not exists (select 1 from public.customers cu where cu.id = new.customer_id and cu.organization_id = new.organization_id) then
    raise exception 'customer_id não pertence à organização informada';
  end if;
  return new;
end $$;
revoke execute on function private.validate_recurring_tenant() from public;
grant execute on function private.validate_recurring_tenant() to authenticated;

drop trigger if exists validate_recurring_tenant on public.recurring_reservations;
create trigger validate_recurring_tenant
  before insert or update on public.recurring_reservations
  for each row execute function private.validate_recurring_tenant();

-- 2) Vínculo das ocorrências reais em reservations ----------------------------
alter table public.reservations add column if not exists recurring_reservation_id uuid references public.recurring_reservations(id) on delete set null;
alter table public.reservations add column if not exists occurrence_date date;        -- ÂNCORA da recorrência (ver nota abaixo)
alter table public.reservations add column if not exists price integer;               -- valor por jogo EM CENTAVOS (opcional)
alter table public.reservations add column if not exists is_exception boolean not null default false; -- ocorrência editada "apenas esta"

do $$ begin
  -- price não-negativo ou nulo (idempotência escopada à tabela reservations).
  if not exists (select 1 from pg_constraint where conname='reservations_price_nonneg' and conrelid='public.reservations'::regclass) then
    alter table public.reservations add constraint reservations_price_nonneg check (price is null or price >= 0);
  end if;
  -- Toda ocorrência vinculada a uma série DEVE ter data-âncora (não burlar o índice único).
  if not exists (select 1 from pg_constraint where conname='reservations_recurring_anchor' and conrelid='public.reservations'::regclass) then
    alter table public.reservations add constraint reservations_recurring_anchor check (recurring_reservation_id is null or occurrence_date is not null);
  end if;
end $$;

create index if not exists idx_res_recurring on public.reservations (recurring_reservation_id);

-- Idempotência do rolling window: uma série NUNCA materializa a mesma data-âncora
-- duas vezes. Também impede recriar uma ocorrência MOVIDA (is_exception) ou CANCELADA,
-- pois a linha permanece ocupando a âncora original.
create unique index if not exists idx_res_series_anchor
  on public.reservations (recurring_reservation_id, occurrence_date)
  where recurring_reservation_id is not null and occurrence_date is not null;

-- NOTA (semântica de occurrence_date) — garantida também no backend:
--   * Ao gerar: occurrence_date = data originalmente prevista pela série.
--   * "Apenas esta reserva" (mesmo movendo de dia/quadra): start_at/end_at/court_id podem
--     mudar, is_exception = true, porém occurrence_date NÃO muda.
--   * "Cancelar apenas esta data": status = CANCELLED, occurrence_date NÃO muda.
--   * Recorrência que cruza a meia-noite (ex.: 23:00→00:00): occurrence_date é o dia do
--     start_at; o backend monta end_at no dia seguinte. anti-overlap continua final.

-- 2.a) Integridade reservation <-> série (org/arena/court) --------------------
-- Quando recurring_reservation_id não é NULL:
--   (a) a série deve pertencer à MESMA organização e arena da reserva;
--   (b) new.court_id deve SEMPRE pertencer à MESMA organização e arena da reserva;
--   (c) is_exception = false -> new.court_id deve ser exatamente a quadra da série;
--       is_exception = true  -> new.court_id pode diferir (ex.: Society 01 -> Society 02 da
--       MESMA arena), mas nunca de outra arena/organização (garantido por (b)).
-- Reservas normais (recurring_reservation_id IS NULL) não são afetadas.
create or replace function private.validate_reservation_recurring()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.recurring_reservation_id is not null then
    -- (a) A série referenciada deve pertencer à MESMA organização e arena da reserva.
    if not exists (
      select 1 from public.recurring_reservations s
      where s.id = new.recurring_reservation_id
        and s.organization_id = new.organization_id
        and s.arena_id = new.arena_id
    ) then
      raise exception 'recurring_reservation_id não corresponde à organização/arena da reserva';
    end if;
    -- (b) A quadra da reserva deve pertencer à MESMA organização e arena (sempre).
    if not exists (
      select 1 from public.courts c
      where c.id = new.court_id
        and c.organization_id = new.organization_id
        and c.arena_id = new.arena_id
    ) then
      raise exception 'court_id não pertence à organização/arena da reserva';
    end if;
    -- (c) Regra por exceção:
    --     is_exception = false -> a quadra deve ser exatamente a da série.
    --     is_exception = true  -> pode diferir, mas (b) já garante mesma org+arena.
    if new.is_exception = false and not exists (
      select 1 from public.recurring_reservations s
      where s.id = new.recurring_reservation_id and s.court_id = new.court_id
    ) then
      raise exception 'ocorrência não-excepcional deve usar a mesma quadra da série';
    end if;
  end if;
  return new;
end $$;
revoke execute on function private.validate_reservation_recurring() from public;
grant execute on function private.validate_reservation_recurring() to authenticated;

drop trigger if exists validate_reservation_recurring on public.reservations;
create trigger validate_reservation_recurring
  before insert or update on public.reservations
  for each row execute function private.validate_reservation_recurring();

-- 2.b) Imutabilidade da ÂNCORA e do vínculo de série (BEFORE UPDATE) ----------
-- Depois de criada, uma ocorrência NÃO pode ser transferida para outra série nem ter a
-- data-âncora alterada: recurring_reservation_id e occurrence_date são imutáveis no UPDATE.
-- "Apenas esta" continua podendo mudar start_at/end_at/court_id/status/notes/is_exception,
-- desde que série e âncora permaneçam as originais. (INSERT não é afetado.)
create or replace function private.protect_occurrence_anchor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.recurring_reservation_id is distinct from old.recurring_reservation_id then
    raise exception 'recurring_reservation_id é imutável após a criação da ocorrência';
  end if;
  if new.occurrence_date is distinct from old.occurrence_date then
    raise exception 'occurrence_date (âncora da recorrência) é imutável após a criação';
  end if;
  return new;
end $$;
-- Trigger não exige EXECUTE ao usuário; apenas removemos o acesso público.
revoke execute on function private.protect_occurrence_anchor() from public;

drop trigger if exists protect_occurrence_anchor on public.reservations;
create trigger protect_occurrence_anchor
  before update on public.reservations
  for each row execute function private.protect_occurrence_anchor();

-- 3) Grants + RLS multi-tenant (SEM DELETE físico) ----------------------------
-- Concede apenas o necessário e REVOGA DELETE explicitamente (remove privilégio herdado
-- de qualquer versão anterior). Histórico preservado; cancelar = status CANCELLED.
grant select, insert, update on public.recurring_reservations to authenticated;
revoke delete on public.recurring_reservations from authenticated;
revoke all on public.recurring_reservations from anon;

alter table public.recurring_reservations enable row level security;

-- Reaplicação segura: remove policies antigas antes de recriar.
drop policy if exists "recurring write manager" on public.recurring_reservations;
drop policy if exists "recurring read member" on public.recurring_reservations;
drop policy if exists "recurring insert manager" on public.recurring_reservations;
drop policy if exists "recurring update manager" on public.recurring_reservations;

-- Leitura: qualquer membro ativo da organização.
create policy "recurring read member" on public.recurring_reservations for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

-- Criação: apenas OWNER/MANAGER.
create policy "recurring insert manager" on public.recurring_reservations for insert to authenticated
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- Atualização (inclui pausar/reativar/cancelar via status): apenas OWNER/MANAGER.
create policy "recurring update manager" on public.recurring_reservations for update to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- Intencionalmente NÃO há policy de DELETE: exclusão física fica bloqueada pela RLS
-- e, adicionalmente, o privilégio DELETE foi revogado acima.

-- Observações finais:
--  * As OCORRÊNCIAS continuam em public.reservations e seguem as políticas já existentes.
--  * A constraint reservations_no_overlap continua sendo a AUTORIDADE FINAL contra
--    reserva dupla (ocorrências canceladas liberam o horário).
--  * reservations já está na publication supabase_realtime (Fase 02A) — a Agenda
--    atualiza automaticamente quando ocorrências são criadas/editadas/canceladas.
