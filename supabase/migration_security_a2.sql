-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING A2 — integridade multi-tenant (P0-2)
-- Rodar no SQL Editor do Supabase. IDEMPOTENTE e segura para reaplicar.
-- NÃO altera dados, RLS, FKs, DELETE/cascade nem a constraint reservations_no_overlap.
-- Complementa (não substitui) as proteções da Fase 02C:
--   * private.validate_recurring_tenant        (recurring_reservations)
--   * private.validate_reservation_recurring   (ocorrência <-> série)
--   * private.protect_occurrence_anchor        (âncora imutável)
--
-- Problema: a RLS de reservations/courts/customers/business_hours checa apenas
-- organization_id. Um membro da Org A podia gravar linhas da Org A apontando para
-- arena/quadra/cliente da Org B (ex.: bloquear a quadra de outra arena, cujos IDs
-- são públicos). Estado real antes desta migration: 0 inconsistências existentes.
--
-- Segundo problema: mudar o vínculo de um registro PAI (ex.: courts.arena_id) não
-- dispara os triggers dos filhos e deixaria reservas existentes inconsistentes; e um
-- UPDATE simultâneo de todos os vínculos para um conjunto coerente de OUTRO tenant
-- (usuário membro das duas orgs) passaria pelo RGT01. Por isso os vínculos estruturais
-- de arenas, courts, business_hours, customers, reservations e recurring_reservations
-- passam a ser IMUTÁVEIS após o INSERT (seção 5).
--
-- Padrões de erro (mensagem genérica, sem IDs, nomes ou dados de outra organização):
--   SQLSTATE 'RGT01' = vínculo com outra organização/arena (tenant_mismatch)
--   SQLSTATE 'RGT02' = tentativa de alterar vínculo estrutural imutável
-- A API traduz ambos para 400 amigável.
--
-- SECURITY DEFINER (owner postgres, search_path = ''): a validação precisa enxergar
-- arena/quadra/cliente de forma determinística, independente da RLS de quem chama
-- (mesmo padrão das funções da 02C). As funções não recebem parâmetros, não usam
-- SQL dinâmico, só leem NEW e fazem lookups por PK. Funções de trigger não podem ser
-- chamadas diretamente; ainda assim o EXECUTE é revogado de PUBLIC.
-- =============================================================================
begin;

-- 1) reservations — TODAS as linhas (comuns e recorrentes) ---------------------
--    arena ∈ organização; quadra ∈ organização E arena; cliente (se houver) ∈ organização.
--    Não exige customer.arena_id = arena da reserva: clientes são da organização
--    (dedup por telefone é por organização; customers.arena_id é só a origem).
create or replace function private.enforce_reservation_tenant()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.arenas a
                 where a.id = new.arena_id and a.organization_id = new.organization_id) then
    raise exception 'tenant_mismatch: arena não pertence à organização da reserva' using errcode = 'RGT01';
  end if;
  if not exists (select 1 from public.courts c
                 where c.id = new.court_id and c.organization_id = new.organization_id and c.arena_id = new.arena_id) then
    raise exception 'tenant_mismatch: quadra não pertence à organização/arena da reserva' using errcode = 'RGT01';
  end if;
  if new.customer_id is not null and not exists (select 1 from public.customers cu
                 where cu.id = new.customer_id and cu.organization_id = new.organization_id) then
    raise exception 'tenant_mismatch: cliente não pertence à organização da reserva' using errcode = 'RGT01';
  end if;
  return new;
end $$;
revoke execute on function private.enforce_reservation_tenant() from public;

-- Nome começa com "enforce_" de propósito: triggers BEFORE disparam em ordem alfabética,
-- então esta checagem roda ANTES de protect_occurrence_anchor, trg_reservations_updated
-- e validate_reservation_recurring (02C), garantindo o código RGT01 também em linhas
-- recorrentes com quadra/arena/cliente de outra organização.
drop trigger if exists enforce_reservation_tenant on public.reservations;
create trigger enforce_reservation_tenant
  before insert or update on public.reservations
  for each row execute function private.enforce_reservation_tenant();

-- 2) courts: arena ∈ organização da quadra ------------------------------------
create or replace function private.enforce_arena_child_tenant()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Usada por courts e business_hours (arena_id NOT NULL) e customers (arena_id opcional).
  if new.arena_id is not null and not exists (select 1 from public.arenas a
                 where a.id = new.arena_id and a.organization_id = new.organization_id) then
    raise exception 'tenant_mismatch: arena não pertence à organização informada' using errcode = 'RGT01';
  end if;
  return new;
end $$;
revoke execute on function private.enforce_arena_child_tenant() from public;

drop trigger if exists enforce_court_tenant on public.courts;
create trigger enforce_court_tenant
  before insert or update on public.courts
  for each row execute function private.enforce_arena_child_tenant();

-- 3) business_hours: arena ∈ organização --------------------------------------
drop trigger if exists enforce_business_hours_tenant on public.business_hours;
create trigger enforce_business_hours_tenant
  before insert or update on public.business_hours
  for each row execute function private.enforce_arena_child_tenant();

-- 4) customers: se arena_id não for NULL, arena ∈ organização (NULL continua válido) --
drop trigger if exists enforce_customer_tenant on public.customers;
create trigger enforce_customer_tenant
  before insert or update on public.customers
  for each row execute function private.enforce_arena_child_tenant();

-- 5) Vínculos estruturais IMUTÁVEIS após o INSERT ----------------------------------
--    Sem isto, um UPDATE simultâneo de vários vínculos para um conjunto COERENTE de
--    outro tenant passaria pela RLS (usuário membro das duas orgs) e pelo RGT01.
--
--    Tabela                  | imutável                                   | continua editável
--    arenas                  | organization_id                            | demais campos
--    courts                  | organization_id, arena_id                  | nome, tipo, ativa...
--    business_hours          | organization_id, arena_id                  | horários, fechado
--    customers               | organization_id                            | arena_id (mesma org, seção 4)
--    reservations            | organization_id, arena_id                  | court_id (mesma org/arena, RGT01)
--                            |                                            | customer_id (mesma org, RGT01)
--    recurring_reservations  | organization_id, arena_id, court_id,       | status, notes, default_price,
--                            | customer_id                                | end_date, has_no_end_date...
--
--    reservations mantém court_id/customer_id editáveis para o fluxo "Apenas esta".
--    Mudança estrutural de série só pelo fluxo "Esta e as próximas" (nova série,
--    histórico preservado). validate_recurring_tenant (02C) NÃO é alterada.
--
--    Efeito colateral CONSCIENTE: a FK recurring_reservations.customer_id é ON DELETE
--    SET NULL, e ações de FK disparam triggers de UPDATE. Logo, excluir fisicamente um
--    cliente que tenha série passa a falhar com RGT02 (histórico preservado). As FKs em
--    reservations (customer SET NULL) e os CASCADEs (DELETE) não são afetados.
--
--    Vale para TODOS os papéis (inclusive service_role/postgres): nenhum fluxo legítimo
--    altera esses vínculos. SECURITY INVOKER basta: só compara OLD x NEW, sem consultas.
--    Sem SQL dinâmico: tg_table_name só escolhe entre ramos estáticos, e cada ramo só
--    referencia colunas que existem na tabela correspondente.
create or replace function private.protect_structural_links()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'structural_link_immutable: organization_id não pode ser alterado' using errcode = 'RGT02';
  end if;
  if tg_table_name in ('courts', 'business_hours', 'reservations', 'recurring_reservations') then
    if new.arena_id is distinct from old.arena_id then
      raise exception 'structural_link_immutable: arena_id não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  if tg_table_name = 'recurring_reservations' then
    if new.court_id is distinct from old.court_id then
      raise exception 'structural_link_immutable: court_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
    if new.customer_id is distinct from old.customer_id then
      raise exception 'structural_link_immutable: customer_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  return new;
end $$;
revoke execute on function private.protect_structural_links() from public;

drop trigger if exists protect_arena_links on public.arenas;
create trigger protect_arena_links
  before update on public.arenas
  for each row execute function private.protect_structural_links();

drop trigger if exists protect_court_links on public.courts;
create trigger protect_court_links
  before update on public.courts
  for each row execute function private.protect_structural_links();

drop trigger if exists protect_business_hours_links on public.business_hours;
create trigger protect_business_hours_links
  before update on public.business_hours
  for each row execute function private.protect_structural_links();

drop trigger if exists protect_customer_links on public.customers;
create trigger protect_customer_links
  before update on public.customers
  for each row execute function private.protect_structural_links();

-- Em reservations dispara depois de enforce_reservation_tenant e protect_occurrence_anchor
-- (ordem alfabética); todos recusam antes de gravar, a ordem só define qual código aparece.
drop trigger if exists protect_reservation_links on public.reservations;
create trigger protect_reservation_links
  before update on public.reservations
  for each row execute function private.protect_structural_links();

-- Em recurring_reservations dispara ANTES de set_recurring_updated_at e
-- validate_recurring_tenant (02C, inalterada).
drop trigger if exists protect_recurring_links on public.recurring_reservations;
create trigger protect_recurring_links
  before update on public.recurring_reservations
  for each row execute function private.protect_structural_links();

commit;

-- -----------------------------------------------------------------------------
-- Verificação (somente leitura) após aplicar:
--   select c.relname, t.tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
--    where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
--      and c.relname in ('arenas','reservations','recurring_reservations','courts','business_hours','customers') order by 1, 2;
--     -> arenas:                 protect_arena_links, trg_arenas_updated
--        business_hours:         enforce_business_hours_tenant, protect_business_hours_links
--        courts:                 enforce_court_tenant, protect_court_links, trg_courts_updated
--        customers:              enforce_customer_tenant, protect_customer_links, trg_customers_updated
--        recurring_reservations: protect_recurring_links, set_recurring_updated_at, validate_recurring_tenant
--        reservations:           enforce_reservation_tenant, protect_occurrence_anchor, protect_reservation_links,
--                                trg_reservations_updated, validate_reservation_recurring
--   select proname, prosecdef, proconfig from pg_proc
--    where pronamespace = 'private'::regnamespace
--      and proname in ('enforce_reservation_tenant','enforce_arena_child_tenant','protect_structural_links');
--     -> enforce_*: prosecdef = true; protect_structural_links: prosecdef = false; todas search_path=""
-- -----------------------------------------------------------------------------
