-- =========================================================
-- RESERVA GOL — FASE 02B
-- Perfil público, reservas públicas e Storage
-- (versão aplicada pelo usuário no SQL Editor do Supabase)
-- =========================================================
-- 1) Campos públicos da arena
alter table public.arenas
  add column if not exists slug text;
alter table public.arenas
  add column if not exists public_booking_enabled boolean not null default false;
alter table public.arenas
  add column if not exists description text;
alter table public.arenas
  add column if not exists cover_image_url text;
alter table public.arenas
  add column if not exists amenities jsonb not null default '[]'::jsonb;
alter table public.arenas
  add column if not exists booking_rules text;
alter table public.arenas
  add column if not exists photos jsonb not null default '[]'::jsonb;
-- Slug público precisa ser único
create unique index if not exists idx_arenas_slug_unique
  on public.arenas (slug)
  where slug is not null;
-- 2) Reserva pública
alter table public.reservations
  add column if not exists public_code text;
alter table public.reservations
  add column if not exists idempotency_key text;
-- Código público deve ser único globalmente (usado em /reserva/[codigo])
create unique index if not exists idx_reservations_public_code_unique
  on public.reservations (public_code)
  where public_code is not null;
-- Idempotência isolada por arena
create unique index if not exists idx_reservations_arena_idempotency_unique
  on public.reservations (arena_id, idempotency_key)
  where idempotency_key is not null;
-- 3) Storage público somente para mídia pública das arenas
insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'arena-media', 'arena-media', true, 5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
-- Bucket público já serve arquivos via URL pública; sem policy de SELECT.
-- Upload/alteração/exclusão continuam restritos ao backend/service role.
drop policy if exists "Public can read arena media" on storage.objects;
