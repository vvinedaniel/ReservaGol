-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING B3 — FOUNDATION (Revision 3.1)
-- Mensalistas atômicos: RPC por operação para a parte crítica de gravação.
-- DRAFT PARA REVISÃO. Rodar no SQL Editor do Supabase SOMENTE após aprovação explícita.
-- IDEMPOTENTE e segura para reaplicar. NÃO altera nem apaga dados existentes.
--
-- ROLLOUT (ordem obrigatória):
--   ETAPA 0 — PRE-FOUNDATION (só código, sem banco): o route deixa de usar select('*') /
--      .select() sem colunas em recurring_reservations e passa a usar a allowlist das 20
--      colunas de negócio existentes. PRÉ-REQUISITO DURO desta migration: ela troca o
--      SELECT de tabela de authenticated por SELECT por coluna (sem operation_request);
--      um select('*') remanescente passa a falhar com 42501 (fail-closed, sem vazar).
--   ETAPA 1 — INICIAR a janela de manutenção (mutações de mensalistas suspensas) e aplicar
--      ESTA migration (FOUNDATION).
--   ETAPA 2 — publicar o route B3 (RPCs rg_recurring_*).
--   ETAPA 3 — smoke tests B3 essenciais + regressões necessárias.
--   ETAPA 4 — aplicar migration_security_b3_lockdown.sql e verificar grants + estado terminal.
--   ETAPA 5 — SOMENTE com as verificações verdes: ENCERRAR a janela de manutenção.
--   A janela cobre ETAPA 1 a 4 porque, entre FOUNDATION e LOCKDOWN, ainda existe escrita
--   direta transitória (restrita) em recurring_reservations, e um reschedule feito pelo
--   route antigo não entra na linhagem B3 (previous_series_id/operation_* ficam NULL).
--
-- Compatibilidade da FOUNDATION com o route antigo (já com a ETAPA 0):
--   * Escrita de authenticated em recurring_reservations passa a ser POR COLUNA, com
--     allowlists mínimas e DIFERENTES:
--       INSERT transitório = 17 colunas (exatamente as dos dois INSERTs do route antigo:
--         organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
--         start_time, end_time, start_date, end_date, has_no_end_date, status, default_price,
--         notes, is_demo, created_by). id/created_at/updated_at usam os defaults do banco.
--       UPDATE transitório = 5 colunas (notes, default_price, end_date, has_no_end_date,
--         status) — tudo o que PATCH, pause/reactivate/cancel e o reschedule antigo alteram.
--     A estrutura da recorrência (org/arena/quadra/cliente/frequência/dia/horário/início,
--     is_demo, created_by) NÃO pode ser alterada por UPDATE direto, nem durante a janela.
--     Os metadados B3 (operation_id, operation_kind, operation_request, previous_series_id)
--     NÃO podem ser gravados nem forjados por authenticated; só as RPCs (owner postgres).
--   * SELECT de authenticated por coluna: tudo menos operation_request (PII da intenção do
--     cliente); operation_id/operation_kind/previous_series_id seguem legíveis para o
--     preflight de replay do route.
--   * NÃO torna CANCELLED terminal por trigger (o rollback manual do reschedule antigo
--     restaura status); as RPCs já aplicam D1. O terminal fica no LOCKDOWN.
--   * Harness afetado a partir DESTA migration: tests/security_a2_tenant_integrity.py faz
--     PATCH direto com token de usuário e Prefer: return=representation (RETURNING *), que
--     passa a falhar com 42501 por causa de operation_request. Atualizar na ETAPA 2.
--
-- NÃO altera nem renomeia: reservations_no_overlap, idx_res_series_anchor,
-- reservations_recurring_anchor, protect_occurrence_anchor, validate_reservation_recurring,
-- validate_recurring_tenant, protect_structural_links, enforce_reservation_tenant, nem nada
-- de A1–A6 / B1 / B2. Só ACRESCENTA colunas, constraints, índices, funções e triggers.
--
-- Arquitetura (opção C aprovada):
--   * 1 chamada PostgREST = 1 transação: OU toda a operação lógica persiste, OU nada;
--   * SELECT ... FOR UPDATE na linha da série serializa operações da mesma série (sem
--     advisory lock);
--   * o preview continua no JS e NÃO é autoridade de integridade. A RPC valida que TODA data
--     recebida é uma âncora legítima da série travada, mas NÃO prova que o chamador enviou
--     TODAS as datas possíveis. Por isso o route deve tratar como FAIL-CLOSED qualquer erro
--     ao ler business_hours / reservations / âncoras existentes durante o preview (nunca
--     interpretar falha de SELECT como "não há conflitos");
--   * reservations_no_overlap continua sendo a autoridade final contra reserva dupla;
--   * audit_logs na MESMA transação, só com fatos derivados na transação;
--   * SECURITY DEFINER com autorização explícita: auth.uid() obrigatório; tenant SEMPRE
--     derivado da série/arena no banco.
--
-- Idempotência (create/reschedule):
--   * operation_id OBRIGATÓRIO, único por (organization_id, operation_id);
--   * operation_kind + operation_request (JSONB normalizado da INTENÇÃO original, sem
--     p_dates) gravados na série criada e IMUTÁVEIS. O replay compara com a operação
--     original, nunca com o estado atual (mutável) da série;
--   * mesmo request -> idempotent=true; request diferente -> RGR02.
--   * Contrato do REPLAY (não reconstrói nem armazena números históricos):
--       create     -> {series_id, status, idempotent: true}
--       reschedule -> {previous_series_id, new_series_id, status, idempotent: true}
--     SEM created/skipped/existing/cancelled_future/customer_id. O route trata
--     idempotent=true como fluxo próprio ("Mensalista já criado" / "Reagendamento já
--     aplicado") e nunca lê contadores nesse caso.
--   * O route deve checar operation_id já confirmado ANTES do preview/needs_decision:
--     SELECT (RLS de membro) por organization_id + operation_id; se existir, chamar a RPC
--     com p_dates vazio — o replay é decidido antes de qualquer uso de p_dates.
--   * create resolve/cria o cliente DENTRO da transação (a partir do customer_id ou dos
--     dados do cliente), e o fingerprint guarda a INTENÇÃO do cliente, não o id resolvido.
--
-- SQLSTATEs novos:
--   RGR01 = estado/transição inválida da série.
--   RGR02 = operation_id reutilizado com operação diferente (idempotency mismatch).
--   RGF01 = falha INJETADA de teste (inalcançável via PostgREST; ver private.rg_fault).
-- Padrão: 42501, P0002, 22023, 23514, 23P01/23505, RGT01/RGT02 (A2).
--
-- Ordem dos BEFORE ROW triggers (ordem alfabética do nome):
--   reservations, INSERT:
--     1. enforce_reservation_tenant                 (A2, RGT01)
--     2. validate_reservation_recurring             (02C)
--     3. validate_reservation_zz_series_occurrence  (B3/D7 — NOVO, último de propósito)
--   reservations, UPDATE: inalterado ("apenas esta" continua como hoje).
--   recurring_reservations, INSERT:
--     1. validate_recurring_tenant (02C)
--     2. validate_recurring_zz_lineage              (B3 — NOVO, último de propósito)
--   recurring_reservations, UPDATE:
--     1. protect_recurring_links (A2)  2. set_recurring_updated_at  3. validate_recurring_tenant
--     4. validate_recurring_zz_lineage (B3)
--     (o lockdown acrescenta 5. validate_recurring_zz_terminal_state)
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1) Colunas novas em recurring_reservations (nulas; nenhuma linha existente muda)
-- -----------------------------------------------------------------------------
alter table public.recurring_reservations add column if not exists operation_id uuid;
alter table public.recurring_reservations add column if not exists operation_kind text;
alter table public.recurring_reservations add column if not exists operation_request jsonb;
alter table public.recurring_reservations add column if not exists previous_series_id uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'recurring_previous_series_fkey'
                 and conrelid = 'public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_previous_series_fkey
      foreign key (previous_series_id) references public.recurring_reservations(id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'recurring_previous_not_self'
                 and conrelid = 'public.recurring_reservations'::regclass) then
    alter table public.recurring_reservations add constraint recurring_previous_not_self
      check (previous_series_id is null or previous_series_id <> id);
  end if;
end $$;

-- Exatamente três estados válidos (recriada para refletir sempre esta definição):
--   legado     : operation_id, operation_kind, operation_request e previous_series_id NULL;
--   CREATE     : operation_id + kind CREATE + request objeto + previous_series_id NULL;
--   RESCHEDULE : operation_id + kind RESCHEDULE + request objeto + previous_series_id NOT NULL.
-- coalesce(..., false): um CHECK que avalia para NULL passaria; aqui NULL = violação.
alter table public.recurring_reservations drop constraint if exists recurring_operation_consistency;
alter table public.recurring_reservations add constraint recurring_operation_consistency check (coalesce(
  (operation_id is null and operation_kind is null and operation_request is null and previous_series_id is null)
  or (operation_id is not null and operation_kind = 'CREATE'
      and operation_request is not null and jsonb_typeof(operation_request) = 'object'
      and previous_series_id is null)
  or (operation_id is not null and operation_kind = 'RESCHEDULE'
      and operation_request is not null and jsonb_typeof(operation_request) = 'object'
      and previous_series_id is not null),
  false));

-- Idempotência escopada por organização (nunca global).
create unique index if not exists idx_recurring_org_operation
  on public.recurring_reservations (organization_id, operation_id)
  where operation_id is not null;

-- Consulta da linhagem (inclui descendentes CANCELLED).
create index if not exists idx_recurring_previous
  on public.recurring_reservations (previous_series_id)
  where previous_series_id is not null;

-- D6 (aprovado): no máximo UM descendente vivo (ACTIVE ou PAUSED) por série de origem.
-- ACTIVE<->PAUSED mantém a linha no índice; ACTIVE/PAUSED -> CANCELLED a retira.
create unique index if not exists idx_recurring_one_live_child
  on public.recurring_reservations (previous_series_id)
  where previous_series_id is not null and status <> 'CANCELLED';

-- -----------------------------------------------------------------------------
-- 2) Helpers privados (SECURITY INVOKER; só executados por dentro de RPCs/triggers,
--    que rodam como o owner postgres)
-- -----------------------------------------------------------------------------

-- "Hoje" no fuso da arena (mesma regra de todayInTZ no JS).
create or replace function private.rg_today()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

-- Janela de materialização [hoje, hoje + 90], igual ao JS. occurrence_date é a data de
-- INÍCIO (23:00 -> 00:00 ancora no primeiro dia): nenhum fluxo precisa da âncora de ontem.
create or replace function private.rg_in_window(p_date date)
returns boolean language sql stable set search_path = '' as $$
  select p_date is not null and p_date between private.rg_today() and private.rg_today() + 90
$$;

-- Espelha toISO/endISO do JS: offset FIXO -03:00, precisão de minuto (o JS usa HH:MM),
-- fim <= início (em minutos) termina no dia seguinte.
create or replace function private.rg_occurrence_bounds(p_date date, p_start time, p_end time)
returns table (start_at timestamptz, end_at timestamptz)
language sql stable set search_path = '' as $$
  select
    (to_char(p_date, 'YYYY-MM-DD') || ' '
       || lpad(extract(hour from p_start)::int::text, 2, '0') || ':'
       || lpad(extract(minute from p_start)::int::text, 2, '0') || ':00-03:00')::timestamptz,
    (to_char(case when extract(hour from p_end)::int * 60 + extract(minute from p_end)::int
                       <= extract(hour from p_start)::int * 60 + extract(minute from p_start)::int
                  then p_date + 1 else p_date end, 'YYYY-MM-DD') || ' '
       || lpad(extract(hour from p_end)::int::text, 2, '0') || ':'
       || lpad(extract(minute from p_end)::int::text, 2, '0') || ':00-03:00')::timestamptz
$$;

-- Verificador de âncora (mesma regra de computeAnchors no JS):
--   WEEKLY: dia da semana; BIWEEKLY: dia da semana + múltiplo de 14 dias a partir da 1ª
--   data >= start_date com esse dia; MONTHLY: dia do mês; sempre em [start_date, end_date].
create or replace function private.rg_is_anchor(p_series public.recurring_reservations, p_date date)
returns boolean language sql stable set search_path = '' as $$
  select p_date is not null
     and p_date >= p_series.start_date
     and (p_series.has_no_end_date or (p_series.end_date is not null and p_date <= p_series.end_date))
     and case p_series.frequency
           when 'WEEKLY' then
             p_series.weekday is not null and extract(dow from p_date)::int = p_series.weekday
           when 'BIWEEKLY' then
             p_series.weekday is not null and extract(dow from p_date)::int = p_series.weekday
             and ((p_date - (p_series.start_date
                   + ((p_series.weekday - extract(dow from p_series.start_date)::int + 7) % 7))) % 14) = 0
           when 'MONTHLY' then
             p_series.day_of_month is not null and extract(day from p_date)::int = p_series.day_of_month
           else false
         end
$$;

-- Falha injetada SOMENTE para testes de rollback. Dispara só se:
--   (a) session_user = 'postgres' (PostgREST conecta como "authenticator", não superuser,
--       NOINHERIT, membro só de anon/authenticated/service_role; SECURITY DEFINER e SET ROLE
--       mudam current_user, nunca session_user); E
--   (b) a GUC local rg.fault_at = p_step (PostgREST não define GUCs arbitrárias).
-- Via API é sempre no-op.
create or replace function private.rg_fault(p_step text)
returns void language plpgsql volatile set search_path = '' as $$
begin
  if session_user = 'postgres' and current_setting('rg.fault_at', true) = p_step then
    raise exception 'rg_fault_injected: %', p_step using errcode = 'RGF01';
  end if;
end $$;

-- Autorização + trava principal da série (autorização ANTES da trava; inexistente e outro
-- tenant = mesmo erro; FOR UPDATE relê a última versão confirmada).
create or replace function private.rg_lock_series(p_series_id uuid, p_require_manager boolean)
returns public.recurring_reservations
language plpgsql set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_series public.recurring_reservations;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select s.organization_id into v_org from public.recurring_reservations s where s.id = p_series_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  if p_require_manager and not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para alterar mensalista' using errcode = '42501';
  end if;
  select s.* into v_series from public.recurring_reservations s where s.id = p_series_id for update;
  return v_series;
end $$;

-- Intenção normalizada do cliente do create (entra no operation_request):
--   customer_id informado      -> {"id": <uuid>}
--   dados com nome não vazio   -> {"name": ..., "phone": <só dígitos ou null>, "email": <ou null>}
--   nada (ou sem nome)         -> null   (mesma regra de resolveCustomerId no JS)
create or replace function private.rg_customer_request(p_customer_id uuid, p_customer jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_name text;
begin
  if p_customer_id is not null and p_customer is not null and p_customer <> 'null'::jsonb then
    raise exception 'rg: informe customer_id OU os dados do cliente, não ambos' using errcode = '22023';
  end if;
  if p_customer_id is not null then
    return jsonb_build_object('id', p_customer_id);
  end if;
  if p_customer is null or p_customer = 'null'::jsonb then
    return null;
  end if;
  if jsonb_typeof(p_customer) <> 'object' then
    raise exception 'rg: dados do cliente inválidos' using errcode = '22023';
  end if;
  v_name := p_customer->>'name';
  if v_name is null or v_name = '' then
    return null;
  end if;
  return jsonb_build_object(
    'name', v_name,
    'phone', nullif(regexp_replace(coalesce(p_customer->>'phone', ''), '\D', '', 'g'), ''),
    'email', nullif(p_customer->>'email', ''));
end $$;

-- Resolve/cria o cliente a partir da intenção normalizada, DENTRO da transação do create
-- (mesma regra de resolveCustomerId: telefone igual na org reaproveita; senão cria).
-- Cliente informado por id: pertencimento à org é garantido por validate_recurring_tenant.
create or replace function private.rg_resolve_customer(p_org uuid, p_arena uuid, p_request jsonb)
returns uuid language plpgsql volatile set search_path = '' as $$
declare
  v_id uuid;
  v_phone text;
begin
  if p_request is null then
    return null;
  end if;
  if p_request ? 'id' then
    return (p_request->>'id')::uuid;
  end if;
  v_phone := p_request->>'phone';
  if v_phone is not null then
    select c.id into v_id from public.customers c
     where c.organization_id = p_org and c.phone = v_phone
     order by c.created_at, c.id limit 1;
    if found then
      return v_id;
    end if;
  end if;
  insert into public.customers (organization_id, arena_id, name, phone, email)
  values (p_org, p_arena, p_request->>'name', v_phone, p_request->>'email')
  returning id into v_id;
  return v_id;
end $$;

-- Normaliza as mudanças do reschedule: lista FECHADA de chaves, valores com tipo canônico
-- (uuid/time/int como o banco os representa). Presença da chave = mudança.
create or replace function private.rg_normalize_changes(p_changes jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_in jsonb := coalesce(p_changes, '{}'::jsonb);
  v_out jsonb := '{}'::jsonb;
begin
  -- Dois IFs: SQL não garante curto-circuito de OR (jsonb_object_keys exige objeto).
  if jsonb_typeof(v_in) <> 'object' then
    raise exception 'rg: alteração não permitida no reagendamento' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_in) as k
              where k not in ('court_id', 'frequency', 'weekday', 'day_of_month',
                              'start_time', 'end_time', 'default_price', 'notes')) then
    raise exception 'rg: alteração não permitida no reagendamento' using errcode = '22023';
  end if;
  if v_in ? 'court_id' then v_out := v_out || jsonb_build_object('court_id', (v_in->>'court_id')::uuid); end if;
  if v_in ? 'frequency' then v_out := v_out || jsonb_build_object('frequency', v_in->>'frequency'); end if;
  if v_in ? 'weekday' then v_out := v_out || jsonb_build_object('weekday', (v_in->>'weekday')::integer); end if;
  if v_in ? 'day_of_month' then v_out := v_out || jsonb_build_object('day_of_month', (v_in->>'day_of_month')::integer); end if;
  if v_in ? 'start_time' then v_out := v_out || jsonb_build_object('start_time', (v_in->>'start_time')::time); end if;
  if v_in ? 'end_time' then v_out := v_out || jsonb_build_object('end_time', (v_in->>'end_time')::time); end if;
  if v_in ? 'default_price' then v_out := v_out || jsonb_build_object('default_price', (v_in->>'default_price')::integer); end if;
  if v_in ? 'notes' then v_out := v_out || jsonb_build_object('notes', v_in->>'notes'); end if;
  return v_out;
end $$;

-- Materialização atômica: valida TODAS as datas antes (âncora real + janela) -> 22023;
-- um INSERT por data em ordem crescente, cada um em savepoint. Só são absorvidos:
--   23P01 de reservations_no_overlap com p_skip_conflicts = true -> "skipped";
--   23505 de idx_res_series_anchor -> "existing" (idempotente).
-- Qualquer outro erro propaga e desfaz a transação inteira.
create or replace function private.rg_materialize(
  p_series public.recurring_reservations, p_dates date[], p_skip_conflicts boolean, p_uid uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
  v_constraint text;
  v_step integer := 0;
  v_created date[] := '{}';
  v_skipped date[] := '{}';
  v_existing date[] := '{}';
begin
  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    if v_date is null or not private.rg_in_window(v_date) or not private.rg_is_anchor(p_series, v_date) then
      raise exception 'rg: data % não é uma ocorrência válida desta série na janela atual', v_date
        using errcode = '22023';
    end if;
  end loop;

  for v_date in select distinct d from unnest(coalesce(p_dates, '{}'::date[])) as d order by 1 loop
    select b.start_at, b.end_at into v_start, v_end
      from private.rg_occurrence_bounds(v_date, p_series.start_time, p_series.end_time) as b;
    begin
      insert into public.reservations (
        organization_id, arena_id, court_id, customer_id, start_at, end_at, status, source,
        notes, price, recurring_reservation_id, occurrence_date, is_exception, created_by)
      values (
        p_series.organization_id, p_series.arena_id, p_series.court_id, p_series.customer_id,
        v_start, v_end, 'CONFIRMED', 'RECORRENTE',
        p_series.notes, p_series.default_price, p_series.id, v_date, false, p_uid);
      v_created := array_append(v_created, v_date);
    exception
      when exclusion_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'reservations_no_overlap' and coalesce(p_skip_conflicts, false) then
          v_skipped := array_append(v_skipped, v_date);
        else
          raise;
        end if;
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint = 'idx_res_series_anchor' then
          v_existing := array_append(v_existing, v_date);
        else
          raise;
        end if;
    end;
    v_step := v_step + 1;
    perform private.rg_fault('materialize:' || v_step);
  end loop;

  return jsonb_build_object(
    'created', to_jsonb(v_created), 'skipped', to_jsonb(v_skipped), 'existing', to_jsonb(v_existing));
end $$;

-- Cancelamento das futuras — filtro IDÊNTICO ao cancelFutureOccurrences atual (D11).
create or replace function private.rg_cancel_future(p_series_id uuid, p_from date)
returns integer language sql volatile set search_path = '' as $$
  with u as (
    update public.reservations r set status = 'CANCELLED'
     where r.recurring_reservation_id = p_series_id
       and r.status <> 'CANCELLED'
       and r.start_at >= (to_char(p_from, 'YYYY-MM-DD') || ' 00:00:00-03:00')::timestamptz
    returning 1)
  select count(*)::integer from u
$$;

-- -----------------------------------------------------------------------------
-- 3) Triggers de integridade (SECURITY DEFINER)
-- -----------------------------------------------------------------------------

-- D7: todo INSERT com recurring_reservation_id precisa ser EXATAMENTE a ocorrência que a
-- série geraria. Impede, por exemplo, "tombstone" artificial (linha CANCELLED numa âncora
-- válida ocupando idx_res_series_anchor e bloqueando a materialização legítima).
-- UPDATE não é afetado: "apenas esta" continua como hoje.
create or replace function private.enforce_recurring_occurrence()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_series public.recurring_reservations;
  v_start timestamptz;
  v_end timestamptz;
begin
  if new.recurring_reservation_id is null then
    return new;
  end if;
  -- Espelha a RLS antes de ler a série (a RLS de INSERT só roda depois dos BEFORE triggers).
  if v_uid is not null and not private.is_org_member(new.organization_id, v_uid) then
    raise exception 'new row violates row-level security policy for table "reservations"'
      using errcode = '42501';
  end if;
  -- FOR SHARE: serializa com o FOR UPDATE das RPCs e com UPDATE de status da série.
  select s.* into v_series from public.recurring_reservations s
   where s.id = new.recurring_reservation_id for share;
  if not found then
    raise exception 'recurring_occurrence_invalid: série inexistente' using errcode = '23514';
  end if;
  if v_series.status <> 'ACTIVE' then
    raise exception 'recurring_series_not_active: a série não está ativa' using errcode = 'RGR01';
  end if;
  if new.organization_id is distinct from v_series.organization_id
     or new.arena_id is distinct from v_series.arena_id
     or new.court_id is distinct from v_series.court_id then
    raise exception 'recurring_occurrence_invalid: organização/arena/quadra diferentes da série'
      using errcode = '23514';
  end if;
  if new.occurrence_date is null or not private.rg_is_anchor(v_series, new.occurrence_date) then
    raise exception 'recurring_occurrence_invalid: data não é âncora da série' using errcode = '23514';
  end if;
  if new.is_exception then
    raise exception 'recurring_occurrence_invalid: ocorrência nova não pode nascer como exceção'
      using errcode = '23514';
  end if;
  select b.start_at, b.end_at into v_start, v_end
    from private.rg_occurrence_bounds(new.occurrence_date, v_series.start_time, v_series.end_time) as b;
  if new.start_at is distinct from v_start or new.end_at is distinct from v_end then
    raise exception 'recurring_occurrence_invalid: horário diferente do horário da série'
      using errcode = '23514';
  end if;
  if new.status is distinct from 'CONFIRMED' or new.source is distinct from 'RECORRENTE' then
    raise exception 'recurring_occurrence_invalid: ocorrência nova deve ser CONFIRMED/RECORRENTE'
      using errcode = '23514';
  end if;
  -- notes: '' e NULL são equivalentes (o route atual grava series.notes || null).
  if new.customer_id is distinct from v_series.customer_id
     or new.price is distinct from v_series.default_price
     or nullif(new.notes, '') is distinct from nullif(v_series.notes, '') then
    raise exception 'recurring_occurrence_invalid: cliente/preço/observação diferentes da série'
      using errcode = '23514';
  end if;
  if new.public_code is not null or new.idempotency_key is not null then
    raise exception 'recurring_occurrence_invalid: ocorrência recorrente não usa código público'
      using errcode = '23514';
  end if;
  if v_uid is not null and new.created_by is distinct from v_uid then
    raise exception 'recurring_occurrence_invalid: created_by deve ser o usuário autenticado'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists validate_reservation_zz_series_occurrence on public.reservations;
create trigger validate_reservation_zz_series_occurrence
  before insert on public.reservations
  for each row execute function private.enforce_recurring_occurrence();

-- Linhagem e operação: previous_series_id, operation_id, operation_kind e operation_request
-- são imutáveis após o INSERT (RGT02). No INSERT com previous_series_id: espelha a RLS e
-- exige série anterior da MESMA organização e arena (RGT01; inexistente = mesmo erro).
-- (CANCELLED terminal fica no LOCKDOWN para não bloquear o rollback manual do route antigo.)
create or replace function private.enforce_recurring_lineage()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if tg_op = 'UPDATE' then
    if new.previous_series_id is distinct from old.previous_series_id
       or new.operation_id is distinct from old.operation_id
       or new.operation_kind is distinct from old.operation_kind
       or new.operation_request is distinct from old.operation_request then
      raise exception 'structural_link_immutable: linhagem/operação da série não pode ser alterada'
        using errcode = 'RGT02';
    end if;
    return new;
  end if;

  if new.previous_series_id is not null then
    if v_uid is not null and not private.is_org_member(new.organization_id, v_uid) then
      raise exception 'new row violates row-level security policy for table "recurring_reservations"'
        using errcode = '42501';
    end if;
    if not exists (
      select 1 from public.recurring_reservations p
       where p.id = new.previous_series_id
         and p.organization_id = new.organization_id
         and p.arena_id = new.arena_id
    ) then
      raise exception 'tenant_mismatch: série anterior não pertence à mesma organização/arena'
        using errcode = 'RGT01';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists validate_recurring_zz_lineage on public.recurring_reservations;
create trigger validate_recurring_zz_lineage
  before insert or update on public.recurring_reservations
  for each row execute function private.enforce_recurring_lineage();

-- -----------------------------------------------------------------------------
-- 4) RPCs públicas (SECURITY DEFINER, owner postgres, search_path = '')
-- -----------------------------------------------------------------------------

-- CREATE: cliente (resolve/cria) + série + ocorrências + audit numa transação.
-- Tenant = arenas.organization_id (organization_id do cliente não existe na assinatura).
create or replace function public.rg_recurring_create(
  p_operation_id uuid,
  p_arena_id uuid,
  p_court_id uuid,
  p_customer_id uuid,
  p_customer jsonb,
  p_frequency text,
  p_weekday integer,
  p_day_of_month integer,
  p_start_time time,
  p_end_time time,
  p_start_date date,
  p_end_date date,
  p_has_no_end_date boolean,
  p_default_price integer,
  p_notes text,
  p_is_demo boolean,
  p_skip_conflicts boolean,
  p_dates date[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_customer_request jsonb;
  v_request jsonb;
  v_customer_id uuid;
  v_series public.recurring_reservations;
  v_conflict boolean := false;
  v_constraint text;
  v_mat jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  select a.organization_id into v_org from public.arenas a where a.id = p_arena_id;
  if v_org is null or not private.is_org_member(v_org, v_uid) then
    raise exception 'rg: arena não encontrada' using errcode = 'P0002';
  end if;
  if not private.is_org_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para criar mensalista' using errcode = '42501';
  end if;

  -- Intenção original normalizada (SEM p_dates). É o que o replay compara.
  v_customer_request := private.rg_customer_request(p_customer_id, p_customer);
  v_request := jsonb_build_object(
    'arena_id', p_arena_id,
    'court_id', p_court_id,
    'customer', v_customer_request,
    'frequency', p_frequency,
    'weekday', p_weekday,
    'day_of_month', p_day_of_month,
    'start_time', p_start_time,
    'end_time', p_end_time,
    'start_date', p_start_date,
    'end_date', p_end_date,
    'has_no_end_date', coalesce(p_has_no_end_date, false),
    'default_price', p_default_price,
    'notes', p_notes,
    'is_demo', coalesce(p_is_demo, false),
    'skip_conflicts', coalesce(p_skip_conflicts, false));

  -- Replay rápido (antes de qualquer efeito colateral, inclusive criar cliente).
  select s.* into v_series from public.recurring_reservations s
   where s.organization_id = v_org and s.operation_id = p_operation_id;
  if found then
    if v_series.operation_kind = 'CREATE' and v_series.operation_request = v_request then
      return jsonb_build_object('series_id', v_series.id, 'status', v_series.status, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGR02';
  end if;

  -- Cliente + série num SAVEPOINT: se outra transação confirmar o mesmo operation_id
  -- primeiro, o INSERT espera, recebe 23505 em idx_recurring_org_operation e o savepoint
  -- desfaz também o cliente criado aqui (nenhum cliente órfão).
  begin
    v_customer_id := private.rg_resolve_customer(v_org, p_arena_id, v_customer_request);
    insert into public.recurring_reservations (
      organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
      start_time, end_time, start_date, end_date, has_no_end_date, default_price, notes,
      is_demo, created_by, status, operation_id, operation_kind, operation_request)
    values (
      v_org, p_arena_id, p_court_id, v_customer_id, p_frequency, p_weekday, p_day_of_month,
      p_start_time, p_end_time, p_start_date, p_end_date, coalesce(p_has_no_end_date, false),
      p_default_price, p_notes, coalesce(p_is_demo, false), v_uid, 'ACTIVE',
      p_operation_id, 'CREATE', v_request)
    returning * into v_series;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_recurring_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;

  if v_conflict then
    select s.* into v_series from public.recurring_reservations s
     where s.organization_id = v_org and s.operation_id = p_operation_id;
    if found and v_series.operation_kind = 'CREATE' and v_series.operation_request = v_request then
      return jsonb_build_object('series_id', v_series.id, 'status', v_series.status, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGR02';
  end if;
  perform private.rg_fault('create:after_series');

  v_mat := private.rg_materialize(v_series, p_dates, p_skip_conflicts, v_uid);
  perform private.rg_fault('create:before_audit');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'RECURRING_RESERVATION_CREATED', 'recurring_reservation', v_series.id,
    jsonb_build_object(
      'frequency', v_series.frequency,
      'created', jsonb_array_length(v_mat->'created'),
      'skipped', jsonb_array_length(v_mat->'skipped'),
      'existing', jsonb_array_length(v_mat->'existing')));

  return jsonb_build_object(
    'series_id', v_series.id, 'status', v_series.status, 'customer_id', v_series.customer_id,
    'idempotent', false,
    'created', v_mat->'created', 'skipped', v_mat->'skipped', 'existing', v_mat->'existing');
end $$;

-- RESCHEDULE ("esta e as próximas"). Ordem: replay -> estado -> INSERT da série nova com
-- ON CONFLICT (reivindica o operation_id ANTES de mexer na antiga) -> encerra a antiga ->
-- cancela futuras antigas -> materializa a nova -> audit. Tudo numa transação.
create or replace function public.rg_recurring_reschedule(
  p_series_id uuid,
  p_operation_id uuid,
  p_from_date date,
  p_changes jsonb,
  p_skip_conflicts boolean,
  p_dates date[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_changes jsonb;
  v_request jsonb;
  v_old public.recurring_reservations;
  v_new public.recurring_reservations;
  v_cancelled integer;
  v_mat jsonb;
begin
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  if p_from_date is null then
    raise exception 'rg: from_date é obrigatório' using errcode = '22023';
  end if;
  v_changes := private.rg_normalize_changes(p_changes);
  -- Intenção original: a OPERAÇÃO pedida (não uma cópia do estado da série). Sem p_dates.
  v_request := jsonb_build_object(
    'series_id', p_series_id,
    'from_date', p_from_date,
    'changes', v_changes,
    'skip_conflicts', coalesce(p_skip_conflicts, false));

  -- Autorização (OWNER/MANAGER) + trava da série de origem.
  v_old := private.rg_lock_series(p_series_id, true);

  -- Replay (antes das checagens de estado: no retry a antiga já está encerrada).
  select s.* into v_new from public.recurring_reservations s
   where s.organization_id = v_old.organization_id and s.operation_id = p_operation_id;
  if found then
    if v_new.operation_kind = 'RESCHEDULE' and v_new.operation_request = v_request then
      return jsonb_build_object(
        'previous_series_id', v_new.previous_series_id, 'new_series_id', v_new.id,
        'status', v_new.status, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGR02';
  end if;

  -- Estado (D1, D2, D6).
  if v_old.status = 'CANCELLED' then
    raise exception 'rg: mensalista cancelado não pode ser reagendado' using errcode = 'RGR01';
  end if;
  if p_from_date < private.rg_today() then
    raise exception 'rg: não é possível reagendar a partir de uma data passada' using errcode = '22023';
  end if;
  if not v_old.has_no_end_date and p_from_date > v_old.end_date then
    raise exception 'rg: o mensalista já termina antes desta data' using errcode = 'RGR01';
  end if;
  if exists (select 1 from public.recurring_reservations c
              where c.previous_series_id = v_old.id and c.status <> 'CANCELLED') then
    raise exception 'rg: este mensalista já foi reagendado; altere a série atual' using errcode = 'RGR01';
  end if;

  -- 1) Série nova PRIMEIRO: reivindica o operation_id antes de qualquer mudança na antiga.
  --    Reschedule de OUTRA série com o mesmo operation_id: série diferente = lock diferente;
  --    o ON CONFLICT espera a outra transação e, se ela confirmou, cai no mismatch abaixo.
  insert into public.recurring_reservations (
    organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
    start_time, end_time, start_date, end_date, has_no_end_date, default_price, notes,
    is_demo, created_by, status, previous_series_id, operation_id, operation_kind, operation_request)
  values (
    v_old.organization_id, v_old.arena_id,
    case when v_changes ? 'court_id' then (v_changes->>'court_id')::uuid else v_old.court_id end,
    v_old.customer_id,
    case when v_changes ? 'frequency' then v_changes->>'frequency' else v_old.frequency end,
    case when v_changes ? 'weekday' then (v_changes->>'weekday')::integer else v_old.weekday end,
    case when v_changes ? 'day_of_month' then (v_changes->>'day_of_month')::integer else v_old.day_of_month end,
    case when v_changes ? 'start_time' then (v_changes->>'start_time')::time else v_old.start_time end,
    case when v_changes ? 'end_time' then (v_changes->>'end_time')::time else v_old.end_time end,
    p_from_date, v_old.end_date, v_old.has_no_end_date,
    case when v_changes ? 'default_price' then (v_changes->>'default_price')::integer else v_old.default_price end,
    case when v_changes ? 'notes' then v_changes->>'notes' else v_old.notes end,
    v_old.is_demo, v_uid, 'ACTIVE', v_old.id, p_operation_id, 'RESCHEDULE', v_request)
  on conflict (organization_id, operation_id) where operation_id is not null do nothing
  returning * into v_new;

  if not found then
    select s.* into v_new from public.recurring_reservations s
     where s.organization_id = v_old.organization_id and s.operation_id = p_operation_id;
    if found and v_new.operation_kind = 'RESCHEDULE' and v_new.operation_request = v_request then
      -- Nada foi alterado nesta transação até aqui: devolver o resultado original é seguro.
      return jsonb_build_object(
        'previous_series_id', v_new.previous_series_id, 'new_series_id', v_new.id,
        'status', v_new.status, 'idempotent', true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGR02';
  end if;
  perform private.rg_fault('reschedule:after_new_series');

  -- 2) Encerra a antiga em from_date - 1 (ou cancela, se reagendada desde o início).
  if p_from_date - 1 < v_old.start_date then
    update public.recurring_reservations r set status = 'CANCELLED' where r.id = v_old.id;
  else
    update public.recurring_reservations r set end_date = p_from_date - 1, has_no_end_date = false
     where r.id = v_old.id;
  end if;
  perform private.rg_fault('reschedule:after_old_update');

  -- 3) Libera as futuras da antiga (mesma transação: a anti-overlap já as vê CANCELLED).
  v_cancelled := private.rg_cancel_future(v_old.id, p_from_date);
  perform private.rg_fault('reschedule:after_cancel_future');

  -- 4) Materializa a nova (skip_conflicts = false: conflito inesperado aborta tudo — D3).
  v_mat := private.rg_materialize(v_new, p_dates, p_skip_conflicts, v_uid);
  perform private.rg_fault('reschedule:before_audit');

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_old.organization_id, v_uid, 'RECURRING_RESERVATION_UPDATED', 'recurring_reservation', v_old.id,
    jsonb_build_object(
      'rescheduled_from', p_from_date,
      'new_series', v_new.id,
      'cancelled_future', v_cancelled,
      'created', jsonb_array_length(v_mat->'created'),
      'skipped', jsonb_array_length(v_mat->'skipped'),
      'existing', jsonb_array_length(v_mat->'existing')));

  return jsonb_build_object(
    'previous_series_id', v_old.id, 'new_series_id', v_new.id, 'idempotent', false,
    'cancelled_future', v_cancelled,
    'created', v_mat->'created', 'skipped', v_mat->'skipped', 'existing', v_mat->'existing');
end $$;

-- PAUSE: status + cancelamento opcional das futuras + audit. CANCELLED -> RGR01 (D1).
create or replace function public.rg_recurring_pause(p_series_id uuid, p_cancel_future boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_series public.recurring_reservations;
  v_status_changed boolean := false;
  v_cancelled integer := 0;
begin
  v_series := private.rg_lock_series(p_series_id, true);
  if v_series.status = 'CANCELLED' then
    raise exception 'rg: mensalista cancelado não pode ser pausado' using errcode = 'RGR01';
  end if;
  if v_series.status = 'ACTIVE' then
    update public.recurring_reservations r set status = 'PAUSED' where r.id = v_series.id;
    v_status_changed := true;
  end if;
  perform private.rg_fault('pause:after_status');
  if coalesce(p_cancel_future, false) then
    v_cancelled := private.rg_cancel_future(v_series.id, private.rg_today());
  end if;
  perform private.rg_fault('pause:before_audit');
  if v_status_changed or v_cancelled > 0 then
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
    values (v_series.organization_id, v_uid, 'RECURRING_RESERVATION_PAUSED', 'recurring_reservation',
      v_series.id, jsonb_build_object('cancelled_future', v_cancelled));
  end if;
  return jsonb_build_object(
    'series_id', v_series.id, 'status', 'PAUSED',
    'changed', v_status_changed or v_cancelled > 0, 'cancelled_future', v_cancelled);
end $$;

-- CANCEL: status + cancelamento das futuras + audit. Já CANCELLED -> no-op (sem audit).
create or replace function public.rg_recurring_cancel(p_series_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_series public.recurring_reservations;
  v_cancelled integer := 0;
begin
  v_series := private.rg_lock_series(p_series_id, true);
  if v_series.status = 'CANCELLED' then
    return jsonb_build_object(
      'series_id', v_series.id, 'status', 'CANCELLED', 'changed', false, 'cancelled_future', 0);
  end if;
  update public.recurring_reservations r set status = 'CANCELLED' where r.id = v_series.id;
  perform private.rg_fault('cancel:after_status');
  v_cancelled := private.rg_cancel_future(v_series.id, private.rg_today());
  perform private.rg_fault('cancel:before_audit');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_series.organization_id, v_uid, 'RECURRING_RESERVATION_CANCELLED', 'recurring_reservation',
    v_series.id, jsonb_build_object('cancelled_future', v_cancelled));
  return jsonb_build_object(
    'series_id', v_series.id, 'status', 'CANCELLED', 'changed', true, 'cancelled_future', v_cancelled);
end $$;

-- REACTIVATE: PAUSED -> ACTIVE + materialização + audit. CANCELLED -> RGR01 (D1).
-- Já ACTIVE -> no-op. D4: skip = true só para conflito real; cada data ignorada em "skipped".
-- D10 (mantido): âncoras canceladas pelo pause continuam ocupadas e voltam em "existing".
create or replace function public.rg_recurring_reactivate(p_series_id uuid, p_dates date[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_series public.recurring_reservations;
  v_mat jsonb;
begin
  v_series := private.rg_lock_series(p_series_id, true);
  if v_series.status = 'CANCELLED' then
    raise exception 'rg: mensalista cancelado não pode ser reativado' using errcode = 'RGR01';
  end if;
  if v_series.status = 'ACTIVE' then
    return jsonb_build_object(
      'series_id', v_series.id, 'status', 'ACTIVE', 'changed', false,
      'created', '[]'::jsonb, 'skipped', '[]'::jsonb, 'existing', '[]'::jsonb);
  end if;
  update public.recurring_reservations r set status = 'ACTIVE' where r.id = v_series.id;
  v_series.status := 'ACTIVE';
  perform private.rg_fault('reactivate:after_status');
  v_mat := private.rg_materialize(v_series, p_dates, true, v_uid);
  perform private.rg_fault('reactivate:before_audit');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_series.organization_id, v_uid, 'RECURRING_RESERVATION_REACTIVATED', 'recurring_reservation',
    v_series.id, jsonb_build_object(
      'created', jsonb_array_length(v_mat->'created'),
      'skipped', jsonb_array_length(v_mat->'skipped'),
      'existing', jsonb_array_length(v_mat->'existing')));
  return jsonb_build_object(
    'series_id', v_series.id, 'status', 'ACTIVE', 'changed', true,
    'created', v_mat->'created', 'skipped', v_mat->'skipped', 'existing', v_mat->'existing');
end $$;

-- GENERATE / TOP-UP: qualquer membro ativo (D5); só ACTIVE (RGR01; o top-up automático
-- trata RGR01 como no-op); só âncoras reais na janela; sem audit (como hoje).
create or replace function public.rg_recurring_generate(p_series_id uuid, p_dates date[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_series public.recurring_reservations;
  v_mat jsonb;
begin
  v_series := private.rg_lock_series(p_series_id, false);
  if v_series.status <> 'ACTIVE' then
    raise exception 'rg: a série precisa estar ativa para gerar novas reservas' using errcode = 'RGR01';
  end if;
  v_mat := private.rg_materialize(v_series, p_dates, true, v_uid);
  return jsonb_build_object(
    'series_id', v_series.id,
    'created', v_mat->'created', 'skipped', v_mat->'skipped', 'existing', v_mat->'existing');
end $$;

-- UPDATE (PATCH simples, D9): notes / default_price / end_date / has_no_end_date + audit.
-- Top-up é chamada separada; encurtar end_date não cancela ocorrências (como hoje).
create or replace function public.rg_recurring_update(p_series_id uuid, p_changes jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_changes jsonb := coalesce(p_changes, '{}'::jsonb);
  v_series public.recurring_reservations;
  v_notes text;
  v_price integer;
  v_end_date date;
  v_no_end boolean;
begin
  if jsonb_typeof(v_changes) <> 'object' then
    raise exception 'rg: alteração não permitida' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_changes) as k
              where k not in ('notes', 'default_price', 'end_date', 'has_no_end_date')) then
    raise exception 'rg: alteração não permitida' using errcode = '22023';
  end if;
  v_series := private.rg_lock_series(p_series_id, true);
  v_notes := case when v_changes ? 'notes' then v_changes->>'notes' else v_series.notes end;
  v_price := case when v_changes ? 'default_price' then (v_changes->>'default_price')::integer else v_series.default_price end;
  v_end_date := case when v_changes ? 'end_date' then (v_changes->>'end_date')::date else v_series.end_date end;
  v_no_end := case when v_changes ? 'has_no_end_date' then (v_changes->>'has_no_end_date')::boolean else v_series.has_no_end_date end;

  if row(v_notes, v_price, v_end_date, v_no_end)
     is not distinct from row(v_series.notes, v_series.default_price, v_series.end_date, v_series.has_no_end_date) then
    return jsonb_build_object('series_id', v_series.id, 'changed', false);
  end if;

  update public.recurring_reservations r
     set notes = v_notes, default_price = v_price, end_date = v_end_date, has_no_end_date = v_no_end
   where r.id = v_series.id;
  perform private.rg_fault('update:before_audit');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id)
  values (v_series.organization_id, v_uid, 'RECURRING_RESERVATION_UPDATED', 'recurring_reservation', v_series.id);
  return jsonb_build_object('series_id', v_series.id, 'changed', true);
end $$;

-- -----------------------------------------------------------------------------
-- 5) Privilégios de tabela por COLUNA para authenticated (metadados B3 protegidos)
-- -----------------------------------------------------------------------------
-- Least privilege TRANSITÓRIO (só até o LOCKDOWN), com allowlists diferentes:
--   INSERT = 17 colunas: exatamente as dos dois INSERTs do route antigo (create e reschedule).
--            id / created_at / updated_at ficam fora e usam os defaults do banco.
--   UPDATE = 5 colunas: notes, default_price, end_date, has_no_end_date, status.
--            (PATCH, pause/reactivate/cancel e reschedule antigo). updated_at é gravado pelo
--            trigger set_recurring_updated_at, que não depende de privilégio do chamador.
-- Tudo o que não está listado — inclusive operation_id / operation_kind / operation_request /
-- previous_series_id e a estrutura da recorrência — falha com 42501 ANTES de triggers e RLS.
-- Colunas futuras nascem sem privilégio (default-deny). O LOCKDOWN revoga INSERT/UPDATE de
-- tabela, o que remove também estes privilégios de coluna.
revoke insert, update on public.recurring_reservations from authenticated;
grant insert (organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
              start_time, end_time, start_date, end_date, has_no_end_date, status, default_price,
              notes, is_demo, created_by)
  on public.recurring_reservations to authenticated;
grant update (notes, default_price, end_date, has_no_end_date, status)
  on public.recurring_reservations to authenticated;

-- SELECT: tudo menos operation_request (intenção do cliente, pode ter nome/telefone/e-mail).
-- operation_id / operation_kind / previous_series_id continuam legíveis (preflight de replay
-- e linhagem; sem PII). Requer a ETAPA 0: select('*') passa a falhar com 42501.
revoke select on public.recurring_reservations from authenticated;
grant select (id, organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
              start_time, end_time, start_date, end_date, has_no_end_date, status, default_price,
              notes, is_demo, created_by, created_at, updated_at,
              operation_id, operation_kind, previous_series_id)
  on public.recurring_reservations to authenticated;

-- -----------------------------------------------------------------------------
-- 6) Owner explícito, grants e revokes de funções
-- -----------------------------------------------------------------------------
-- O Supabase concede EXECUTE a anon/authenticated/service_role por padrão em funções novas
-- do schema public: os REVOKE explícitos abaixo são obrigatórios.

alter function private.rg_today() owner to postgres;
alter function private.rg_in_window(date) owner to postgres;
alter function private.rg_occurrence_bounds(date, time, time) owner to postgres;
alter function private.rg_is_anchor(public.recurring_reservations, date) owner to postgres;
alter function private.rg_fault(text) owner to postgres;
alter function private.rg_lock_series(uuid, boolean) owner to postgres;
alter function private.rg_customer_request(uuid, jsonb) owner to postgres;
alter function private.rg_resolve_customer(uuid, uuid, jsonb) owner to postgres;
alter function private.rg_normalize_changes(jsonb) owner to postgres;
alter function private.rg_materialize(public.recurring_reservations, date[], boolean, uuid) owner to postgres;
alter function private.rg_cancel_future(uuid, date) owner to postgres;
alter function private.enforce_recurring_occurrence() owner to postgres;
alter function private.enforce_recurring_lineage() owner to postgres;
alter function public.rg_recurring_create(uuid, uuid, uuid, uuid, jsonb, text, integer, integer, time, time, date, date, boolean, integer, text, boolean, boolean, date[]) owner to postgres;
alter function public.rg_recurring_reschedule(uuid, uuid, date, jsonb, boolean, date[]) owner to postgres;
alter function public.rg_recurring_pause(uuid, boolean) owner to postgres;
alter function public.rg_recurring_cancel(uuid) owner to postgres;
alter function public.rg_recurring_reactivate(uuid, date[]) owner to postgres;
alter function public.rg_recurring_generate(uuid, date[]) owner to postgres;
alter function public.rg_recurring_update(uuid, jsonb) owner to postgres;

-- RPCs: somente authenticated.
revoke all on function public.rg_recurring_create(uuid, uuid, uuid, uuid, jsonb, text, integer, integer, time, time, date, date, boolean, integer, text, boolean, boolean, date[]) from public, anon, service_role;
revoke all on function public.rg_recurring_reschedule(uuid, uuid, date, jsonb, boolean, date[]) from public, anon, service_role;
revoke all on function public.rg_recurring_pause(uuid, boolean) from public, anon, service_role;
revoke all on function public.rg_recurring_cancel(uuid) from public, anon, service_role;
revoke all on function public.rg_recurring_reactivate(uuid, date[]) from public, anon, service_role;
revoke all on function public.rg_recurring_generate(uuid, date[]) from public, anon, service_role;
revoke all on function public.rg_recurring_update(uuid, jsonb) from public, anon, service_role;

grant execute on function public.rg_recurring_create(uuid, uuid, uuid, uuid, jsonb, text, integer, integer, time, time, date, date, boolean, integer, text, boolean, boolean, date[]) to authenticated;
grant execute on function public.rg_recurring_reschedule(uuid, uuid, date, jsonb, boolean, date[]) to authenticated;
grant execute on function public.rg_recurring_pause(uuid, boolean) to authenticated;
grant execute on function public.rg_recurring_cancel(uuid) to authenticated;
grant execute on function public.rg_recurring_reactivate(uuid, date[]) to authenticated;
grant execute on function public.rg_recurring_generate(uuid, date[]) to authenticated;
grant execute on function public.rg_recurring_update(uuid, jsonb) to authenticated;

-- Helpers e funções de trigger privados: nenhum papel de API executa diretamente.
revoke all on function private.rg_today() from public, anon, authenticated, service_role;
revoke all on function private.rg_in_window(date) from public, anon, authenticated, service_role;
revoke all on function private.rg_occurrence_bounds(date, time, time) from public, anon, authenticated, service_role;
revoke all on function private.rg_is_anchor(public.recurring_reservations, date) from public, anon, authenticated, service_role;
revoke all on function private.rg_fault(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_lock_series(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function private.rg_customer_request(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.rg_resolve_customer(uuid, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.rg_normalize_changes(jsonb) from public, anon, authenticated, service_role;
revoke all on function private.rg_materialize(public.recurring_reservations, date[], boolean, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_cancel_future(uuid, date) from public, anon, authenticated, service_role;
revoke all on function private.enforce_recurring_occurrence() from public, anon, authenticated, service_role;
revoke all on function private.enforce_recurring_lineage() from public, anon, authenticated, service_role;

commit;

-- =============================================================================
-- VERIFICAÇÃO (somente leitura; rodar após aplicar — NÃO fazem parte da migration)
-- =============================================================================
-- 1) Colunas, constraints e índices novos:
--   select column_name, data_type, is_nullable from information_schema.columns
--    where table_schema = 'public' and table_name = 'recurring_reservations'
--      and column_name in ('operation_id', 'operation_kind', 'operation_request', 'previous_series_id');
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--    where conrelid = 'public.recurring_reservations'::regclass
--      and conname in ('recurring_previous_series_fkey', 'recurring_previous_not_self', 'recurring_operation_consistency');
--   select indexname, indexdef from pg_indexes where schemaname = 'public'
--      and indexname in ('idx_recurring_org_operation', 'idx_recurring_previous', 'idx_recurring_one_live_child');
--
-- 2) Ordem dos BEFORE ROW triggers:
--   select c.relname, t.tgname,
--          concat_ws(',', case when t.tgtype & 4 = 4 then 'INSERT' end, case when t.tgtype & 16 = 16 then 'UPDATE' end) as ev
--     from pg_trigger t join pg_class c on c.oid = t.tgrelid
--    where not t.tgisinternal and t.tgtype & 2 = 2 and c.relname in ('reservations', 'recurring_reservations')
--    order by c.relname, t.tgname;
--
-- 3) Funções B3: SECURITY DEFINER, owner, search_path e EXECUTE
--    (esperado: RPCs -> postgres + authenticated; private -> somente postgres):
--   select n.nspname || '.' || p.proname as fn, p.prosecdef, pg_get_userbyid(p.proowner) as owner, p.proconfig,
--          (select string_agg(case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end, ',')
--             from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
--            where a.privilege_type = 'EXECUTE') as exec_to
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where (n.nspname = 'public' and p.proname like 'rg\_recurring\_%')
--       or (n.nspname = 'private' and (p.proname like 'rg\_%'
--           or p.proname in ('enforce_recurring_occurrence', 'enforce_recurring_lineage')))
--    order by 1;
--
-- 4) Proteções existentes intactas:
--   select conname from pg_constraint where conrelid = 'public.reservations'::regclass
--      and conname in ('reservations_no_overlap', 'reservations_recurring_anchor');
--   select indexname from pg_indexes where indexname = 'idx_res_series_anchor';
--   select tgname from pg_trigger where tgname in ('protect_occurrence_anchor', 'validate_reservation_recurring',
--      'enforce_reservation_tenant', 'protect_recurring_links', 'validate_recurring_tenant');
--
-- 5) Privilégios de authenticated após a FOUNDATION:
--   select has_table_privilege('authenticated', 'public.recurring_reservations', 'SELECT') as tbl_sel,
--          has_table_privilege('authenticated', 'public.recurring_reservations', 'INSERT') as tbl_ins,
--          has_table_privilege('authenticated', 'public.recurring_reservations', 'UPDATE') as tbl_upd;
--   -- esperado: f, f, f (nenhum privilégio de TABELA; só por coluna)
--   select a.attname,
--          has_column_privilege('authenticated', a.attrelid, a.attnum, 'SELECT') as sel,
--          has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT') as ins,
--          has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE') as upd
--     from pg_attribute a
--    where a.attrelid = 'public.recurring_reservations'::regclass and a.attnum > 0 and not a.attisdropped
--    order by a.attnum;
--   -- esperado:
--   --   notes, default_price, end_date, has_no_end_date, status        -> sel=t ins=t upd=t
--   --   organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
--   --   start_time, end_time, start_date, is_demo, created_by           -> sel=t ins=t upd=f
--   --   id, created_at, updated_at                                       -> sel=t ins=f upd=f
--   --   operation_id, operation_kind, previous_series_id                 -> sel=t ins=f upd=f
--   --   operation_request                                                -> sel=f ins=f upd=f
--   -- (totais: INSERT = 17 colunas; UPDATE = 5 colunas; SELECT = 23 colunas)
--
-- 6) Metadados B3 forjados por authenticated (em transação descartada, como postgres):
--   begin;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<uuid de um OWNER>","role":"authenticated"}';
--   insert into public.recurring_reservations (organization_id, arena_id, court_id, frequency, weekday,
--     start_time, end_time, start_date, has_no_end_date, operation_id, operation_kind, operation_request)
--   values ('<org>', '<arena>', '<quadra>', 'WEEKLY', 2, '18:00', '19:00', current_date, true,
--     gen_random_uuid(), 'CREATE', '{}');
--     -- esperado: ERROR 42501 permission denied for table recurring_reservations
--   rollback;
--
-- 7) UPDATE estrutural direto por authenticated (mesma preparação do item 6, cada um em
--    transação descartada):
--   update public.recurring_reservations set frequency = 'MONTHLY' where id = '<série da org>';
--     -- esperado: ERROR 42501
--   update public.recurring_reservations set start_time = '20:00' where id = '<série da org>';
--     -- esperado: ERROR 42501
--   update public.recurring_reservations set created_by = '<outro uuid>' where id = '<série da org>';
--     -- esperado: ERROR 42501
--   update public.recurring_reservations set status = 'PAUSED' where id = '<série da org>';
--     -- esperado: PERMITIDO pela camada de grant durante a FOUNDATION (depois sujeito à
--     --   RLS de OWNER/MANAGER e aos triggers); vira 42501 após o LOCKDOWN.
