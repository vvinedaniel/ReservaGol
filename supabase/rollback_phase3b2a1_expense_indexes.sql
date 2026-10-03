-- =============================================================================
-- RESERVA GOL — FASE 03B.2A.1 — ROLLBACK DOS ÍNDICES
-- Restaura exatamente o estado 03B.2A puro: recria idx_expense_payments_expense e
-- idx_expense_payments_reversal_of com as definições originais e remove os 3 índices da 03B.2A.1.
-- Só índices: nenhum dado, tabela, constraint, RPC, grant, RLS ou trigger é tocado.
--
-- ORDEM OPERACIONAL OFICIAL para desfazer as duas fases: PRIMEIRO este rollback (03B.2A.1),
-- DEPOIS supabase/rollback_phase3b2_expenses.sql (03B.2A).
-- Uma transação. Qualquer divergência => erro antes de qualquer efeito. Sem CASCADE.
-- =============================================================================
begin;
set local lock_timeout = '5s';
set local search_path = '';

-- 0) Tabelas da 03B.2 (sem lock, sem efeito)
do $$
begin
  if to_regclass('public.expense_categories') is null or to_regclass('public.expenses') is null
     or to_regclass('public.expense_payments') is null then
    raise exception '03B.2A.1 rollback: tabelas da 03B.2 ausentes' using errcode = '55000';
  end if;
end $$;

-- 1) Locks na ordem global (despesa -> lançamento); DROP INDEX exige ACCESS EXCLUSIVE nas duas.
lock table public.expenses in access exclusive mode;
lock table public.expense_payments in access exclusive mode;

-- 2) Preflight: estado exato pós-03B.2A.1 e nomes originais livres.
do $$
declare
  v_found text[];
  v_expected text[] := array(select unnest(array[
    'CREATE INDEX idx_expense_payments_expense_org ON public.expense_payments USING btree (expense_id, organization_id)',
    'CREATE INDEX idx_expense_payments_org_paid ON public.expense_payments USING btree (organization_id, paid_at, id)',
    'CREATE INDEX idx_expense_payments_reversal_org ON public.expense_payments USING btree (reversal_of, organization_id) WHERE (reversal_of IS NOT NULL)',
    'CREATE INDEX idx_expenses_arena_due ON public.expenses USING btree (arena_id, due_date, id)',
    'CREATE INDEX idx_expenses_category_org ON public.expenses USING btree (category_id, organization_id)',
    'CREATE INDEX idx_expenses_org_due ON public.expenses USING btree (organization_id, due_date, id)',
    'CREATE UNIQUE INDEX expense_payments_id_org_key ON public.expense_payments USING btree (id, organization_id)',
    'CREATE UNIQUE INDEX expense_payments_pkey ON public.expense_payments USING btree (id)',
    'CREATE UNIQUE INDEX expenses_id_org_key ON public.expenses USING btree (id, organization_id)',
    'CREATE UNIQUE INDEX expenses_pkey ON public.expenses USING btree (id)',
    'CREATE UNIQUE INDEX idx_expense_payments_org_operation ON public.expense_payments USING btree (organization_id, operation_id)',
    'CREATE UNIQUE INDEX idx_expenses_org_operation ON public.expenses USING btree (organization_id, operation_id)']) d order by d);
  v_actual text[];
begin
  select array_agg(n.nspname || '.' || c.relname order by c.relname) into v_found
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where c.relname in ('idx_expense_payments_expense', 'idx_expense_payments_reversal_of');
  if v_found is not null then
    raise exception '03B.2A.1 rollback: índice original já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;
  v_actual := array(
    select pg_catalog.pg_get_indexdef(i.indexrelid)
           || case when i.indisvalid and i.indisready and i.indislive then '' else ' [INVALID]' end as d
      from pg_catalog.pg_index i
     where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
     order by d);
  if v_actual is distinct from v_expected then
    raise exception E'03B.2A.1 rollback: índices fora do estado 03B.2A.1\nesperado: %\natual: %',
      array_to_string(v_expected, E'\n  '), array_to_string(v_actual, E'\n  ') using errcode = '55000';
  end if;
end $$;

-- 3) Recria os 2 índices simples originais (definição idêntica à da 03B.2A)
create index idx_expense_payments_expense on public.expense_payments (expense_id);
create index idx_expense_payments_reversal_of on public.expense_payments (reversal_of) where reversal_of is not null;

-- 4) Confere as definições recriadas
do $$
declare
  v_def text;
begin
  foreach v_def in array array[
    'CREATE INDEX idx_expense_payments_expense ON public.expense_payments USING btree (expense_id)',
    'CREATE INDEX idx_expense_payments_reversal_of ON public.expense_payments USING btree (reversal_of) WHERE (reversal_of IS NOT NULL)'] loop
    if not exists (select 1 from pg_catalog.pg_index i
                    where i.indrelid = 'public.expense_payments'::regclass
                      and i.indisvalid and i.indisready and i.indislive
                      and pg_catalog.pg_get_indexdef(i.indexrelid) = v_def) then
      raise exception '03B.2A.1 rollback: índice original não recriado como esperado: %', v_def using errcode = '55000';
    end if;
  end loop;
end $$;

-- 5) Remove os 3 índices da 03B.2A.1 (sem CASCADE)
drop index public.idx_expenses_category_org;
drop index public.idx_expense_payments_reversal_org;
drop index public.idx_expense_payments_expense_org;

-- 6) Conferência final: índices de expenses/expense_payments idênticos ao estado 03B.2A
do $$
declare
  v_expected text[] := array(select unnest(array[
    'CREATE INDEX idx_expense_payments_expense ON public.expense_payments USING btree (expense_id)',
    'CREATE INDEX idx_expense_payments_org_paid ON public.expense_payments USING btree (organization_id, paid_at, id)',
    'CREATE INDEX idx_expense_payments_reversal_of ON public.expense_payments USING btree (reversal_of) WHERE (reversal_of IS NOT NULL)',
    'CREATE INDEX idx_expenses_arena_due ON public.expenses USING btree (arena_id, due_date, id)',
    'CREATE INDEX idx_expenses_org_due ON public.expenses USING btree (organization_id, due_date, id)',
    'CREATE UNIQUE INDEX expense_payments_id_org_key ON public.expense_payments USING btree (id, organization_id)',
    'CREATE UNIQUE INDEX expense_payments_pkey ON public.expense_payments USING btree (id)',
    'CREATE UNIQUE INDEX expenses_id_org_key ON public.expenses USING btree (id, organization_id)',
    'CREATE UNIQUE INDEX expenses_pkey ON public.expenses USING btree (id)',
    'CREATE UNIQUE INDEX idx_expense_payments_org_operation ON public.expense_payments USING btree (organization_id, operation_id)',
    'CREATE UNIQUE INDEX idx_expenses_org_operation ON public.expenses USING btree (organization_id, operation_id)']) d order by d);
  v_actual text[];
begin
  v_actual := array(
    select pg_catalog.pg_get_indexdef(i.indexrelid)
           || case when i.indisvalid and i.indisready and i.indislive then '' else ' [INVALID]' end as d
      from pg_catalog.pg_index i
     where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
     order by d);
  if v_actual is distinct from v_expected then
    raise exception E'03B.2A.1 rollback: conferência final — índices fora do estado 03B.2A\natual: %',
      array_to_string(v_actual, E'\n  ') using errcode = '55000';
  end if;
end $$;

commit;
