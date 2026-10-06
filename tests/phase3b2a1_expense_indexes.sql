-- =============================================================================
-- RESERVA GOL — FASE 03B.2A.1 — testes SQL dos índices das FKs compostas
-- Requer 03B.2A + migration_phase3b2a1_expense_indexes.sql aplicadas. Banco de TESTE local, nunca Production.
--
-- Como rodar:
--   psql -U postgres -v ON_ERROR_STOP=1 -v rg_baseline_ex5=<md5> -f tests/phase3b2a1_expense_indexes.sql
-- rg_baseline_ex5 = pg_temp.fp_ex5() calculado no estado 03B.2A puro (ANTES da A.1): fingerprint do
-- schema public+private sem os 5 índices envolvidos. Sem a variável, T07 falha (não há SKIP).
-- Sucesso: imprime "P3B2A1_RESULTS OK ..." e faz ROLLBACK explícito. Falha: erro "P3B2A1_RESULTS FAIL ...".
-- Fixture sintética (~21 mil linhas) + ANALYZE dentro da transação: o planner tem opção real entre
-- índice e seq scan. ZERO RESÍDUO (estatísticas do ANALYZE também voltam com o ROLLBACK).
-- =============================================================================
\if :{?rg_baseline_ex5}
\else
\set rg_baseline_ex5 ''
\endif
begin;
set local statement_timeout = '300s';
set local lock_timeout = '5s';

create temp table fx (k text primary key, id uuid not null) on commit drop;
create temp table rr (seq serial, name text, ok boolean, detail text) on commit drop;
create temp table cfg (k text primary key, v text) on commit drop;
insert into cfg values ('baseline_ex5', :'rg_baseline_ex5');

do $$ begin
  if session_user <> 'postgres' then raise exception 'p3b2a1: execute como postgres (session_user=%)', session_user; end if;
  if to_regclass('public.expenses') is null then raise exception 'p3b2a1: 03B.2A não aplicada'; end if;
  if to_regclass('public.idx_expenses_category_org') is null then raise exception 'p3b2a1: 03B.2A.1 não aplicada'; end if;
end $$;

-- ----------------------------------------------------------------------------- helpers (pg_temp)
create function pg_temp.k(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create function pg_temp.ok(p_name text, p_ok boolean, p_detail text) returns void language sql as $$
  insert into rr (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- definições dos índices de expenses/expense_payments (search_path vazio => tabela qualificada)
create function pg_temp.ixdefs() returns text[] language sql stable set search_path = '' as $$
  select array(select pg_catalog.pg_get_indexdef(i.indexrelid)
                      || case when i.indisvalid and i.indisready and i.indislive then '' else ' [INVALID]' end as d
                 from pg_catalog.pg_index i
                where i.indrelid in ('public.expenses'::regclass, 'public.expense_payments'::regclass)
                order by d) $$;

-- Equivalente ao lint 0001 (unindexed_foreign_keys) do Supabase: FK coberta quando suas colunas são
-- as colunas iniciais de um índice válido, na mesma ordem. O lint NÃO olha o predicado (índice parcial).
-- Conferido em Production: reproduz exatamente os 16 achados do advisor de 2026-10-03.
create function pg_temp.lint_uncovered() returns table (table_name text, fkey_name text) language sql stable as $$
  with foreign_keys as (
    select cl.relname::text as table_name, cl.oid as table_oid, ct.conname::text as fkey_name, ct.conkey as col_attnums
      from pg_catalog.pg_constraint ct
      join pg_catalog.pg_class cl on ct.conrelid = cl.oid
      left join pg_catalog.pg_depend d on d.objid = cl.oid and d.deptype = 'e'
     where ct.contype = 'f' and d.objid is null and cl.relnamespace = 'public'::regnamespace
  ), index_ as (
    select pi.indrelid as table_oid, pi.indexrelid, string_to_array(pi.indkey::text, ' ')::smallint[] as col_attnums
      from pg_catalog.pg_index pi where pi.indisvalid
  )
  select fk.table_name, fk.fkey_name
    from foreign_keys fk
    left join index_ idx on fk.table_oid = idx.table_oid
                        and fk.col_attnums = idx.col_attnums[1:array_length(fk.col_attnums, 1)]
   where idx.indexrelid is null $$;

-- @@FP_EX5_BEGIN@@
-- Fingerprint do schema public+private (funções, ACLs, colunas, constraints, índices, triggers,
-- políticas, RLS, grants de tabela, flags de índice) SEM os 5 índices envolvidos na 03B.2A.1.
create function pg_temp.fp_ex5() returns text language sql stable set search_path = '' as $$
  with n as (select oid, nspname from pg_catalog.pg_namespace where nspname in ('public', 'private')),
  items as (
    select 'fn:' || n.nspname || '.' || p.oid::regprocedure::text as k,
           md5(regexp_replace(replace(pg_catalog.pg_get_functiondef(p.oid), chr(13), ''), '\s+', ' ', 'g')) as h
      from pg_catalog.pg_proc p join n on n.oid = p.pronamespace where p.prokind in ('f', 'p')
    union all
    select 'acl:' || n.nspname || '.' || p.oid::regprocedure::text,
           md5(coalesce((select string_agg(pg_catalog.pg_get_userbyid(a.grantee) || ':' || a.privilege_type, ','
                                           order by pg_catalog.pg_get_userbyid(a.grantee), a.privilege_type)
                           from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a), '')
               || '|sec=' || p.prosecdef::text || '|cfg=' || coalesce(array_to_string(p.proconfig, ','), ''))
      from pg_catalog.pg_proc p join n on n.oid = p.pronamespace where p.prokind in ('f', 'p')
    union all
    select 'col:' || c.table_schema || '.' || c.table_name || '.' || c.column_name,
           md5(c.data_type || '|' || c.is_nullable || '|' || coalesce(c.column_default, '') || '|' || coalesce(c.generation_expression, ''))
      from information_schema.columns c where c.table_schema in ('public', 'private')
    union all
    select 'con:' || n.nspname || '.' || cl.relname || '.' || co.conname,
           md5(regexp_replace(pg_catalog.pg_get_constraintdef(co.oid), '\s+', ' ', 'g'))
      from pg_catalog.pg_constraint co join pg_catalog.pg_class cl on cl.oid = co.conrelid join n on n.oid = cl.relnamespace
    union all
    select 'idx:' || i.schemaname || '.' || i.indexname, md5(regexp_replace(i.indexdef, '\s+', ' ', 'g'))
      from pg_catalog.pg_indexes i where i.schemaname in ('public', 'private')
    union all
    select 'trg:' || n.nspname || '.' || cl.relname || '.' || t.tgname,
           md5(regexp_replace(pg_catalog.pg_get_triggerdef(t.oid), '\s+', ' ', 'g') || '|en=' || t.tgenabled::text)
      from pg_catalog.pg_trigger t join pg_catalog.pg_class cl on cl.oid = t.tgrelid join n on n.oid = cl.relnamespace
     where not t.tgisinternal
    union all
    select 'pol:' || p.schemaname || '.' || p.tablename || '.' || p.policyname,
           md5(p.cmd || '|' || array_to_string(p.roles, ',') || '|' || coalesce(regexp_replace(p.qual, '\s+', ' ', 'g'), '')
               || '|' || coalesce(regexp_replace(p.with_check, '\s+', ' ', 'g'), ''))
      from pg_catalog.pg_policies p where p.schemaname in ('public', 'private')
    union all
    select 'rls:' || n.nspname || '.' || cl.relname, md5(cl.relrowsecurity::text || cl.relforcerowsecurity::text)
      from pg_catalog.pg_class cl join n on n.oid = cl.relnamespace where cl.relkind = 'r'
    union all
    select 'tgrant:' || g.table_schema || '.' || g.table_name,
           md5(string_agg(g.grantee || ':' || g.privilege_type, ',' order by g.grantee, g.privilege_type))
      from information_schema.role_table_grants g where g.table_schema in ('public', 'private') group by g.table_schema, g.table_name
    union all
    select 'ixflags:' || n.nspname || '.' || ic.relname,
           md5(i.indisvalid::text || i.indisready::text || i.indislive::text || i.indisunique::text || i.indisprimary::text)
      from pg_catalog.pg_index i join pg_catalog.pg_class ic on ic.oid = i.indexrelid join n on n.oid = ic.relnamespace
  )
  select md5(string_agg(k || '|' || h, E'\n' order by k))
    from items
   where k !~ '^(idx|ixflags):public\.(idx_expense_payments_expense|idx_expense_payments_expense_org|idx_expense_payments_reversal_of|idx_expense_payments_reversal_org|idx_expenses_category_org)$' $$;
-- @@FP_EX5_END@@

-- Plano (JSON) de uma consulta; uses() = o plano usa aquele índice e não faz Seq Scan na tabela.
create function pg_temp.plan(p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute 'explain (format json, costs true) ' || p_sql into v;
  return v;
end $$;
create function pg_temp.uses(p_plan jsonb, p_index text, p_table text) returns boolean language sql immutable as $$
  select p_plan::text like '%"Index Name": "' || p_index || '"%'
     and not exists (select 1 from jsonb_path_query(p_plan, '$.**') e
                      where jsonb_typeof(e) = 'object' and e->>'Node Type' = 'Seq Scan' and e->>'Relation Name' = p_table) $$;
create function pg_temp.nodes(p_plan jsonb) returns text language sql immutable as $$
  select string_agg(coalesce(e->>'Node Type', '') || coalesce('(' || (e->>'Index Name') || ')', ''), ' > ')
    from jsonb_path_query(p_plan, '$.**') e where jsonb_typeof(e) = 'object' and e ? 'Node Type' $$;
-- Plano GENÉRICO (parâmetros $n, como a checagem interna de FK usa): PREPARE + force_generic_plan.
create function pg_temp.gplan(p_stmt text, p_types text, p_args text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute format('prepare rg_gp(%s) as %s', p_types, p_stmt);
  perform set_config('plan_cache_mode', 'force_generic_plan', true);
  execute format('explain (format json) execute rg_gp(%s)', p_args) into v;
  perform set_config('plan_cache_mode', 'auto', true);
  execute 'deallocate rg_gp';
  return v;
end $$;
-- scans do índice na transação corrente (contador transacional, ainda não publicado)
create function pg_temp.scans(p_index text) returns bigint language sql volatile as $$
  select pg_catalog.pg_stat_get_xact_numscans(to_regclass('public.' || p_index)) $$;

-- ============================================================================= T01–T07 metadados
do $$
declare
  v_post text[] := array(select unnest(array[
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
  v_defs text[] := pg_temp.ixdefs();
  v_new text[] := array[
    'CREATE INDEX idx_expense_payments_expense_org ON public.expense_payments USING btree (expense_id, organization_id)',
    'CREATE INDEX idx_expense_payments_reversal_org ON public.expense_payments USING btree (reversal_of, organization_id) WHERE (reversal_of IS NOT NULL)',
    'CREATE INDEX idx_expenses_category_org ON public.expenses USING btree (category_id, organization_id)'];
  v_unc text[];
  v_pred text;
  v_base text := (select v from cfg where k = 'baseline_ex5');
  v_fp text := pg_temp.fp_ex5();
begin
  perform pg_temp.ok('T01 os 3 índices novos existem com a definição exata e válidos', v_defs @> v_new, array_to_string(v_new, ' ; '));
  perform pg_temp.ok('T02 os 2 índices simples antigos não existem mais',
    to_regclass('public.idx_expense_payments_expense') is null and to_regclass('public.idx_expense_payments_reversal_of') is null,
    'idx_expense_payments_expense, idx_expense_payments_reversal_of ausentes');
  perform pg_temp.ok('T03 conjunto exato de índices de expenses/expense_payments pós-A.1 (12, todos válidos)',
    v_defs = v_post, format('%s índices', cardinality(v_defs)));

  select array_agg(table_name || '.' || fkey_name order by fkey_name) into v_unc from pg_temp.lint_uncovered();
  perform pg_temp.ok('T04 lint 0001 equivalente: as 3 FKs compostas NÃO aparecem como sem cobertura',
    not (coalesce(v_unc, '{}') && array['expenses.expenses_category_org_fkey', 'expense_payments.expense_payments_expense_org_fkey',
                                         'expense_payments.expense_payments_reversal_org_fkey']),
    'sem cobertura (public): ' || coalesce(array_to_string(v_unc, ', '), '-'));
  select array_agg(table_name || '.' || fkey_name order by fkey_name) into v_unc
    from pg_temp.lint_uncovered() where table_name in ('expense_categories', 'expenses', 'expense_payments');
  perform pg_temp.ok('T05 tabelas 03B.2: sobram só as 4 FKs para auth.users (fora do escopo); nenhum alerta novo',
    v_unc = array['expense_payments.expense_payments_created_by_fkey', 'expense_payments.expense_payments_voided_by_fkey',
                  'expenses.expenses_cancelled_by_fkey', 'expenses.expenses_created_by_fkey'],
    coalesce(array_to_string(v_unc, ', '), '-'));

  select pg_get_expr(i.indpred, i.indrelid) into v_pred from pg_index i where i.indexrelid = to_regclass('public.idx_expense_payments_reversal_org');
  perform pg_temp.ok('T06 reversal_org: índice PARCIAL (reversal_of IS NOT NULL) e o lint o reconhece como cobertura',
    v_pred = '(reversal_of IS NOT NULL)'
    and not exists (select 1 from pg_temp.lint_uncovered() where fkey_name = 'expense_payments_reversal_org_fkey'),
    'predicado=' || coalesce(v_pred, 'NULL') || '; lint 0001 não avalia indpred');

  perform pg_temp.ok('T07 schema public+private fora dos 5 índices idêntico ao estado 03B.2A (fingerprint)',
    v_base <> '' and v_fp = v_base, format('atual=%s baseline=%s', v_fp, coalesce(nullif(v_base, ''), 'NÃO INFORMADO (-v rg_baseline_ex5)')));
end $$;

-- ============================================================================= fixture sintética
do $$
declare
  v_tag text := substr(md5(random()::text), 1, 8);
  v_org uuid; v_arena uuid; v_cats uuid[]; v_cat_free uuid; v_exp_free uuid; v_exp uuid;
begin
  insert into public.organizations (name, is_demo) values ('P3B2A1 ' || v_tag, true) returning id into v_org;  -- seed: 10 categorias
  insert into public.arenas (organization_id, name) values (v_org, 'A ' || v_tag) returning id into v_arena;
  insert into public.expense_categories (organization_id, name)
  select v_org, 'Fixture ' || lpad(g::text, 3, '0') from generate_series(1, 290) g;
  insert into public.expense_categories (organization_id, name) values (v_org, 'Fixture livre') returning id into v_cat_free;
  select array_agg(c.id order by c.name) into v_cats from public.expense_categories c where c.organization_id = v_org and c.id <> v_cat_free;

  -- 3000 despesas em 300 categorias (10 por categoria)
  insert into public.expenses (organization_id, arena_id, category_id, description, amount, due_date, operation_id, operation_fingerprint)
  select v_org, case when g % 2 = 0 then v_arena end, v_cats[1 + g % 300], 'Despesa ' || g, 100000,
         current_date - (g % 300), gen_random_uuid(), sha256(convert_to('e' || g || v_tag, 'UTF8'))
    from generate_series(1, 3000) g;
  -- despesa sem lançamentos (alvo do DELETE real)
  insert into public.expenses (organization_id, category_id, description, amount, due_date, operation_id, operation_fingerprint)
  values (v_org, v_cats[1], 'Despesa livre', 100000, current_date, gen_random_uuid(), sha256(convert_to('free' || v_tag, 'UTF8')))
  returning id into v_exp_free;

  -- 6 pagamentos por despesa (18000) + 1 devolução no 1º pagamento de 1000 despesas
  insert into public.expense_payments (organization_id, expense_id, kind, method, amount, paid_at, operation_id, operation_fingerprint)
  select v_org, e.id, 'PAYMENT', 'PIX', 1000, now() - make_interval(hours => s * 24 + (row_number() over ())::int % 20),
         gen_random_uuid(), sha256(convert_to(e.id::text || s, 'UTF8'))
    from public.expenses e cross join generate_series(1, 6) s
   where e.organization_id = v_org and e.id <> v_exp_free;
  insert into public.expense_payments (organization_id, expense_id, kind, reversal_of, method, amount, paid_at, operation_id, operation_fingerprint)
  select v_org, p.expense_id, 'REVERSAL', p.id, 'PIX', 500, now(), gen_random_uuid(), sha256(convert_to('r' || p.id::text, 'UTF8'))
    from (select distinct on (p.expense_id) p.* from public.expense_payments p
           where p.organization_id = v_org order by p.expense_id, p.paid_at, p.id) p
   order by p.expense_id limit 1000;

  select e.id into v_exp from public.expenses e
   where e.organization_id = v_org and exists (select 1 from public.expense_payments r where r.expense_id = e.id and r.kind = 'REVERSAL')
   order by e.id limit 1;
  insert into fx values ('org', v_org), ('cat_free', v_cat_free), ('cat_used', v_cats[7]), ('exp_free', v_exp_free), ('exp', v_exp),
    ('pay_with_rev', (select p.id from public.expense_payments p where p.expense_id = v_exp and p.kind = 'PAYMENT'
                        and exists (select 1 from public.expense_payments r where r.reversal_of = p.id) limit 1)),
    ('pay_no_rev', (select p.id from public.expense_payments p where p.expense_id = v_exp and p.kind = 'PAYMENT'
                      and not exists (select 1 from public.expense_payments r where r.reversal_of = p.id) order by p.id limit 1)),
    ('rev', (select r.id from public.expense_payments r where r.expense_id = v_exp and r.kind = 'REVERSAL' limit 1));
end $$;
analyze public.expense_categories;
analyze public.expenses;
analyze public.expense_payments;

do $$ begin
  perform pg_temp.ok('T08 fixture: 3001 despesas, 18000 pagamentos, 1000 devoluções, 301 categorias (10 padrão + 291 fixture)',
    (select count(*) from public.expenses where organization_id = pg_temp.k('org')) = 3001
    and (select count(*) from public.expense_payments where organization_id = pg_temp.k('org') and kind = 'PAYMENT') = 18000
    and (select count(*) from public.expense_payments where organization_id = pg_temp.k('org') and kind = 'REVERSAL') = 1000
    and (select count(*) from public.expense_categories where organization_id = pg_temp.k('org')) = 301
    and (select reltuples from pg_class where oid = 'public.expense_payments'::regclass) >= 19000,
    format('reltuples expense_payments=%s', (select reltuples from pg_class where oid = 'public.expense_payments'::regclass)));
end $$;

-- ============================================================================= T09–T20 EXPLAIN (com dados)
do $$
declare
  v_org uuid := pg_temp.k('org'); v_exp uuid := pg_temp.k('exp'); v_pay uuid := pg_temp.k('pay_with_rev'); v_cat uuid := pg_temp.k('cat_used');
  p jsonb;
begin
  -- planos customizados (literais), consultas reais da 03B.2
  p := pg_temp.plan(format('select * from public.expense_payments where expense_id = %L', v_exp));
  perform pg_temp.ok('T09 expense_id = X usa idx_expense_payments_expense_org', pg_temp.uses(p, 'idx_expense_payments_expense_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select coalesce(sum(case when p.kind = ''PAYMENT'' then p.amount else -p.amount end), 0) from public.expense_payments p where p.expense_id = %L and p.voided_at is null', v_exp));
  perform pg_temp.ok('T10 saldo do trigger/RPC (expense_id = X and voided_at is null) usa idx_expense_payments_expense_org', pg_temp.uses(p, 'idx_expense_payments_expense_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select * from public.expense_payments where expense_id = %L and organization_id = %L', v_exp, v_org));
  perform pg_temp.ok('T11 expense_id = X and organization_id = Y usa idx_expense_payments_expense_org', pg_temp.uses(p, 'idx_expense_payments_expense_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select * from public.expense_payments where reversal_of = %L', v_pay));
  perform pg_temp.ok('T12 reversal_of = X usa idx_expense_payments_reversal_org (parcial)', pg_temp.uses(p, 'idx_expense_payments_reversal_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select coalesce(sum(c.amount), 0) from public.expense_payments c where c.reversal_of = %L and c.voided_at is null', v_pay));
  perform pg_temp.ok('T13 soma devolvida (reversal_of = X and voided_at is null) usa idx_expense_payments_reversal_org', pg_temp.uses(p, 'idx_expense_payments_reversal_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select * from public.expense_payments where reversal_of = %L and organization_id = %L', v_pay, v_org));
  perform pg_temp.ok('T14 reversal_of = X and organization_id = Y usa idx_expense_payments_reversal_org', pg_temp.uses(p, 'idx_expense_payments_reversal_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select 1 from public.expenses where category_id = %L and organization_id = %L', v_cat, v_org));
  perform pg_temp.ok('T15 category_id = X and organization_id = Y usa idx_expenses_category_org', pg_temp.uses(p, 'idx_expenses_category_org', 'expenses'), pg_temp.nodes(p));

  -- planos GENÉRICOS no formato da checagem interna de FK (RI_FKey_restrict: "... = $1 AND ... = $2 FOR KEY SHARE")
  p := pg_temp.gplan('select 1 from only public.expense_payments x where expense_id = $1 and organization_id = $2 for key share of x',
                     'uuid, uuid', format('%L, %L', v_exp, v_org));
  perform pg_temp.ok('T16 checagem FK expense_org (plano genérico $1/$2) usa idx_expense_payments_expense_org', pg_temp.uses(p, 'idx_expense_payments_expense_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.gplan('select 1 from only public.expense_payments x where reversal_of = $1 and organization_id = $2 for key share of x',
                     'uuid, uuid', format('%L, %L', v_pay, v_org));
  perform pg_temp.ok('T17 checagem FK reversal_org (plano genérico $1/$2) usa o índice PARCIAL: reversal_of = $1 implica IS NOT NULL',
    pg_temp.uses(p, 'idx_expense_payments_reversal_org', 'expense_payments'), pg_temp.nodes(p));
  p := pg_temp.gplan('select 1 from only public.expenses x where category_id = $1 and organization_id = $2 for key share of x',
                     'uuid, uuid', format('%L, %L', v_cat, v_org));
  perform pg_temp.ok('T18 checagem FK category_org (plano genérico $1/$2) usa idx_expenses_category_org', pg_temp.uses(p, 'idx_expenses_category_org', 'expenses'), pg_temp.nodes(p));
  -- consultas da 03B.2 que não dependem dos índices novos continuam nos índices originais
  p := pg_temp.plan(format('select * from public.expenses x where x.organization_id = %L and x.due_date between current_date - 3 and current_date', v_org));
  perform pg_temp.ok('T19 rg_exp_rows (org + vencimento) continua em idx_expenses_org_due', pg_temp.uses(p, 'idx_expenses_org_due', 'expenses'), pg_temp.nodes(p));
  p := pg_temp.plan(format('select * from public.expense_payments ep where ep.organization_id = %L and ep.paid_at >= now() - interval ''25 hours'' and ep.paid_at < now() - interval ''24 hours''', v_org));
  perform pg_temp.ok('T20 caixa (org + paid_at) continua em idx_expense_payments_org_paid', pg_temp.uses(p, 'idx_expense_payments_org_paid', 'expense_payments'), pg_temp.nodes(p));
end $$;

-- ============================================================================= T21–T26 checagem REAL de FK (DELETE)
-- A organização da fixture é demo: guard_finance_delete permite o DELETE e a checagem RI do
-- PostgreSQL roda de verdade. pg_stat_get_xact_numscans prova qual índice ela usou.
do $$
declare
  b bigint; v_state text;
begin
  b := pg_temp.scans('idx_expenses_category_org');
  delete from public.expense_categories where id = pg_temp.k('cat_free');
  perform pg_temp.ok('T21 DELETE de categoria sem uso: checagem FK category_org varre idx_expenses_category_org',
    pg_temp.scans('idx_expenses_category_org') > b and not exists (select 1 from public.expense_categories where id = pg_temp.k('cat_free')),
    format('scans %s -> %s', b, pg_temp.scans('idx_expenses_category_org')));

  b := pg_temp.scans('idx_expenses_category_org');
  begin
    delete from public.expense_categories where id = pg_temp.k('cat_used');
    v_state := 'OK';
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.ok('T22 DELETE de categoria em uso => 23503 (FK RESTRICT intacta), via idx_expenses_category_org',
    v_state = '23503' and pg_temp.scans('idx_expenses_category_org') > b, format('state=%s scans %s -> %s', v_state, b, pg_temp.scans('idx_expenses_category_org')));

  b := pg_temp.scans('idx_expense_payments_expense_org');
  delete from public.expenses where id = pg_temp.k('exp_free');
  perform pg_temp.ok('T23 DELETE de despesa sem lançamentos (org demo): checagem FK expense_org varre idx_expense_payments_expense_org',
    pg_temp.scans('idx_expense_payments_expense_org') > b and not exists (select 1 from public.expenses where id = pg_temp.k('exp_free')),
    format('scans %s -> %s', b, pg_temp.scans('idx_expense_payments_expense_org')));

  b := pg_temp.scans('idx_expense_payments_expense_org');
  begin
    delete from public.expenses where id = pg_temp.k('exp');
    v_state := 'OK';
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.ok('T24 DELETE de despesa com lançamentos => 23503, via idx_expense_payments_expense_org',
    v_state = '23503' and pg_temp.scans('idx_expense_payments_expense_org') > b, format('state=%s scans %s -> %s', v_state, b, pg_temp.scans('idx_expense_payments_expense_org')));

  b := pg_temp.scans('idx_expense_payments_reversal_org');
  delete from public.expense_payments where id = pg_temp.k('pay_no_rev');
  perform pg_temp.ok('T25 DELETE de pagamento sem devolução: checagem FK reversal_org usa o índice PARCIAL idx_expense_payments_reversal_org',
    pg_temp.scans('idx_expense_payments_reversal_org') > b and not exists (select 1 from public.expense_payments where id = pg_temp.k('pay_no_rev')),
    format('scans %s -> %s', b, pg_temp.scans('idx_expense_payments_reversal_org')));

  b := pg_temp.scans('idx_expense_payments_reversal_org');
  begin
    delete from public.expense_payments where id = pg_temp.k('pay_with_rev');
    v_state := 'OK';
  exception when others then v_state := sqlstate;
  end;
  perform pg_temp.ok('T26 DELETE de pagamento com devolução => 23503, via idx_expense_payments_reversal_org',
    v_state = '23503' and pg_temp.scans('idx_expense_payments_reversal_org') > b, format('state=%s scans %s -> %s', v_state, b, pg_temp.scans('idx_expense_payments_reversal_org')));
end $$;

-- ============================================================================= resultado
do $$
declare v_fail int; v_total int; v_txt text;
begin
  select count(*) filter (where not ok), count(*) into v_fail, v_total from rr;
  if v_fail > 0 then
    select string_agg(format('%s %s [%s]', case when ok then 'PASS' else 'FAIL' end, name, detail), E'\n' order by seq) into v_txt from rr;
    raise exception E'P3B2A1_RESULTS FAIL — % PASS / % FAIL (total %). Transação NÃO confirmada.\n%',
      v_total - v_fail, v_fail, v_total, v_txt;
  end if;
end $$;

select format('P3B2A1_RESULTS OK — %s PASS / 0 FAIL (total %s)', count(*), count(*))
       || E'\n' || string_agg(format('PASS %s [%s]', name, detail), E'\n' order by seq) as p3b2a1_results
  from rr;

rollback;
