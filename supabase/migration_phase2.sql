-- =============================================================================
-- RESERVA GOL - FASE 02A - Habilitar Supabase Realtime na tabela reservations
-- Realtime respeita RLS: cada assinante só recebe mudanças da própria organização.
-- Rodar no SQL Editor do Supabase (idempotente).
-- =============================================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'reservations'
  ) then
    alter publication supabase_realtime add table public.reservations;
  end if;
end $$;
