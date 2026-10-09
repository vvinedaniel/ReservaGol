#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — CLIENTES C2D — ciclo migration -> rollback -> reaplicar (banco Docker LOCAL, nunca Production)
#   bash tests/customers_c2d_lifecycle.sh        (RG_TEST_CONTAINER, padrão rg-p3a-testdb)
# Prova: rollback só age sobre o corpo C2D e restaura o md5 C2A; segundo rollback recusa sem alterar;
# migration reaplica (md5 C2D) e uma segunda aplicação recusa; comportamento de "C2C Cliente 008" acompanha o corpo.
# Termina SEMPRE com o C2D aplicado (estado esperado do ambiente de teste).
# =============================================================================
set -u
CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C2A_MD5=fb743a428ead37ca1fbccf8011eb8032
C2D_MD5=335bcf83465140e02b3fd6a69e1a6028
PASS=0; FAIL=0
psql_c() { docker exec -i "$CONTAINER" psql -U postgres -d postgres -X -q -At "$@"; }
md5_now() { echo "select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.rg_customer_list(uuid, text, text, integer, text, uuid)'::regprocedure;" | psql_c | tr -d '\r'; }
# nomes devolvidos para "C2C Cliente 008" por um membro, dentro de uma transação desfeita (zero resíduo)
probe() {
  psql_c -v ON_ERROR_STOP=1 <<'SQL' | tr -d '\r' | tail -n 1
begin;
create temp table t (u uuid, o uuid) on commit drop;
with u as (insert into auth.users (id, email) values (gen_random_uuid(), 'c2d-lc-' || gen_random_uuid() || '@reservagol.test') returning id),
     o as (insert into public.organizations (name, is_demo) values ('C2D lifecycle', true) returning id)
insert into t select u.id, o.id from u, o;
insert into public.organization_members (organization_id, user_id, role, status) select o, u, 'RECEPTIONIST', 'ACTIVE' from t;
insert into public.customers (organization_id, name, phone) select o, 'C2C Cliente 008', '41988000008' from t;
select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true), set_config('c2d.org', o::text, true) from t;
set local role authenticated;
select coalesce((select string_agg(e->>'name', '|') from jsonb_array_elements(public.rg_customer_list(current_setting('c2d.org')::uuid, 'C2C Cliente 008', 'ALL', 10)->'items') e), '<vazio>');
rollback;
SQL
}
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1 (esperado '$3', obtido '$2')"; fi; }
run_file() { psql_c -v ON_ERROR_STOP=1 < "$1" > /dev/null 2>&1; echo $?; }

check "L01 estado inicial: corpo C2D" "$(md5_now)" "$C2D_MD5"
check "L02 com C2D, \"C2C Cliente 008\" é busca por nome" "$(probe)" "C2C Cliente 008"
check "L03 rollback executa sem erro" "$(run_file "$ROOT/supabase/rollback_customers_c2d_search.sql")" "0"
check "L04 após rollback: corpo C2A restaurado (md5)" "$(md5_now)" "$C2A_MD5"
check "L05 com C2A, \"C2C Cliente 008\" volta ao modo telefone (defeito original reproduzido)" "$(probe)" "<vazio>"
check "L06 segundo rollback RECUSA (corpo não é C2D)" "$(run_file "$ROOT/supabase/rollback_customers_c2d_search.sql")" "3"
check "L07 segundo rollback não alterou nada" "$(md5_now)" "$C2A_MD5"
check "L08 migration reaplica sem erro" "$(run_file "$ROOT/supabase/migration_customers_c2d_search.sql")" "0"
check "L09 após reaplicar: corpo C2D (md5)" "$(md5_now)" "$C2D_MD5"
check "L10 segunda aplicação RECUSA (corpo já é C2D)" "$(run_file "$ROOT/supabase/migration_customers_c2d_search.sql")" "3"
check "L11 segunda aplicação não alterou nada; busca por nome ativa" "$(md5_now)|$(probe)" "$C2D_MD5|C2C Cliente 008"
GRANTS=$(echo "select string_agg(grantee, ',' order by grantee) from information_schema.routine_privileges where routine_schema='public' and routine_name='rg_customer_list';" | psql_c | tr -d '\r')
check "L12 grants após o ciclo: authenticated + postgres (owner)" "$GRANTS" "authenticated,postgres"

echo
echo "C2D_LIFECYCLE ${PASS} PASS / ${FAIL} FAIL (total $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
