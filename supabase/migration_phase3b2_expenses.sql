-- =============================================================================
-- RESERVA GOL — FASE 03B.2 — DESPESAS & CAIXA (banco)
-- Contrato: Freeze 2 aprovado. Receita e despesa são domínios separados; só a LEITURA consolida.
--
-- Cria:
--   tabelas  public.expense_categories, public.expenses, public.expense_payments (append-only)
--   14 RPCs  8 de escrita (categoria, despesa, pagamento/devolução/anulação) + 6 de leitura
--   seed     10 categorias padrão para as organizações existentes + trigger para as novas
--
-- Regras centrais:
--   - Acesso agregado e escrita = vínculo ATIVO real OWNER/MANAGER (private.rg_exp_is_manager).
--     RECEPTIONIST negado no banco. Sem o atalho de PLATFORM_SUPER_ADMIN do is_org_manager.
--   - Dinheiro em centavos inteiros; teto 100.000.000 (R$ 1.000.000,00) por despesa e lançamento.
--   - Status derivado (private.rg_exp_rows): CANCELLED > PAID (a pagar = 0) > PARTIAL > OPEN;
--     OVERDUE é flag sobre OPEN/PARTIAL. Overpay bloqueado em todos os caminhos.
--   - Ordem global de locks: categoria (FOR SHARE) -> despesa (FOR UPDATE) -> lançamento (FOR UPDATE).
--     Toda condição é revalidada DEPOIS dos locks. Idempotência (operation_id) é conferida antes
--     do estado mutável: repetição exata = replay mesmo que o estado tenha mudado depois.
--   - Nenhuma RPC da 03A/03B.1 é alterada. Funções compartilhadas são só reutilizadas.
--
-- Uma transação. Sem CREATE OR REPLACE, sem IF NOT EXISTS: qualquer objeto já existente => 42710
-- antes de qualquer efeito. Rollback: supabase/rollback_phase3b2_expenses.sql.
-- =============================================================================
begin;

-- Nenhuma organização pode ser criada entre o seed das existentes e a criação do trigger.
lock table public.organizations in share row exclusive mode;

-- -----------------------------------------------------------------------------
-- 0) Dependências (03A / 03B.1 / helpers compartilhados)
-- -----------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.organizations') is null or to_regclass('public.arenas') is null
     or to_regclass('public.organization_members') is null or to_regclass('public.audit_logs') is null
     or to_regclass('public.reservation_payments') is null or to_regclass('public.idx_payments_org_received') is null
     or to_regprocedure('private.guard_finance_delete()') is null
     or to_regprocedure('private.rg_fin_notes(text)') is null
     or to_regprocedure('private.rg_today()') is null
     or to_regprocedure('public.set_updated_at()') is null
     or to_regprocedure('private.rg_fault(text)') is null
     or to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is null then
    raise exception '03B.2: dependência ausente (03A / 03B.1 / helpers compartilhados)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1) Preflight de colisão: TODOS os objetos que esta migration cria, nominalmente.
-- -----------------------------------------------------------------------------
do $$
declare
  v_found text[] := '{}';
  v_name text;
begin
  -- tabelas e seus tipos compostos
  foreach v_name in array array['public.expense_categories', 'public.expenses', 'public.expense_payments'] loop
    if to_regclass(v_name) is not null or to_regtype(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  -- índices e índices de constraints (pkey / unique)
  foreach v_name in array array[
    'public.expense_categories_pkey', 'public.expense_categories_id_org_key', 'public.idx_expense_categories_org_name_key',
    'public.expenses_pkey', 'public.expenses_id_org_key', 'public.idx_expenses_org_operation', 'public.idx_expenses_org_due',
    'public.idx_expenses_arena_due',
    'public.expense_payments_pkey', 'public.expense_payments_id_org_key', 'public.idx_expense_payments_org_operation',
    'public.idx_expense_payments_org_paid', 'public.idx_expense_payments_expense', 'public.idx_expense_payments_reversal_of'] loop
    if to_regclass(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  -- funções privadas (assinatura)
  foreach v_name in array array[
    'private.rg_exp_name_key(text)',
    'private.rg_exp_is_manager(uuid, uuid)',
    'private.rg_exp_scope(uuid, uuid, date, date, integer)',
    'private.rg_exp_rows(uuid, uuid, date, date)',
    'private.rg_exp_validate_entry(uuid, text, integer, timestamptz)',
    'private.rg_exp_fingerprint_expense(uuid, uuid, uuid, text, integer, date, text)',
    'private.rg_exp_fingerprint_payment(text, uuid, uuid, integer, text, timestamptz, text)',
    'private.rg_exp_seed_default_categories(uuid)',
    'private.rg_exp_seed_org_categories()',
    'private.enforce_expense_integrity()',
    'private.protect_expense_record()',
    'private.enforce_expense_payment_integrity()',
    'private.protect_expense_payment_ledger()',
    -- RPCs públicas (assinatura)
    'public.rg_expense_category_create(uuid, text)',
    'public.rg_expense_category_update(uuid, jsonb)',
    'public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text)',
    'public.rg_expense_update(uuid, jsonb)',
    'public.rg_expense_cancel(uuid, text)',
    'public.rg_expense_payment_register(uuid, uuid, text, integer, timestamptz, text)',
    'public.rg_expense_payment_reverse(uuid, uuid, text, integer, timestamptz, text)',
    'public.rg_expense_payment_void(uuid, text)',
    'public.rg_expense_categories(uuid, boolean)',
    'public.rg_expense_overview(uuid, uuid, uuid, date, date, date, date)',
    'public.rg_expenses(uuid, uuid, uuid, date, date, text, integer, date, uuid)',
    'public.rg_expense_detail(uuid)',
    'public.rg_fin_cash_result(uuid, uuid, date, date, text)',
    'public.rg_fin_cash_movements(uuid, uuid, date, date, integer, timestamptz, smallint, uuid)'] loop
    if to_regprocedure(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  -- qualquer sobrecarga com o mesmo nome também é colisão (evita ambiguidade de resolução)
  select v_found || coalesce(array_agg(distinct n.nspname || '.' || p.proname || '(*)'), '{}') into v_found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname = 'public' and p.proname in ('rg_expense_category_create', 'rg_expense_category_update', 'rg_expense_create',
            'rg_expense_update', 'rg_expense_cancel', 'rg_expense_payment_register', 'rg_expense_payment_reverse',
            'rg_expense_payment_void', 'rg_expense_categories', 'rg_expense_overview', 'rg_expenses', 'rg_expense_detail',
            'rg_fin_cash_result', 'rg_fin_cash_movements'))
      or (n.nspname = 'private' and p.proname in ('rg_exp_name_key', 'rg_exp_is_manager', 'rg_exp_scope', 'rg_exp_rows',
            'rg_exp_validate_entry', 'rg_exp_fingerprint_expense', 'rg_exp_fingerprint_payment', 'rg_exp_seed_default_categories',
            'rg_exp_seed_org_categories', 'enforce_expense_integrity', 'protect_expense_record',
            'enforce_expense_payment_integrity', 'protect_expense_payment_ledger'));
  -- trigger em organizations
  if exists (select 1 from pg_trigger t where t.tgrelid = 'public.organizations'::regclass and t.tgname = 'seed_expense_categories') then
    v_found := v_found || 'trigger public.organizations.seed_expense_categories'::text;
  end if;
  if cardinality(v_found) > 0 then
    raise exception '03B.2: objeto de destino já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2) Normalização do nome de categoria (precisa existir antes da coluna gerada)
--    Ignora maiúsculas/minúsculas, espaços externos/repetidos e acentos portugueses.
--    normalize(NFC) junta acento combinante (ex.: "A" + U+0301) na letra precomposta; translate()
--    leva os acentos a ASCII ANTES do lower() => independente de locale. Tudo IMMUTABLE.
-- -----------------------------------------------------------------------------
create function private.rg_exp_name_key(p_name text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select lower(btrim(regexp_replace(
    translate(normalize(p_name, NFC), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
                                      'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn'),
    '\s+', ' ', 'g')))
$$;

-- -----------------------------------------------------------------------------
-- 3) Tabelas
-- -----------------------------------------------------------------------------
create table public.expense_categories (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  name text not null,
  name_key text generated always as (private.rg_exp_name_key(name)) stored,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expense_categories_pkey primary key (id),
  constraint expense_categories_id_org_key unique (id, organization_id),
  -- CASCADE: o harness de testes apaga organizações; categoria em uso continua protegida pela FK RESTRICT de expenses.
  constraint expense_categories_org_fkey foreign key (organization_id) references public.organizations(id) on delete cascade,
  constraint expense_categories_name_chk check (
    name = btrim(regexp_replace(name, '\s+', ' ', 'g')) and char_length(name) between 1 and 60)
);
create unique index idx_expense_categories_org_name_key on public.expense_categories (organization_id, name_key);

create table public.expenses (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  arena_id uuid,
  category_id uuid not null,
  description text not null,
  amount integer not null,
  due_date date not null,
  notes text,
  operation_id uuid not null,
  operation_fingerprint bytea not null,
  created_by uuid,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expenses_pkey primary key (id),
  constraint expenses_id_org_key unique (id, organization_id),
  constraint expenses_org_fkey foreign key (organization_id) references public.organizations(id) on delete restrict,
  constraint expenses_arena_fkey foreign key (arena_id) references public.arenas(id) on delete restrict,
  constraint expenses_category_org_fkey foreign key (category_id, organization_id)
    references public.expense_categories(id, organization_id) on delete restrict,
  constraint expenses_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null,
  constraint expenses_cancelled_by_fkey foreign key (cancelled_by) references auth.users(id) on delete set null,
  constraint expenses_description_chk check (
    description = btrim(regexp_replace(description, '\s+', ' ', 'g')) and char_length(description) between 1 and 200),
  constraint expenses_amount_chk check (amount between 1 and 100000000),
  constraint expenses_due_date_chk check (due_date between date '2000-01-01' and date '2100-12-31'),
  constraint expenses_notes_chk check (notes is null or (notes = btrim(notes) and notes <> '' and char_length(notes) <= 500)),
  constraint expenses_fingerprint_chk check (octet_length(operation_fingerprint) = 32),
  constraint expenses_cancel_chk check ((cancelled_at is null) = (cancel_reason is null) and (cancelled_at is not null or cancelled_by is null)),
  constraint expenses_cancel_reason_chk check (
    cancel_reason is null or (cancel_reason = btrim(cancel_reason) and cancel_reason <> '' and char_length(cancel_reason) <= 500))
);
create unique index idx_expenses_org_operation on public.expenses (organization_id, operation_id);
create index idx_expenses_org_due on public.expenses (organization_id, due_date, id);
create index idx_expenses_arena_due on public.expenses (arena_id, due_date, id);

-- Ledger append-only (mesma filosofia de reservation_payments). Sem updated_at: só a anulação muda a linha.
create table public.expense_payments (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  expense_id uuid not null,
  kind text not null,
  reversal_of uuid,
  method text not null,
  amount integer not null,
  paid_at timestamptz not null,
  notes text,
  operation_id uuid not null,
  operation_fingerprint bytea not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid,
  void_reason text,
  constraint expense_payments_pkey primary key (id),
  constraint expense_payments_id_org_key unique (id, organization_id),
  constraint expense_payments_org_fkey foreign key (organization_id) references public.organizations(id) on delete restrict,
  constraint expense_payments_expense_org_fkey foreign key (expense_id, organization_id)
    references public.expenses(id, organization_id) on delete restrict,
  -- devolução só pode apontar para lançamento da MESMA organização (integridade relacional, além do trigger)
  constraint expense_payments_reversal_org_fkey foreign key (reversal_of, organization_id)
    references public.expense_payments(id, organization_id) on delete restrict,
  constraint expense_payments_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null,
  constraint expense_payments_voided_by_fkey foreign key (voided_by) references auth.users(id) on delete set null,
  constraint expense_payments_kind_chk check (kind in ('PAYMENT', 'REVERSAL')),
  constraint expense_payments_reversal_chk check ((kind = 'REVERSAL') = (reversal_of is not null)),
  constraint expense_payments_method_chk check (method in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER')),
  constraint expense_payments_amount_chk check (amount between 1 and 100000000),
  constraint expense_payments_paid_at_chk check (
    paid_at >= timestamptz '2000-01-01 00:00:00+00' and paid_at < timestamptz '2101-01-01 00:00:00+00'),
  constraint expense_payments_notes_chk check (notes is null or (notes = btrim(notes) and notes <> '' and char_length(notes) <= 500)),
  constraint expense_payments_fingerprint_chk check (octet_length(operation_fingerprint) = 32),
  constraint expense_payments_void_chk check (((voided_at is null) = (void_reason is null)) and (voided_at is not null or voided_by is null)),
  constraint expense_payments_void_reason_chk check (
    void_reason is null or (void_reason = btrim(void_reason) and void_reason <> '' and char_length(void_reason) <= 500))
);
create unique index idx_expense_payments_org_operation on public.expense_payments (organization_id, operation_id);
create index idx_expense_payments_org_paid on public.expense_payments (organization_id, paid_at, id);
create index idx_expense_payments_expense on public.expense_payments (expense_id);
create index idx_expense_payments_reversal_of on public.expense_payments (reversal_of) where reversal_of is not null;

-- -----------------------------------------------------------------------------
-- 4) Funções de trigger + triggers das tabelas novas
-- -----------------------------------------------------------------------------
create function private.enforce_expense_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.arena_id is not null and (tg_op = 'INSERT' or new.arena_id is distinct from old.arena_id)
     and not exists (select 1 from public.arenas a where a.id = new.arena_id and a.organization_id = new.organization_id) then
    raise exception 'tenant_mismatch: arena não pertence à organização da despesa' using errcode = 'RGT01';
  end if;
  return new;
end $$;

create function private.protect_expense_record()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_net bigint;
begin
  -- identidade imutável (created_by/cancelled_by só podem virar NULL pela FK ON DELETE SET NULL)
  if row(new.id, new.organization_id, new.operation_id, new.operation_fingerprint, new.created_at)
     is distinct from row(old.id, old.organization_id, old.operation_id, old.operation_fingerprint, old.created_at)
     or (new.created_by is distinct from old.created_by and new.created_by is not null) then
    raise exception 'expense_immutable: identidade da despesa não pode ser alterada' using errcode = 'RGT02';
  end if;
  -- despesa cancelada: nada mais muda
  if old.cancelled_at is not null then
    if row(new.arena_id, new.category_id, new.description, new.amount, new.due_date, new.notes,
           new.cancelled_at, new.cancel_reason)
       is distinct from row(old.arena_id, old.category_id, old.description, old.amount, old.due_date, old.notes,
           old.cancelled_at, old.cancel_reason)
       or (new.cancelled_by is distinct from old.cancelled_by and new.cancelled_by is not null) then
      raise exception 'rg: despesa cancelada não pode ser alterada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
    end if;
    return new;
  end if;
  if new.cancelled_at is null and (new.cancelled_by is not null or new.cancel_reason is not null) then
    raise exception 'expense_immutable: dados de cancelamento sem cancelamento' using errcode = 'RGT02';
  end if;
  -- valor e arena ficam imutáveis enquanto existir PAYMENT não anulado (mesmo se totalmente devolvido)
  if (new.amount is distinct from old.amount or new.arena_id is distinct from old.arena_id)
     and exists (select 1 from public.expense_payments p
                  where p.expense_id = old.id and p.kind = 'PAYMENT' and p.voided_at is null) then
    if new.amount is distinct from old.amount then
      raise exception 'rg: valor da despesa não pode mudar depois de um pagamento' using errcode = 'RGP01', hint = 'AMOUNT_LOCKED';
    end if;
    raise exception 'rg: arena da despesa não pode mudar depois de um pagamento' using errcode = 'RGP01', hint = 'ARENA_LOCKED';
  end if;
  -- cancelamento só com pago líquido = 0
  if new.cancelled_at is not null then
    select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
      from public.expense_payments p where p.expense_id = old.id and p.voided_at is null;
    if v_net <> 0 then
      raise exception 'rg: despesa com valor pago não pode ser cancelada' using errcode = 'RGP01', hint = 'NET_PAID';
    end if;
  end if;
  return new;
end $$;

create function private.enforce_expense_payment_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_exp public.expenses;
  v_parent public.expense_payments;
  v_net bigint;
  v_reversed bigint;
begin
  if new.voided_at is not null or new.voided_by is not null or new.void_reason is not null then
    raise exception 'payment_invalid: lançamento não pode nascer anulado' using errcode = '23514';
  end if;
  -- ordem global: despesa antes do lançamento original
  select e.* into v_exp from public.expenses e
   where e.id = new.expense_id and e.organization_id = new.organization_id for update;
  if not found then
    raise exception 'tenant_mismatch: lançamento não corresponde à organização da despesa' using errcode = 'RGT01';
  end if;
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  if new.paid_at > now() + interval '5 minutes' then
    raise exception 'payment_invalid: data do movimento no futuro' using errcode = '23514';
  end if;
  select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
    from public.expense_payments p where p.expense_id = new.expense_id and p.voided_at is null;
  if new.kind = 'PAYMENT' then
    if v_net + new.amount > v_exp.amount then
      raise exception 'rg: valor acima do saldo a pagar' using errcode = 'RGP03', hint = 'OVER_BALANCE';
    end if;
  else
    select p.* into v_parent from public.expense_payments p where p.id = new.reversal_of for update;
    if not found or v_parent.organization_id <> new.organization_id or v_parent.expense_id <> new.expense_id then
      raise exception 'payment_invalid: devolução deve referenciar um pagamento da mesma despesa' using errcode = '23514';
    end if;
    if v_parent.kind <> 'PAYMENT' then
      raise exception 'rg: somente pagamentos podem ser devolvidos' using errcode = 'RGP01', hint = 'NOT_A_PAYMENT';
    end if;
    if v_parent.voided_at is not null then
      raise exception 'rg: pagamento anulado não pode ser devolvido' using errcode = 'RGP01', hint = 'PAYMENT_VOIDED';
    end if;
    select coalesce(sum(c.amount), 0) into v_reversed from public.expense_payments c
     where c.reversal_of = new.reversal_of and c.voided_at is null;
    if v_reversed + new.amount > v_parent.amount then
      raise exception 'rg: devolução acima do valor do pagamento' using errcode = 'RGP03', hint = 'OVER_REVERSIBLE';
    end if;
  end if;
  return new;
end $$;

create function private.protect_expense_payment_ledger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_exp public.expenses;
  v_net bigint;
begin
  if row(new.id, new.organization_id, new.expense_id, new.kind, new.reversal_of, new.method, new.amount, new.paid_at,
         new.notes, new.operation_id, new.operation_fingerprint, new.created_at)
     is distinct from row(old.id, old.organization_id, old.expense_id, old.kind, old.reversal_of, old.method, old.amount,
         old.paid_at, old.notes, old.operation_id, old.operation_fingerprint, old.created_at)
     or (new.created_by is distinct from old.created_by and new.created_by is not null) then
    raise exception 'ledger_immutable: lançamento de despesa não pode ser alterado' using errcode = 'RGT02';
  end if;
  if old.voided_at is not null then
    if new.voided_at is distinct from old.voided_at or new.void_reason is distinct from old.void_reason
       or (new.voided_by is distinct from old.voided_by and new.voided_by is not null) then
      raise exception 'ledger_immutable: anulação já registrada' using errcode = 'RGT02';
    end if;
    return new;
  end if;
  if new.voided_at is null then
    if new.voided_by is not null or new.void_reason is not null then
      raise exception 'ledger_immutable: dados de anulação sem anulação' using errcode = 'RGT02';
    end if;
    return new;
  end if;
  -- anulação agora: revalida contra a despesa (o RPC já detém o lock; aqui é reentrante)
  select e.* into v_exp from public.expenses e where e.id = old.expense_id for update;
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  if old.kind = 'PAYMENT' and exists (
    select 1 from public.expense_payments c where c.reversal_of = old.id and c.voided_at is null) then
    raise exception 'rg: anule primeiro as devoluções deste pagamento' using errcode = 'RGP01', hint = 'HAS_REVERSALS';
  end if;
  if old.kind = 'REVERSAL' then
    select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
      from public.expense_payments p where p.expense_id = old.expense_id and p.voided_at is null;
    if v_net + old.amount > v_exp.amount then
      raise exception 'rg: anular esta devolução deixaria a despesa paga acima do valor' using errcode = 'RGP03', hint = 'OVER_BALANCE';
    end if;
  end if;
  return new;
end $$;

create trigger enforce_expense_integrity before insert or update on public.expenses
  for each row execute function private.enforce_expense_integrity();
create trigger protect_expense_record before update on public.expenses
  for each row execute function private.protect_expense_record();
create trigger guard_expense_delete before delete on public.expenses
  for each row execute function private.guard_finance_delete();
create trigger trg_expenses_updated before update on public.expenses
  for each row execute function public.set_updated_at();
create trigger trg_expense_categories_updated before update on public.expense_categories
  for each row execute function public.set_updated_at();
create trigger enforce_expense_payment_integrity before insert on public.expense_payments
  for each row execute function private.enforce_expense_payment_integrity();
create trigger protect_expense_payment_ledger before update on public.expense_payments
  for each row execute function private.protect_expense_payment_ledger();
create trigger guard_expense_payment_delete before delete on public.expense_payments
  for each row execute function private.guard_finance_delete();

-- -----------------------------------------------------------------------------
-- 5) Helpers privados
-- -----------------------------------------------------------------------------
-- Vínculo ATIVO real OWNER/MANAGER. Diferente de private.is_org_manager: NÃO inclui admin da plataforma.
create function private.rg_exp_is_manager(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_org is not null and p_user is not null and exists (
    select 1 from public.organization_members m
     where m.organization_id = p_org and m.user_id = p_user and m.status = 'ACTIVE' and m.role in ('OWNER', 'MANAGER'))
$$;

-- Cópia de private.rg_fin_scope com rg_exp_is_manager: autorização + período + arena => [v_start, v_end)
create function private.rg_exp_scope(p_org uuid, p_arena uuid, p_from date, p_to date, p_max_days integer)
returns table (v_start timestamptz, v_end timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to
     or extract(year from p_from) not between 2000 and 2100
     or extract(year from p_to) not between 2000 and 2100 then
    raise exception 'rg: período inválido' using errcode = '22023';
  end if;
  if (p_to - p_from + 1) > p_max_days then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;
  if p_arena is not null and not exists (
       select 1 from public.arenas a where a.id = p_arena and a.organization_id = p_org) then
    raise exception 'rg: arena inválida' using errcode = '22023';
  end if;
  v_start := p_from::timestamp at time zone 'America/Sao_Paulo';
  v_end := (p_to + 1)::timestamp at time zone 'America/Sao_Paulo';
  return next;
end $$;

-- Núcleo set-based por despesa (ÚNICA fonte de status/saldos). Sem checagem de papel: só é chamado
-- pelas RPCs, DEPOIS da autorização. Filtro por vencimento [p_from, p_to] (NULL = sem limite).
-- Arena informada => só despesas daquela arena (gerais ficam fora).
create function private.rg_exp_rows(p_org uuid, p_arena uuid, p_from date, p_to date)
returns table (
  expense_id uuid, organization_id uuid, arena_id uuid, category_id uuid, description text, amount integer,
  due_date date, notes text, created_by uuid, created_at timestamptz, updated_at timestamptz,
  cancelled_at timestamptz, cancel_reason text,
  paid_gross bigint, reversed bigint, net_paid bigint, amount_due bigint, has_valid_payment boolean,
  status text, overdue boolean)
language sql stable security definer set search_path = '' as $$
  with e as (
    select x.* from public.expenses x
     where x.organization_id = p_org
       and (p_arena is null or x.arena_id = p_arena)
       and (p_from is null or x.due_date >= p_from)
       and (p_to is null or x.due_date <= p_to)
  ), p as (
    select y.expense_id,
           coalesce(sum(y.amount) filter (where y.kind = 'PAYMENT'), 0)::bigint as paid_gross,
           coalesce(sum(y.amount) filter (where y.kind = 'REVERSAL'), 0)::bigint as reversed,
           bool_or(y.kind = 'PAYMENT') as has_valid
      from public.expense_payments y
     where y.organization_id = p_org and y.voided_at is null and y.expense_id in (select e.id from e)
     group by y.expense_id
  ), j as (
    select e.*, coalesce(p.paid_gross, 0) as pg, coalesce(p.reversed, 0) as rv, coalesce(p.has_valid, false) as hv
      from e left join p on p.expense_id = e.id
  )
  select j.id, j.organization_id, j.arena_id, j.category_id, j.description, j.amount, j.due_date, j.notes,
         j.created_by, j.created_at, j.updated_at, j.cancelled_at, j.cancel_reason,
         j.pg, j.rv, j.pg - j.rv,
         case when j.cancelled_at is not null then 0 else j.amount - (j.pg - j.rv) end::bigint,
         j.hv,
         case when j.cancelled_at is not null then 'CANCELLED'
              when j.amount - (j.pg - j.rv) = 0 then 'PAID'
              when j.pg - j.rv > 0 then 'PARTIAL'
              else 'OPEN' end,
         (j.cancelled_at is null and j.amount - (j.pg - j.rv) > 0 and j.due_date < private.rg_today())
    from j
$$;

create function private.rg_exp_validate_entry(p_operation_id uuid, p_method text, p_amount integer, p_at timestamptz)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER') then
    raise exception 'rg: meio de pagamento inválido' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000000 then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  if p_at is null or p_at < timestamptz '2000-01-01 00:00:00+00' or p_at >= timestamptz '2101-01-01 00:00:00+00' then
    raise exception 'rg: data do movimento inválida' using errcode = '22023';
  end if;
end $$;

create function private.rg_exp_fingerprint_expense(
  p_org uuid, p_arena uuid, p_category uuid, p_description text, p_amount integer, p_due_date date, p_notes text)
returns bytea language sql immutable set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object(
    'v', 1, 'kind', 'EXPENSE', 'organization_id', p_org, 'arena_id', p_arena, 'category_id', p_category,
    'description', p_description, 'amount', p_amount, 'due_date', to_char(p_due_date, 'YYYY-MM-DD'),
    'notes', p_notes)::text, 'UTF8'))
$$;

create function private.rg_exp_fingerprint_payment(
  p_kind text, p_expense_id uuid, p_reversal_of uuid, p_amount integer, p_method text, p_at timestamptz, p_notes text)
returns bytea language sql stable set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object(
    'v', 1, 'kind', p_kind, 'expense_id', p_expense_id, 'reversal_of', p_reversal_of, 'amount', p_amount,
    'method', p_method, 'at', to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'notes', p_notes)::text, 'UTF8'))
$$;

-- Seed idempotente das 10 categorias padrão. Não sobrescreve nem reativa nada existente.
create function private.rg_exp_seed_default_categories(p_org uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  insert into public.expense_categories (organization_id, name)
  select p_org, d.name
    from unnest(array['Aluguel', 'Energia', 'Água', 'Internet', 'Funcionários', 'Manutenção', 'Materiais',
                      'Marketing', 'Impostos e taxas', 'Outros']) with ordinality as d(name, ord)
   order by d.ord
  on conflict (organization_id, name_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create function private.rg_exp_seed_org_categories()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.rg_exp_seed_default_categories(new.id);
  return null;
end $$;

-- -----------------------------------------------------------------------------
-- 6) RPCs de escrita
-- -----------------------------------------------------------------------------
create function public.rg_expense_category_create(p_org uuid, p_name text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_cat public.expense_categories;
  v_constraint text;
  v_conflict boolean := false;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  if v_name = '' or char_length(v_name) > 60 then
    raise exception 'rg: nome de categoria inválido' using errcode = '22023';
  end if;
  select c.* into v_cat from public.expense_categories c
   where c.organization_id = p_org and c.name_key = private.rg_exp_name_key(v_name);
  if not found then
    begin
      insert into public.expense_categories (organization_id, name) values (p_org, v_name) returning * into v_cat;
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'idx_expense_categories_org_name_key' then
          raise;
        end if;
        v_conflict := true;
    end;
    if v_conflict then
      -- corrida com outra criação equivalente: relê a versão confirmada
      select c.* into v_cat from public.expense_categories c
       where c.organization_id = p_org and c.name_key = private.rg_exp_name_key(v_name);
      if not found then
        raise exception 'rg: conflito ao criar categoria, tente novamente' using errcode = '40001';
      end if;
    else
      perform private.rg_fault('expense_category_create:after_insert');
      insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
      values (p_org, v_uid, 'EXPENSE_CATEGORY_CREATED', 'expense_category', v_cat.id, jsonb_build_object('name', v_cat.name));
      return jsonb_build_object('category_id', v_cat.id, 'name', v_cat.name, 'is_active', v_cat.is_active, 'created', true);
    end if;
  end if;
  if not v_cat.is_active then
    raise exception 'rg: já existe uma categoria equivalente inativa' using errcode = 'RGP01', hint = 'CATEGORY_INACTIVE_EXISTS';
  end if;
  return jsonb_build_object('category_id', v_cat.id, 'name', v_cat.name, 'is_active', v_cat.is_active, 'created', false);
end $$;

create function public.rg_expense_category_update(p_category_id uuid, p_changes jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_cat public.expense_categories;
  v_key text;
  v_name text;
  v_active boolean;
  v_constraint text;
  v_action text;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  -- p_changes estrito: objeto não vazio, allowlist, tipos validados
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'rg: alterações inválidas' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('name', 'is_active') then
      raise exception 'rg: campo não permitido: %', v_key using errcode = '22023';
    end if;
  end loop;
  if p_changes ? 'name' then
    if jsonb_typeof(p_changes->'name') <> 'string' then
      raise exception 'rg: nome de categoria inválido' using errcode = '22023';
    end if;
    v_name := btrim(regexp_replace(p_changes->>'name', '\s+', ' ', 'g'));
    if v_name = '' or char_length(v_name) > 60 then
      raise exception 'rg: nome de categoria inválido' using errcode = '22023';
    end if;
  end if;
  if p_changes ? 'is_active' and jsonb_typeof(p_changes->'is_active') <> 'boolean' then
    raise exception 'rg: is_active inválido' using errcode = '22023';
  end if;
  -- leitura sem lock só para descobrir a organização
  select c.organization_id into v_org from public.expense_categories c where c.id = p_category_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: categoria não encontrada' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select c.* into v_cat from public.expense_categories c where c.id = p_category_id and c.organization_id = v_org for update;
  if not found then
    raise exception 'rg: categoria não encontrada' using errcode = 'P0002';
  end if;
  v_name := coalesce(v_name, v_cat.name);
  v_active := coalesce((p_changes->>'is_active')::boolean, v_cat.is_active);
  if v_name = v_cat.name and v_active = v_cat.is_active then
    return jsonb_build_object('category_id', v_cat.id, 'name', v_cat.name, 'is_active', v_cat.is_active, 'changed', false);
  end if;
  begin
    update public.expense_categories c set name = v_name, is_active = v_active where c.id = v_cat.id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_expense_categories_org_name_key' then
        raise;
      end if;
      raise exception 'rg: já existe categoria com este nome' using errcode = 'RGP01', hint = 'CATEGORY_NAME_EXISTS';
  end;
  perform private.rg_fault('expense_category_update:after_update');
  -- uma ação por chamada: mudança de ativo prevalece; renomeação vai nos metadados
  v_action := case when v_active <> v_cat.is_active and not v_active then 'EXPENSE_CATEGORY_DEACTIVATED'
                   when v_active <> v_cat.is_active and v_active then 'EXPENSE_CATEGORY_REACTIVATED'
                   else 'EXPENSE_CATEGORY_UPDATED' end;
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, v_action, 'expense_category', v_cat.id,
    jsonb_build_object('name', jsonb_build_object('from', v_cat.name, 'to', v_name),
                       'is_active', jsonb_build_object('from', v_cat.is_active, 'to', v_active)));
  return jsonb_build_object('category_id', v_cat.id, 'name', v_name, 'is_active', v_active, 'changed', true);
end $$;

create function public.rg_expense_create(
  p_operation_id uuid, p_org uuid, p_arena uuid, p_category uuid, p_description text, p_amount integer,
  p_due_date date, p_notes text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_desc text := btrim(regexp_replace(coalesce(p_description, ''), '\s+', ' ', 'g'));
  v_notes text;
  v_cat public.expense_categories;
  v_fp bytea;
  v_existing public.expenses;
  v_id uuid;
  v_constraint text;
  v_conflict boolean := false;
begin
  -- 1) autenticação + forma imutável da intenção
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  if v_desc = '' or char_length(v_desc) > 200 then
    raise exception 'rg: descrição inválida' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000000 then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  if p_due_date is null or p_due_date not between date '2000-01-01' and date '2100-12-31' then
    raise exception 'rg: vencimento inválido' using errcode = '22023';
  end if;
  if p_category is null then
    raise exception 'rg: categoria inválida' using errcode = '22023';
  end if;
  v_notes := private.rg_fin_notes(p_notes);
  -- 2) tenant/autorização
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  -- 3) lock: categoria (FOR SHARE impede inativação concorrente)
  select c.* into v_cat from public.expense_categories c
   where c.id = p_category and c.organization_id = p_org for share;
  if not found then
    raise exception 'rg: categoria inválida' using errcode = '22023';
  end if;
  -- 4) operation_id já confirmado? (antes do estado mutável)
  v_fp := private.rg_exp_fingerprint_expense(p_org, p_arena, p_category, v_desc, p_amount, p_due_date, v_notes);
  select e.* into v_existing from public.expenses e where e.organization_id = p_org and e.operation_id = p_operation_id;
  if found then
    if v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('expense_id', v_existing.id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  -- 5) estado mutável
  if not v_cat.is_active then
    raise exception 'rg: categoria inativa' using errcode = 'RGP01', hint = 'CATEGORY_INACTIVE';
  end if;
  if p_arena is not null and not exists (select 1 from public.arenas a where a.id = p_arena and a.organization_id = p_org) then
    raise exception 'rg: arena inválida' using errcode = '22023';
  end if;
  -- 6) nova operação (corrida do mesmo operation_id => 23505 no índice => reler)
  begin
    insert into public.expenses (organization_id, arena_id, category_id, description, amount, due_date, notes,
      operation_id, operation_fingerprint, created_by)
    values (p_org, p_arena, p_category, v_desc, p_amount, p_due_date, v_notes, p_operation_id, v_fp, v_uid)
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_expenses_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select e.* into v_existing from public.expenses e where e.organization_id = p_org and e.operation_id = p_operation_id;
    if found and v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('expense_id', v_existing.id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('expense_create:after_insert');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (p_org, v_uid, 'EXPENSE_CREATED', 'expense', v_id,
    jsonb_build_object('amount', p_amount, 'category_id', p_category, 'arena_id', p_arena, 'due_date', p_due_date));
  return jsonb_build_object('expense_id', v_id, 'idempotent', false);
end $$;

create function public.rg_expense_update(p_expense_id uuid, p_changes jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_key text;
  v_new_cat uuid;
  v_cat public.expense_categories;
  v_exp public.expenses;
  v_desc text;
  v_arena uuid;
  v_amount integer;
  v_due date;
  v_notes text;
  v_diff jsonb := '{}'::jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  -- p_changes estrito: objeto não vazio, allowlist explícita, tipo de cada valor validado
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'rg: alterações inválidas' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('description', 'category_id', 'arena_id', 'amount', 'due_date', 'notes') then
      raise exception 'rg: campo não permitido: %', v_key using errcode = '22023';
    end if;
  end loop;
  if p_changes ? 'description' then
    if jsonb_typeof(p_changes->'description') <> 'string' then
      raise exception 'rg: descrição inválida' using errcode = '22023';
    end if;
    v_desc := btrim(regexp_replace(p_changes->>'description', '\s+', ' ', 'g'));
    if v_desc = '' or char_length(v_desc) > 200 then
      raise exception 'rg: descrição inválida' using errcode = '22023';
    end if;
  end if;
  if p_changes ? 'category_id' then
    if jsonb_typeof(p_changes->'category_id') <> 'string'
       or p_changes->>'category_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'rg: categoria inválida' using errcode = '22023';
    end if;
    v_new_cat := (p_changes->>'category_id')::uuid;
  end if;
  if p_changes ? 'arena_id' then
    if jsonb_typeof(p_changes->'arena_id') = 'null' then
      v_arena := null;
    elsif jsonb_typeof(p_changes->'arena_id') <> 'string'
          or p_changes->>'arena_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'rg: arena inválida' using errcode = '22023';
    else
      v_arena := (p_changes->>'arena_id')::uuid;
    end if;
  end if;
  if p_changes ? 'amount' then
    if jsonb_typeof(p_changes->'amount') <> 'number' or (p_changes->>'amount') !~ '^[0-9]{1,9}$'
       or (p_changes->>'amount')::bigint not between 1 and 100000000 then
      raise exception 'rg: valor inválido' using errcode = '22023';
    end if;
    v_amount := (p_changes->>'amount')::integer;
  end if;
  if p_changes ? 'due_date' then
    if jsonb_typeof(p_changes->'due_date') <> 'string' or (p_changes->>'due_date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'rg: vencimento inválido' using errcode = '22023';
    end if;
    begin
      v_due := (p_changes->>'due_date')::date;
    exception when others then
      raise exception 'rg: vencimento inválido' using errcode = '22023';
    end;
    if to_char(v_due, 'YYYY-MM-DD') <> p_changes->>'due_date' or v_due not between date '2000-01-01' and date '2100-12-31' then
      raise exception 'rg: vencimento inválido' using errcode = '22023';
    end if;
  end if;
  if p_changes ? 'notes' then
    if jsonb_typeof(p_changes->'notes') = 'null' then
      v_notes := null;
    elsif jsonb_typeof(p_changes->'notes') <> 'string' then
      raise exception 'rg: observação inválida' using errcode = '22023';
    else
      v_notes := private.rg_fin_notes(p_changes->>'notes');
    end if;
  end if;
  -- leitura sem lock só para descobrir a organização
  select e.organization_id into v_org from public.expenses e where e.id = p_expense_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  -- locks na ordem global: categoria nova (FOR SHARE) -> despesa (FOR UPDATE)
  if v_new_cat is not null then
    select c.* into v_cat from public.expense_categories c where c.id = v_new_cat and c.organization_id = v_org for share;
    if not found then
      raise exception 'rg: categoria inválida' using errcode = '22023';
    end if;
  end if;
  select e.* into v_exp from public.expenses e where e.id = p_expense_id and e.organization_id = v_org for update;
  if not found then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  -- revalidação depois dos locks
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada não pode ser alterada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  if p_changes ? 'description' and v_desc is distinct from v_exp.description then
    v_diff := v_diff || jsonb_build_object('description', jsonb_build_object('from', v_exp.description, 'to', v_desc));
  else
    v_desc := v_exp.description;
  end if;
  if v_new_cat is not null and v_new_cat is distinct from v_exp.category_id then
    if not v_cat.is_active then
      raise exception 'rg: categoria inativa' using errcode = 'RGP01', hint = 'CATEGORY_INACTIVE';
    end if;
    v_diff := v_diff || jsonb_build_object('category_id', jsonb_build_object('from', v_exp.category_id, 'to', v_new_cat));
  else
    v_new_cat := v_exp.category_id;
  end if;
  if p_changes ? 'arena_id' and v_arena is distinct from v_exp.arena_id then
    if v_arena is not null and not exists (select 1 from public.arenas a where a.id = v_arena and a.organization_id = v_org) then
      raise exception 'rg: arena inválida' using errcode = '22023';
    end if;
    v_diff := v_diff || jsonb_build_object('arena_id', jsonb_build_object('from', v_exp.arena_id, 'to', v_arena));
  else
    v_arena := v_exp.arena_id;
  end if;
  if p_changes ? 'amount' and v_amount is distinct from v_exp.amount then
    v_diff := v_diff || jsonb_build_object('amount', jsonb_build_object('from', v_exp.amount, 'to', v_amount));
  else
    v_amount := v_exp.amount;
  end if;
  if p_changes ? 'due_date' and v_due is distinct from v_exp.due_date then
    v_diff := v_diff || jsonb_build_object('due_date', jsonb_build_object('from', v_exp.due_date, 'to', v_due));
  else
    v_due := v_exp.due_date;
  end if;
  if p_changes ? 'notes' and v_notes is distinct from v_exp.notes then
    v_diff := v_diff || jsonb_build_object('notes', jsonb_build_object('changed', true));
  else
    v_notes := v_exp.notes;
  end if;
  if (v_diff ? 'amount' or v_diff ? 'arena_id') and exists (
       select 1 from public.expense_payments p where p.expense_id = v_exp.id and p.kind = 'PAYMENT' and p.voided_at is null) then
    if v_diff ? 'amount' then
      raise exception 'rg: valor da despesa não pode mudar depois de um pagamento' using errcode = 'RGP01', hint = 'AMOUNT_LOCKED';
    end if;
    raise exception 'rg: arena da despesa não pode mudar depois de um pagamento' using errcode = 'RGP01', hint = 'ARENA_LOCKED';
  end if;
  if v_diff = '{}'::jsonb then
    return jsonb_build_object('expense_id', v_exp.id, 'changed', false);
  end if;
  update public.expenses e
     set description = v_desc, category_id = v_new_cat, arena_id = v_arena, amount = v_amount, due_date = v_due, notes = v_notes
   where e.id = v_exp.id;
  perform private.rg_fault('expense_update:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'EXPENSE_UPDATED', 'expense', v_exp.id, jsonb_build_object('changes', v_diff));
  return jsonb_build_object('expense_id', v_exp.id, 'changed', true);
end $$;

create function public.rg_expense_cancel(p_expense_id uuid, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_org uuid;
  v_exp public.expenses;
  v_net bigint;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'rg: informe o motivo do cancelamento' using errcode = '22023';
  end if;
  select e.organization_id into v_org from public.expenses e where e.id = p_expense_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select e.* into v_exp from public.expenses e where e.id = p_expense_id and e.organization_id = v_org for update;
  if not found then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  if v_exp.cancelled_at is not null then
    return jsonb_build_object('expense_id', v_exp.id, 'changed', false);
  end if;
  select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
    from public.expense_payments p where p.expense_id = v_exp.id and p.voided_at is null;
  if v_net <> 0 then
    raise exception 'rg: despesa com valor pago não pode ser cancelada' using errcode = 'RGP01', hint = 'NET_PAID';
  end if;
  update public.expenses e set cancelled_at = now(), cancelled_by = v_uid, cancel_reason = v_reason where e.id = v_exp.id;
  perform private.rg_fault('expense_cancel:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'EXPENSE_CANCELLED', 'expense', v_exp.id, jsonb_build_object('amount', v_exp.amount));
  return jsonb_build_object('expense_id', v_exp.id, 'changed', true);
end $$;

create function public.rg_expense_payment_register(
  p_operation_id uuid, p_expense_id uuid, p_method text, p_amount integer, p_paid_at timestamptz, p_notes text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_notes text;
  v_org uuid;
  v_exp public.expenses;
  v_fp bytea;
  v_existing public.expense_payments;
  v_net bigint;
  v_id uuid;
  v_constraint text;
  v_conflict boolean := false;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  perform private.rg_exp_validate_entry(p_operation_id, p_method, p_amount, p_paid_at);
  v_notes := private.rg_fin_notes(p_notes);
  select e.organization_id into v_org from public.expenses e where e.id = p_expense_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select e.* into v_exp from public.expenses e where e.id = p_expense_id and e.organization_id = v_org for update;
  if not found then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  -- idempotência antes do estado mutável
  v_fp := private.rg_exp_fingerprint_payment('PAYMENT', v_exp.id, null, p_amount, p_method, p_paid_at, v_notes);
  select p.* into v_existing from public.expense_payments p where p.organization_id = v_org and p.operation_id = p_operation_id;
  if found then
    if v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'expense_id', v_existing.expense_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
    from public.expense_payments p where p.expense_id = v_exp.id and p.voided_at is null;
  if p_amount > v_exp.amount - v_net then
    raise exception 'rg: valor acima do saldo a pagar' using errcode = 'RGP03', hint = 'OVER_BALANCE';
  end if;
  begin
    insert into public.expense_payments (organization_id, expense_id, kind, reversal_of, method, amount, paid_at, notes,
      operation_id, operation_fingerprint, created_by)
    values (v_org, v_exp.id, 'PAYMENT', null, p_method, p_amount, p_paid_at, v_notes, p_operation_id, v_fp, v_uid)
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_expense_payments_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select p.* into v_existing from public.expense_payments p where p.organization_id = v_org and p.operation_id = p_operation_id;
    if found and v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'expense_id', v_existing.expense_id, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('expense_payment:after_insert');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'EXPENSE_PAYMENT_RECORDED', 'expense_payment', v_id,
    jsonb_build_object('expense_id', v_exp.id, 'amount', p_amount, 'method', p_method));
  return jsonb_build_object('payment_id', v_id, 'expense_id', v_exp.id, 'idempotent', false);
end $$;

create function public.rg_expense_payment_reverse(
  p_operation_id uuid, p_payment_id uuid, p_method text, p_amount integer, p_reversed_at timestamptz, p_notes text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_notes text;
  v_org uuid;
  v_exp_id uuid;
  v_exp public.expenses;
  v_pay public.expense_payments;
  v_fp bytea;
  v_existing public.expense_payments;
  v_reversed bigint;
  v_id uuid;
  v_constraint text;
  v_conflict boolean := false;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  perform private.rg_exp_validate_entry(p_operation_id, p_method, p_amount, p_reversed_at);
  v_notes := private.rg_fin_notes(p_notes);
  -- leitura preliminar sem lock: só localiza organização/despesa
  select p.organization_id, p.expense_id into v_org, v_exp_id from public.expense_payments p where p.id = p_payment_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: lançamento não encontrado' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  -- locks: despesa -> lançamento original; tudo revalidado depois
  select e.* into v_exp from public.expenses e where e.id = v_exp_id and e.organization_id = v_org for update;
  select p.* into v_pay from public.expense_payments p where p.id = p_payment_id for update;
  if v_exp.id is null or v_pay.id is null or v_pay.organization_id <> v_org or v_pay.expense_id <> v_exp.id then
    raise exception 'rg: lançamento não encontrado' using errcode = 'P0002';
  end if;
  v_fp := private.rg_exp_fingerprint_payment('REVERSAL', v_exp.id, v_pay.id, p_amount, p_method, p_reversed_at, v_notes);
  select p.* into v_existing from public.expense_payments p where p.organization_id = v_org and p.operation_id = p_operation_id;
  if found then
    if v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'expense_id', v_existing.expense_id,
                                'reversal_of', v_existing.reversal_of, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  if v_pay.kind <> 'PAYMENT' then
    raise exception 'rg: somente pagamentos podem ser devolvidos' using errcode = 'RGP01', hint = 'NOT_A_PAYMENT';
  end if;
  if v_pay.voided_at is not null then
    raise exception 'rg: pagamento anulado não pode ser devolvido' using errcode = 'RGP01', hint = 'PAYMENT_VOIDED';
  end if;
  select coalesce(sum(c.amount), 0) into v_reversed from public.expense_payments c
   where c.reversal_of = v_pay.id and c.voided_at is null;
  if p_amount > v_pay.amount - v_reversed then
    raise exception 'rg: devolução acima do valor do pagamento' using errcode = 'RGP03', hint = 'OVER_REVERSIBLE';
  end if;
  begin
    insert into public.expense_payments (organization_id, expense_id, kind, reversal_of, method, amount, paid_at, notes,
      operation_id, operation_fingerprint, created_by)
    values (v_org, v_exp.id, 'REVERSAL', v_pay.id, p_method, p_amount, p_reversed_at, v_notes, p_operation_id, v_fp, v_uid)
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_expense_payments_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select p.* into v_existing from public.expense_payments p where p.organization_id = v_org and p.operation_id = p_operation_id;
    if found and v_existing.operation_fingerprint = v_fp then
      return jsonb_build_object('payment_id', v_existing.id, 'expense_id', v_existing.expense_id,
                                'reversal_of', v_existing.reversal_of, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('expense_reversal:after_insert');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'EXPENSE_PAYMENT_REVERSED', 'expense_payment', v_id,
    jsonb_build_object('expense_id', v_exp.id, 'reversal_of', v_pay.id, 'amount', p_amount, 'method', p_method));
  return jsonb_build_object('payment_id', v_id, 'expense_id', v_exp.id, 'reversal_of', v_pay.id, 'idempotent', false);
end $$;

create function public.rg_expense_payment_void(p_payment_id uuid, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_org uuid;
  v_exp_id uuid;
  v_exp public.expenses;
  v_pay public.expense_payments;
  v_net bigint;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) > 500 then
    raise exception 'rg: informe o motivo da anulação' using errcode = '22023';
  end if;
  select p.organization_id, p.expense_id into v_org, v_exp_id from public.expense_payments p where p.id = p_payment_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: lançamento não encontrado' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select e.* into v_exp from public.expenses e where e.id = v_exp_id and e.organization_id = v_org for update;
  select p.* into v_pay from public.expense_payments p where p.id = p_payment_id for update;
  if v_exp.id is null or v_pay.id is null or v_pay.organization_id <> v_org or v_pay.expense_id <> v_exp.id then
    raise exception 'rg: lançamento não encontrado' using errcode = 'P0002';
  end if;
  if v_pay.voided_at is not null then
    return jsonb_build_object('payment_id', v_pay.id, 'changed', false);
  end if;
  if v_exp.cancelled_at is not null then
    raise exception 'rg: despesa cancelada' using errcode = 'RGP01', hint = 'EXPENSE_CANCELLED';
  end if;
  if v_pay.kind = 'PAYMENT' and exists (
    select 1 from public.expense_payments c where c.reversal_of = v_pay.id and c.voided_at is null) then
    raise exception 'rg: anule primeiro as devoluções deste pagamento' using errcode = 'RGP01', hint = 'HAS_REVERSALS';
  end if;
  if v_pay.kind = 'REVERSAL' then
    select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) into v_net
      from public.expense_payments p where p.expense_id = v_exp.id and p.voided_at is null;
    if v_net + v_pay.amount > v_exp.amount then
      raise exception 'rg: anular esta devolução deixaria a despesa paga acima do valor' using errcode = 'RGP03', hint = 'OVER_BALANCE';
    end if;
  end if;
  update public.expense_payments p set voided_at = now(), voided_by = v_uid, void_reason = v_reason where p.id = v_pay.id;
  perform private.rg_fault('expense_void:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'EXPENSE_PAYMENT_VOIDED', 'expense_payment', v_pay.id,
    jsonb_build_object('expense_id', v_exp.id, 'kind', v_pay.kind, 'amount', v_pay.amount));
  return jsonb_build_object('payment_id', v_pay.id, 'changed', true);
end $$;

-- -----------------------------------------------------------------------------
-- 7) RPCs de leitura (STABLE: o banco proíbe escrita)
-- -----------------------------------------------------------------------------
create function public.rg_expense_categories(p_org uuid, p_include_inactive boolean)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  v_uid uuid := auth.uid();
  v_items jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'is_active', c.is_active)
                            order by c.is_active desc, c.name_key, c.id), '[]'::jsonb)
    into v_items
    from public.expense_categories c
   where c.organization_id = p_org and (coalesce(p_include_inactive, false) or c.is_active);
  return jsonb_build_object('items', v_items);
end $$;

create function public.rg_expense_overview(p_org uuid, p_arena uuid, p_category uuid, p_from date, p_to date,
                                           p_compare_from date, p_compare_to date)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  a record;
  v_has_cmp boolean;
  v_c_expected bigint;
  v_c_count bigint;
begin
  select * into s from private.rg_exp_scope(p_org, p_arena, p_from, p_to, 366);
  if p_category is not null and not exists (
       select 1 from public.expense_categories c where c.id = p_category and c.organization_id = p_org) then
    raise exception 'rg: categoria inválida' using errcode = '22023';
  end if;
  if (p_compare_from is null) <> (p_compare_to is null) then
    raise exception 'rg: período de comparação inválido' using errcode = '22023';
  end if;
  v_has_cmp := p_compare_from is not null;
  if v_has_cmp and (p_compare_from > p_compare_to or p_compare_to >= p_from
       or (p_compare_to - p_compare_from + 1) > 366
       or extract(year from p_compare_from) not between 2000 and 2100
       or extract(year from p_compare_to) not between 2000 and 2100) then
    raise exception 'rg: período de comparação inválido' using errcode = '22023';
  end if;

  select coalesce(sum(r.amount) filter (where r.cancelled_at is null), 0)::bigint as expected,
         count(*) filter (where r.cancelled_at is null) as expected_count,
         coalesce(sum(r.net_paid) filter (where r.cancelled_at is null), 0)::bigint as paid,
         coalesce(sum(r.amount_due) filter (where r.cancelled_at is null), 0)::bigint as payable,
         count(*) filter (where r.cancelled_at is null and r.amount_due > 0) as payable_count,
         coalesce(sum(r.amount_due) filter (where r.overdue), 0)::bigint as overdue,
         count(*) filter (where r.overdue) as overdue_count,
         count(*) filter (where r.cancelled_at is not null) as cancelled_count
    into a
    from private.rg_exp_rows(p_org, p_arena, p_from, p_to) r
   where p_category is null or r.category_id = p_category;

  if v_has_cmp then
    select coalesce(sum(r.amount), 0)::bigint, count(*)
      into v_c_expected, v_c_count
      from private.rg_exp_rows(p_org, p_arena, p_compare_from, p_compare_to) r
     where r.cancelled_at is null and (p_category is null or r.category_id = p_category);
  end if;

  return jsonb_build_object(
    'period', jsonb_build_object('from', to_char(p_from, 'YYYY-MM-DD'), 'to', to_char(p_to, 'YYYY-MM-DD'),
                                 'days', p_to - p_from + 1, 'timezone', 'America/Sao_Paulo'),
    'compare', case when v_has_cmp then jsonb_build_object('from', to_char(p_compare_from, 'YYYY-MM-DD'),
                                 'to', to_char(p_compare_to, 'YYYY-MM-DD'), 'days', p_compare_to - p_compare_from + 1) end,
    'as_of', to_jsonb(now()),
    'excludes_general', p_arena is not null,
    'category_id', p_category,
    'expected', jsonb_build_object('current', a.expected, 'count', a.expected_count,
                                   'compare', v_c_expected, 'compare_count', v_c_count),
    'paid_of_period', jsonb_build_object('current', a.paid),
    'payable', jsonb_build_object('total', a.payable, 'count', a.payable_count),
    'overdue', jsonb_build_object('total', a.overdue, 'count', a.overdue_count),
    'cancelled_count', a.cancelled_count);
end $$;

create function public.rg_expenses(p_org uuid, p_arena uuid, p_category uuid, p_from date, p_to date, p_status text,
                                   p_limit integer, p_after_due date, p_after_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  v_status text := coalesce(p_status, 'ACTIVE');
  v_items jsonb;
  v_more boolean;
  v_last_due date;
  v_last_id uuid;
begin
  select * into s from private.rg_exp_scope(p_org, p_arena, p_from, p_to, 366);
  if v_status not in ('ACTIVE', 'OPEN', 'OVERDUE', 'PAID', 'CANCELLED') then
    raise exception 'rg: filtro inválido' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if (p_after_due is null) <> (p_after_id is null) then
    raise exception 'rg: cursor incompleto' using errcode = '22023';
  end if;
  if p_category is not null and not exists (
       select 1 from public.expense_categories c where c.id = p_category and c.organization_id = p_org) then
    raise exception 'rg: categoria inválida' using errcode = '22023';
  end if;

  with sel as (
    select r.*
      from private.rg_exp_rows(p_org, p_arena, p_from, p_to) r
     where (p_category is null or r.category_id = p_category)
       and case v_status
             when 'ACTIVE' then r.cancelled_at is null
             when 'OPEN' then r.status in ('OPEN', 'PARTIAL')
             when 'OVERDUE' then r.overdue
             when 'PAID' then r.status = 'PAID'
             else r.status = 'CANCELLED'
           end
       and (p_after_due is null or (r.due_date, r.expense_id) > (p_after_due, p_after_id))
     order by r.due_date, r.expense_id
     limit p_limit + 1
  ), num as (
    select sel.*, row_number() over (order by sel.due_date, sel.expense_id) as rn from sel
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'expense_id', n.expense_id, 'description', n.description, 'amount', n.amount, 'due_date', to_char(n.due_date, 'YYYY-MM-DD'),
           'category_id', n.category_id, 'category_name', c.name, 'arena_id', n.arena_id, 'arena_name', a.name,
           'net_paid', n.net_paid, 'amount_due', n.amount_due, 'status', n.status, 'overdue', n.overdue,
           'has_valid_payment', n.has_valid_payment, 'cancelled_at', n.cancelled_at)
           order by n.due_date, n.expense_id) filter (where n.rn <= p_limit), '[]'::jsonb),
         coalesce(bool_or(n.rn > p_limit), false)
    into v_items, v_more
    from num n
    left join public.expense_categories c on c.id = n.category_id and c.organization_id = p_org
    left join public.arenas a on a.id = n.arena_id and a.organization_id = p_org;

  if v_more then
    select (e->>'due_date')::date, (e->>'expense_id')::uuid into v_last_due, v_last_id
      from jsonb_array_elements(v_items) with ordinality as t(e, i) order by t.i desc limit 1;
  end if;
  return jsonb_build_object(
    'status', v_status,
    'excludes_general', p_arena is not null,
    'items', v_items,
    'next_cursor', case when v_more then jsonb_build_object('due_date', to_char(v_last_due, 'YYYY-MM-DD'), 'id', v_last_id) end);
end $$;

create function public.rg_expense_detail(p_expense_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_due date;
  r record;
  v_entries jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select e.organization_id, e.due_date into v_org, v_due from public.expenses e where e.id = p_expense_id;
  if v_org is null or not exists (select 1 from public.organization_members m
                                   where m.organization_id = v_org and m.user_id = v_uid and m.status = 'ACTIVE') then
    raise exception 'rg: despesa não encontrada' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select x.* into r from private.rg_exp_rows(v_org, null, v_due, v_due) x where x.expense_id = p_expense_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'kind', p.kind, 'reversal_of', p.reversal_of, 'method', p.method, 'amount', p.amount,
           'paid_at', p.paid_at, 'notes', p.notes, 'created_at', p.created_at,
           'voided_at', p.voided_at, 'void_reason', p.void_reason,
           'reversed', case when p.kind = 'PAYMENT' then coalesce((select sum(c.amount) from public.expense_payments c
                              where c.reversal_of = p.id and c.voided_at is null), 0) end)
           order by p.paid_at, p.created_at, p.id), '[]'::jsonb)
    into v_entries
    from public.expense_payments p where p.expense_id = p_expense_id and p.organization_id = v_org;
  return jsonb_build_object(
    'expense_id', r.expense_id, 'organization_id', r.organization_id, 'arena_id', r.arena_id,
    'arena_name', (select a.name from public.arenas a where a.id = r.arena_id),
    'category_id', r.category_id,
    'category_name', (select c.name from public.expense_categories c where c.id = r.category_id),
    'description', r.description, 'amount', r.amount, 'due_date', to_char(r.due_date, 'YYYY-MM-DD'), 'notes', r.notes,
    'created_at', r.created_at, 'updated_at', r.updated_at, 'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason,
    'paid_gross', r.paid_gross, 'reversed', r.reversed, 'net_paid', r.net_paid, 'amount_due', r.amount_due,
    'status', r.status, 'overdue', r.overdue,
    'amount_locked', r.has_valid_payment, 'arena_locked', r.has_valid_payment,
    'can_cancel', r.cancelled_at is null and r.net_paid = 0,
    'entries', v_entries);
end $$;

create function public.rg_fin_cash_result(p_org uuid, p_arena uuid, p_from date, p_to date, p_granularity text)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  v_buckets jsonb;
  v_in_gross bigint; v_in_refunds bigint; v_out_gross bigint; v_out_reversals bigint;
begin
  -- granularidade validada ANTES do limite (o limite depende dela)
  if p_granularity is null or p_granularity not in ('day', 'month', 'year') then
    raise exception 'rg: granularidade inválida' using errcode = '22023';
  end if;
  select * into s from private.rg_exp_scope(p_org, p_arena, p_from, p_to,
    case when p_granularity = 'day' then 366 else 3660 end);
  if p_granularity = 'month'
     and ((extract(year from p_to) * 12 + extract(month from p_to)) - (extract(year from p_from) * 12 + extract(month from p_from)) + 1) > 60 then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;
  if p_granularity = 'year' and (extract(year from p_to) - extract(year from p_from) + 1) > 10 then
    raise exception 'rg: período acima do limite' using errcode = '22023';
  end if;

  with b as (
    select g::date as bucket
      from generate_series(date_trunc(p_granularity, p_from::timestamp), date_trunc(p_granularity, p_to::timestamp),
                           ('1 ' || p_granularity)::interval) g
  ), i as (
    select date_trunc(p_granularity, p.received_at at time zone 'America/Sao_Paulo')::date as bucket,
           coalesce(sum(p.amount) filter (where p.kind = 'PAYMENT'), 0)::bigint as gross,
           coalesce(sum(p.amount) filter (where p.kind = 'REFUND'), 0)::bigint as refunds
      from public.reservation_payments p
     where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
       and p.voided_at is null and p.received_at >= s.v_start and p.received_at < s.v_end
     group by 1
  ), o as (
    select date_trunc(p_granularity, ep.paid_at at time zone 'America/Sao_Paulo')::date as bucket,
           coalesce(sum(ep.amount) filter (where ep.kind = 'PAYMENT'), 0)::bigint as gross,
           coalesce(sum(ep.amount) filter (where ep.kind = 'REVERSAL'), 0)::bigint as reversals
      from public.expense_payments ep
      join public.expenses e on e.id = ep.expense_id and e.organization_id = p_org
     where ep.organization_id = p_org and (p_arena is null or e.arena_id = p_arena)
       and ep.voided_at is null and ep.paid_at >= s.v_start and ep.paid_at < s.v_end
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(b.bucket, 'YYYY-MM-DD'),
           'in_gross', coalesce(i.gross, 0), 'in_refunds', coalesce(i.refunds, 0),
           'in_net', coalesce(i.gross, 0) - coalesce(i.refunds, 0),
           'out_gross', coalesce(o.gross, 0), 'out_reversals', coalesce(o.reversals, 0),
           'out_net', coalesce(o.gross, 0) - coalesce(o.reversals, 0),
           'result', (coalesce(i.gross, 0) - coalesce(i.refunds, 0)) - (coalesce(o.gross, 0) - coalesce(o.reversals, 0)))
           order by b.bucket), '[]'::jsonb),
         coalesce(sum(i.gross), 0)::bigint, coalesce(sum(i.refunds), 0)::bigint,
         coalesce(sum(o.gross), 0)::bigint, coalesce(sum(o.reversals), 0)::bigint
    into v_buckets, v_in_gross, v_in_refunds, v_out_gross, v_out_reversals
    from b left join i on i.bucket = b.bucket left join o on o.bucket = b.bucket;

  return jsonb_build_object(
    'granularity', p_granularity,
    'excludes_general', p_arena is not null,
    'buckets', v_buckets,
    'totals', jsonb_build_object(
      'in_gross', v_in_gross, 'in_refunds', v_in_refunds, 'in_net', v_in_gross - v_in_refunds,
      'out_gross', v_out_gross, 'out_reversals', v_out_reversals, 'out_net', v_out_gross - v_out_reversals,
      'result', (v_in_gross - v_in_refunds) - (v_out_gross - v_out_reversals)));
end $$;

-- Movimentos de caixa das duas fontes, ordem total DESC por (occurred_at, source_kind, id).
-- source/source_kind = domínio de origem: 1 = reserva, 2 = despesa. direction = direção REAL do dinheiro
-- (IN: recebimento de reserva, devolução de despesa; OUT: estorno de reserva, pagamento de despesa).
-- signed_amount = efeito no resultado de caixa; invariante: direction = 'IN' sse signed_amount > 0.
create function public.rg_fin_cash_movements(p_org uuid, p_arena uuid, p_from date, p_to date, p_limit integer,
                                             p_after_at timestamptz, p_after_source smallint, p_after_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' set timezone = 'UTC' as $$
declare
  s record;
  v_items jsonb;
  v_more boolean;
  v_last jsonb;
begin
  select * into s from private.rg_exp_scope(p_org, p_arena, p_from, p_to, 366);
  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if not ((p_after_at is null and p_after_source is null and p_after_id is null)
          or (p_after_at is not null and p_after_source is not null and p_after_id is not null)) then
    raise exception 'rg: cursor incompleto' using errcode = '22023';
  end if;
  if p_after_source is not null and p_after_source not in (1, 2) then
    raise exception 'rg: cursor inválido' using errcode = '22023';
  end if;

  with r as (
    select p.received_at as at_, 1::smallint as src, p.id, p.kind, p.method, p.amount,
           case when p.kind = 'PAYMENT' then p.amount else -p.amount end::bigint as signed_amount,
           -- direção real do dinheiro: recebimento entra; estorno ao cliente sai
           case when p.kind = 'PAYMENT' then 'IN' else 'OUT' end as direction,
           p.reservation_id, null::uuid as expense_id
      from public.reservation_payments p
     where p.organization_id = p_org and (p_arena is null or p.arena_id = p_arena)
       and p.voided_at is null and p.received_at >= s.v_start and p.received_at < s.v_end
       and (p_after_at is null or (p.received_at, 1::smallint, p.id) < (p_after_at, p_after_source, p_after_id))
     order by p.received_at desc, p.id desc
     limit p_limit + 1
  ), x as (
    select ep.paid_at as at_, 2::smallint as src, ep.id, ep.kind, ep.method, ep.amount,
           case when ep.kind = 'PAYMENT' then -ep.amount else ep.amount end::bigint as signed_amount,
           -- direção real do dinheiro: pagamento ao fornecedor sai; devolução do fornecedor entra
           case when ep.kind = 'PAYMENT' then 'OUT' else 'IN' end as direction,
           null::uuid as reservation_id, ep.expense_id
      from public.expense_payments ep
      join public.expenses e on e.id = ep.expense_id and e.organization_id = p_org
     where ep.organization_id = p_org and (p_arena is null or e.arena_id = p_arena)
       and ep.voided_at is null and ep.paid_at >= s.v_start and ep.paid_at < s.v_end
       and (p_after_at is null or (ep.paid_at, 2::smallint, ep.id) < (p_after_at, p_after_source, p_after_id))
     order by ep.paid_at desc, ep.id desc
     limit p_limit + 1
  ), u as (
    select * from r union all select * from x
  ), sel as (
    select u.*, row_number() over (order by u.at_ desc, u.src desc, u.id desc) as rn from u
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'occurred_at', sel.at_, 'source', case sel.src when 1 then 'RESERVATION' else 'EXPENSE' end,
           'source_kind', sel.src, 'direction', sel.direction,
           'id', sel.id, 'kind', sel.kind, 'method', sel.method, 'amount', sel.amount, 'signed_amount', sel.signed_amount,
           'reservation_id', sel.reservation_id, 'reservation_start_at', rs.start_at, 'court_name', ct.name,
           'customer_name', cu.name,
           'expense_id', sel.expense_id, 'description', ex.description, 'category_name', ec.name)
           order by sel.at_ desc, sel.src desc, sel.id desc) filter (where sel.rn <= p_limit), '[]'::jsonb),
         coalesce(bool_or(sel.rn > p_limit), false)
    into v_items, v_more
    from sel
    left join public.reservations rs on rs.id = sel.reservation_id and rs.organization_id = p_org
    left join public.courts ct on ct.id = rs.court_id and ct.organization_id = p_org
    left join public.customers cu on cu.id = rs.customer_id and cu.organization_id = p_org
    left join public.expenses ex on ex.id = sel.expense_id and ex.organization_id = p_org
    left join public.expense_categories ec on ec.id = ex.category_id and ec.organization_id = p_org;

  if v_more then
    select e into v_last from jsonb_array_elements(v_items) with ordinality as t(e, i) order by t.i desc limit 1;
  end if;
  return jsonb_build_object(
    'excludes_general', p_arena is not null,
    'items', v_items,
    'next_cursor', case when v_more then jsonb_build_object(
      'occurred_at', v_last->'occurred_at', 'source_kind', (v_last->>'source_kind')::smallint, 'id', v_last->'id') end);
end $$;

-- -----------------------------------------------------------------------------
-- 8) Owner, RLS, grants
-- -----------------------------------------------------------------------------
alter table public.expense_categories owner to postgres;
alter table public.expenses owner to postgres;
alter table public.expense_payments owner to postgres;
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_payments enable row level security;
-- sem políticas: tudo negado; leitura/escrita só pelas RPCs
revoke all on table public.expense_categories from public, anon, authenticated, service_role;
revoke all on table public.expenses from public, anon, authenticated, service_role;
revoke all on table public.expense_payments from public, anon, authenticated, service_role;
-- service_role: só SELECT/DELETE em despesas e lançamentos (limpeza de organizações demo do harness;
-- guard_finance_delete barra não-demo). expense_categories: NENHUM privilégio direto — as categorias de
-- uma organização apagada saem pela ação referencial ON DELETE CASCADE (executada pelo dono da tabela).
grant select, delete on table public.expenses to service_role;
grant select, delete on table public.expense_payments to service_role;

alter function private.rg_exp_name_key(text) owner to postgres;
alter function private.rg_exp_is_manager(uuid, uuid) owner to postgres;
alter function private.rg_exp_scope(uuid, uuid, date, date, integer) owner to postgres;
alter function private.rg_exp_rows(uuid, uuid, date, date) owner to postgres;
alter function private.rg_exp_validate_entry(uuid, text, integer, timestamptz) owner to postgres;
alter function private.rg_exp_fingerprint_expense(uuid, uuid, uuid, text, integer, date, text) owner to postgres;
alter function private.rg_exp_fingerprint_payment(text, uuid, uuid, integer, text, timestamptz, text) owner to postgres;
alter function private.rg_exp_seed_default_categories(uuid) owner to postgres;
alter function private.rg_exp_seed_org_categories() owner to postgres;
alter function private.enforce_expense_integrity() owner to postgres;
alter function private.protect_expense_record() owner to postgres;
alter function private.enforce_expense_payment_integrity() owner to postgres;
alter function private.protect_expense_payment_ledger() owner to postgres;
alter function public.rg_expense_category_create(uuid, text) owner to postgres;
alter function public.rg_expense_category_update(uuid, jsonb) owner to postgres;
alter function public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text) owner to postgres;
alter function public.rg_expense_update(uuid, jsonb) owner to postgres;
alter function public.rg_expense_cancel(uuid, text) owner to postgres;
alter function public.rg_expense_payment_register(uuid, uuid, text, integer, timestamptz, text) owner to postgres;
alter function public.rg_expense_payment_reverse(uuid, uuid, text, integer, timestamptz, text) owner to postgres;
alter function public.rg_expense_payment_void(uuid, text) owner to postgres;
alter function public.rg_expense_categories(uuid, boolean) owner to postgres;
alter function public.rg_expense_overview(uuid, uuid, uuid, date, date, date, date) owner to postgres;
alter function public.rg_expenses(uuid, uuid, uuid, date, date, text, integer, date, uuid) owner to postgres;
alter function public.rg_expense_detail(uuid) owner to postgres;
alter function public.rg_fin_cash_result(uuid, uuid, date, date, text) owner to postgres;
alter function public.rg_fin_cash_movements(uuid, uuid, date, date, integer, timestamptz, smallint, uuid) owner to postgres;

revoke all on function private.rg_exp_name_key(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_is_manager(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_scope(uuid, uuid, date, date, integer) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_rows(uuid, uuid, date, date) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_validate_entry(uuid, text, integer, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_fingerprint_expense(uuid, uuid, uuid, text, integer, date, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_fingerprint_payment(text, uuid, uuid, integer, text, timestamptz, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_seed_default_categories(uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_exp_seed_org_categories() from public, anon, authenticated, service_role;
revoke all on function private.enforce_expense_integrity() from public, anon, authenticated, service_role;
revoke all on function private.protect_expense_record() from public, anon, authenticated, service_role;
revoke all on function private.enforce_expense_payment_integrity() from public, anon, authenticated, service_role;
revoke all on function private.protect_expense_payment_ledger() from public, anon, authenticated, service_role;

revoke all on function public.rg_expense_category_create(uuid, text) from public, anon, service_role;
revoke all on function public.rg_expense_category_update(uuid, jsonb) from public, anon, service_role;
revoke all on function public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text) from public, anon, service_role;
revoke all on function public.rg_expense_update(uuid, jsonb) from public, anon, service_role;
revoke all on function public.rg_expense_cancel(uuid, text) from public, anon, service_role;
revoke all on function public.rg_expense_payment_register(uuid, uuid, text, integer, timestamptz, text) from public, anon, service_role;
revoke all on function public.rg_expense_payment_reverse(uuid, uuid, text, integer, timestamptz, text) from public, anon, service_role;
revoke all on function public.rg_expense_payment_void(uuid, text) from public, anon, service_role;
revoke all on function public.rg_expense_categories(uuid, boolean) from public, anon, service_role;
revoke all on function public.rg_expense_overview(uuid, uuid, uuid, date, date, date, date) from public, anon, service_role;
revoke all on function public.rg_expenses(uuid, uuid, uuid, date, date, text, integer, date, uuid) from public, anon, service_role;
revoke all on function public.rg_expense_detail(uuid) from public, anon, service_role;
revoke all on function public.rg_fin_cash_result(uuid, uuid, date, date, text) from public, anon, service_role;
revoke all on function public.rg_fin_cash_movements(uuid, uuid, date, date, integer, timestamptz, smallint, uuid) from public, anon, service_role;

grant execute on function public.rg_expense_category_create(uuid, text) to authenticated;
grant execute on function public.rg_expense_category_update(uuid, jsonb) to authenticated;
grant execute on function public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text) to authenticated;
grant execute on function public.rg_expense_update(uuid, jsonb) to authenticated;
grant execute on function public.rg_expense_cancel(uuid, text) to authenticated;
grant execute on function public.rg_expense_payment_register(uuid, uuid, text, integer, timestamptz, text) to authenticated;
grant execute on function public.rg_expense_payment_reverse(uuid, uuid, text, integer, timestamptz, text) to authenticated;
grant execute on function public.rg_expense_payment_void(uuid, text) to authenticated;
grant execute on function public.rg_expense_categories(uuid, boolean) to authenticated;
grant execute on function public.rg_expense_overview(uuid, uuid, uuid, date, date, date, date) to authenticated;
grant execute on function public.rg_expenses(uuid, uuid, uuid, date, date, text, integer, date, uuid) to authenticated;
grant execute on function public.rg_expense_detail(uuid) to authenticated;
grant execute on function public.rg_fin_cash_result(uuid, uuid, date, date, text) to authenticated;
grant execute on function public.rg_fin_cash_movements(uuid, uuid, date, date, integer, timestamptz, smallint, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 9) Seed controlado das organizações existentes (mesma função do trigger)
-- -----------------------------------------------------------------------------
do $$
declare
  v_orgs bigint;
  v_bad bigint;
begin
  perform private.rg_exp_seed_default_categories(o.id) from public.organizations o;
  select count(*) into v_orgs from public.organizations;
  select count(*) into v_bad from public.organizations o
   where (select count(*) from public.expense_categories c where c.organization_id = o.id) <> 10;
  if v_bad <> 0 or (select count(*) from public.expense_categories) <> v_orgs * 10 then
    raise exception '03B.2: seed de categorias inconsistente (% organizações divergentes)', v_bad;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 10) Trigger para organizações novas (depois do seed; organizations segue travada)
-- -----------------------------------------------------------------------------
create trigger seed_expense_categories after insert on public.organizations
  for each row execute function private.rg_exp_seed_org_categories();

-- -----------------------------------------------------------------------------
-- 11) Conferência final
-- -----------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('rg_expense_category_create', 'rg_expense_category_update', 'rg_expense_create',
         'rg_expense_update', 'rg_expense_cancel', 'rg_expense_payment_register', 'rg_expense_payment_reverse',
         'rg_expense_payment_void', 'rg_expense_categories', 'rg_expense_overview', 'rg_expenses', 'rg_expense_detail',
         'rg_fin_cash_result', 'rg_fin_cash_movements')) <> 14 then
    raise exception '03B.2: conferência final — RPCs públicas ausentes';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public', 'private') and p.prosecdef
                and (p.proname like 'rg_exp%' or p.proname like 'rg_expense%' or p.proname in ('rg_fin_cash_result', 'rg_fin_cash_movements',
                     'enforce_expense_integrity', 'protect_expense_record', 'enforce_expense_payment_integrity', 'protect_expense_payment_ledger'))
                and not ('search_path=""' = any(coalesce(p.proconfig, '{}')))) then
    raise exception '03B.2: conferência final — SECURITY DEFINER sem search_path vazio';
  end if;
end $$;

commit;
