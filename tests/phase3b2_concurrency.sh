#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — FASE 03B.2 — harness multi-sessão / multi-transação (banco Docker LOCAL)
#
# Fala SÓ com um container Docker local (docker exec). Nunca toca Supabase remoto/Production.
#
# Uso:
#   bash tests/phase3b2_concurrency.sh concurrency   # T19–T23: sessões PostgreSQL realmente concorrentes
#   bash tests/phase3b2_concurrency.sh lifecycle     # T52–T57: colisão, rollback seguro, fingerprint, diff 03A/03B.1
#   bash tests/phase3b2_concurrency.sh all           # lifecycle + concurrency
# Pré-requisito: migration_phase3b2_expenses.sql APLICADA (lifecycle a reaplica no fim).
# Opcional: RG_P3B2_BASELINE=<arquivo> com o fingerprint de schema ANTES do primeiro apply (T55 exato).
# Variáveis: RG_TEST_CONTAINER (rg-p3a-testdb), RG_TEST_DB_USER (postgres), RG_TEST_DB_NAME (postgres).
#
# Concorrência real: a sessão A abre transação, executa a RPC (adquire os locks) e dorme; a sessão B
# é iniciada e o harness EXIGE observar B esperando lock em pg_stat_activity (wait_event_type='Lock')
# enquanto A ainda está aberta. Sem esse bloqueio observado o teste FALHA (execução sequencial não vale).
# Cada sessão tem timeout; deadlock (40P01) em qualquer saída => FAIL.
# =============================================================================
set -u

CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
DB_USER="${RG_TEST_DB_USER:-postgres}"
DB_NAME="${RG_TEST_DB_NAME:-postgres}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIG="$ROOT/supabase/migration_phase3b2_expenses.sql"
RB="$ROOT/supabase/rollback_phase3b2_expenses.sql"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; RESULTS=""

ok()   { PASS=$((PASS + 1)); RESULTS="$RESULTS"$'\n'"PASS $1"; echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS="$RESULTS"$'\n'"FAIL $1 :: $2"; echo "FAIL  $1 :: $2"; }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# psql no container (stdin), sem psqlrc, saída crua
psql_c() { timeout "${PSQL_TIMEOUT:-120}" docker exec -i -e PGAPPNAME="${APP:-rg3b2_ctl}" "$CONTAINER" \
             psql -U "$DB_USER" -d "$DB_NAME" -X -q -At -v VERBOSITY=verbose "$@"; }
q()  { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r' | tail -n 1; }
qa() { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r'; }

# Sanidade: container local respondendo e é um banco de TESTE (sem dados de Production)
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then echo "container $CONTAINER inexistente"; exit 2; fi
# Production tem dezenas de organizações reais; o banco de teste local começa vazio.
if [ "$(q "select (select count(*) from public.organizations) < 50")" != "t" ]; then
  echo "banco não parece ser de teste (>= 50 organizações) — abortado"; exit 2
fi

FP_SQL=$(cat <<'SQL'
with n as (select oid, nspname from pg_namespace where nspname in ('public', 'private')),
items as (
  select 'fn:' || n.nspname || '.' || p.oid::regprocedure::text as k,
         md5(regexp_replace(replace(pg_get_functiondef(p.oid), chr(13), ''), '\s+', ' ', 'g')) as h
    from pg_proc p join n on n.oid = p.pronamespace where p.prokind in ('f', 'p')
  union all
  select 'acl:' || n.nspname || '.' || p.oid::regprocedure::text,
         md5(coalesce((select string_agg(pg_get_userbyid(a.grantee) || ':' || a.privilege_type, ',' order by pg_get_userbyid(a.grantee), a.privilege_type)
                         from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a), '') || '|sec=' || p.prosecdef::text || '|cfg=' || coalesce(array_to_string(p.proconfig, ','), ''))
    from pg_proc p join n on n.oid = p.pronamespace where p.prokind in ('f', 'p')
  union all
  select 'col:' || c.table_schema || '.' || c.table_name || '.' || c.column_name,
         md5(c.data_type || '|' || c.is_nullable || '|' || coalesce(c.column_default, '') || '|' || coalesce(c.generation_expression, ''))
    from information_schema.columns c where c.table_schema in ('public', 'private')
  union all
  select 'con:' || n.nspname || '.' || cl.relname || '.' || co.conname, md5(regexp_replace(pg_get_constraintdef(co.oid), '\s+', ' ', 'g'))
    from pg_constraint co join pg_class cl on cl.oid = co.conrelid join n on n.oid = cl.relnamespace
  union all
  select 'idx:' || i.schemaname || '.' || i.indexname, md5(regexp_replace(i.indexdef, '\s+', ' ', 'g'))
    from pg_indexes i where i.schemaname in ('public', 'private')
  union all
  select 'trg:' || n.nspname || '.' || cl.relname || '.' || t.tgname, md5(regexp_replace(pg_get_triggerdef(t.oid), '\s+', ' ', 'g') || '|en=' || t.tgenabled::text)
    from pg_trigger t join pg_class cl on cl.oid = t.tgrelid join n on n.oid = cl.relnamespace where not t.tgisinternal
  union all
  select 'pol:' || p.schemaname || '.' || p.tablename || '.' || p.policyname,
         md5(p.cmd || '|' || array_to_string(p.roles, ',') || '|' || coalesce(regexp_replace(p.qual, '\s+', ' ', 'g'), '') || '|' || coalesce(regexp_replace(p.with_check, '\s+', ' ', 'g'), ''))
    from pg_policies p where p.schemaname in ('public', 'private')
  union all
  select 'rls:' || n.nspname || '.' || cl.relname, md5(cl.relrowsecurity::text || cl.relforcerowsecurity::text)
    from pg_class cl join n on n.oid = cl.relnamespace where cl.relkind = 'r'
)
select k || '|' || h from items order by k;
SQL
)
DATA_SQL=$(cat <<'SQL'
select t || '|' || n || '|' || h from (
  select 'reservations' t, count(*) n, md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) h from public.reservations x
  union all select 'reservation_payments', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.reservation_payments x
  union all select 'audit_logs', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.audit_logs x
  union all select 'organizations', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.organizations x
  union all select 'organization_members', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.organization_members x
  union all select 'arenas', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.arenas x
  union all select 'courts', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.courts x
  union all select 'customers', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.customers x
  union all select 'profiles', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.profiles x
  union all select 'auth.users', count(*), md5(coalesce(string_agg(x.id::text || coalesce(x.email, ''), '' order by x.id), '')) from auth.users x
  union all select 'recurring_reservations', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.recurring_reservations x
  union all select 'court_pricing_rules', count(*), md5(coalesce(string_agg(row_to_json(x)::text, '' order by x.id), '')) from public.court_pricing_rules x
) s order by 1;
SQL
)
fp()   { printf '%s\n' "$FP_SQL" | psql_c -v ON_ERROR_STOP=1 | tr -d '\r' | LC_ALL=C sort; }
data() { printf '%s\n' "$DATA_SQL" | psql_c -v ON_ERROR_STOP=1 | tr -d '\r'; }
applied() { q "select to_regclass('public.expenses') is not null"; }

# Fixture comum: usuário OWNER + organização demo (o trigger semeia as categorias)
# $1 = sufixo, $2 = is_demo (true/false). Ecoa "uid org cat_outros cat_energia arena".
mk_org() {
  qa "do \$\$ declare u uuid := gen_random_uuid(); o uuid; a uuid; begin
        insert into auth.users (id, email) values (u, 'p3b2c-$1-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
        insert into public.organizations (name, is_demo) values ('P3B2C $1', $2) returning id into o;
        insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE');
        insert into public.arenas (organization_id, name) values (o, 'Arena $1') returning id into a;
        raise notice 'FX % % % % %', u, o,
          (select id from public.expense_categories where organization_id = o and name = 'Outros'),
          (select id from public.expense_categories where organization_id = o and name = 'Energia'), a;
      end \$\$;" | sed -n 's/.*FX \(.*\)/\1/p' | tail -n 1
}
claims() { printf '{"sub":"%s","role":"authenticated"}' "$1"; }
# executa SQL como o usuário $1 (fora de transação explícita); ecoa a última linha
as_user() { q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$1")', false); $2"; }
new_expense() { # uid org cat amount -> expense_id
  as_user "$1" "select public.rg_expense_create(gen_random_uuid(), '$2', null, '$3', 'Concorrência', $4, current_date, null)->>'expense_id';"
}
pay() { # uid exp amount -> payment_id
  as_user "$1" "select public.rg_expense_payment_register(gen_random_uuid(), '$2', 'PIX', $3, now() - interval '1 minute', null)->>'payment_id';"
}
cleanup_org() { # org uid (org demo ou não): apaga lançamentos, despesas, organização e usuário
  qa "update public.organizations set is_demo = true where id = '$1';
      delete from public.expense_payments where organization_id = '$1' and kind = 'REVERSAL';
      delete from public.expense_payments where organization_id = '$1';
      delete from public.expenses where organization_id = '$1';
      delete from public.arenas where organization_id = '$1';
      delete from public.organizations where id = '$1';
      delete from auth.users where id = '$2';" >/dev/null
}

wait_for() { # condição SQL, timeout em s
  local cond="$1" t="${2:-20}" i=0
  while [ "$i" -lt $((t * 5)) ]; do
    [ "$(q "select ($cond)::int")" = "1" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------- concorrência
# race NAME UID SQL_A SQL_B : A trava e dorme; B só começa depois que A está dormindo;
# exige B observado esperando lock. Saídas em $TMP/NAME_A.out e $TMP/NAME_B.out. Ecoa "blocked=0|1".
race() {
  local name="$1" uid="$2" sqla="$3" sqlb="$4" cl
  cl=$(claims "$uid")
  printf '%s\n' "set lock_timeout = '25s'; set statement_timeout = '40s';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$cl', true);
$sqla
select pg_sleep(6);
commit;" | APP="rg3b2_${name}_A" PSQL_TIMEOUT=60 psql_c > "$TMP/${name}_A.out" 2>&1 &
  local pa=$!
  if ! wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3b2_${name}_A' and state = 'active' and query ilike '%pg_sleep%')" 20; then
    wait "$pa"; echo "blocked=0 (A não chegou ao sleep)"; return
  fi
  printf '%s\n' "set lock_timeout = '25s'; set statement_timeout = '40s';
set role authenticated;
select set_config('request.jwt.claims', '$cl', false);
$sqlb" | APP="rg3b2_${name}_B" PSQL_TIMEOUT=60 psql_c > "$TMP/${name}_B.out" 2>&1 &
  local pb=$! blocked=0
  if wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3b2_${name}_B' and wait_event_type = 'Lock')" 5 \
     && [ "$(q "select exists (select 1 from pg_stat_activity where application_name = 'rg3b2_${name}_A' and state <> 'idle')::int")" = "1" ]; then
    blocked=1
  fi
  wait "$pa"; wait "$pb"
  echo "blocked=$blocked"
}
no_deadlock() { ! grep -qiE '40P01|deadlock' "$TMP/$1_A.out" "$TMP/$1_B.out"; }
err_of() { grep -oE 'ERROR:  [0-9A-Z]{5}' "$TMP/$1" | head -n 1 | awk '{print $2}'; }
hint_of() { grep -oE '^HINT:  [A-Z_]+' "$TMP/$1" | head -n 1 | awk '{print $2}'; }

run_concurrency() {
  echo "== concorrência (sessões reais) =="
  [ "$(applied)" = "t" ] || { bad "pré-requisito" "migration 03B.2 não aplicada"; return; }
  read -r U ORG CAT CAT_E ARENA <<< "$(mk_org conc true)"
  [ -n "${ORG:-}" ] || { bad "fixture" "falhou ao criar organização"; return; }
  local E P r st n

  # T20 dois pagamentos do saldo total com operation_ids diferentes
  E=$(new_expense "$U" "$ORG" "$CAT" 10000)
  r=$(race t20 "$U" "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 10000, now() - interval '1 minute', null);" \
                   "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 10000, now() - interval '1 minute', null);")
  st=$(q "select (count(*)::text || '/' || coalesce(sum(amount), 0)::text) from public.expense_payments where expense_id = '$E' and voided_at is null")
  check "T20 dois pagamentos simultâneos do total (operation_ids diferentes): 1 grava, outro RGP03 OVER_BALANCE; total pago = valor" \
    "$( [ "$r" = "blocked=1" ] && [ "$(err_of t20_B.out)" = "RGP03" ] && [ "$(hint_of t20_B.out)" = "OVER_BALANCE" ] && [ "$st" = "1/10000" ] && no_deadlock t20 && echo 1)" \
    "$r B=$(err_of t20_B.out)/$(hint_of t20_B.out) pagamentos=$st"

  # T19 mesmo operation_id em duas sessões => um único registro (replay)
  E=$(new_expense "$U" "$ORG" "$CAT" 5000); local OP; OP=$(q "select gen_random_uuid()")
  r=$(race t19 "$U" "select public.rg_expense_payment_register('$OP', '$E', 'PIX', 5000, '2026-01-01T10:00:00Z', null);" \
                   "select public.rg_expense_payment_register('$OP', '$E', 'PIX', 5000, '2026-01-01T10:00:00Z', null);")
  n=$(q "select count(*) from public.expense_payments where expense_id = '$E'")
  check "T19 corrida do MESMO operation_id: um único lançamento; a segunda sessão recebe replay (idempotent=true)" \
    "$( [ "$r" = "blocked=1" ] && grep -q '"idempotent": true' "$TMP/t19_B.out" && [ "$n" = "1" ] && no_deadlock t19 && echo 1)" "$r n=$n"

  # T21a cancelar × pagar (A paga e segura; B cancela) => NET_PAID
  E=$(new_expense "$U" "$ORG" "$CAT" 3000)
  r=$(race t21a "$U" "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 3000, now() - interval '1 minute', null);" \
                    "select public.rg_expense_cancel('$E', 'teste');")
  st=$(q "select (cancelled_at is null)::text from public.expenses where id = '$E'")
  check "T21a pagar (A) × cancelar (B): B espera e recebe RGP01 NET_PAID; despesa não cancelada" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21a_B.out)" = "NET_PAID" ] && [ "$st" = "true" ] && no_deadlock t21a && echo 1)" "$r B=$(hint_of t21a_B.out)"
  # T21b cancelar (A) × pagar (B) => EXPENSE_CANCELLED
  E=$(new_expense "$U" "$ORG" "$CAT" 3000)
  r=$(race t21b "$U" "select public.rg_expense_cancel('$E', 'teste');" \
                    "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 3000, now() - interval '1 minute', null);")
  n=$(q "select count(*) from public.expense_payments where expense_id = '$E'")
  check "T21b cancelar (A) × pagar (B): B espera e recebe RGP01 EXPENSE_CANCELLED; nenhum lançamento" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21b_B.out)" = "EXPENSE_CANCELLED" ] && [ "$n" = "0" ] && no_deadlock t21b && echo 1)" "$r B=$(hint_of t21b_B.out)"

  # T21c anular (A) × devolver (B) => PAYMENT_VOIDED
  E=$(new_expense "$U" "$ORG" "$CAT" 4000); P=$(pay "$U" "$E" 4000)
  r=$(race t21c "$U" "select public.rg_expense_payment_void('$P', 'teste');" \
                    "select public.rg_expense_payment_reverse(gen_random_uuid(), '$P', 'PIX', 1000, now() - interval '1 minute', null);")
  n=$(q "select count(*) from public.expense_payments where reversal_of = '$P'")
  check "T21c anular (A) × devolver (B): B espera e recebe RGP01 PAYMENT_VOIDED; nenhuma devolução" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21c_B.out)" = "PAYMENT_VOIDED" ] && [ "$n" = "0" ] && no_deadlock t21c && echo 1)" "$r B=$(hint_of t21c_B.out)"
  # T21d devolver (A) × anular (B) => HAS_REVERSALS
  E=$(new_expense "$U" "$ORG" "$CAT" 4000); P=$(pay "$U" "$E" 4000)
  r=$(race t21d "$U" "select public.rg_expense_payment_reverse(gen_random_uuid(), '$P', 'PIX', 4000, now() - interval '1 minute', null);" \
                    "select public.rg_expense_payment_void('$P', 'teste');")
  st=$(q "select (voided_at is null)::text from public.expense_payments where id = '$P'")
  check "T21d devolver (A) × anular (B): B espera e recebe RGP01 HAS_REVERSALS; pagamento não anulado" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21d_B.out)" = "HAS_REVERSALS" ] && [ "$st" = "true" ] && no_deadlock t21d && echo 1)" "$r B=$(hint_of t21d_B.out)"

  # T21e pagar (A) × mudar valor (B) => AMOUNT_LOCKED
  E=$(new_expense "$U" "$ORG" "$CAT" 10000)
  r=$(race t21e "$U" "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 5000, now() - interval '1 minute', null);" \
                    "select public.rg_expense_update('$E', '{\"amount\": 8000}');")
  st=$(q "select amount from public.expenses where id = '$E'")
  check "T21e pagar (A) × mudar valor (B): B espera e recebe RGP01 AMOUNT_LOCKED; valor inalterado" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21e_B.out)" = "AMOUNT_LOCKED" ] && [ "$st" = "10000" ] && no_deadlock t21e && echo 1)" "$r B=$(hint_of t21e_B.out)"
  # T21f mudar valor (A) × pagar o antigo total (B) => OVER_BALANCE
  E=$(new_expense "$U" "$ORG" "$CAT" 10000)
  r=$(race t21f "$U" "select public.rg_expense_update('$E', '{\"amount\": 8000}');" \
                    "select public.rg_expense_payment_register(gen_random_uuid(), '$E', 'PIX', 10000, now() - interval '1 minute', null);")
  st=$(q "select coalesce(sum(amount), 0) from public.expense_payments where expense_id = '$E'")
  check "T21f mudar valor para 8000 (A) × pagar 10000 (B): B espera e recebe RGP03 OVER_BALANCE; nada pago acima do valor" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t21f_B.out)" = "OVER_BALANCE" ] && [ "$st" = "0" ] && no_deadlock t21f && echo 1)" "$r B=$(hint_of t21f_B.out)"

  # T22a duas categorias com o mesmo name_key => created:false, nunca 500
  r=$(race t22a "$U" "select public.rg_expense_category_create('$ORG', 'Lavanderia');" \
                     "select public.rg_expense_category_create('$ORG', '  LAVANDÉRIA ');")
  n=$(q "select count(*) from public.expense_categories where organization_id = '$ORG' and name_key = 'lavanderia'")
  check "T22a criar mesma name_key em duas sessões: 1 criada; a outra created=false (unique capturado, sem 500)" \
    "$( [ "$r" = "blocked=1" ] && grep -q '"created": false' "$TMP/t22a_B.out" && ! grep -q 'ERROR' "$TMP/t22a_B.out" && [ "$n" = "1" ] && no_deadlock t22a && echo 1)" "$r n=$n"
  # T22b a criada concorrente fica inativa antes do commit => CATEGORY_INACTIVE_EXISTS
  r=$(race t22b "$U" "select public.rg_expense_category_update((public.rg_expense_category_create('$ORG', 'Limpeza')->>'category_id')::uuid, '{\"is_active\": false}');" \
                     "select public.rg_expense_category_create('$ORG', 'limpeza');")
  n=$(q "select count(*) from public.expense_categories where organization_id = '$ORG' and name_key = 'limpeza'")
  check "T22b corrida com a equivalente inativa: RGP01 CATEGORY_INACTIVE_EXISTS (sem 500, sem duplicata)" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t22b_B.out)" = "CATEGORY_INACTIVE_EXISTS" ] && [ "$n" = "1" ] && no_deadlock t22b && echo 1)" "$r B=$(hint_of t22b_B.out) n=$n"

  # T23a criar despesa (A, FOR SHARE na categoria) × inativar categoria (B) => B espera; ambos consistentes
  r=$(race t23a "$U" "select public.rg_expense_create(gen_random_uuid(), '$ORG', null, '$CAT_E', 'Com categoria', 100, current_date, null);" \
                     "select public.rg_expense_category_update('$CAT_E', '{\"is_active\": false}');")
  st=$(q "select (select count(*) from public.expenses where category_id = '$CAT_E')::text || '/' || (select is_active::text from public.expense_categories where id = '$CAT_E')")
  check "T23a criar despesa (A) × inativar categoria (B): B espera o commit de A; despesa criada e categoria inativada, sem deadlock" \
    "$( [ "$r" = "blocked=1" ] && grep -q '"changed": true' "$TMP/t23a_B.out" && [ "$st" = "1/false" ] && no_deadlock t23a && echo 1)" "$r st=$st"
  # T23b inativar categoria (A) × criar despesa nela (B) => CATEGORY_INACTIVE
  as_user "$U" "select public.rg_expense_category_update('$CAT_E', '{\"is_active\": true}');" >/dev/null
  r=$(race t23b "$U" "select public.rg_expense_category_update('$CAT_E', '{\"is_active\": false}');" \
                     "select public.rg_expense_create(gen_random_uuid(), '$ORG', null, '$CAT_E', 'Sem categoria ativa', 100, current_date, null);")
  st=$(q "select count(*) from public.expenses where category_id = '$CAT_E'")
  check "T23b inativar categoria (A) × criar despesa (B): B espera e recebe RGP01 CATEGORY_INACTIVE" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of t23b_B.out)" = "CATEGORY_INACTIVE" ] && [ "$st" = "1" ] && no_deadlock t23b && echo 1)" "$r B=$(hint_of t23b_B.out)"

  # invariante global da fixture: nenhuma despesa paga acima do valor, nenhum net negativo
  st=$(q "select count(*) from public.expenses e where e.organization_id = '$ORG' and (
            (select coalesce(sum(case when p.kind = 'PAYMENT' then p.amount else -p.amount end), 0) from public.expense_payments p
              where p.expense_id = e.id and p.voided_at is null) not between 0 and e.amount)")
  check "T20-INV nenhuma despesa com pago líquido negativo ou acima do valor" "$( [ "$st" = "0" ] && echo 1)" "$st"
  cleanup_org "$ORG" "$U"
  check "T20-CLEAN fixture da concorrência removida" "$( [ "$(q "select count(*) from public.organizations where id = '$ORG'")" = "0" ] && echo 1)"
}

# ---------------------------------------------------------------- ciclo de vida
strip_sql() { sed -e 's/--.*$//' "$1"; }
run_lifecycle() {
  echo "== ciclo de vida (colisão / rollback / fingerprint) =="
  [ "$(applied)" = "t" ] || { bad "pré-requisito" "migration 03B.2 não aplicada"; return; }
  local out st

  # T56 estático: rollback sem CASCADE e na ordem congelada; migration sem OR REPLACE / IF NOT EXISTS
  local l_trg l_fn l_tab l_priv
  l_trg=$(strip_sql "$RB" | grep -n 'drop trigger seed_expense_categories' | head -n 1 | cut -d: -f1)
  l_fn=$(strip_sql "$RB" | grep -n 'drop function public\.' | head -n 1 | cut -d: -f1)
  l_tab=$(strip_sql "$RB" | grep -n 'drop table public\.expense_payments' | head -n 1 | cut -d: -f1)
  l_priv=$(strip_sql "$RB" | grep -n 'drop function private\.' | head -n 1 | cut -d: -f1)
  check "T56 rollback: ZERO CASCADE; ordem trigger -> RPCs -> tabelas -> funções privadas; migration sem CREATE OR REPLACE / IF NOT EXISTS" \
    "$( ! strip_sql "$RB" | grep -qiw 'cascade' && ! strip_sql "$MIG" | grep -qiE 'or replace|if not exists' \
        && [ -n "$l_trg" ] && [ "$l_trg" -lt "$l_fn" ] && [ "$l_fn" -lt "$l_tab" ] && [ "$l_tab" -lt "$l_priv" ] && echo 1)" \
    "trg=$l_trg fn=$l_fn tab=$l_tab priv=$l_priv"

  fp > "$TMP/applied.fp"; data > "$TMP/applied.data"

  # T53 rollback aborta com despesa em organização NÃO-demo (antes de qualquer DROP)
  read -r U ORG CAT CAT_E ARENA <<< "$(mk_org rbabort false)"
  new_expense "$U" "$ORG" "$CAT" 100 >/dev/null
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T53a rollback ABORTA com despesa em organização não-demo; nenhum objeto removido" \
    "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'ABORTADO: 1 despesa' && [ "$(applied)" = "t" ] && fp | cmp -s - "$TMP/applied.fp" && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  qa "update public.organizations set is_demo = true where id = '$ORG';
      delete from public.expenses where organization_id = '$ORG';
      update public.organizations set is_demo = false where id = '$ORG';" >/dev/null

  # T54 categorias fora do estado padrão
  local CUST
  CUST=$(q "insert into public.expense_categories (organization_id, name) values ('$ORG', 'Customizada') returning id")
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T54a rollback ABORTA com categoria customizada" "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'customizada' && [ "$(applied)" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  q "delete from public.expense_categories where id = '$CUST'" >/dev/null
  q "update public.expense_categories set name = 'Outras' where organization_id = '$ORG' and name = 'Outros'" >/dev/null
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T54b rollback ABORTA com categoria padrão renomeada" "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'renomeada' && [ "$(applied)" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  q "update public.expense_categories set name = 'Outros' where organization_id = '$ORG' and name = 'Outras'" >/dev/null
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T54c rollback ABORTA com categoria padrão editada e revertida (updated_at != created_at)" \
    "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'editada' && [ "$(applied)" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  cleanup_org "$ORG" "$U"
  read -r U ORG CAT CAT_E ARENA <<< "$(mk_org rbinact false)"
  q "update public.expense_categories set is_active = false where id = '$CAT_E'" >/dev/null
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T54d rollback ABORTA com categoria padrão inativada" "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'inativada' && [ "$(applied)" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  cleanup_org "$ORG" "$U"
  read -r U ORG CAT CAT_E ARENA <<< "$(mk_org rbset false)"
  q "delete from public.expense_categories where organization_id = '$ORG' and name = 'Internet'" >/dev/null
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  check "T54e rollback ABORTA sem o conjunto exato das 10 categorias padrão" \
    "$( [ "$st" -ne 0 ] && echo "$out" | grep -q 'conjunto exato' && [ "$(applied)" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
  cleanup_org "$ORG" "$U"
  check "T53b nenhum dado alterado pelas tentativas abortadas (dados = antes)" "$( data | cmp -s - "$TMP/applied.data" && echo 1)"

  # Organizações existentes ANTES do rollback/reapply: uma não-demo padrão e uma demo com despesa
  read -r U1 ORG1 _ _ _ <<< "$(mk_org existente false)"
  read -r U2 ORG2 CAT2 _ _ <<< "$(mk_org demo true)"
  new_expense "$U2" "$ORG2" "$CAT2" 500 >/dev/null
  fp > "$TMP/applied2.fp"; data > "$TMP/applied2.data"

  # T55 rollback no estado padrão (demo com dados pode ser descartada)
  out=$(psql_c -v ON_ERROR_STOP=1 < "$RB" 2>&1); st=$?
  fp > "$TMP/rb.fp"; data > "$TMP/rb.data"
  local removed_other changed added_ok
  removed_other=$(comm -23 "$TMP/applied2.fp" "$TMP/rb.fp" | cut -d'|' -f1 \
    | grep -vE 'expense|rg_exp|rg_fin_cash_result|rg_fin_cash_movements|seed_expense_categories' | wc -l)
  check "T55a rollback no estado padrão conclui; remove só objetos da 03B.2; dados das tabelas existentes intactos" \
    "$( [ "$st" -eq 0 ] && [ "$(applied)" = "f" ] && [ "$removed_other" = "0" ] && [ -z "$(comm -13 "$TMP/applied2.fp" "$TMP/rb.fp")" ] \
        && cmp -s "$TMP/applied2.data" "$TMP/rb.data" && echo 1)" "st=$st removidos_fora=$removed_other $(echo "$out" | grep -m1 ERROR)"
  if [ -n "${RG_P3B2_BASELINE:-}" ] && [ -f "$RG_P3B2_BASELINE" ]; then
    check "T55b fingerprint de schema após rollback = baseline anterior ao primeiro apply (exato)" \
      "$( tr -d '\r' < "$RG_P3B2_BASELINE" | grep -v '^$' | LC_ALL=C sort | cmp -s - "$TMP/rb.fp" && echo 1)"
  fi

  # T52 colisão: cada sentinela faz a migration falhar com 42710 sem efeito parcial
  local s name cleanup
  for s in \
    "table|create table public.expenses (x int);|drop table public.expenses;" \
    "index|create table public.zz_p3b2_sentinel (x int); create index idx_expenses_org_due on public.zz_p3b2_sentinel (x);|drop table public.zz_p3b2_sentinel;" \
    "função privada|create function private.rg_exp_rows(uuid, uuid, date, date) returns int language sql as 'select 1';|drop function private.rg_exp_rows(uuid, uuid, date, date);" \
    "RPC pública|create function public.rg_fin_cash_result(uuid, uuid, date, date, text) returns int language sql as 'select 1';|drop function public.rg_fin_cash_result(uuid, uuid, date, date, text);" \
    "sobrecarga|create function public.rg_expenses(text) returns int language sql as 'select 1';|drop function public.rg_expenses(text);" \
    "trigger em organizations|create function public.zz_p3b2_trg() returns trigger language plpgsql as 'begin return null; end'; create trigger seed_expense_categories after insert on public.organizations for each row execute function public.zz_p3b2_trg();|drop trigger seed_expense_categories on public.organizations; drop function public.zz_p3b2_trg();"; do
    name="${s%%|*}"; cleanup="${s##*|}"; s="${s#*|}"; s="${s%|*}"
    qa "$s" >/dev/null
    fp > "$TMP/sent_before.fp"
    out=$(psql_c -v ON_ERROR_STOP=1 < "$MIG" 2>&1); st=$?
    fp > "$TMP/sent_after.fp"
    check "T52 colisão ($name) => 42710 sem efeito parcial" \
      "$( [ "$st" -ne 0 ] && echo "$out" | grep -q '42710' && cmp -s "$TMP/sent_before.fp" "$TMP/sent_after.fp" \
          && [ "$(q "select to_regclass('public.expense_categories') is null")" = "t" ] && echo 1)" "$(echo "$out" | grep -m1 ERROR)"
    qa "$cleanup" >/dev/null
  done
  check "T52b sentinelas removidas: schema voltou ao estado pós-rollback" "$( fp | cmp -s - "$TMP/rb.fp" && echo 1)"

  # Reaplicação: seed das organizações existentes + schema idêntico ao aplicado
  out=$(psql_c -v ON_ERROR_STOP=1 < "$MIG" 2>&1); st=$?
  fp > "$TMP/re.fp"
  check "T55c reaplicar após rollback: schema idêntico ao aplicado antes (fingerprint exato)" \
    "$( [ "$st" -eq 0 ] && cmp -s "$TMP/applied.fp" "$TMP/re.fp" && echo 1)" "st=$st $(echo "$out" | grep -m1 ERROR)"
  check "T55d seed das organizações existentes na reaplicação: 10 categorias padrão em cada uma (não-demo e demo)" \
    "$( [ "$(q "select count(*) from public.organizations o where (select count(*) from public.expense_categories c where c.organization_id = o.id) <> 10")" = "0" ] \
        && [ "$(q "select count(*) from public.expense_categories where organization_id in ('$ORG1', '$ORG2')")" = "20" ] && echo 1)"

  # T57 diff 03A/03B.1: aplicado vs pós-rollback só difere por adições da 03B.2
  local foreign
  foreign=$(comm -13 "$TMP/rb.fp" "$TMP/re.fp" | cut -d'|' -f1 \
    | grep -vE 'expense|rg_exp|rg_fin_cash_result|rg_fin_cash_movements|seed_expense_categories' | wc -l)
  check "T57 zero diferença em objetos da 03A/03B.1: a migration só ADICIONA objetos da 03B.2 (nada alterado/removido)" \
    "$( [ "$foreign" = "0" ] && [ -z "$(comm -23 "$TMP/rb.fp" "$TMP/re.fp")" ] && echo 1)" "fora_do_escopo=$foreign removidos=$(comm -23 "$TMP/rb.fp" "$TMP/re.fp" | wc -l)"

  cleanup_org "$ORG1" "$U1"; cleanup_org "$ORG2" "$U2"
  check "T5x-CLEAN organizações do ciclo de vida removidas" \
    "$( [ "$(q "select count(*) from public.organizations where id in ('$ORG1', '$ORG2')")" = "0" ] && echo 1)"
}

case "${1:-all}" in
  concurrency) run_concurrency ;;
  lifecycle) run_lifecycle ;;
  all) run_lifecycle; run_concurrency ;;
  *) echo "uso: $0 [concurrency|lifecycle|all]"; exit 2 ;;
esac

echo
echo "P3B2_HARNESS $PASS PASS / $FAIL FAIL (total $((PASS + FAIL)))"
[ "$FAIL" -eq 0 ]
