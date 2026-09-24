-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING A1 — proteger profiles.is_platform_admin
-- Rodar no SQL Editor do Supabase. IDEMPOTENTE e segura para reaplicar.
-- Altera SOMENTE public.profiles (grants, policy de INSERT e um trigger de proteção).
--
-- Problema (P0-1): a policy "profiles self update" + GRANT UPDATE na tabela inteira
-- permitiam ao usuário autenticado alterar a própria coluna is_platform_admin e, com
-- isso, obter acesso a TODAS as organizações via private.is_org_member/manager/owner.
--
-- Uso legítimo auditado no código:
--   * leitura: /api/me (select *) e canManageOrg (select is_platform_admin) — mantidas;
--   * escrita: apenas onboarding via service role (full_name, phone) — não afetada;
--   * criação do profile: trigger handle_new_user (SECURITY DEFINER) — não afetada;
--   * nenhuma escrita em profiles com o token do usuário hoje.
-- =============================================================================
begin;

-- 1) UPDATE: remove o privilégio amplo e concede só as colunas do próprio usuário.
--    (Revoga também eventuais grants por coluna explícitos nas colunas internas.)
revoke update on public.profiles from authenticated, anon;
revoke update (id, email, is_platform_admin, created_at, updated_at) on public.profiles from authenticated, anon;
grant update (full_name, phone) on public.profiles to authenticated;
-- A policy "profiles self update" (id = auth.uid()) continua limitando a QUAL linha.
-- email NÃO é concedido: o e-mail real é o de auth.users (alterado via Supabase Auth).

-- 2) INSERT direto não é necessário: o profile é criado por handle_new_user.
revoke insert on public.profiles from authenticated, anon;
drop policy if exists "profiles self insert" on public.profiles;

-- 3) Defesa em profundidade: mesmo que um GRANT amplo volte a existir no futuro
--    (ex.: "grant all on all tables ... to authenticated"), chamadas feitas com o
--    papel de cliente (authenticated/anon) não conseguem conceder privilégio de
--    plataforma nem alterar identidade, e-mail ou data de criação do profile.
--    SECURITY INVOKER de propósito: current_user reflete quem executou o comando.
--    service_role, postgres e funções SECURITY DEFINER (ex.: handle_new_user)
--    continuam podendo administrar a flag.
create or replace function private.protect_profile_privileges()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' and new.is_platform_admin then
      raise exception 'is_platform_admin não pode ser definido pelo cliente' using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (
         new.is_platform_admin is distinct from old.is_platform_admin
      or new.id is distinct from old.id
      or new.created_at is distinct from old.created_at
      or new.email is distinct from old.email
      -- updated_at fica de fora de propósito: é atualizado legitimamente por set_updated_at.
    ) then
      raise exception 'campos protegidos do perfil não podem ser alterados pelo cliente' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke execute on function private.protect_profile_privileges() from public;

drop trigger if exists protect_profile_privileges on public.profiles;
create trigger protect_profile_privileges
  before insert or update on public.profiles
  for each row execute function private.protect_profile_privileges();

commit;

-- -----------------------------------------------------------------------------
-- Verificação (somente leitura) após aplicar:
--   select grantee, privilege_type from information_schema.table_privileges
--    where table_schema='public' and table_name='profiles' and grantee in ('authenticated','anon');
--     -> authenticated: SELECT, DELETE (sem policy de DELETE => bloqueado pela RLS), sem INSERT/UPDATE
--   select grantee, column_name, privilege_type from information_schema.column_privileges
--    where table_schema='public' and table_name='profiles' and grantee='authenticated' and privilege_type='UPDATE';
--     -> apenas full_name e phone
--   select policyname, cmd from pg_policies where schemaname='public' and tablename='profiles';
--     -> "profiles self read" (SELECT) e "profiles self update" (UPDATE)
--   select tgname from pg_trigger where tgrelid='public.profiles'::regclass and not tgisinternal;
--     -> protect_profile_privileges, trg_profiles_updated
--   select count(*) from public.profiles where is_platform_admin;   -> 0
-- -----------------------------------------------------------------------------
