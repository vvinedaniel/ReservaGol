#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — CLIENTES M2-B — ciclo migration -> rollback -> reaplicar (banco Docker LOCAL, nunca Production)
#   bash tests/customers_m2b_lifecycle.sh        (RG_TEST_CONTAINER, padrão rg-p3a-testdb)
# Pré-condição: M2-B aplicada. Termina SEMPRE com a M2-B aplicada (estado esperado do ambiente de teste).
# Prova por ACL exata E por comportamento (membro ativo tentando INSERT direto; RPC criando), em transação desfeita.
# =============================================================================
set -u
CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACL_BEFORE='{postgres=arwdDxtm/postgres,authenticated=arwm/postgres,service_role=arwdDxtm/postgres}'
ACL_M2B='{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}'
PASS=0; FAIL=0
psql_c() { docker exec -i "$CONTAINER" psql -U postgres -d postgres -X -q -At "$@"; }
acl() { echo "select relacl::text from pg_class where oid = 'public.customers'::regclass;" | psql_c | tr -d '\r'; }
data_fp() { echo "select count(*) || '/' || md5(string_agg(c::text, ',' order by c.id)) from public.customers c;" | psql_c | tr -d '\r'; }
# "<insert direto>|<rpc>" de um membro ativo (OWNER) numa org descartável, tudo desfeito
probe() {
  psql_c -v ON_ERROR_STOP=1 <<'SQL' | tr -d '\r' | tail -n 1
begin;
create temp table t (u uuid, o uuid) on commit drop;
with u as (insert into auth.users (id, email) values (gen_random_uuid(), 'm2b-lc-' || gen_random_uuid() || '@reservagol.test') returning id),
     o as (insert into public.organizations (name, is_demo) values ('M2B lifecycle', true) returning id)
insert into t select u.id, o.id from u, o;
insert into public.organization_members (organization_id, user_id, role, status) select o, u, 'OWNER', 'ACTIVE' from t;
select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true), set_config('m2b.org', o::text, true) from t;
create function pg_temp.try(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'OK'; exception when others then return sqlstate; end $f$;
set local role authenticated;
select pg_temp.try(format('insert into public.customers (organization_id, name) values (%L, ''direto'')', current_setting('m2b.org')))
       || '|' || pg_temp.try(format('select public.rg_customer_resolve(%L::uuid, ''via rpc'', null, null, null, ''CUSTOMERS'')', current_setting('m2b.org')));
rollback;
SQL
}
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1 (esperado '$3', obtido '$2')"; fi; }
run_file() { psql_c -v ON_ERROR_STOP=1 < "$1" > /dev/null 2>&1; echo $?; }
MIG="$ROOT/supabase/migration_customers_m2b_write_lockdown.sql"
RB="$ROOT/supabase/rollback_customers_m2b_write_lockdown.sql"
DATA0="$(data_fp)"

check "L01 migration aplicada: ACL exata pós-M2-B" "$(acl)" "$ACL_M2B"
check "L02 estado M2-B confirmado por comportamento: INSERT direto negado (42501), RPC funciona" "$(probe)" "42501|OK"
check "L03 segunda aplicação da migration RECUSA" "$(run_file "$MIG")" "3"
check "L04 segunda aplicação não alterou a ACL" "$(acl)" "$ACL_M2B"
check "L05 rollback executa sem erro" "$(run_file "$RB")" "0"
check "L06 permissões originais restauradas (ACL exata)" "$(acl)" "$ACL_BEFORE"
check "L07 comportamento original: INSERT direto de membro volta a ser aceito, RPC funciona" "$(probe)" "OK|OK"
check "L08 segundo rollback RECUSA" "$(run_file "$RB")" "3"
check "L09 segundo rollback não alterou a ACL" "$(acl)" "$ACL_BEFORE"
check "L10 migration reaplicada sem erro" "$(run_file "$MIG")" "0"
check "L11 estado final M2-B confirmado (ACL exata)" "$(acl)" "$ACL_M2B"
check "L12 estado final M2-B por comportamento" "$(probe)" "42501|OK"
check "L13 nenhum dado de customers alterado em todo o ciclo" "$(data_fp)" "$DATA0"

echo
echo "M2B_LIFECYCLE ${PASS} PASS / ${FAIL} FAIL (total $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
