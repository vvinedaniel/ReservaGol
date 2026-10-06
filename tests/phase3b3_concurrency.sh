#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — FASE 03B.3A — harness multi-sessão / multi-transação (banco Docker LOCAL)
#
# Fala SÓ com um container Docker local (docker exec). Nunca toca Supabase remoto/Production.
#
# Uso:
#   bash tests/phase3b3_concurrency.sh concurrency   # R01–R12: sessões PostgreSQL realmente concorrentes
#   bash tests/phase3b3_concurrency.sh lifecycle     # L01–L06: colisão, rollback seguro, restauração exata
#   bash tests/phase3b3_concurrency.sh all           # lifecycle + concurrency
# Pré-requisito: migration_phase3b3_recurring_month.sql APLICADA (lifecycle a reaplica no fim).
# Variáveis: RG_TEST_CONTAINER (rg-p3a-testdb), RG_TEST_DB_USER (postgres), RG_TEST_DB_NAME (postgres).
#
# Concorrência real: a sessão A abre transação, executa a operação (adquire os locks) e dorme; a sessão B
# é iniciada e o harness EXIGE observar B esperando lock em pg_stat_activity (wait_event_type='Lock')
# enquanto A ainda está aberta (exceto R12, que exige NÃO bloquear). Deadlock (40P01) em qualquer saída => FAIL.
# =============================================================================
set -u

CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
DB_USER="${RG_TEST_DB_USER:-postgres}"
DB_NAME="${RG_TEST_DB_NAME:-postgres}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIG="$ROOT/supabase/migration_phase3b3_recurring_month.sql"
RB="$ROOT/supabase/rollback_phase3b3_recurring_month.sql"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; RESULTS=""

ok()   { PASS=$((PASS + 1)); RESULTS="$RESULTS"$'\n'"PASS $1"; echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); RESULTS="$RESULTS"$'\n'"FAIL $1 :: $2"; echo "FAIL  $1 :: $2"; }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

psql_c() { timeout "${PSQL_TIMEOUT:-120}" docker exec -i -e PGAPPNAME="${APP:-rg3b3_ctl}" "$CONTAINER" \
             psql -U "$DB_USER" -d "$DB_NAME" -X -q -At -v VERBOSITY=verbose "$@"; }
q()  { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r' | tail -n 1; }
qa() { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r'; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then echo "container $CONTAINER inexistente"; exit 2; fi
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
  union all
  select 'tgr:' || g.table_schema || '.' || g.table_name || '.' || g.grantee || '.' || g.privilege_type, md5('1')
    from information_schema.role_table_grants g where g.table_schema in ('public', 'private')
)
select k || '|' || h from items order by k;
SQL
)
fp()      { printf '%s\n' "$FP_SQL" | psql_c -v ON_ERROR_STOP=1 | tr -d '\r' | LC_ALL=C sort; }
applied() { q "select to_regclass('public.reservation_payment_batches') is not null"; }

claims() { printf '{"sub":"%s","role":"authenticated"}' "$1"; }
as_user() { q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$1")', false); $2"; }

# Fixture: organização demo com OWNER + RECEPTIONIST, arena, quadra, cliente. Ecoa "owner rec org arena court cust".
mk_org() {
  qa "do \$\$ declare u uuid := gen_random_uuid(); r uuid := gen_random_uuid(); o uuid; a uuid; c uuid; cu uuid; begin
        insert into auth.users (id, email) values (u, 'p3b3c-$1-o-' || substr(md5(random()::text), 1, 6) || '@reservagol.test'),
                                                  (r, 'p3b3c-$1-r-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
        insert into public.organizations (name, is_demo) values ('P3B3C $1', true) returning id into o;
        insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE'), (o, r, 'RECEPTIONIST', 'ACTIVE');
        insert into public.arenas (organization_id, name) values (o, 'Arena $1') returning id into a;
        insert into public.courts (organization_id, arena_id, name) values (o, a, 'Quadra $1') returning id into c;
        insert into public.customers (organization_id, arena_id, name, phone) values (o, a, 'Cliente $1', null) returning id into cu;
        raise notice 'FX % % % % % %', u, r, o, a, c, cu;
      end \$\$;" | sed -n 's/.*FX \(.*\)/\1/p' | tail -n 1
}
MONTH=$(q "select to_char(date_trunc('month', (now() at time zone 'America/Sao_Paulo')::date) + interval '1 month', 'YYYY-MM-DD')")
# Série semanal (dia da semana $5, hora $6) materializada pela RPC real nas datas do próximo mês. Ecoa series_id.
# $1 owner $2 arena $3 court $4 customer|null $5 weekday $6 HH $7 price|null
new_series() {
  local cust="null"; [ "$4" != "null" ] && cust="'$4'"
  as_user "$1" "select public.rg_recurring_create(gen_random_uuid(), '$2', '$3', $cust, null, 'WEEKLY', $5, null,
      '$6:00'::time, '$6:59'::time, ('$MONTH'::date - 7), null, true, $7, null, false, false,
      array(select g::date from generate_series('$MONTH'::date, ('$MONTH'::date + interval '1 month' - interval '1 day')::date, interval '1 day') g
             where extract(dow from g)::int = $5))->>'series_id';"
}
occ_ids() { q "select string_agg(id::text, ' ' order by occurrence_date) from public.reservations where recurring_reservation_id = '$1'"; }
month_open() { # series(root) -> saldo aberto do mês (linhagem)
  q "select coalesce(sum(collectible_balance), 0) from private.rg_rm_rows(array(select series_id from private.rg_rm_lineage('$1')), '$MONTH'::date, ('$MONTH'::date + interval '1 month' - interval '1 day')::date)"
}
pay_month() { # actor lineage amount expected [op] [received_at] -> SQL
  local op="${5:-gen_random_uuid()}" at="${6:-now() - interval '1 minute'}"
  [ "$op" != "gen_random_uuid()" ] && op="'$op'"
  [ -n "${6:-}" ] && at="'$6'::timestamptz"
  printf "select public.rg_recurring_month_payment_record(%s, '%s', '%s'::date, %s, 'PIX', %s, null, %s);" "$op" "$2" "$MONTH" "$3" "$at" "$4"
}
cleanup_org() { # org owner rec
  qa "update public.organizations set is_demo = true where id = '$1';
      delete from public.reservation_payment_batch_items where organization_id = '$1';
      delete from public.reservation_payment_batches where organization_id = '$1';
      delete from public.reservation_payments where organization_id = '$1' and kind = 'REFUND';
      delete from public.reservation_payments where organization_id = '$1';
      delete from public.audit_logs where organization_id = '$1';
      delete from public.reservations where organization_id = '$1';
      delete from public.recurring_reservations where organization_id = '$1' and previous_series_id is not null;
      delete from public.recurring_reservations where organization_id = '$1';
      delete from public.customers where organization_id = '$1';
      delete from public.courts where organization_id = '$1';
      delete from public.arenas where organization_id = '$1';
      delete from public.organizations where id = '$1';
      delete from auth.users where id in ('$2', '$3');" >/dev/null
}

wait_for() {
  local cond="$1" t="${2:-20}" i=0
  while [ "$i" -lt $((t * 5)) ]; do
    [ "$(q "select ($cond)::int")" = "1" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# race NAME UID_A SQL_A UID_B SQL_B : A trava e dorme; B só começa depois que A dorme. Ecoa "blocked=0|1".
race() {
  local name="$1" ua="$2" sqla="$3" ub="$4" sqlb="$5"
  printf '%s\n' "set lock_timeout = '25s'; set statement_timeout = '40s';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '$(claims "$ua")', true);
$sqla
select pg_sleep(6);
commit;" | APP="rg3b3_${name}_A" PSQL_TIMEOUT=60 psql_c > "$TMP/${name}_A.out" 2>&1 &
  local pa=$!
  if ! wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3b3_${name}_A' and state = 'active' and query ilike '%pg_sleep%')" 20; then
    wait "$pa"; echo "blocked=0 (A não chegou ao sleep)"; return
  fi
  printf '%s\n' "set lock_timeout = '25s'; set statement_timeout = '40s';
set role authenticated;
select set_config('request.jwt.claims', '$(claims "$ub")', false);
$sqlb" | APP="rg3b3_${name}_B" PSQL_TIMEOUT=60 psql_c > "$TMP/${name}_B.out" 2>&1 &
  local pb=$! blocked=0
  if wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3b3_${name}_B' and wait_event_type = 'Lock')" 5 \
     && [ "$(q "select exists (select 1 from pg_stat_activity where application_name = 'rg3b3_${name}_A' and state <> 'idle')::int")" = "1" ]; then
    blocked=1
  fi
  wait "$pa"; wait "$pb"
  echo "blocked=$blocked"
}
no_deadlock() { ! grep -qiE '40P01|deadlock' "$TMP/$1_A.out" "$TMP/$1_B.out"; }
err_of()  { grep -oE 'ERROR:  [0-9A-Z]{5}' "$TMP/$1" | head -n 1 | awk '{print $2}'; }
hint_of() { grep -oE '^HINT:  [A-Z_]+' "$TMP/$1" | head -n 1 | awk '{print $2}'; }
noerr()   { ! grep -q 'ERROR:' "$TMP/$1"; }

# ---------------------------------------------------------------- concorrência
run_concurrency() {
  echo "== concorrência (sessões reais) =="
  [ "$(applied)" = "t" ] || { bad "pré-requisito" "migration 03B.3 não aplicada"; return; }
  read -r U R ORG ARENA COURT CUST <<< "$(mk_org conc)"
  [ -n "${ORG:-}" ] || { bad "fixture" "falhou ao criar organização"; return; }
  local S S2 OCC N TOTAL r st OP first P

  # R01 OWNER e RECEPÇÃO apertam "Receber mês" juntos (operation_ids diferentes)
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 08 10000); TOTAL=$(month_open "$S")
  r=$(race r01 "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")" "$R" "$(pay_month "$R" "$S" "$TOTAL" "$TOTAL")")
  st=$(q "select count(*) || '/' || coalesce(sum(amount), 0) from public.reservation_payment_batches where lineage_id = '$S'")
  check "R01 dois 'Receber mês' simultâneos: B espera e recebe RGP01 NOTHING_DUE; 1 batch; total = previsto" \
    "$( [ "$r" = "blocked=1" ] && [ "$(err_of r01_B.out)" = "RGP01" ] && [ "$(hint_of r01_B.out)" = "NOTHING_DUE" ] && [ "$st" = "1/$TOTAL" ] && [ "$(month_open "$S")" = "0" ] && no_deadlock r01 && echo 1)" \
    "$r B=$(err_of r01_B.out)/$(hint_of r01_B.out) batches=$st total=$TOTAL"

  # R02 mesmo operation_id em duas sessões => um batch; B recebe replay
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 10 10000); TOTAL=$(month_open "$S"); OP=$(q "select gen_random_uuid()")
  local AT; AT=$(q "select (now() - interval '1 hour')::text")
  r=$(race r02 "$U" "$(pay_month "$U" "$S" 15000 "$TOTAL" "$OP" "$AT")" "$R" "$(pay_month "$R" "$S" 15000 null "$OP" "$AT")")
  st=$(q "select (select count(*) from public.reservation_payment_batches where lineage_id = '$S') || '/' || (select count(*) from public.reservation_payment_batch_items i join public.reservation_payment_batches b on b.id = i.batch_id where b.lineage_id = '$S')")
  check "R02 corrida do MESMO operation_id: 1 batch, 2 itens; B devolve idempotent=true" \
    "$( [ "$r" = "blocked=1" ] && [ "$st" = "1/2" ] && grep -q '"idempotent": true' "$TMP/r02_B.out" && no_deadlock r02 && echo 1)" "$r batches/itens=$st"

  # R03 batch (A) × pagamento individual 03A (B) na 1ª ocorrência
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 12 10000); TOTAL=$(month_open "$S"); first=$(occ_ids "$S" | awk '{print $1}')
  r=$(race r03 "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")" "$R" "select public.rg_payment_register(gen_random_uuid(), '$first', 'PIX', 10000, now() - interval '1 minute', null);")
  check "R03 batch × pagamento individual: B espera e recebe RGP03 OVER_BALANCE; mês quitado sem excesso" \
    "$( [ "$r" = "blocked=1" ] && [ "$(err_of r03_B.out)" = "RGP03" ] && [ "$(month_open "$S")" = "0" ] && no_deadlock r03 && echo 1)" "$r B=$(err_of r03_B.out)"

  # R04 pagamento individual (A) × batch com saldo antigo (B)
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 14 10000); TOTAL=$(month_open "$S"); first=$(occ_ids "$S" | awk '{print $1}')
  r=$(race r04 "$R" "select public.rg_payment_register(gen_random_uuid(), '$first', 'PIX', 4000, now() - interval '1 minute', null);" "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")")
  check "R04 pagamento individual × batch: B espera e recebe RGP01 STATE_CHANGED (saldo mudou); nada gravado por B" \
    "$( [ "$r" = "blocked=1" ] && [ "$(err_of r04_B.out)" = "RGP01" ] && [ "$(hint_of r04_B.out)" = "STATE_CHANGED" ] && [ "$(month_open "$S")" = "$((TOTAL - 4000))" ] && no_deadlock r04 && echo 1)" "$r B=$(err_of r04_B.out)/$(hint_of r04_B.out)"

  # R05 batch (A) × estorno (B) de um pagamento anterior da mesma reserva
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 16 10000); first=$(occ_ids "$S" | awk '{print $1}')
  P=$(as_user "$R" "select public.rg_payment_register(gen_random_uuid(), '$first', 'PIX', 5000, now() - interval '1 hour', null)->>'payment_id';")
  TOTAL=$(month_open "$S")
  r=$(race r05 "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")" "$U" "select public.rg_payment_refund(gen_random_uuid(), '$P', 'PIX', 2000, now() - interval '1 minute', null);")
  st=$(q "select count(*) from private.rg_financials(array(select id from public.reservations where recurring_reservation_id = '$S')) where net_received > amount_due")
  check "R05 batch × estorno: B espera e estorna depois; nenhuma reserva acima do valor; mês reabre R\$20" \
    "$( [ "$r" = "blocked=1" ] && noerr r05_B.out && [ "$st" = "0" ] && [ "$(month_open "$S")" = "2000" ] && no_deadlock r05 && echo 1)" "$r B=$(err_of r05_B.out) acima=$st aberto=$(month_open "$S")"

  # R06 batch (A) × cancelamento da ocorrência (B)
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 18 10000); TOTAL=$(month_open "$S"); OCC=$(occ_ids "$S" | awk '{print $2}')
  r=$(race r06 "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")" "$U" "update public.reservations set status = 'CANCELLED' where id = '$OCC';")
  st=$(q "select payment_status from private.rg_financials(array['$OCC'::uuid])")
  check "R06 batch × cancelar ocorrência: B espera; depois a ocorrência fica RETAINED (dinheiro retido, visível)" \
    "$( [ "$r" = "blocked=1" ] && noerr r06_B.out && [ "$st" = "RETAINED" ] && no_deadlock r06 && echo 1)" "$r B=$(err_of r06_B.out) status=$st"

  # R07 cancelamento (A) × batch com saldo antigo (B)
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 20 10000); TOTAL=$(month_open "$S"); OCC=$(occ_ids "$S" | awk '{print $2}')
  r=$(race r07 "$U" "update public.reservations set status = 'CANCELLED' where id = '$OCC';" "$R" "$(pay_month "$R" "$S" "$TOTAL" "$TOTAL")")
  check "R07 cancelar ocorrência × batch: B espera e recebe RGP01 STATE_CHANGED" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of r07_B.out)" = "STATE_CHANGED" ] && no_deadlock r07 && echo 1)" "$r B=$(err_of r07_B.out)/$(hint_of r07_B.out)"

  # R08 alteração de valor (A) × batch com saldo antigo (B)
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 2 22 10000); TOTAL=$(month_open "$S"); first=$(occ_ids "$S" | awk '{print $1}')
  r=$(race r08 "$U" "select public.rg_reservation_set_price('$first', 'MANUAL', 15000, 'CORRECTION');" "$R" "$(pay_month "$R" "$S" "$TOTAL" "$TOTAL")")
  check "R08 alterar valor × batch: B espera e recebe RGP01 STATE_CHANGED" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of r08_B.out)" = "STATE_CHANGED" ] && no_deadlock r08 && echo 1)" "$r B=$(err_of r08_B.out)/$(hint_of r08_B.out)"

  # R09 reagendamento (A) × batch (B): a linhagem muda enquanto B espera o lock da série
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 3 08 10000); TOTAL=$(month_open "$S")
  local FROM; FROM=$(q "select occurrence_date from public.reservations where recurring_reservation_id = '$S' order by occurrence_date offset 2 limit 1")
  r=$(race r09 "$U" "select public.rg_recurring_reschedule('$S', gen_random_uuid(), '$FROM', '{\"start_time\":\"09:00\",\"end_time\":\"09:59\"}'::jsonb, false, '{}'::date[]);" \
               "$R" "$(pay_month "$R" "$S" "$TOTAL" "$TOTAL")")
  check "R09 reagendar × batch: B espera o lock da série e recebe RGP01 STATE_CHANGED (linhagem mudou)" \
    "$( [ "$r" = "blocked=1" ] && [ "$(hint_of r09_B.out)" = "STATE_CHANGED" ] && no_deadlock r09 && echo 1)" "$r B=$(err_of r09_B.out)/$(hint_of r09_B.out)"

  # R10 batch (A) × reagendamento (B): B espera; depois cancela futuras pagas (RETAINED), sem deadlock
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 3 11 10000); TOTAL=$(month_open "$S")
  FROM=$(q "select occurrence_date from public.reservations where recurring_reservation_id = '$S' order by occurrence_date offset 2 limit 1")
  r=$(race r10 "$U" "$(pay_month "$U" "$S" "$TOTAL" "$TOTAL")" \
               "$U" "select public.rg_recurring_reschedule('$S', gen_random_uuid(), '$FROM', '{\"start_time\":\"12:00\",\"end_time\":\"12:59\"}'::jsonb, false, '{}'::date[]);")
  st=$(q "select count(*) from private.rg_financials(array(select id from public.reservations where recurring_reservation_id = '$S')) where payment_status = 'RETAINED'")
  check "R10 batch × reagendar: B espera e conclui; ocorrências futuras pagas viram RETAINED (visíveis), sem deadlock" \
    "$( [ "$r" = "blocked=1" ] && noerr r10_B.out && [ "${st:-0}" -ge 1 ] && no_deadlock r10 && echo 1)" "$r B=$(err_of r10_B.out) retidas=$st"

  # R11 W1 vincular cliente (A) × batch (B) na linhagem sem cliente
  S=$(new_series "$U" "$ARENA" "$COURT" null 4 08 10000); TOTAL=$(month_open "$S")
  r=$(race r11 "$U" "select public.rg_recurring_link_customer('$S', '$CUST', null);" "$R" "$(pay_month "$R" "$S" "$TOTAL" "$TOTAL")")
  check "R11 W1 × batch: B espera o vínculo e então recebe o mês (cliente já presente)" \
    "$( [ "$r" = "blocked=1" ] && noerr r11_B.out && [ "$(month_open "$S")" = "0" ] && no_deadlock r11 && echo 1)" "$r B=$(err_of r11_B.out)/$(hint_of r11_B.out)"

  # R12 W2 aplicar valor (A) × batch (B) — mesma linhagem sem valor
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 4 10 null)
  as_user "$U" "select public.rg_recurring_update('$S', '{\"default_price\":7000}'::jsonb);" >/dev/null
  N=$(q "select count(*) from public.reservations where recurring_reservation_id = '$S'")
  r=$(race r12 "$U" "select public.rg_recurring_month_apply_series_price('$S', '$MONTH');" "$R" "$(pay_month "$R" "$S" "$((N * 7000))" null)")
  check "R12 W2 × batch: B espera a aplicação do valor e então recebe o mês inteiro" \
    "$( [ "$r" = "blocked=1" ] && noerr r12_B.out && [ "$(month_open "$S")" = "0" ] && no_deadlock r12 && echo 1)" "$r B=$(err_of r12_B.out)/$(hint_of r12_B.out)"

  # R13 linhagens diferentes NÃO se bloqueiam
  S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 5 08 10000); S2=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 5 10 10000)
  r=$(race r13 "$U" "$(pay_month "$U" "$S" "$(month_open "$S")" null)" "$R" "$(pay_month "$R" "$S2" "$(month_open "$S2")" null)")
  check "R13 linhagens diferentes não se bloqueiam; ambos gravam" \
    "$( [ "$r" = "blocked=0" ] && noerr r13_A.out && noerr r13_B.out && [ "$(month_open "$S")" = "0" ] && [ "$(month_open "$S2")" = "0" ] && echo 1)" "$r"

  # invariantes globais da fixture
  st=$(q "select (select count(*) from private.rg_financials(array(select id from public.reservations where organization_id = '$ORG' and status <> 'CANCELLED')) where net_received > amount_due)
          || '/' || (select count(*) from public.reservation_payment_batches b where b.organization_id = '$ORG'
                      and b.amount <> (select coalesce(sum(i.amount), 0) from public.reservation_payment_batch_items i where i.batch_id = b.id))")
  check "R-INV nenhuma reserva cobrável acima do valor; todo batch = soma dos itens" "$( [ "$st" = "0/0" ] && echo 1)" "$st"

  cleanup_org "$ORG" "$U" "$R"
  check "R-CLEAN fixture da concorrência removida" "$( [ "$(q "select count(*) from public.organizations where id = '$ORG'")" = "0" ] && echo 1)" "org restou"
}

# ---------------------------------------------------------------- ciclo de vida
run_lifecycle() {
  echo "== ciclo de vida (colisão, rollback seguro, restauração exata) =="
  [ "$(applied)" = "t" ] || { bad "pré-requisito" "migration 03B.3 não aplicada"; return; }
  local F_APPLIED F_PURE F_RE out
  F_APPLIED=$(fp)

  # L01 reaplicar sobre a própria migration => 42710 antes de qualquer efeito
  out=$(psql_c -v ON_ERROR_STOP=1 -f - < "$MIG" 2>&1 | tr -d '\r')
  check "L01 reaplicar com a 03B.3 presente => 42710 sem efeito parcial" \
    "$( echo "$out" | grep -q '42710' && [ "$(fp)" = "$F_APPLIED" ] && echo 1)" "$(echo "$out" | grep ERROR | head -n 1)"

  # L02 rollback com recebimento mensal registrado => aborta, nada muda
  read -r U R ORG ARENA COURT CUST <<< "$(mk_org life)"
  local S; S=$(new_series "$U" "$ARENA" "$COURT" "$CUST" 1 08 10000)
  as_user "$R" "$(pay_month "$R" "$S" 10000 null)" >/dev/null
  local F_WITH; F_WITH=$(fp)
  out=$(psql_c -v ON_ERROR_STOP=1 -f - < "$RB" 2>&1 | tr -d '\r')
  check "L02 rollback com batch registrado => aborta e preserva tudo" \
    "$( echo "$out" | grep -q 'rollback abortado' && [ "$(fp)" = "$F_WITH" ] && [ "$(q "select count(*) from public.reservation_payment_batches where organization_id = '$ORG'")" = "1" ] && echo 1)" \
    "$(echo "$out" | grep ERROR | head -n 1)"
  cleanup_org "$ORG" "$U" "$R"

  # L03 rollback no estado limpo: só objetos 03B.3 saem; protect_structural_links volta ao A2 (md5)
  out=$(psql_c -v ON_ERROR_STOP=1 -f - < "$RB" 2>&1 | tr -d '\r')
  F_PURE=$(fp)
  check "L03 rollback conclui; corpo A2 restaurado (md5 82b84c5d…); nenhuma função/tabela 03B.3" \
    "$( ! echo "$out" | grep -q ERROR && [ "$(applied)" = "f" ] \
        && [ "$(q "select md5(prosrc) from pg_proc where oid = 'private.protect_structural_links()'::regprocedure")" = "82b84c5d95d11123949ead4928896743" ] \
        && [ "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.proname like 'rg_rm_%' or p.proname like 'rg_recurring_month%' or p.proname = 'rg_recurring_link_customer'")" = "0" ] && echo 1)" \
    "$(echo "$out" | grep ERROR | head -n 1)"
  if [ -n "${RG_P3B3_BASELINE:-}" ] && [ -f "$RG_P3B3_BASELINE" ]; then
    check "L03b schema pós-rollback idêntico ao baseline pré-03B.3 (fingerprint exato)" \
      "$( [ "$F_PURE" = "$(cat "$RG_P3B3_BASELINE")" ] && echo 1)" "$(diff <(echo "$F_PURE") "$RG_P3B3_BASELINE" | head -n 5 | tr '\n' ' ')"
  fi

  # L04 colisão: cada sentinela isolada => 42710, schema volta ao estado puro
  local sent ok_all=1 name
  for sent in "create table public.reservation_payment_batches (x int)" \
              "create index idx_rp_batches_lineage_month on public.reservations (id)" \
              "create function private.rg_rm_root(uuid) returns uuid language sql as 'select null::uuid'" \
              "create function public.rg_recurring_month_detail(int) returns int language sql as 'select 1'"; do
    q "$sent" >/dev/null
    out=$(psql_c -v ON_ERROR_STOP=1 -f - < "$MIG" 2>&1 | tr -d '\r')
    echo "$out" | grep -q '42710' || ok_all=0
    q "drop table if exists public.reservation_payment_batches; drop index if exists public.idx_rp_batches_lineage_month;
       drop function if exists private.rg_rm_root(uuid); drop function if exists public.rg_recurring_month_detail(int);" >/dev/null
  done
  check "L04 colisão (tabela, índice, função privada, sobrecarga pública) => 42710 sem efeito parcial" \
    "$( [ "$ok_all" = "1" ] && [ "$(fp)" = "$F_PURE" ] && echo 1)" "sentinelas"

  # L05 reaplicar após rollback: schema idêntico ao aplicado antes
  out=$(psql_c -v ON_ERROR_STOP=1 -f - < "$MIG" 2>&1 | tr -d '\r')
  F_RE=$(fp)
  check "L05 reaplicar após rollback: schema idêntico ao aplicado antes (fingerprint exato)" \
    "$( ! echo "$out" | grep -q ERROR && [ "$F_RE" = "$F_APPLIED" ] && echo 1)" "$(diff <(echo "$F_RE") <(echo "$F_APPLIED") | head -n 5 | tr '\n' ' ')"

  # L06 diferença pura x aplicada: entre objetos pré-existentes, SÓ protect_structural_links muda
  local changed
  changed=$(LC_ALL=C join -t'|' -j1 <(echo "$F_PURE" | sed 's/|/\t/' | awk -F'\t' '{print $1"|"$2}' | LC_ALL=C sort -t'|' -k1,1) \
                                    <(echo "$F_APPLIED" | sed 's/|/\t/' | awk -F'\t' '{print $1"|"$2}' | LC_ALL=C sort -t'|' -k1,1) \
            | awk -F'|' '$2 != $3 {print $1}' | tr '\n' ' ')
  check "L06 objetos 03A/03B.1/03B.2/B3 inalterados; único alterado = protect_structural_links (W1)" \
    "$( [ "$changed" = "fn:private.private.protect_structural_links() " ] && echo 1)" "alterados=[$changed]"
}

case "${1:-all}" in
  concurrency) run_concurrency ;;
  lifecycle) run_lifecycle ;;
  all) run_lifecycle; run_concurrency ;;
  *) echo "uso: $0 [concurrency|lifecycle|all]"; exit 2 ;;
esac

echo
echo "P3B3_HARNESS $PASS PASS / $FAIL FAIL (total $((PASS + FAIL)))"
[ "$FAIL" -eq 0 ]
