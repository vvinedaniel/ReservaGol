-- =============================================================================
-- RESERVA GOL — FASE 03B.2A.1 — ÍNDICES DAS FKs COMPOSTAS DA 03B.2
-- Requer migration_phase3b2_expenses.sql aplicada (estado 03B.2A puro).
--
-- Cobre as 3 FKs compostas apontadas pelo advisor (lint 0001 unindexed_foreign_keys), com as
-- colunas da FK como PREFIXO do índice e na MESMA ordem da FK:
--   expense_payments_expense_org_fkey  (expense_id, organization_id)
--     => idx_expense_payments_expense_org   SUBSTITUI idx_expense_payments_expense (expense_id)
--   expense_payments_reversal_org_fkey (reversal_of, organization_id)
--     => idx_expense_payments_reversal_org  SUBSTITUI idx_expense_payments_reversal_of (reversal_of)
--        Continua PARCIAL (WHERE reversal_of IS NOT NULL): só devoluções entram no índice.
--   expenses_category_org_fkey         (category_id, organization_id)
--     => idx_expenses_category_org          NOVO
-- Os substituídos ficam redundantes: os novos começam pela mesma coluna, então toda consulta
-- atual por expense_id / reversal_of continua servida pelo prefixo.
-- Fora do escopo: FKs para auth.users (created_by, cancelled_by, voided_by).
--
-- Nada além desses 5 índices muda: tabelas, colunas, constraints, RPCs, grants, RLS e triggers
-- ficam idênticos. Uma transação; qualquer divergência => erro antes de qualquer efeito.
--
-- Rollback: supabase/rollback_phase3b2a1_expense_indexes.sql.
-- ORDEM OPERACIONAL OFICIAL para desfazer as duas fases: PRIMEIRO o rollback da 03B.2A.1,
-- DEPOIS o rollback da 03B.2A (supabase/rollback_phase3b2_expenses.sql). Reaplicar a 03B.2A
-- recria os índices simples originais; nesse caso a 03B.2A.1 precisa ser aplicada de novo.
-- =============================================================================
begin;
set local lock_timeout = '5s';
set local search_path = '';

-- 0) Tabelas da 03B.2 (sem lock, sem efeito)
do $$
begin
  if to_regclass('public.expense_categories') is null or to_regclass('public.expenses') is null
     or to_regclass('public.expense_payments') is null then
    raise exception '03B.2A.1: tabelas da 03B.2 ausentes (aplique migration_phase3b2_expenses.sql)' using errcode = '55000';
  end if;
end $$;

-- 1) Locks na ordem global (despesa -> lançamento). CREATE INDEX exige SHARE; DROP INDEX exige
--    ACCESS EXCLUSIVE na tabela dos índices removidos.
lock table public.expenses in share mode;
lock table public.expense_payments in access exclusive mode;

-- 2) Preflight: FKs exatas, conjunto exato de índices da 03B.2A, nenhum nome novo ocupado.
do $$
declare
  v_fk record;
  v_found text[];
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
  -- nomes novos: livres em qualquer schema
  select array_agg(n.nspname || '.' || c.relname order by c.relname) into v_found
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where c.relname in ('idx_expense_payments_expense_org', 'idx_expense_payments_reversal_org', 'idx_expenses_category_org');
  if v_found is not null then
    raise exception '03B.2A.1: objeto de destino já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;

  -- as 3 FKs compostas, exatamente como a 03B.2 criou
  for v_fk in select * from (values
      ('expenses_category_org_fkey', 'public.expenses', 'public.expense_categories', array['category_id', 'organization_id']),
      ('expense_payments_expense_org_fkey', 'public.expense_payments', 'public.expenses', array['expense_id', 'organization_id']),
      ('expense_payments_reversal_org_fkey', 'public.expense_payments', 'public.expense_payments', array['reversal_of', 'organization_id'])
    ) x(conname, tbl, reftbl, cols) loop
    if not exists (
      select 1 from pg_catalog.pg_constraint c
       where c.conname = v_fk.conname and c.contype = 'f' and c.convalidated
         and c.conrelid = v_fk.tbl::regclass and c.confrelid = v_fk.reftbl::regclass and c.confdeltype = 'r'
         and array(select a.attname::text from unnest(c.conkey) with ordinality k(attnum, ord)
                     join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum order by k.ord) = v_fk.cols
         and array(select a.attname::text from unnest(c.confkey) with ordinality k(attnum, ord)
                     join pg_catalog.pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum order by k.ord)
             = array['id', 'organization_id']) then
      raise exception '03B.2A.1: FK % divergente ou ausente', v_fk.conname using errcode = '55000';
    end if;
  end loop;

  -- índices de expenses/expense_payments: exatamente o estado 03B.2A, todos válidos
  v_actual := array(
    select pg_catalog.pg_get_indexdef(i.indexrelid)
           || case when i.indisvalid and i.indisready and i.indislive then '' else ' [INVALID]' end as d
      from pg_catalog.pg_index i
     where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
     order by d);
  if v_actual is distinct from v_expected then
    raise exception E'03B.2A.1: índices de expenses/expense_payments fora do estado 03B.2A\nesperado: %\natual: %',
      array_to_string(v_expected, E'\n  '), array_to_string(v_actual, E'\n  ') using errcode = '55000';
  end if;
end $$;

-- 3) Índices compostos (prefixo = colunas da FK, na ordem da FK)
create index idx_expense_payments_expense_org on public.expense_payments using btree (expense_id, organization_id);
create index idx_expense_payments_reversal_org on public.expense_payments using btree (reversal_of, organization_id)
  where reversal_of is not null;
create index idx_expenses_category_org on public.expenses using btree (category_id, organization_id);

-- 4) Os 3 novos existem com a definição exata e estão válidos
do $$
declare
  v_def text;
begin
  foreach v_def in array array[
    'CREATE INDEX idx_expense_payments_expense_org ON public.expense_payments USING btree (expense_id, organization_id)',
    'CREATE INDEX idx_expense_payments_reversal_org ON public.expense_payments USING btree (reversal_of, organization_id) WHERE (reversal_of IS NOT NULL)',
    'CREATE INDEX idx_expenses_category_org ON public.expenses USING btree (category_id, organization_id)'] loop
    if not exists (select 1 from pg_catalog.pg_index i
                    where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
                      and i.indisvalid and i.indisready and i.indislive
                      and pg_catalog.pg_get_indexdef(i.indexrelid) = v_def) then
      raise exception '03B.2A.1: índice não criado como esperado: %', v_def using errcode = '55000';
    end if;
  end loop;
end $$;

-- 5) Remove os simples que ficaram redundantes (sem CASCADE)
drop index public.idx_expense_payments_expense;
drop index public.idx_expense_payments_reversal_of;

-- 6) Conferência final: conjunto exato pós-03B.2A.1 e as 3 FKs cobertas (mesma regra do lint 0001:
--    colunas da FK = colunas iniciais de um índice válido, na mesma ordem).
do $$
declare
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
  v_uncovered text[];
begin
  v_actual := array(
    select pg_catalog.pg_get_indexdef(i.indexrelid)
           || case when i.indisvalid and i.indisready and i.indislive then '' else ' [INVALID]' end as d
      from pg_catalog.pg_index i
     where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
     order by d);
  if v_actual is distinct from v_expected then
    raise exception E'03B.2A.1: conferência final — índices divergentes\natual: %', array_to_string(v_actual, E'\n  ')
      using errcode = '55000';
  end if;
  select array_agg(c.conname::text order by c.conname) into v_uncovered
    from pg_catalog.pg_constraint c
   where c.conname in ('expenses_category_org_fkey', 'expense_payments_expense_org_fkey', 'expense_payments_reversal_org_fkey')
     and not exists (select 1 from pg_catalog.pg_index i
                      where i.indrelid = c.conrelid and i.indisvalid
                        and (string_to_array(i.indkey::text, ' ')::smallint[])[1:cardinality(c.conkey)] = c.conkey);
  if v_uncovered is not null then
    raise exception '03B.2A.1: conferência final — FK sem índice de cobertura: %', array_to_string(v_uncovered, ', ')
      using errcode = '55000';
  end if;
end $$;

commit;
