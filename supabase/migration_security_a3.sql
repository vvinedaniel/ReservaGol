-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING A3 — DELETE físico, grants e cascatas
-- Rodar no SQL Editor do Supabase. IDEMPOTENTE e segura para reaplicar.
-- NÃO altera nem apaga dados. NÃO altera a lógica do A1 (policies, grants por coluna e
-- protect_profile_privileges de profiles — só revoga privilégios de tabela excedentes),
-- do A2 (triggers de tenant), da 02C (triggers/funções de recorrência) nem a
-- constraint reservations_no_overlap.
--
-- Princípio: preservar histórico operacional.
--   * RLS decide QUAIS LINHAS; GRANT decide QUAIS OPERAÇÕES. As duas camadas são ajustadas.
--   * A aplicação não faz DELETE físico em nenhuma tabela (auditado no código):
--     reservas são canceladas (status), quadras/arenas desativadas (active=false),
--     horários editados (upsert). Por isso DELETE deixa de existir para o cliente.
--   * PostgREST precisa apenas de SELECT/INSERT/UPDATE; REFERENCES e TRIGGER só servem
--     para DDL e TRUNCATE ignora a RLS — nenhum é necessário ao papel authenticated.
--
-- Código de erro novo: SQLSTATE 'RGT03' = remover/rebaixar o último OWNER ativo.
-- =============================================================================
begin;

-- 1) RLS: trocar policies FOR ALL (que incluem DELETE) por INSERT + UPDATE separadas.
--    As policies de SELECT existentes não mudam. Sem policy de DELETE = DELETE negado.

-- reservations: membro lê/cria/edita; ninguém apaga.
drop policy if exists "reservations write" on public.reservations;
drop policy if exists "reservations insert member" on public.reservations;
drop policy if exists "reservations update member" on public.reservations;
create policy "reservations insert member" on public.reservations for insert to authenticated
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));
create policy "reservations update member" on public.reservations for update to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))))
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));

-- customers: membro lê/cria/edita; ninguém apaga.
drop policy if exists "customers write" on public.customers;
drop policy if exists "customers insert member" on public.customers;
drop policy if exists "customers update member" on public.customers;
create policy "customers insert member" on public.customers for insert to authenticated
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));
create policy "customers update member" on public.customers for update to authenticated
  using ((select private.is_org_member(organization_id, (select auth.uid()))))
  with check ((select private.is_org_member(organization_id, (select auth.uid()))));

-- courts: membro lê; OWNER/MANAGER cria/edita (inclui desativar); ninguém apaga.
drop policy if exists "courts write manager" on public.courts;
drop policy if exists "courts insert manager" on public.courts;
drop policy if exists "courts update manager" on public.courts;
create policy "courts insert manager" on public.courts for insert to authenticated
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));
create policy "courts update manager" on public.courts for update to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- arenas: membro lê; OWNER/MANAGER cria/edita (inclui desativar/publicar); ninguém apaga.
drop policy if exists "arenas write manager" on public.arenas;
drop policy if exists "arenas insert manager" on public.arenas;
drop policy if exists "arenas update manager" on public.arenas;
create policy "arenas insert manager" on public.arenas for insert to authenticated
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));
create policy "arenas update manager" on public.arenas for update to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- business_hours: membro lê; OWNER/MANAGER cria/edita (upsert = INSERT + UPDATE); ninguém apaga.
drop policy if exists "hours write manager" on public.business_hours;
drop policy if exists "hours insert manager" on public.business_hours;
drop policy if exists "hours update manager" on public.business_hours;
create policy "hours insert manager" on public.business_hours for insert to authenticated
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));
create policy "hours update manager" on public.business_hours for update to authenticated
  using ((select private.is_org_manager(organization_id, (select auth.uid()))))
  with check ((select private.is_org_manager(organization_id, (select auth.uid()))));

-- audit_logs: append-only. INSERT só em nome do próprio usuário (user_id = auth.uid());
-- inserts do servidor (onboarding/reserva pública) usam service role e não passam pela RLS.
drop policy if exists "audit insert member" on public.audit_logs;
create policy "audit insert member" on public.audit_logs for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and (select private.is_org_member(organization_id, (select auth.uid())))
  );

-- recurring_reservations: policies atuais (SELECT membro, INSERT/UPDATE manager, sem DELETE)
-- já estão corretas desde a 02C — não são tocadas.
-- organizations: SELECT membro / UPDATE owner, sem INSERT/DELETE — não são tocadas.
-- organization_members: "members manage by owner" (FOR ALL) é mantida de propósito:
-- remover membro da equipe é legítimo. O último OWNER é protegido pelo trigger da seção 4.

-- 2) GRANTS: menor privilégio para authenticated; nenhum acesso para anon.
revoke delete, truncate, trigger, references on public.reservations   from authenticated;
revoke delete, truncate, trigger, references on public.customers      from authenticated;
revoke delete, truncate, trigger, references on public.courts         from authenticated;
revoke delete, truncate, trigger, references on public.arenas         from authenticated;
revoke delete, truncate, trigger, references on public.business_hours from authenticated;
revoke        truncate, trigger, references on public.recurring_reservations from authenticated; -- DELETE já revogado (02C)
revoke insert, delete, truncate, trigger, references on public.organizations from authenticated; -- criação só via onboarding (service role)
revoke update, delete, truncate, trigger, references on public.audit_logs    from authenticated; -- append-only
revoke        truncate, trigger, references on public.organization_members   from authenticated; -- DELETE/UPDATE mantidos p/ gestão de equipe
-- profiles: SELECT e o UPDATE por coluna (full_name, phone) do A1 permanecem; INSERT já
-- foi revogado no A1. Policies e protect_profile_privileges (A1) não são tocadas.
revoke delete, truncate, trigger, references on public.profiles from authenticated;

revoke all on public.reservations, public.recurring_reservations, public.customers, public.courts,
              public.arenas, public.business_hours, public.organizations, public.audit_logs,
              public.organization_members
  from anon;
revoke all on public.profiles from anon;

-- 3) FOREIGN KEYS: histórico comercial não pode sumir em cascata.
--    RESTRICT = o pai não pode ser apagado enquanto houver filho. Não falha com os dados
--    atuais (as referências já são válidas); apenas muda a ação de ON DELETE.
--    Mantidos de propósito: business_hours -> arena/org CASCADE (configuração, sem valor
--    histórico); customers.arena_id SET NULL (origem do cadastro); organization_members
--    -> org CASCADE (vínculo sem sentido sem a org); audit_logs -> org CASCADE e
--    audit_logs.user_id -> auth.users SET NULL (decisões de encerramento de conta/LGPD
--    ficam para depois); reservations/recurring customer_id SET NULL (ver decisão sobre
--    customers: DELETE bloqueado por GRANT/RLS; FK mantida para rotina administrativa).
alter table public.reservations drop constraint if exists reservations_organization_id_fkey;
alter table public.reservations add constraint reservations_organization_id_fkey
  foreign key (organization_id) references public.organizations(id) on delete restrict;
alter table public.reservations drop constraint if exists reservations_arena_id_fkey;
alter table public.reservations add constraint reservations_arena_id_fkey
  foreign key (arena_id) references public.arenas(id) on delete restrict;
alter table public.reservations drop constraint if exists reservations_court_id_fkey;
alter table public.reservations add constraint reservations_court_id_fkey
  foreign key (court_id) references public.courts(id) on delete restrict;

alter table public.courts drop constraint if exists courts_arena_id_fkey;
alter table public.courts add constraint courts_arena_id_fkey
  foreign key (arena_id) references public.arenas(id) on delete restrict;
alter table public.courts drop constraint if exists courts_organization_id_fkey;
alter table public.courts add constraint courts_organization_id_fkey
  foreign key (organization_id) references public.organizations(id) on delete restrict;

alter table public.arenas drop constraint if exists arenas_organization_id_fkey;
alter table public.arenas add constraint arenas_organization_id_fkey
  foreign key (organization_id) references public.organizations(id) on delete restrict;

alter table public.customers drop constraint if exists customers_organization_id_fkey;
alter table public.customers add constraint customers_organization_id_fkey
  foreign key (organization_id) references public.organizations(id) on delete restrict;

-- 4) organization_members: sempre ao menos 1 OWNER ATIVO por organização.
--    Recusa DELETE, rebaixamento de papel, mudança de status ou de organização do ÚLTIMO
--    OWNER ativo. Não interfere em outros papéis nem quando existe outro OWNER ativo.
--    Vale para todos os papéis (inclusive service_role): para remover o último OWNER,
--    primeiro promova outro. Exceção: se a própria organização já foi apagada (cascata
--    do DELETE em organizations), a remoção é permitida.
--    SECURITY DEFINER: precisa contar OWNERs e travar a linha da organização
--    (SELECT ... FOR UPDATE) independentemente da RLS de quem chama; o lock serializa
--    dois OWNERs tentando se remover ao mesmo tempo. Sem parâmetros, sem SQL dinâmico.
create or replace function private.protect_last_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_removing_owner boolean := false;
begin
  if old.role = 'OWNER' and old.status = 'ACTIVE' then
    -- Em DELETE, NEW é nulo: a decisão fica em IFs separados (sem depender de curto-circuito).
    if tg_op = 'DELETE' then
      v_removing_owner := true;
    else
      v_removing_owner := new.role is distinct from 'OWNER'
                       or new.status is distinct from 'ACTIVE'
                       or new.organization_id is distinct from old.organization_id;
    end if;
  end if;

  if v_removing_owner then
    -- Trava a organização (serializa remoções concorrentes). Se ela já não existe
    -- (cascata do DELETE em organizations), não há o que proteger.
    perform 1 from public.organizations o where o.id = old.organization_id for update;
    if found and not exists (
      select 1 from public.organization_members m
       where m.organization_id = old.organization_id
         and m.role = 'OWNER' and m.status = 'ACTIVE'
         and m.id <> old.id
    ) then
      raise exception 'last_owner: a organização precisa manter ao menos um proprietário ativo' using errcode = 'RGT03';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;
revoke execute on function private.protect_last_owner() from public;

drop trigger if exists protect_last_owner on public.organization_members;
create trigger protect_last_owner
  before delete or update on public.organization_members
  for each row execute function private.protect_last_owner();

commit;

-- -----------------------------------------------------------------------------
-- Verificação (somente leitura) após aplicar:
--   select tablename, policyname, cmd from pg_policies where schemaname = 'public'
--      and tablename in ('reservations','customers','courts','arenas','business_hours','audit_logs',
--                        'recurring_reservations','organizations','organization_members')
--    order by 1, 3, 2;
--     -> nenhuma policy DELETE; FOR ALL somente em organization_members ("members manage by owner")
--   select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type)
--     from information_schema.table_privileges where table_schema = 'public'
--      and grantee in ('authenticated','anon') and table_name in (...mesmas tabelas..., 'profiles')
--    group by 1, 2 order by 1, 2;
--     -> authenticated sem TRUNCATE/TRIGGER/REFERENCES em todas; sem DELETE exceto
--        organization_members; organizations = SELECT,UPDATE; audit_logs = INSERT,SELECT;
--        profiles = SELECT (sem INSERT/UPDATE de tabela/DELETE/TRUNCATE/TRIGGER/REFERENCES);
--        anon: nenhuma linha
--   select grantee, column_name, privilege_type from information_schema.column_privileges
--    where table_schema = 'public' and table_name = 'profiles'
--      and grantee = 'authenticated' and privilege_type in ('UPDATE','INSERT');
--     -> apenas UPDATE em full_name e phone (A1); nenhum INSERT
--   select conname, confdeltype from pg_constraint
--    where conname in ('reservations_organization_id_fkey','reservations_arena_id_fkey',
--                      'reservations_court_id_fkey','courts_arena_id_fkey','courts_organization_id_fkey',
--                      'arenas_organization_id_fkey','customers_organization_id_fkey');
--     -> todas confdeltype = 'r' (RESTRICT)
--   select tgname from pg_trigger where tgrelid = 'public.organization_members'::regclass and not tgisinternal;
--     -> protect_last_owner
--   select count(*) from (select organization_id from public.organization_members
--     where role = 'OWNER' and status = 'ACTIVE' group by 1) t;   -- orgs com OWNER ativo (conferência)
-- -----------------------------------------------------------------------------
