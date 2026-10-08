#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — CLIENTES C2A — harness multi-sessão de identidade/concorrência (banco Docker LOCAL)
# Fala SÓ com o container Docker local. Nunca toca Supabase remoto/Production.
# Uso:  bash tests/customers_c2a_concurrency.sh      (pré-requisito: migration C2A aplicada; banco de teste)
#
# Barreira: uma sessão de controle segura pg_advisory_lock(K); os workers ficam em pg_advisory_lock_shared(K)
# e são liberados juntos => as chamadas disparam praticamente ao mesmo tempo.
# C01 N sessões rg_customer_resolve no MESMO org+telefone (formatos diferentes, papéis diferentes) => 1 cliente, mesmo id, sem 23505
# C02 N sessões rg_recurring_create com o MESMO telefone novo => todas criam a série, 1 cliente, sem 23505
# C03 N sessões W1 (linhagens distintas sem cliente) com o MESMO telefone novo => todas vinculam, 1 cliente
# C04 misto: resolve + create + W1 simultâneos no MESMO telefone novo => 1 cliente, todos o mesmo id
# C05 troca explícita concorrente na MESMA reserva (mesmo expected, alvos diferentes) => exatamente 1 troca + 1 RGC02, 1 auditoria
# C06 nenhum 23505 / 40P01 em nenhuma saída
# =============================================================================
set -u

CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
K=730312211
ok()    { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()   { FAIL=$((FAIL + 1)); echo "FAIL  $1 :: $2"; }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
psql_c() { timeout 120 docker exec -i -e PGAPPNAME="${APP:-c2a_ctl}" "$CONTAINER" psql -U postgres -X -q -At -v VERBOSITY=verbose "$@"; }
q()  { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r' | tail -n 1; }
qa() { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r'; }
claims() { printf '{"sub":"%s","role":"authenticated"}' "$1"; }
# worker: espera a barreira e executa SQL como o usuário; saída em arquivo
worker() { # name uid sql
  printf '%s\n' "set role authenticated;" "select set_config('request.jwt.claims', '$(claims "$2")', false);" \
    "select pg_advisory_lock_shared($K);" "select pg_advisory_unlock_shared($K);" "$3" \
    | APP="c2a_w_$1" psql_c > "$TMP/$1.out" 2>&1
}
barrier_up()   { printf '%s\n' "select pg_advisory_lock($K);" "select pg_sleep(${1:-4});" "select pg_advisory_unlock($K);" | APP=c2a_barrier psql_c >/dev/null 2>&1 & BARRIER=$!; sleep 0.8; }
barrier_wait() { wait "$BARRIER" 2>/dev/null; wait; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then echo "container $CONTAINER inexistente"; exit 2; fi
if [ "$(q "select (select count(*) from public.organizations) < 50")" != "t" ]; then echo "banco não parece ser de teste — abortado"; exit 2; fi
if [ "$(q "select to_regprocedure('public.rg_customer_resolve(uuid, text, text, text, uuid, text)') is not null")" != "t" ]; then echo "migration C2A não aplicada — abortado"; exit 2; fi

# fixture: org (OWNER, MANAGER, RECEPTIONIST), arena 06–23, 12 quadras
FX=$(qa "do \$\$ declare u uuid := gen_random_uuid(); m uuid := gen_random_uuid(); r uuid := gen_random_uuid(); o uuid; a uuid; i int; begin
  insert into auth.users (id, email) values (u, 'c2a-h-o-' || substr(md5(random()::text), 1, 6) || '@reservagol.test'),
    (m, 'c2a-h-m-' || substr(md5(random()::text), 1, 6) || '@reservagol.test'), (r, 'c2a-h-r-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
  insert into public.organizations (name, is_demo) values ('C2A-H', true) returning id into o;
  insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE'), (o, m, 'MANAGER', 'ACTIVE'), (o, r, 'RECEPTIONIST', 'ACTIVE');
  insert into public.arenas (organization_id, name) values (o, 'Arena C2A-H') returning id into a;
  insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed) select o, a, w, '06:00', '23:00', false from generate_series(0, 6) w;
  for i in 1..12 loop insert into public.courts (organization_id, arena_id, name) values (o, a, 'Q' || i); end loop;
  raise notice 'FX % % % % %', u, m, r, o, a;
end \$\$;" | sed -n 's/.*FX \(.*\)/\1/p' | tail -n 1)
read -r U M R ORG AR <<< "$FX"
COURTS=($(qa "select id from public.courts where organization_id = '$ORG' order by name"))
DOW=$(q "select extract(dow from private.rg_today() + 10)::int")
START=$(q "select private.rg_today() - 7")
cleanup() {
  qa "delete from public.audit_logs where organization_id = '$ORG';
      delete from public.reservations where organization_id = '$ORG';
      delete from public.recurring_reservations where organization_id = '$ORG' and previous_series_id is not null;
      delete from public.recurring_reservations where organization_id = '$ORG';
      delete from public.customers where organization_id = '$ORG';
      delete from public.courts where organization_id = '$ORG';
      delete from public.business_hours where organization_id = '$ORG';
      delete from public.arenas where organization_id = '$ORG';
      delete from public.organizations where id = '$ORG';
      delete from auth.users where id in ('$U', '$M', '$R');" >/dev/null
}
ids_of() { for f in "$@"; do grep -E '^[0-9a-f-]{36}$' "$TMP/$f.out" | tail -n 1; done; }

echo "== C2A harness (local) =="
# ---------------------------------------------------------------- C01
FORMATS=("41977771001" "+55 41 97777-1001" "5541977771001" "(41) 97777-1001" "041977771001" "41 9 7777 1001" "+5541977771001" "41-97777-1001")
USERS=("$U" "$M" "$R" "$U" "$M" "$R" "$U" "$M")
barrier_up 4
for i in "${!FORMATS[@]}"; do
  worker "c01_$i" "${USERS[$i]}" "select public.rg_customer_resolve('$ORG', 'Corrida $i', '${FORMATS[$i]}', null, null, 'CUSTOMERS')->>'customer_id';" &
done
barrier_wait
C01_IDS=$(ids_of c01_0 c01_1 c01_2 c01_3 c01_4 c01_5 c01_6 c01_7 | sort -u)
check "C01 8 sessões resolve (formatos/papéis diferentes) no mesmo telefone => 1 cliente, todas o mesmo id" \
  "$( [ "$(echo "$C01_IDS" | grep -c .)" = "1" ] && [ "$(ids_of c01_0 c01_1 c01_2 c01_3 c01_4 c01_5 c01_6 c01_7 | grep -c .)" = "8" ] \
      && [ "$(q "select count(*) from public.customers where organization_id = '$ORG' and phone = '41977771001'")" = "1" ] \
      && [ "$(q "select count(*) from public.audit_logs where organization_id = '$ORG' and action = 'CUSTOMER_CREATED' and entity_id = '$(echo "$C01_IDS" | head -n 1)'")" = "1" ] && echo 1 || echo 0)" \
  "ids=$(echo $C01_IDS) $(cat "$TMP"/c01_*.out | grep -iE 'error' | head -n 2)"

# ---------------------------------------------------------------- C02
barrier_up 4
for i in 0 1 2 3 4 5; do
  H=$((7 + i))
  worker "c02_$i" "$U" "select public.rg_recurring_create(gen_random_uuid(), '$AR', '${COURTS[$i]}', null, '{\"name\":\"Serie $i\",\"phone\":\"+55 41 97777-2002\"}'::jsonb, 'WEEKLY', $DOW, null, '$(printf '%02d' $H):00', '$(printf '%02d' $H):59', '$START', null, true, 10000, null, false, false, '{}'::date[])->>'series_id';" &
done
barrier_wait
C02_N=$(ids_of c02_0 c02_1 c02_2 c02_3 c02_4 c02_5 | grep -c .)
check "C02 6 sessões rg_recurring_create com o mesmo telefone novo => 6 séries, 1 cliente compartilhado" \
  "$( [ "$C02_N" = "6" ] && [ "$(q "select count(*) from public.customers where organization_id = '$ORG' and phone = '41977772002'")" = "1" ] \
      && [ "$(q "select count(distinct customer_id) from public.recurring_reservations where organization_id = '$ORG' and customer_id = (select id from public.customers where organization_id = '$ORG' and phone = '41977772002')")" = "1" ] \
      && [ "$(q "select count(*) from public.recurring_reservations where organization_id = '$ORG' and customer_id = (select id from public.customers where organization_id = '$ORG' and phone = '41977772002')")" = "6" ] && echo 1 || echo 0)" \
  "series=$C02_N $(cat "$TMP"/c02_*.out | grep -iE 'error' | head -n 2)"

# ---------------------------------------------------------------- C03 (linhagens sem cliente)
L=()
for i in 6 7 8 9; do
  H=$((7 + i))
  L+=("$(q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$U")', false);
            select public.rg_recurring_create(gen_random_uuid(), '$AR', '${COURTS[$i]}', null, null, 'WEEKLY', $DOW, null, '$(printf '%02d' $H):00', '$(printf '%02d' $H):59', '$START', null, true, 10000, null, false, false, '{}'::date[])->>'series_id';")")
done
barrier_up 4
for j in 0 1 2 3; do
  worker "c03_$j" "$M" "select public.rg_recurring_link_customer('${L[$j]}', null, '{\"name\":\"W1 $j\",\"phone\":\"(41) 97777-3003\"}'::jsonb)->>'customer_id';" &
done
barrier_wait
check "C03 4 sessões W1 (linhagens distintas) com o mesmo telefone novo => todas vinculam ao MESMO cliente" \
  "$( [ "$(ids_of c03_0 c03_1 c03_2 c03_3 | sort -u | grep -c .)" = "1" ] && [ "$(ids_of c03_0 c03_1 c03_2 c03_3 | grep -c .)" = "4" ] \
      && [ "$(q "select count(*) from public.customers where organization_id = '$ORG' and phone = '41977773003'")" = "1" ] && echo 1 || echo 0)" \
  "$(cat "$TMP"/c03_*.out | grep -iE 'error' | head -n 2)"

# ---------------------------------------------------------------- C04 misto
L2=$(q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$U")', false);
        select public.rg_recurring_create(gen_random_uuid(), '$AR', '${COURTS[10]}', null, null, 'WEEKLY', $DOW, null, '18:00', '18:59', '$START', null, true, 10000, null, false, false, '{}'::date[])->>'series_id';")
barrier_up 4
worker c04_a "$R" "select public.rg_customer_resolve('$ORG', 'Misto A', '41977774004')->>'customer_id';" &
worker c04_b "$U" "select public.rg_customer_resolve('$ORG', 'Misto B', '+55 41 97777-4004', null, null, 'RESERVATION')->>'customer_id';" &
worker c04_c "$U" "select public.rg_recurring_create(gen_random_uuid(), '$AR', '${COURTS[11]}', null, '{\"name\":\"Misto C\",\"phone\":\"5541977774004\"}'::jsonb, 'WEEKLY', $DOW, null, '19:00', '19:59', '$START', null, true, 10000, null, false, false, '{}'::date[])->>'series_id';" &
worker c04_d "$M" "select public.rg_recurring_link_customer('$L2', null, '{\"name\":\"Misto D\",\"phone\":\"041977774004\"}'::jsonb)->>'customer_id';" &
barrier_wait
CU4=$(q "select id from public.customers where organization_id = '$ORG' and phone = '41977774004'")
check "C04 misto (resolve + resolve RESERVATION + create + W1) no mesmo telefone => 1 cliente, todos apontam para ele" \
  "$( [ "$(q "select count(*) from public.customers where organization_id = '$ORG' and phone = '41977774004'")" = "1" ] \
      && [ "$(ids_of c04_a)" = "$CU4" ] && [ "$(ids_of c04_b)" = "$CU4" ] && [ "$(ids_of c04_d)" = "$CU4" ] \
      && [ "$(q "select customer_id from public.recurring_reservations where id = '$(ids_of c04_c)'")" = "$CU4" ] && echo 1 || echo 0)" \
  "$(cat "$TMP"/c04_*.out | grep -iE 'error' | head -n 2)"

# ---------------------------------------------------------------- C05 troca explícita concorrente
CA=$(q "select id from public.customers where organization_id = '$ORG' and phone = '41977771001'")
CB=$(q "select id from public.customers where organization_id = '$ORG' and phone = '41977773003'")
RES=$(q "insert into public.reservations (organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source)
         values ('$ORG', '$AR', '${COURTS[0]}', '$CU4', date_trunc('hour', now()) + interval '30 days', date_trunc('hour', now()) + interval '30 days 1 hour', 'CONFIRMED', 'INTERNAL') returning id")
barrier_up 4
worker c05_a "$R" "select public.rg_reservation_change_customer('$RES', '$CA', '$CU4')->>'changed';" &
worker c05_b "$U" "select public.rg_reservation_change_customer('$RES', '$CB', '$CU4')->>'changed';" &
barrier_wait
NCH=$(cat "$TMP/c05_a.out" "$TMP/c05_b.out" | grep -c '^true$')
NST=$(cat "$TMP/c05_a.out" "$TMP/c05_b.out" | grep -c 'RGC02')
FINAL=$(q "select customer_id from public.reservations where id = '$RES'")
check "C05 troca concorrente (mesmo expected): exatamente 1 troca + 1 RGC02 STALE_UPDATE, 1 auditoria, estado final = vencedora" \
  "$( [ "$NCH" = "1" ] && [ "$NST" = "1" ] && { [ "$FINAL" = "$CA" ] || [ "$FINAL" = "$CB" ]; } \
      && [ "$(q "select count(*) from public.audit_logs where entity_id = '$RES' and action = 'RESERVATION_CUSTOMER_CHANGED'")" = "1" ] && echo 1 || echo 0)" \
  "changed=$NCH stale=$NST final=$FINAL"

# ---------------------------------------------------------------- C06
check "C06 nenhum 23505 (unique_violation) / 40P01 (deadlock) vazou em nenhuma sessão" \
  "$( ! grep -lE '23505|40P01|duplicate key|deadlock' "$TMP"/*.out >/dev/null 2>&1 && echo 1 || echo 0)" \
  "$(grep -hE '23505|40P01' "$TMP"/*.out | head -n 2)"

cleanup
check "R-CLEAN fixture do harness removida" "$( [ "$(q "select count(*) from public.organizations where id = '$ORG'")" = "0" ] && echo 1 || echo 0)"
echo
echo "C2A_HARNESS $PASS PASS / $FAIL FAIL (total $((PASS + FAIL)))"
[ "$FAIL" = "0" ]
