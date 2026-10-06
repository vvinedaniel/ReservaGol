-- =============================================================================
-- RESERVA GOL — FASE 03B.2 — ROLLBACK SEGURO
-- Remove exatamente o que migration_phase3b2_expenses.sql criou. NUNCA apaga dado de usuário:
-- aborta ANTES de qualquer DROP se alguma organização NÃO-demo tiver despesa, lançamento ou
-- categorias fora do estado padrão (conjunto exato das 10 canônicas, ativas, nunca editadas).
-- Dados de organizações demo podem ser descartados (contrato).
-- Ordem (sem CASCADE): locks -> conferência -> trigger em organizations -> 14 RPCs -> tabelas
-- (expense_payments, expenses, expense_categories) -> funções privadas exclusivas -> conferência final.
-- audit_logs NÃO é tocado (linhas EXPENSE_* permanecem como histórico).
-- Funções compartilhadas preexistentes (guard_finance_delete, rg_fin_notes, rg_today, set_updated_at,
-- rg_fault) nunca são removidas.
-- =============================================================================
begin;

-- 1) Locks: nenhuma escrita nas tabelas da 03B.2 nem criação de organização durante o rollback.
lock table public.organizations in share row exclusive mode;
lock table public.expense_payments, public.expenses, public.expense_categories in access exclusive mode;

-- 2) Preflight de segurança de dados (qualquer divergência => abort antes de qualquer DROP)
do $$
declare
  v_n bigint;
begin
  select count(*) into v_n from public.expenses e
    join public.organizations o on o.id = e.organization_id where not o.is_demo;
  if v_n > 0 then
    raise exception '03B.2 rollback ABORTADO: % despesa(s) em organização não-demo', v_n;
  end if;

  select count(*) into v_n from public.expense_payments p
    join public.organizations o on o.id = p.organization_id where not o.is_demo;
  if v_n > 0 then
    raise exception '03B.2 rollback ABORTADO: % lançamento(s) de despesa em organização não-demo', v_n;
  end if;

  -- categoria customizada / renomeada (nome fora da grafia canônica)
  select count(*) into v_n from public.expense_categories c
    join public.organizations o on o.id = c.organization_id
   where not o.is_demo
     and c.name not in ('Aluguel', 'Energia', 'Água', 'Internet', 'Funcionários', 'Manutenção', 'Materiais',
                        'Marketing', 'Impostos e taxas', 'Outros');
  if v_n > 0 then
    raise exception '03B.2 rollback ABORTADO: % categoria(s) customizada(s) ou renomeada(s) em organização não-demo', v_n;
  end if;

  -- categoria inativada ou editada (updated_at != created_at)
  select count(*) into v_n from public.expense_categories c
    join public.organizations o on o.id = c.organization_id
   where not o.is_demo and (not c.is_active or c.updated_at <> c.created_at);
  if v_n > 0 then
    raise exception '03B.2 rollback ABORTADO: % categoria(s) inativada(s) ou editada(s) em organização não-demo', v_n;
  end if;

  -- conjunto exato das 10 canônicas em cada organização não-demo
  select count(*) into v_n from public.organizations o
   where not o.is_demo
     and ((select count(*) from public.expense_categories c where c.organization_id = o.id) <> 10
          or (select count(distinct c.name) from public.expense_categories c where c.organization_id = o.id
               and c.name in ('Aluguel', 'Energia', 'Água', 'Internet', 'Funcionários', 'Manutenção', 'Materiais',
                              'Marketing', 'Impostos e taxas', 'Outros')) <> 10);
  if v_n > 0 then
    raise exception '03B.2 rollback ABORTADO: % organização(ões) não-demo sem o conjunto exato das 10 categorias padrão', v_n;
  end if;
end $$;

-- 3) Trigger em organizations
drop trigger seed_expense_categories on public.organizations;

-- 4) 14 RPCs públicas (assinatura exata)
drop function public.rg_fin_cash_movements(uuid, uuid, date, date, integer, timestamptz, smallint, uuid);
drop function public.rg_fin_cash_result(uuid, uuid, date, date, text);
drop function public.rg_expense_detail(uuid);
drop function public.rg_expenses(uuid, uuid, uuid, date, date, text, integer, date, uuid);
drop function public.rg_expense_overview(uuid, uuid, uuid, date, date, date, date);
drop function public.rg_expense_categories(uuid, boolean);
drop function public.rg_expense_payment_void(uuid, text);
drop function public.rg_expense_payment_reverse(uuid, uuid, text, integer, timestamptz, text);
drop function public.rg_expense_payment_register(uuid, uuid, text, integer, timestamptz, text);
drop function public.rg_expense_cancel(uuid, text);
drop function public.rg_expense_update(uuid, jsonb);
drop function public.rg_expense_create(uuid, uuid, uuid, uuid, text, integer, date, text);
drop function public.rg_expense_category_update(uuid, jsonb);
drop function public.rg_expense_category_create(uuid, text);

-- 5) Tabelas (triggers, índices, constraints e a coluna gerada são parte de cada tabela)
drop table public.expense_payments;
drop table public.expenses;
drop table public.expense_categories;

-- 6) Funções privadas exclusivas da 03B.2 (só agora: as tabelas dependiam delas)
drop function private.rg_exp_seed_org_categories();
drop function private.rg_exp_seed_default_categories(uuid);
drop function private.protect_expense_payment_ledger();
drop function private.enforce_expense_payment_integrity();
drop function private.protect_expense_record();
drop function private.enforce_expense_integrity();
drop function private.rg_exp_fingerprint_payment(text, uuid, uuid, integer, text, timestamptz, text);
drop function private.rg_exp_fingerprint_expense(uuid, uuid, uuid, text, integer, date, text);
drop function private.rg_exp_validate_entry(uuid, text, integer, timestamptz);
drop function private.rg_exp_rows(uuid, uuid, date, date);
drop function private.rg_exp_scope(uuid, uuid, date, date, integer);
drop function private.rg_exp_is_manager(uuid, uuid);
drop function private.rg_exp_name_key(text);

-- 7) Conferência final: nada da 03B.2 sobrou; 03A, 03B.1 e compartilhados intactos.
do $$
begin
  if to_regclass('public.expense_categories') is not null or to_regclass('public.expenses') is not null
     or to_regclass('public.expense_payments') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where (n.nspname = 'public' and (p.proname like 'rg_expense%' or p.proname in ('rg_fin_cash_result', 'rg_fin_cash_movements')))
                    or (n.nspname = 'private' and (p.proname like 'rg_exp\_%' or p.proname in ('enforce_expense_integrity',
                        'protect_expense_record', 'enforce_expense_payment_integrity', 'protect_expense_payment_ledger'))))
     or exists (select 1 from pg_trigger t where t.tgrelid = 'public.organizations'::regclass and t.tgname = 'seed_expense_categories') then
    raise exception '03B.2 rollback: objeto da 03B.2 ainda presente';
  end if;
  if to_regprocedure('private.guard_finance_delete()') is null or to_regprocedure('private.rg_fin_notes(text)') is null
     or to_regprocedure('private.rg_today()') is null or to_regprocedure('public.set_updated_at()') is null
     or to_regprocedure('private.rg_fault(text)') is null
     or to_regprocedure('private.rg_financials(uuid[])') is null
     or to_regprocedure('public.rg_payment_register(uuid, uuid, text, integer, timestamptz, text)') is null
     or to_regprocedure('public.rg_fin_overview(uuid, uuid, date, date, date, date)') is null
     or to_regprocedure('public.rg_fin_cashflow(uuid, uuid, date, date, text)') is null
     or to_regprocedure('public.rg_fin_cash_entries(uuid, uuid, date, date, integer, timestamptz, uuid)') is null
     or to_regprocedure('public.rg_fin_receivables(uuid, uuid, date, date, text, integer, timestamptz, uuid)') is null
     or to_regprocedure('private.rg_fin_scope(uuid, uuid, date, date, integer)') is null then
    raise exception '03B.2 rollback: objeto da 03A/03B.1/compartilhado ausente — não deveria ter sido tocado';
  end if;
end $$;

commit;
