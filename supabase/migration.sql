-- =============================================================================
-- RESERVA GOL - FASE 01 - Schema multi-tenant + RLS (PostgreSQL / Supabase)
-- Idempotent migration. Safe to run multiple times.
-- =============================================================================

create extension if not exists pgcrypto;      -- gen_random_uuid()
create extension if not exists btree_gist;     -- exclusion constraint (uuid = + range &&)

create schema if not exists private;

-- -----------------------------------------------------------------------------
-- Utility: auto-update updated_at
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- TABLES
-- =============================================================================

-- profiles: 1:1 with auth.users
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  is_platform_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- organizations: the company that owns arenas
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_name text,
  phone text,
  email text,
  is_demo boolean not null default false,
  onboarding_completed boolean not null default false,
  default_reservation_minutes integer not null default 60,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- organization_members: user <-> organization with role
create table if not exists public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'OWNER' check (role in ('OWNER','MANAGER','RECEPTIONIST')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','INVITED','SUSPENDED')),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

-- arenas: physical units
create table if not exists public.arenas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  phone text,
  whatsapp text,
  address text,
  number text,
  complement text,
  neighborhood text,
  city text,
  state text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- courts
create table if not exists public.courts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  arena_id uuid not null references public.arenas(id) on delete cascade,
  name text not null,
  type text,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- business_hours (per arena, per weekday: 0=Sunday .. 6=Saturday)
create table if not exists public.business_hours (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  arena_id uuid not null references public.arenas(id) on delete cascade,
  weekday integer not null check (weekday between 0 and 6),
  open_time time,
  close_time time,
  closed boolean not null default false,
  unique (arena_id, weekday)
);

-- customers
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  arena_id uuid references public.arenas(id) on delete set null,
  name text not null,
  phone text,
  email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- reservations (initial structure; full agenda in phase 2)
create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  arena_id uuid not null references public.arenas(id) on delete cascade,
  court_id uuid not null references public.courts(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  status text not null default 'PENDING'
    check (status in ('PENDING','CONFIRMED','PAID','CANCELLED','BLOCKED','NO_SHOW')),
  source text,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint reservations_time_valid check (end_at > start_at)
);

-- DOUBLE-BOOKING PREVENTION (backend/database guaranteed, not frontend):
-- No two ACTIVE reservations for the same court may overlap in time.
-- Cancelled / no-show reservations are ignored so slots can be re-booked.
alter table public.reservations drop constraint if exists reservations_no_overlap;
alter table public.reservations
  add constraint reservations_no_overlap
  exclude using gist (
    court_id with =,
    tstzrange(start_at, end_at) with &&
  ) where (status in ('PENDING','CONFIRMED','PAID','BLOCKED'));

-- audit_logs
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text,
  entity_id uuid,
  metadata jsonb,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- INDEXES
-- -----------------------------------------------------------------------------
create index if not exists idx_org_members_user on public.organization_members (user_id, organization_id);
create index if not exists idx_arenas_org on public.arenas (organization_id);
create index if not exists idx_courts_org on public.courts (organization_id);
create index if not exists idx_courts_arena on public.courts (arena_id);
create index if not exists idx_hours_arena on public.business_hours (arena_id);
create index if not exists idx_customers_org on public.customers (organization_id);
create index if not exists idx_reservations_org on public.reservations (organization_id);
create index if not exists idx_reservations_court_time on public.reservations (court_id, start_at);
create index if not exists idx_audit_org on public.audit_logs (organization_id);

-- -----------------------------------------------------------------------------
-- updated_at triggers
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','organizations','arenas','courts','customers','reservations']
  loop
    execute format('drop trigger if exists trg_%s_updated on public.%I', t, t);
    execute format('create trigger trg_%s_updated before update on public.%I for each row execute function public.set_updated_at()', t, t);
  end loop;
end $$;

-- =============================================================================
-- AUTH: auto-create a profile when a new auth user signs up
-- =============================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'phone', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =============================================================================
-- PRIVATE HELPER FUNCTIONS (security definer, avoid RLS recursion)
-- =============================================================================
create or replace function private.is_platform_admin(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = p_user and p.is_platform_admin);
$$;

create or replace function private.is_org_member(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_org and m.user_id = p_user and m.status = 'ACTIVE'
  ) or (select private.is_platform_admin(p_user));
$$;

-- MANAGER or OWNER
create or replace function private.is_org_manager(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_org and m.user_id = p_user
      and m.status = 'ACTIVE' and m.role in ('OWNER','MANAGER')
  ) or (select private.is_platform_admin(p_user));
$$;

-- OWNER only (org admin)
create or replace function private.is_org_owner(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_org and m.user_id = p_user
      and m.status = 'ACTIVE' and m.role = 'OWNER'
  ) or (select private.is_platform_admin(p_user));
$$;

-- =============================================================================
-- GRANTS
-- =============================================================================
grant usage on schema public to authenticated;
grant usage on schema private to authenticated;
grant execute on all functions in schema private to authenticated;

grant select, insert, update, delete on
  public.profiles, public.organizations, public.organization_members,
  public.arenas, public.courts, public.business_hours,
  public.customers, public.reservations, public.audit_logs
  to authenticated;

revoke all on
  public.profiles, public.organizations, public.organization_members,
  public.arenas, public.courts, public.business_hours,
  public.customers, public.reservations, public.audit_logs
  from anon;

-- =============================================================================
-- ENABLE RLS
-- =============================================================================
alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.arenas enable row level security;
alter table public.courts enable row level security;
alter table public.business_hours enable row level security;
alter table public.customers enable row level security;
alter table public.reservations enable row level security;
alter table public.audit_logs enable row level security;

-- Helper to (re)create policies idempotently
-- (drop-if-exists then create)

-- ---------- profiles ----------
drop policy if exists "profiles self read" on public.profiles;
create policy "profiles self read" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_platform_admin((select auth.uid()))));

drop policy if exists "profiles self update" on public.profiles;
create policy "profiles self update" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists "profiles self insert" on public.profiles;
create policy "profiles self insert" on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

-- ---------- organizations ----------
drop policy if exists "org read members" on public.organizations;
create policy "org read members" on public.organizations for select to authenticated
  using ((select private.is_org_member(id, (select auth.uid()))));

drop policy if exists "org update owner" on public.organizations;
create policy "org update owner" on public.organizations for update to authenticated
  using ((select private.is_org_owner(id, (select auth.uid()))))
  with check ((select private.is_org_owner(id, (select auth.uid()))));
-- INSERT is intentionally handled by the trusted server (service key) during onboarding.

-- ---------- organization_members ----------
drop policy if exists "members read own org" on public.organization_members;
create policy "members read own org" on public.organization_members for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "members manage by owner" on public.organization_members;
create policy "members manage by owner" on public.organization_members for all to authenticated
  using ((select private.is_org_owner(organization_id, (select auth.uid()))))
  with check ((select private.is_org_owner(organization_id, (select auth.uid()))));

-- ---------- arenas ----------
drop policy if exists "arenas read" on public.arenas;
create policy "arenas read" on public.arenas for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "arenas write manager" on public.arenas;
create policy "arenas write manager" on public.arenas for all to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- ---------- courts ----------
drop policy if exists "courts read" on public.courts;
create policy "courts read" on public.courts for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "courts write manager" on public.courts;
create policy "courts write manager" on public.courts for all to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- ---------- business_hours ----------
drop policy if exists "hours read" on public.business_hours;
create policy "hours read" on public.business_hours for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "hours write manager" on public.business_hours;
create policy "hours write manager" on public.business_hours for all to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- ---------- customers ----------
drop policy if exists "customers read" on public.customers;
create policy "customers read" on public.customers for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "customers write" on public.customers;
create policy "customers write" on public.customers for all to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))))
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));

-- ---------- reservations ----------
drop policy if exists "reservations read" on public.reservations;
create policy "reservations read" on public.reservations for select to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))));

drop policy if exists "reservations write" on public.reservations;
create policy "reservations write" on public.reservations for all to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))))
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));

-- ---------- audit_logs ----------
drop policy if exists "audit read manager" on public.audit_logs;
create policy "audit read manager" on public.audit_logs for select to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))));

drop policy if exists "audit insert member" on public.audit_logs;
create policy "audit insert member" on public.audit_logs for insert to authenticated
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));

-- =============================================================================
-- DONE
-- =============================================================================
