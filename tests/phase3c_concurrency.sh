#!/usr/bin/env bash
# =============================================================================
# RESERVA GOL — FASE 03C — harness multi-sessão do JOB e da concorrência (banco Docker LOCAL)
#
# Fala SÓ com um container Docker local (docker exec). Nunca toca Supabase remoto/Production.
# NÃO agenda nada no pg_cron: o job é chamado exatamente como o cron chamaria — UM único statement
# "CALL private.rg_recurring_topup_job('CRON')" numa sessão em autocommit (desenho A provado no G0).
#
# Uso:  bash tests/phase3c_concurrency.sh
# Pré-requisito: migration_phase3c_recurring_deterministic.sql APLICADA; banco de teste (< 50 organizações).
#
# J01 job CRON: COMMIT por série, horizonte 120, lacunas, auditoria SYSTEM/CRON/run_id
# J02 idempotência (NOOP sem auditoria)           J03 falha numa série => PARTIAL, demais commitadas
# J04 série travada => DEFERRED nas 2 passadas, PARTIAL; convergência na execução seguinte
# J05 job derrubado no meio => commitado persiste; próxima execução marca ABORTED e converge
# J06 dois jobs simultâneos => SKIPPED_CONCURRENT; lote do operador durante o job => SKIPPED_CONCURRENT
# J07 job × pausa concorrente (lock real da RPC B3) => adiada; depois SKIPPED_NOT_ACTIVE sem lacuna
# J08 avulsa × geração em curso na mesma série => avulsa ESPERA (FOR SHARE) e então RECURRING_SLOT
# J09 corrida residual: avulsa × série ainda não confirmada => CONFLICT explícito na execução seguinte
# J10 retenção 90 dias: histórico técnico apagado; lacuna aberta NUNCA apagada; audit intocado
# J11 procedure dentro de transação explícita falha; lote funciona (caminho manual)
# J12 nenhum deadlock (40P01) em nenhuma saída
# =============================================================================
set -u

CONTAINER="${RG_TEST_CONTAINER:-rg-p3a-testdb}"
DB_USER="${RG_TEST_DB_USER:-postgres}"
DB_NAME="${RG_TEST_DB_NAME:-postgres}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()    { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()   { FAIL=$((FAIL + 1)); echo "FAIL  $1 :: $2"; }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

psql_c() { timeout "${PSQL_TIMEOUT:-120}" docker exec -i -e PGAPPNAME="${APP:-rg3c_ctl}" "$CONTAINER" \
             psql -U "$DB_USER" -d "$DB_NAME" -X -q -At -v VERBOSITY=verbose "$@"; }
q()  { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r' | tail -n 1; }
qa() { printf '%s\n' "$1" | psql_c -v ON_ERROR_STOP=1 2>&1 | tr -d '\r'; }
# job em sessão própria, autocommit, um único statement (como o pg_cron)
job()  { printf '%s\n' "call private.rg_recurring_topup_job('${1:-CRON}');" | APP="${APP:-rg3c_job}" psql_c 2>&1 | tr -d '\r'; }
last_run() { q "select id || '|' || status || '|' || origin || '|' || actor || '|' || counts::text from public.recurring_generation_runs order by started_at desc limit 1"; }
wait_for() {
  local cond="$1" t="${2:-20}" i=0
  while [ "$i" -lt $((t * 5)) ]; do
    [ "$(q "select ($cond)::int")" = "1" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then echo "container $CONTAINER inexistente"; exit 2; fi
if [ "$(q "select (select count(*) from public.organizations) < 50")" != "t" ]; then
  echo "banco não parece ser de teste (>= 50 organizações) — abortado"; exit 2
fi
if [ "$(q "select to_regprocedure('private.rg_recurring_topup_job(text)') is not null")" != "t" ]; then
  echo "migration 03C não aplicada — abortado"; exit 2
fi
if [ "$(q "select count(*) from cron.job")" != "0" ]; then echo "há jobs no pg_cron local — abortado (nada deve estar agendado)"; exit 2; fi
# O job processa TODAS as séries candidatas do banco: exige banco sem séries ACTIVE alheias ao harness.
if [ "$(q "select count(*) from public.recurring_reservations where status = 'ACTIVE'")" != "0" ]; then
  echo "há séries ACTIVE no banco local — abortado (o job global as processaria)"; exit 2
fi
T0=$(q "select now()")
LOCKKEY=$(q "select private.rg_topup_lock_key()")

# Fixture: org demo (OWNER + RECEPTIONIST), arena A COM horário 06–23 todos os dias, arena B SEM horário,
# quadra QA (A), QB (B), cliente. Ecoa "owner rec org arenaA arenaB courtA courtB cust".
mk_org() {
  qa "do \$\$ declare u uuid := gen_random_uuid(); r uuid := gen_random_uuid(); o uuid; a uuid; b uuid; c uuid; d uuid; cu uuid; begin
        insert into auth.users (id, email) values (u, 'p3c-$1-o-' || substr(md5(random()::text), 1, 6) || '@reservagol.test'),
                                                  (r, 'p3c-$1-r-' || substr(md5(random()::text), 1, 6) || '@reservagol.test');
        insert into public.organizations (name, is_demo) values ('P3C-H $1', true) returning id into o;
        insert into public.organization_members (organization_id, user_id, role, status) values (o, u, 'OWNER', 'ACTIVE'), (o, r, 'RECEPTIONIST', 'ACTIVE');
        insert into public.arenas (organization_id, name) values (o, 'Arena A $1') returning id into a;
        insert into public.arenas (organization_id, name) values (o, 'Arena B $1') returning id into b;
        insert into public.business_hours (organization_id, arena_id, weekday, open_time, close_time, closed)
        select o, a, w, '06:00', '23:00', false from generate_series(0, 6) w;
        insert into public.courts (organization_id, arena_id, name) values (o, a, 'QA $1') returning id into c;
        insert into public.courts (organization_id, arena_id, name) values (o, b, 'QB $1') returning id into d;
        insert into public.customers (organization_id, arena_id, name, phone) values (o, a, 'Cliente $1', null) returning id into cu;
        raise notice 'FX % % % % % % % %', u, r, o, a, b, c, d, cu;
      end \$\$;" | sed -n 's/.*FX \(.*\)/\1/p' | tail -n 1
}
claims() { printf '{"sub":"%s","role":"authenticated"}' "$1"; }
as_user() { q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$1")', false); $2"; }
# série semanal (dia da semana de hoje+10), sem materializar; ecoa id
new_series() { # owner arena court cust HH
  as_user "$1" "select public.rg_recurring_create(gen_random_uuid(), '$2', '$3', '$4', null, 'WEEKLY',
      extract(dow from private.rg_today() + 10)::int, null, '$5:00'::time, '$5:59'::time, private.rg_today() - 7, null, true, 10000,
      null, false, false, '{}'::date[])->>'series_id';" 2>/dev/null || true
}
# rg_today/rg_occurrence_bounds são internos: o harness usa postgres para calcular e a sessão do usuário só para escrever
new_series_pg() { # owner arena court cust HH  (cria como o OWNER via claims, calculando o dia como postgres)
  local dow; dow=$(q "select extract(dow from private.rg_today() + 10)::int")
  q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$1")', false);
     select public.rg_recurring_create(gen_random_uuid(), '$2', '$3', '$4', null, 'WEEKLY', $dow, null, '$5:00'::time, '$5:59'::time,
       (now() at time zone 'America/Sao_Paulo')::date - 7, null, true, 10000, null, false, false, '{}'::date[])->>'series_id';"
}
nres()  { q "select count(*) from public.reservations where recurring_reservation_id = '$1'"; }
anchors120() { q "select count(*) from generate_series(private.rg_today(), private.rg_today() + 120, interval '1 day') g, public.recurring_reservations s where s.id = '$1' and private.rg_is_anchor(s, g::date)"; }
cleanup_org() { # org owner rec
  qa "delete from public.recurring_generation_run_series where organization_id = '$1';
      delete from public.recurring_occurrence_gaps where organization_id = '$1';
      delete from public.audit_logs where organization_id = '$1';
      delete from public.reservations where organization_id = '$1';
      delete from public.recurring_reservations where organization_id = '$1' and previous_series_id is not null;
      delete from public.recurring_reservations where organization_id = '$1';
      delete from public.customers where organization_id = '$1';
      delete from public.courts where organization_id = '$1';
      delete from public.business_hours where organization_id = '$1';
      delete from public.arenas where organization_id = '$1';
      delete from public.organizations where id = '$1';
      delete from auth.users where id in ('$2', '$3');" >/dev/null
}

echo "== 03C harness (local) =="
read -r U R ORG AA AB CA CB CUST <<< "$(mk_org h1)"
S1=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 19)   # cabe no horário
S2=$(new_series_pg "$U" "$AB" "$CB" "$CUST" 19)   # arena sem horário
S3=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 08)   # falha injetada
S4=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 10)
N120=$(anchors120 "$S1")

# ---------------------------------------------------------------- J01 / J03: job CRON, COMMIT por série, falha isolada
out=$(printf '%s\n' "set rg.fault_at = 'topup:$S3';" "call private.rg_recurring_topup_job('CRON');" | APP=rg3c_j01 psql_c 2>&1 | tr -d '\r')
RUN1=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J01 job CRON: execução registrada (CRON/SYSTEM), S1 até hoje+120 ($N120), S2 só lacunas OUTSIDE" \
  "$( [ "$(q "select origin || actor from public.recurring_generation_runs where id = '$RUN1'")" = "CRONSYSTEM" ] \
      && [ "$(nres "$S1")" = "$N120" ] && [ "$(nres "$S2")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_occurrence_gaps where series_id = '$S2' and resolved_at is null and reason = 'OUTSIDE_BUSINESS_HOURS'")" = "$N120" ] && echo 1)" "$out $(last_run)"
# (durabilidade por série é provada por falha: J03 — erro numa série não desfaz as anteriores — e J05 — job derrubado
#  no meio mantém o que já foi commitado. xmin por linha não mede a transação: cada INSERT roda num savepoint.)
check "J01c auditoria CRON: user_id NULL, actor SYSTEM, origin CRON, run_id válido (S1, S2, S4)" \
  "$( [ "$(q "select count(*) from public.audit_logs a where a.action = 'RECURRING_OCCURRENCES_GENERATED' and a.user_id is null and a.metadata->>'actor' = 'SYSTEM' and a.metadata->>'origin' = 'CRON' and (a.metadata->>'run_id')::uuid = '$RUN1' and exists (select 1 from public.recurring_generation_runs x where x.id = (a.metadata->>'run_id')::uuid)")" = "3" ] && echo 1)"
check "J01d ocorrências do cron: created_by NULL (nenhum usuário fictício)" \
  "$( [ "$(q "select count(*) from public.reservations where recurring_reservation_id = '$S1' and created_by is not null")" = "0" ] && echo 1)"
check "J03 falha numa série: ERROR (RGF01) só em S3; execução PARTIAL; S1/S4 já commitadas" \
  "$( [ "$(q "select status from public.recurring_generation_runs where id = '$RUN1'")" = "PARTIAL" ] && [ "$(nres "$S3")" = "0" ] \
      && [ "$(q "select outcome || sqlstate from public.recurring_generation_run_series where run_id = '$RUN1' and series_id = '$S3'")" = "ERRORRGF01" ] \
      && [ "$(nres "$S4")" = "$N120" ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J02 idempotência + retry de S3
out=$(job CRON)
RUN2=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J02 nova execução: S3 converge (retry); SUCCEEDED; nenhuma auditoria para séries sem mudança" \
  "$( [ "$(q "select status from public.recurring_generation_runs where id = '$RUN2'")" = "SUCCEEDED" ] && [ "$(nres "$S3")" = "$N120" ] \
      && [ "$(q "select count(*) from public.audit_logs where (metadata->>'run_id')::uuid = '$RUN2'")" = "1" ] && echo 1)" "$out $(last_run)"
out=$(job CRON)
RUN3=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J02b execução sem mudança: SUCCEEDED, 0 criadas, 0 auditorias, 0 linhas por série" \
  "$( [ "$(q "select status || ':' || (counts->>'created') from public.recurring_generation_runs where id = '$RUN3'")" = "SUCCEEDED:0" ] \
      && [ "$(q "select count(*) from public.audit_logs where (metadata->>'run_id')::uuid = '$RUN3'")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_generation_run_series where run_id = '$RUN3'")" = "0" ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J04 série travada => DEFERRED x2 => PARTIAL => convergência
S5=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 12)
printf '%s\n' "begin; select 1 from public.recurring_reservations where id = '$S5' for update; select pg_sleep(9); commit;" \
  | APP=rg3c_j04_lock psql_c >/dev/null 2>&1 &
PL=$!
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j04_lock' and query ilike '%pg_sleep%')" 20
out=$(APP=rg3c_j04_job job CRON)
RUN4=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J04 série travada: DEFERRED_LOCKED nas duas passadas (registrado), execução PARTIAL, nada silencioso" \
  "$( [ "$(q "select status from public.recurring_generation_runs where id = '$RUN4'")" = "PARTIAL" ] \
      && [ "$(q "select string_agg(outcome || attempt, ',' order by attempt) from public.recurring_generation_run_series where run_id = '$RUN4' and series_id = '$S5'")" = "DEFERRED_LOCKED1,DEFERRED_LOCKED2" ] \
      && [ "$(nres "$S5")" = "0" ] && [ "$(q "select needs_work from private.v_recurring_horizon_status where series_id = '$S5'")" = "t" ] && echo 1)" "$out $(last_run)"
wait "$PL"
out=$(job CRON)
check "J04b convergência: execução seguinte materializa a série adiada; SUCCEEDED; view sem pendência" \
  "$( [ "$(nres "$S5")" = "$N120" ] && [ "$(last_run | cut -d'|' -f2)" = "SUCCEEDED" ] \
      && [ "$(q "select needs_work from private.v_recurring_horizon_status where series_id = '$S5'")" = "f" ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J05 job derrubado no meio
S6=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 14)
S7=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 16)
FIRST=$(q "select least('$S6'::uuid, '$S7'::uuid)"); SECOND=$(q "select greatest('$S6'::uuid, '$S7'::uuid)")
printf '%s\n' "begin; select 1 from public.recurring_reservations where id = '$SECOND' for update; select pg_sleep(12); commit;" \
  | APP=rg3c_j05_lock psql_c >/dev/null 2>&1 &
PL=$!
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j05_lock' and query ilike '%pg_sleep%')" 20
( APP=rg3c_j05_job job CRON > "$TMP/j05.out" ) &
PJ=$!
# espera o job chegar à 2ª passada (esperando o lock) e o derruba
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j05_job' and wait_event_type = 'Lock')" 20
q "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'rg3c_j05_job'" >/dev/null
wait "$PJ" 2>/dev/null
RUN5=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J05 job derrubado: execução fica RUNNING (órfã); série já processada ($FIRST) persistiu" \
  "$( [ "$(q "select status from public.recurring_generation_runs where id = '$RUN5'")" = "RUNNING" ] && [ "$(nres "$FIRST")" = "$N120" ] \
      && [ "$(nres "$SECOND")" = "0" ] && echo 1)" "$(last_run)"
wait "$PL"
out=$(job CRON)
check "J05b próxima execução: órfã => ABORTED; série pendente converge; SUCCEEDED" \
  "$( [ "$(q "select status from public.recurring_generation_runs where id = '$RUN5'")" = "ABORTED" ] && [ "$(nres "$SECOND")" = "$N120" ] \
      && [ "$(last_run | cut -d'|' -f2)" = "SUCCEEDED" ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J06 concorrência de execuções
printf '%s\n' "select pg_advisory_lock($LOCKKEY); select pg_sleep(6); select pg_advisory_unlock($LOCKKEY);" | APP=rg3c_j06_hold psql_c >/dev/null 2>&1 &
PH=$!
wait_for "exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid where l.locktype = 'advisory' and a.application_name = 'rg3c_j06_hold')" 20
out=$(job CRON)
check "J06 job com outro job em curso => SKIPPED_CONCURRENT registrado" "$( [ "$(last_run | cut -d'|' -f2)" = "SKIPPED_CONCURRENT" ] && echo 1)" "$(last_run)"
out=$(q "select private.rg_recurring_topup_batch(5)->>'status'")
check "J06b lote do operador com job em curso => SKIPPED_CONCURRENT" "$( [ "$out" = "SKIPPED_CONCURRENT" ] && echo 1)" "$out"
wait "$PH"

# ---------------------------------------------------------------- J07 job × pausa concorrente (lock real da RPC B3)
S8=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 17)
printf '%s\n' "begin; set local role authenticated; select set_config('request.jwt.claims', '$(claims "$U")', true);
select public.rg_recurring_pause('$S8', false); select pg_sleep(8); commit;" | APP=rg3c_j07_pause psql_c >/dev/null 2>&1 &
PP=$!
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j07_pause' and query ilike '%pg_sleep%')" 20
out=$(job CRON)
RUN7=$(q "select id from public.recurring_generation_runs order by started_at desc limit 1")
check "J07 pausa em curso (FOR UPDATE da B3) => job adia a série (registrado), não espera indefinidamente" \
  "$( [ "$(q "select count(*) from public.recurring_generation_run_series where run_id = '$RUN7' and series_id = '$S8' and outcome = 'DEFERRED_LOCKED'")" = "2" ] && echo 1)" "$(last_run)"
wait "$PP"
out=$(job CRON)
check "J07b após a pausa confirmada: série PAUSED não é materializada nem ganha lacuna" \
  "$( [ "$(nres "$S8")" = "0" ] && [ "$(q "select count(*) from public.recurring_occurrence_gaps where series_id = '$S8'")" = "0" ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J08 avulsa × geração em curso na mesma série
S9=$(new_series_pg "$U" "$AA" "$CA" "$CUST" 20)
FAR=$(q "select g::date from generate_series(private.rg_today() + 130, private.rg_today() + 140, interval '1 day') g, public.recurring_reservations s where s.id = '$S9' and private.rg_is_anchor(s, g::date) limit 1")
BOUNDS=$(q "select start_at || '|' || end_at from private.rg_occurrence_bounds('$FAR'::date, '20:00', '20:59')")
BS="${BOUNDS%%|*}"; BE="${BOUNDS##*|}"
printf '%s\n' "begin; set local role authenticated; select set_config('request.jwt.claims', '$(claims "$U")', true);
select public.rg_recurring_topup('$S9'); select pg_sleep(6); commit;" | APP=rg3c_j08_gen psql_c > "$TMP/j08a.out" 2>&1 &
PA=$!
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j08_gen' and query ilike '%pg_sleep%')" 20
printf '%s\n' "set lock_timeout = '20s'; set role authenticated; select set_config('request.jwt.claims', '$(claims "$R")', false);
insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
values ('$ORG', '$AA', '$CA', '$BS', '$BE', 'CONFIRMED', 'INTERNAL');" | APP=rg3c_j08_avulsa psql_c > "$TMP/j08b.out" 2>&1 &
PB=$!
BLOCKED=0
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j08_avulsa' and wait_event_type = 'Lock')" 5 && BLOCKED=1
wait "$PA"; wait "$PB"
check "J08 avulsa além do horizonte ESPERA a geração em curso (FOR SHARE) e depois é barrada (RECURRING_SLOT)" \
  "$( [ "$BLOCKED" = "1" ] && grep -q 'RECURRING_SLOT' "$TMP/j08b.out" && ! grep -q 'ERROR' "$TMP/j08a.out" && echo 1)" \
  "blocked=$BLOCKED $(grep -E 'ERROR|HINT' "$TMP/j08b.out" | head -n 2 | tr '\n' ' ')"

# ---------------------------------------------------------------- J09 corrida residual (série ainda não confirmada × avulsa)
DOW=$(q "select extract(dow from private.rg_today() + 10)::int")
NEAR=$(q "select private.rg_today() + 10")
NB=$(q "select start_at || '|' || end_at from private.rg_occurrence_bounds('$NEAR'::date, '21:00', '21:59')")
printf '%s\n' "begin; set local role authenticated; select set_config('request.jwt.claims', '$(claims "$U")', true);
select public.rg_recurring_create(gen_random_uuid(), '$AA', '$CA', '$CUST', null, 'WEEKLY', $DOW, null, '21:00'::time, '21:59'::time,
  (now() at time zone 'America/Sao_Paulo')::date - 7, null, true, 10000, 'p3c-j09', false, false, '{}'::date[]);
select pg_sleep(5); commit;" | APP=rg3c_j09_series psql_c > "$TMP/j09a.out" 2>&1 &
PA=$!
wait_for "exists (select 1 from pg_stat_activity where application_name = 'rg3c_j09_series' and query ilike '%pg_sleep%')" 20
out=$(q "set role authenticated; select set_config('request.jwt.claims', '$(claims "$R")', false);
insert into public.reservations (organization_id, arena_id, court_id, start_at, end_at, status, source)
values ('$ORG', '$AA', '$CA', '${NB%%|*}', '${NB##*|}', 'CONFIRMED', 'INTERNAL') returning id;")
AV9="$out"
wait "$PA"
S10=$(q "select id from public.recurring_reservations where organization_id = '$ORG' and notes = 'p3c-j09'")
out=$(job CRON)
check "J09 corrida residual: avulsa entra antes da série confirmar; o job registra CONFLICT explícito apontando a avulsa" \
  "$( [ -n "$S10" ] && [ "$(q "select reason || ':' || conflict_reservation_id from public.recurring_occurrence_gaps where series_id = '$S10' and occurrence_date = '$NEAR' and resolved_at is null")" = "CONFLICT:$AV9" ] && echo 1)" \
  "av=$AV9 s=$S10 $(last_run)"

# ---------------------------------------------------------------- J10 retenção de 90 dias
OLD=$(q "insert into public.recurring_generation_runs (origin, actor, status, horizon_days, horizon_date, started_at, finished_at)
         values ('CRON', 'SYSTEM', 'SUCCEEDED', 120, current_date, now() - interval '100 days', now() - interval '100 days') returning id")
q "insert into public.recurring_generation_run_series (run_id, series_id, organization_id, outcome) values ('$OLD', '$S2', '$ORG', 'CREATED')" >/dev/null
q "update public.recurring_occurrence_gaps set last_run_id = '$OLD' where series_id = '$S2' and resolved_at is null" >/dev/null
NAUD=$(q "select count(*) from public.audit_logs")
NGAP=$(q "select count(*) from public.recurring_occurrence_gaps where series_id = '$S2' and resolved_at is null")
out=$(job CRON)
check "J10 retenção: execução de 100 dias apagada (e suas linhas por série); lacunas abertas mantidas; audit_logs não encolhe" \
  "$( [ "$(q "select count(*) from public.recurring_generation_runs where id = '$OLD'")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_generation_run_series where run_id = '$OLD'")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_occurrence_gaps where series_id = '$S2' and resolved_at is null")" = "$NGAP" ] \
      && [ "$(q "select count(*) from public.audit_logs") " \> "$((NAUD - 1)) " ] && echo 1)" "$(last_run)"

# ---------------------------------------------------------------- J11 caminho manual
out=$(printf '%s\n' "begin;" "call private.rg_recurring_topup_job('MANUAL');" "rollback;" | psql_c 2>&1 | tr -d '\r')
check "J11 procedure dentro de transação explícita => invalid transaction termination (G0)" \
  "$(echo "$out" | grep -q 'invalid transaction termination' && echo 1)" "$out"
out=$(printf '%s\n' "begin;" "select private.rg_recurring_topup_batch(10)->>'status';" "commit;" | psql_c 2>&1 | tr -d '\r' | grep -E 'SUCCEEDED|PARTIAL|ERROR' | head -n 1)
check "J11b lote do operador funciona dentro de transação externa (SYSTEM_OPERATOR/MANUAL)" \
  "$( [ "$out" = "SUCCEEDED" ] && [ "$(last_run | cut -d'|' -f3-4)" = "MANUAL|SYSTEM_OPERATOR" ] && echo 1)" "$out $(last_run)"

# ---------------------------------------------------------------- J12 deadlock
check "J12 nenhum deadlock (40P01) em nenhuma saída" "$( ! grep -qiE '40P01|deadlock' "$TMP"/*.out 2>/dev/null && echo 1)"

# ---------------------------------------------------------------- limpeza
cleanup_org "$ORG" "$U" "$R"
q "delete from public.recurring_generation_runs where started_at >= '$T0'::timestamptz" >/dev/null
check "R-CLEAN fixture do harness removida (séries, lacunas, execuções do harness)" \
  "$( [ "$(q "select count(*) from public.organizations where id = '$ORG'")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_generation_runs where started_at >= '$T0'::timestamptz")" = "0" ] \
      && [ "$(q "select count(*) from public.recurring_occurrence_gaps where organization_id = '$ORG'")" = "0" ] \
      && [ "$(q "select count(*) from cron.job")" = "0" ] && echo 1)"

echo
echo "P3C_HARNESS $PASS PASS / $FAIL FAIL (total $((PASS + FAIL)))"
[ "$FAIL" = "0" ]
