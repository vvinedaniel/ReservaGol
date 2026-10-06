-- =============================================================================
-- RESERVA GOL — FASE 03B.3A — MENSALISTAS: VISÃO MENSAL + RECEBIMENTO DO MÊS (banco)
-- Contrato: Product/Technical Freeze 03B.3 aprovado (W1, W2, top-up fora dos GETs, RECEPTIONIST no
-- detalhe de UM mensalista, p_expected_open).
--
-- Modelo financeiro inalterado: cada jogo = uma reserva = um snapshot de valor (reservations.price) =
-- lançamentos próprios em reservation_payments (03A). O mês só CONSOLIDA ocorrências.
--
-- Cria:
--   tabelas  public.reservation_payment_batches       (origem de um "Receber mês"; append-only)
--            public.reservation_payment_batch_items   (batch -> lançamentos 03A reais; append-only)
--   6 RPCs   rg_recurring_month_list    (OWNER/MANAGER; agregados)            — leitura pura (STABLE)
--            rg_recurring_month_search  (membro; sem valores)                  — leitura pura (STABLE)
--            rg_recurring_month_detail  (membro; UMA linhagem)                 — leitura pura (STABLE)
--            rg_recurring_month_payment_record (membro; batch atômico)
--            rg_recurring_link_customer (OWNER/MANAGER; W1: NULL -> cliente)
--            rg_recurring_month_apply_series_price (OWNER/MANAGER; W2: só price IS NULL)
-- Altera (única mudança em objeto existente):
--   private.protect_structural_links (A2): customer_id da série continua imutável, EXCETO a transição
--   NULL -> cliente feita pelo W1 (marcador transacional rg.link_customer_series = id da série).
--   Corpo original restaurado byte a byte pelo rollback (md5 conferido nos dois sentidos).
--
-- Regras centrais:
--   - Mensalista = LINHAGEM de séries (raiz = previous_series_id NULL). Mês = occurrence_date.
--   - Semântica financeira = private.rg_financials (03A), sem segunda definição. Atraso = regra 03B.1
--     (cobrável, com valor, saldo > 0 e end_at <= now()).
--   - Acesso real: vínculo ATIVO (private.rg_rm_is_member / private.rg_exp_is_manager). Sem o atalho de
--     PLATFORM_SUPER_ADMIN do is_org_member/is_org_manager.
--   - Ordem global de locks (igual B3/03A): séries da linhagem (ordem de id) -> reservas do mês (FOR UPDATE,
--     ordem de id) -> lançamentos. Toda condição é revalidada DEPOIS dos locks; idempotência antes do
--     estado mutável (replay exato devolve o batch original mesmo se o estado mudou).
--   - Nenhuma RPC/tabela da 03A, 03B.1 ou 03B.2 é alterada; reservation_payments intacta.
--
-- Uma transação. Sem IF NOT EXISTS: qualquer objeto já existente => 42710 antes de qualquer efeito.
-- Rollback: supabase/rollback_phase3b3_recurring_month.sql.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 0) Dependências + corpo esperado da função compartilhada que será estendida
-- -----------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.recurring_reservations') is null or to_regclass('public.reservations') is null
     or to_regclass('public.reservation_payments') is null or to_regclass('public.customers') is null
     or to_regclass('public.organization_members') is null or to_regclass('public.audit_logs') is null
     or to_regclass('public.idx_payments_org_operation') is null or to_regclass('public.idx_res_series_anchor') is null
     or to_regprocedure('private.rg_financials(uuid[])') is null
     or to_regprocedure('private.rg_fin_fingerprint(text, uuid, uuid, integer, text, timestamptz, text)') is null
     or to_regprocedure('private.rg_fin_notes(text)') is null
     or to_regprocedure('private.rg_customer_request(uuid, jsonb)') is null
     or to_regprocedure('private.rg_resolve_customer(uuid, uuid, jsonb)') is null
     or to_regprocedure('private.rg_is_anchor(public.recurring_reservations, date)') is null
     or to_regprocedure('private.rg_today()') is null
     or to_regprocedure('private.rg_fault(text)') is null
     or to_regprocedure('private.guard_finance_delete()') is null
     or to_regprocedure('private.rg_exp_is_manager(uuid, uuid)') is null
     or to_regprocedure('private.protect_structural_links()') is null then
    raise exception '03B.3: dependência ausente (B3 / 03A / 03B.2 / helpers compartilhados)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1) Preflight de colisão: TODOS os objetos novos, nominalmente
-- -----------------------------------------------------------------------------
do $$
declare
  v_found text[] := '{}';
  v_name text;
begin
  foreach v_name in array array['public.reservation_payment_batches', 'public.reservation_payment_batch_items'] loop
    if to_regclass(v_name) is not null or to_regtype(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  foreach v_name in array array[
    'public.reservation_payment_batches_pkey', 'public.reservation_payment_batches_id_org_key',
    'public.idx_rp_batches_org_operation', 'public.idx_rp_batches_lineage_month',
    'public.reservation_payment_batch_items_pkey', 'public.reservation_payment_batch_items_payment_key',
    'public.idx_rp_batch_items_reservation'] loop
    if to_regclass(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  select v_found || coalesce(array_agg(distinct n.nspname || '.' || p.proname || '(*)'), '{}') into v_found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search',
            'rg_recurring_month_detail', 'rg_recurring_month_payment_record', 'rg_recurring_link_customer',
            'rg_recurring_month_apply_series_price'))
      or (n.nspname = 'private' and p.proname in ('rg_rm_is_member', 'rg_rm_root', 'rg_rm_lineage', 'rg_rm_lineage_map',
            'rg_rm_month', 'rg_rm_validate_payment', 'rg_rm_fingerprint', 'rg_rm_rows', 'rg_rm_month_status',
            'rg_rm_lock_lineage', 'rg_rm_batch_result', 'enforce_payment_batch_integrity',
            'enforce_payment_batch_item_integrity', 'protect_payment_batch_record'));
  if cardinality(v_found) > 0 then
    raise exception '03B.3: objeto de destino já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;
end $$;

-- Corpo esperado da função compartilhada estendida pelo W1 (depois da colisão: reaplicar => 42710)
do $$
begin
  if (select md5(p.prosrc) from pg_proc p where p.oid = 'private.protect_structural_links()'::regprocedure)
     <> '82b84c5d95d11123949ead4928896743' then
    raise exception '03B.3: private.protect_structural_links difere do corpo A2 esperado (md5)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2) Tabelas
-- -----------------------------------------------------------------------------
-- Origem de UM "Receber mês". Não é contabilidade: o dinheiro está nos lançamentos 03A (itens).
create table public.reservation_payment_batches (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  lineage_id uuid not null,
  month date not null,
  amount integer not null,
  method text not null,
  received_at timestamptz not null,
  notes text,
  operation_id uuid not null,
  operation_fingerprint bytea not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint reservation_payment_batches_pkey primary key (id),
  constraint reservation_payment_batches_id_org_key unique (id, organization_id),
  constraint reservation_payment_batches_org_fkey foreign key (organization_id) references public.organizations(id) on delete restrict,
  constraint reservation_payment_batches_lineage_fkey foreign key (lineage_id) references public.recurring_reservations(id) on delete restrict,
  constraint reservation_payment_batches_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null,
  constraint reservation_payment_batches_month_chk check (
    extract(day from month) = 1 and month between date '2000-01-01' and date '2100-12-01'),
  constraint reservation_payment_batches_amount_chk check (amount between 1 and 100000000),
  constraint reservation_payment_batches_method_chk check (method in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER')),
  constraint reservation_payment_batches_received_at_chk check (
    received_at >= timestamptz '2000-01-01 00:00:00+00' and received_at < timestamptz '2101-01-01 00:00:00+00'),
  constraint reservation_payment_batches_notes_chk check (
    notes is null or (notes = btrim(notes) and notes <> '' and char_length(notes) <= 500)),
  constraint reservation_payment_batches_fingerprint_chk check (octet_length(operation_fingerprint) = 32)
);
create unique index idx_rp_batches_org_operation on public.reservation_payment_batches (organization_id, operation_id);
create index idx_rp_batches_lineage_month on public.reservation_payment_batches (lineage_id, month);

create table public.reservation_payment_batch_items (
  batch_id uuid not null,
  organization_id uuid not null,
  position smallint not null,
  payment_id uuid not null,
  reservation_id uuid not null,
  amount integer not null,
  constraint reservation_payment_batch_items_pkey primary key (batch_id, position),
  constraint reservation_payment_batch_items_payment_key unique (payment_id),
  constraint reservation_payment_batch_items_batch_org_fkey foreign key (batch_id, organization_id)
    references public.reservation_payment_batches(id, organization_id) on delete restrict,
  constraint reservation_payment_batch_items_payment_fkey foreign key (payment_id) references public.reservation_payments(id) on delete restrict,
  constraint reservation_payment_batch_items_reservation_fkey foreign key (reservation_id) references public.reservations(id) on delete restrict,
  constraint reservation_payment_batch_items_position_chk check (position >= 1),
  constraint reservation_payment_batch_items_amount_chk check (amount between 1 and 10000000)
);
create index idx_rp_batch_items_reservation on public.reservation_payment_batch_items (reservation_id);

-- Sem índice novo em public.reservations: EXPLAIN em dataset sintético (tests/phase3b3_explain.sql)
-- mostrou que idx_res_series_anchor + idx_reservations_org (BitmapAnd) atendem a lista mensal.

-- -----------------------------------------------------------------------------
-- 3) Funções de trigger das tabelas novas
-- -----------------------------------------------------------------------------
create function private.enforce_payment_batch_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.recurring_reservations s
                  where s.id = new.lineage_id and s.organization_id = new.organization_id and s.previous_series_id is null) then
    raise exception 'tenant_mismatch: linhagem deve ser a série raiz da mesma organização' using errcode = 'RGT01';
  end if;
  return new;
end $$;

create function private.enforce_payment_batch_item_integrity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_batch public.reservation_payment_batches;
  v_pay public.reservation_payments;
  v_res public.reservations;
begin
  select b.* into v_batch from public.reservation_payment_batches b
   where b.id = new.batch_id and b.organization_id = new.organization_id;
  if not found then
    raise exception 'tenant_mismatch: item não corresponde ao batch da organização' using errcode = 'RGT01';
  end if;
  select p.* into v_pay from public.reservation_payments p where p.id = new.payment_id;
  if not found or v_pay.organization_id <> new.organization_id or v_pay.reservation_id <> new.reservation_id
     or v_pay.kind <> 'PAYMENT' or v_pay.amount <> new.amount or v_pay.voided_at is not null then
    raise exception 'batch_item_invalid: item deve apontar para um pagamento da mesma reserva e valor' using errcode = '23514';
  end if;
  select r.* into v_res from public.reservations r where r.id = new.reservation_id;
  if v_res.organization_id <> new.organization_id
     or v_res.occurrence_date is null
     or v_res.occurrence_date < v_batch.month or v_res.occurrence_date > (v_batch.month + interval '1 month' - interval '1 day')::date
     or v_res.recurring_reservation_id is null
     or not exists (select 1 from private.rg_rm_lineage(v_batch.lineage_id) l where l.series_id = v_res.recurring_reservation_id) then
    raise exception 'batch_item_invalid: reserva fora da linhagem/mês do batch' using errcode = '23514';
  end if;
  return new;
end $$;

-- Append-only. Única mudança aceita: created_by -> NULL (FK ON DELETE SET NULL do usuário).
create function private.protect_payment_batch_record()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'reservation_payment_batches' then
    if row(new.id, new.organization_id, new.lineage_id, new.month, new.amount, new.method, new.received_at, new.notes,
           new.operation_id, new.operation_fingerprint, new.created_at)
       is distinct from row(old.id, old.organization_id, old.lineage_id, old.month, old.amount, old.method, old.received_at,
           old.notes, old.operation_id, old.operation_fingerprint, old.created_at)
       or (new.created_by is distinct from old.created_by and new.created_by is not null) then
      raise exception 'ledger_immutable: batch de recebimento não pode ser alterado' using errcode = 'RGT02';
    end if;
    return new;
  end if;
  raise exception 'ledger_immutable: item de batch não pode ser alterado' using errcode = 'RGT02';
end $$;

-- -----------------------------------------------------------------------------
-- 4) W1: protect_structural_links (A2) — exceção estreita NULL -> cliente na série
--    Só vale com o marcador transacional definido pela RPC rg_recurring_link_customer para ESTA série.
--    authenticated não tem UPDATE em recurring_reservations (LD); demais regras idênticas ao A2.
-- -----------------------------------------------------------------------------
do $do$
begin
  execute replace($fn$create or replace function private.protect_structural_links()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'structural_link_immutable: organization_id não pode ser alterado' using errcode = 'RGT02';
  end if;
  if tg_table_name in ('courts', 'business_hours', 'reservations', 'recurring_reservations') then
    if new.arena_id is distinct from old.arena_id then
      raise exception 'structural_link_immutable: arena_id não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  if tg_table_name = 'recurring_reservations' then
    if new.court_id is distinct from old.court_id then
      raise exception 'structural_link_immutable: court_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
    if new.customer_id is distinct from old.customer_id
       and not (old.customer_id is null and new.customer_id is not null
                and coalesce(current_setting('rg.link_customer_series', true), '') = new.id::text) then
      raise exception 'structural_link_immutable: customer_id da série não pode ser alterado' using errcode = 'RGT02';
    end if;
  end if;
  return new;
end $$$fn$, chr(13), '');
end $do$;

-- -----------------------------------------------------------------------------
-- 5) Helpers privados
-- -----------------------------------------------------------------------------
-- Vínculo ATIVO real (qualquer papel). Diferente de private.is_org_member: NÃO inclui admin da plataforma.
create function private.rg_rm_is_member(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_org is not null and p_user is not null and exists (
    select 1 from public.organization_members m
     where m.organization_id = p_org and m.user_id = p_user and m.status = 'ACTIVE')
$$;

-- Raiz da linhagem de qualquer série (NULL se a série não existe). previous_series_id é imutável e
-- sempre aponta para série anterior existente => sem ciclo; o teto só protege contra dado corrompido.
create function private.rg_rm_root(p_series uuid)
returns uuid language plpgsql stable set search_path = '' as $$
declare
  v_id uuid := p_series;
  v_prev uuid;
  v_steps integer := 0;
begin
  if p_series is null then
    return null;
  end if;
  loop
    select s.previous_series_id into v_prev from public.recurring_reservations s where s.id = v_id;
    if not found then
      return null;
    end if;
    exit when v_prev is null;
    v_id := v_prev;
    v_steps := v_steps + 1;
    if v_steps > 1000 then
      raise exception 'rg: linhagem de séries inválida' using errcode = '22023';
    end if;
  end loop;
  return v_id;
end $$;

-- Séries da linhagem a partir da RAIZ (vazio se p_root não é raiz).
create function private.rg_rm_lineage(p_root uuid)
returns table (series_id uuid) language sql stable set search_path = '' as $$
  with recursive l(id) as (
    select s.id from public.recurring_reservations s where s.id = p_root and s.previous_series_id is null
    union all
    select c.id from public.recurring_reservations c join l on c.previous_series_id = l.id)
  select l.id from l
$$;

-- Mapa série -> linhagem de TODA a organização (lista mensal sem N+1).
create function private.rg_rm_lineage_map(p_org uuid)
returns table (series_id uuid, lineage_id uuid) language sql stable set search_path = '' as $$
  with recursive l(id, root) as (
    select s.id, s.id from public.recurring_reservations s where s.organization_id = p_org and s.previous_series_id is null
    union all
    select c.id, l.root from public.recurring_reservations c join l on c.previous_series_id = l.id)
  select l.id, l.root from l
$$;

-- Competência YYYY-MM: primeiro dia do mês civil (America/Sao_Paulo é implícito em occurrence_date).
create function private.rg_rm_month(p_month date, out m_from date, out m_to date)
language plpgsql immutable set search_path = '' as $$
begin
  if p_month is null or extract(day from p_month) <> 1 or p_month < date '2000-01-01' or p_month > date '2100-12-01' then
    raise exception 'rg: mês inválido' using errcode = '22023';
  end if;
  m_from := p_month;
  m_to := (p_month + interval '1 month' - interval '1 day')::date;
end $$;

create function private.rg_rm_validate_payment(p_operation_id uuid, p_method text, p_amount integer, p_received_at timestamptz)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_operation_id is null then
    raise exception 'rg: operation_id é obrigatório' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('PIX', 'CASH', 'CREDIT_CARD', 'DEBIT_CARD', 'TRANSFER', 'OTHER') then
    raise exception 'rg: meio de pagamento inválido' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000000 then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  if p_received_at is null or p_received_at < timestamptz '2000-01-01 00:00:00+00'
     or p_received_at >= timestamptz '2101-01-01 00:00:00+00' then
    raise exception 'rg: data do recebimento inválida' using errcode = '22023';
  end if;
end $$;

create function private.rg_rm_fingerprint(p_lineage uuid, p_month date, p_amount integer, p_method text,
  p_received_at timestamptz, p_notes text)
returns bytea language sql stable set search_path = '' as $$
  select pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_object(
    'v', 1,
    'kind', 'RECURRING_MONTH_PAYMENT',
    'lineage_id', p_lineage,
    'month', to_char(p_month, 'YYYY-MM-DD'),
    'amount', p_amount,
    'method', p_method,
    'received_at', to_char(p_received_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'notes', p_notes)::text, 'UTF8'))
$$;

-- Ocorrências do mês de um conjunto de séries + semântica 03A (private.rg_financials) + atraso 03B.1.
create function private.rg_rm_rows(p_series uuid[], p_from date, p_to date)
returns table (
  reservation_id uuid, series_id uuid, occurrence_date date, start_at timestamptz, end_at timestamptz,
  court_id uuid, status text, is_exception boolean, price integer, amount_received bigint, amount_refunded bigint,
  net_received bigint, collectible boolean, collectible_balance bigint, payment_status text, overdue boolean)
language sql stable set search_path = '' as $$
  select r.id, r.recurring_reservation_id, r.occurrence_date, r.start_at, r.end_at, r.court_id, r.status, r.is_exception,
         f.amount_due, f.amount_received, f.amount_refunded, f.net_received, f.collectible, f.collectible_balance,
         f.payment_status,
         (f.collectible and f.amount_due is not null and f.collectible_balance > 0 and r.end_at <= now())
    from public.reservations r
    join private.rg_financials(array(
           select r2.id from public.reservations r2
            where r2.recurring_reservation_id = any(coalesce(p_series, '{}'::uuid[]))
              and r2.occurrence_date between p_from and p_to)) f on f.reservation_id = r.id
   -- mesmo filtro dos dois lados: o lado reservations usa idx_res_recurring (sem varrer a tabela)
   where r.recurring_reservation_id = any(coalesce(p_series, '{}'::uuid[]))
     and r.occurrence_date between p_from and p_to
$$;

-- Status do mês (derivado, nunca gravado). Precedência: UNPRICED > OVERDUE > PARTIAL > OPEN > PAID > NO_CHARGE.
create function private.rg_rm_month_status(p_unpriced numeric, p_open numeric, p_overdue numeric, p_net numeric, p_expected numeric)
returns text language sql immutable set search_path = '' as $$
  select case
    when coalesce(p_unpriced, 0) > 0 then 'UNPRICED'
    when coalesce(p_overdue, 0) > 0 then 'OVERDUE'
    when coalesce(p_open, 0) > 0 and coalesce(p_net, 0) > 0 then 'PARTIAL'
    when coalesce(p_open, 0) > 0 then 'OPEN'
    when coalesce(p_expected, 0) > 0 then 'PAID'
    else 'NO_CHARGE' end
$$;

-- Trava as séries da linhagem (ordem de id) e confere que a linhagem não mudou entre a leitura e o lock
-- (um reagendamento concorrente exige FOR UPDATE na série-mãe => espera este lock). Devolve as séries.
create function private.rg_rm_lock_lineage(p_root uuid, p_for_update boolean)
returns uuid[] language plpgsql volatile set search_path = '' as $$
declare
  v_before uuid[];
  v_after uuid[];
begin
  v_before := array(select l.series_id from private.rg_rm_lineage(p_root) l order by l.series_id);
  if cardinality(v_before) = 0 then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  if p_for_update then
    perform 1 from public.recurring_reservations s where s.id = any(v_before) order by s.id for update;
  else
    perform 1 from public.recurring_reservations s where s.id = any(v_before) order by s.id for share;
  end if;
  v_after := array(select l.series_id from private.rg_rm_lineage(p_root) l order by l.series_id);
  if v_after is distinct from v_before then
    raise exception 'rg: o mensalista mudou durante a operação' using errcode = 'RGP01', hint = 'STATE_CHANGED';
  end if;
  return v_after;
end $$;

-- Resultado de um batch (novo ou replay): itens + saldo atual do mês.
create function private.rg_rm_batch_result(p_batch_id uuid, p_idempotent boolean)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'batch_id', b.id,
    'lineage_id', b.lineage_id,
    'month', to_char(b.month, 'YYYY-MM-DD'),
    'amount', b.amount,
    'applied', (select coalesce(sum(i.amount), 0) from public.reservation_payment_batch_items i where i.batch_id = b.id),
    'idempotent', p_idempotent,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'position', i.position, 'reservation_id', i.reservation_id, 'occurrence_date', to_char(r.occurrence_date, 'YYYY-MM-DD'),
               'amount', i.amount, 'payment_id', i.payment_id) order by i.position)
        from public.reservation_payment_batch_items i join public.reservations r on r.id = i.reservation_id
       where i.batch_id = b.id), '[]'::jsonb),
    'open_after', (select coalesce(sum(x.collectible_balance), 0)
                     from private.rg_rm_rows(array(select l.series_id from private.rg_rm_lineage(b.lineage_id) l),
                                             b.month, (b.month + interval '1 month' - interval '1 day')::date) x))
  from public.reservation_payment_batches b where b.id = p_batch_id
$$;

-- -----------------------------------------------------------------------------
-- 6) RPCs de leitura (STABLE: não escrevem; nenhuma gera ocorrência)
-- -----------------------------------------------------------------------------
-- Lista do mês (OWNER/MANAGER). Cards = mês + arena (independem de status/busca). Paginação por cursor
-- (sem cliente por último, nome, lineage_id). Itens sem identidade de quem registrou pagamentos.
create function public.rg_recurring_month_list(p_org uuid, p_arena uuid, p_month date, p_status text, p_q text,
  p_limit integer, p_cursor jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_from date;
  v_to date;
  v_limit integer := coalesce(p_limit, 50);
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
  v_like text;
  v_digits text;
  c_nc boolean;
  c_name text;
  c_lid uuid;
  v_summary jsonb;
  v_items jsonb;
  v_more boolean;
  v_last jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_exp_is_manager(p_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;
  select m.m_from, m.m_to into v_from, v_to from private.rg_rm_month(p_month) m;
  if p_arena is not null and not exists (select 1 from public.arenas a where a.id = p_arena and a.organization_id = p_org) then
    raise exception 'rg: arena inválida' using errcode = '22023';
  end if;
  if p_status is not null and p_status not in ('ALL', 'OPEN', 'OVERDUE', 'PARTIAL', 'PAID', 'UNPRICED', 'NO_CHARGE', 'NO_CUSTOMER') then
    raise exception 'rg: filtro de situação inválido' using errcode = '22023';
  end if;
  if v_limit < 1 or v_limit > 100 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if v_q is not null and char_length(v_q) > 100 then
    raise exception 'rg: busca muito longa' using errcode = '22023';
  end if;
  if p_cursor is not null then
    if jsonb_typeof(p_cursor) <> 'object' or jsonb_typeof(p_cursor->'nc') <> 'boolean' or jsonb_typeof(p_cursor->'name') <> 'string'
       or jsonb_typeof(p_cursor->'lineage') <> 'string' then
      raise exception 'rg: cursor inválido' using errcode = '22023';
    end if;
    begin
      c_nc := (p_cursor->>'nc')::boolean;
      c_name := p_cursor->>'name';
      c_lid := (p_cursor->>'lineage')::uuid;
    exception when others then
      raise exception 'rg: cursor inválido' using errcode = '22023';
    end;
  end if;
  v_like := case when v_q is null then null
                 else '%' || replace(replace(replace(lower(v_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  v_digits := nullif(regexp_replace(coalesce(v_q, ''), '\D', '', 'g'), '');

  with lm as (
    select m.series_id, m.lineage_id from private.rg_rm_lineage_map(p_org) m
  ), occ as (
    select r.id, lm.lineage_id from public.reservations r join lm on lm.series_id = r.recurring_reservation_id
     where r.organization_id = p_org and r.recurring_reservation_id is not null
       and r.occurrence_date between v_from and v_to
  ), f as (
    select o.lineage_id, x.*, res.end_at
      from occ o
      join private.rg_financials(array(select occ.id from occ)) x on x.reservation_id = o.id
      join public.reservations res on res.id = o.id
  ), agg as (
    select f.lineage_id,
           count(*) filter (where f.status <> 'CANCELLED') as games,
           count(*) filter (where f.status = 'CANCELLED') as cancelled,
           count(*) filter (where f.collectible and f.amount_due is null) as unpriced,
           coalesce(sum(f.amount_due) filter (where f.collectible and f.amount_due is not null), 0) as expected,
           coalesce(sum(f.net_received) filter (where f.collectible), 0) as net,
           coalesce(sum(f.net_received) filter (where f.status = 'CANCELLED' and f.net_received > 0), 0) as retained,
           coalesce(sum(f.collectible_balance), 0) as open,
           coalesce(sum(f.collectible_balance) filter (where f.end_at <= now()), 0) as overdue
      from f group by f.lineage_id
  ), cur as (
    -- série atual de cada linhagem: a mais recente não cancelada (filha reagendada começa depois da mãe)
    select distinct on (lm.lineage_id) lm.lineage_id, s.*
      from lm join public.recurring_reservations s on s.id = lm.series_id
     order by lm.lineage_id, (s.status = 'CANCELLED'), s.start_date desc, s.created_at desc, s.id desc
  ), hdr as (
    select a.*, cur.id as series_id, cur.customer_id, cu.name as customer_name, cu.phone as customer_phone,
           cur.arena_id, ar.name as arena_name, cur.court_id, co.name as court_name, cur.frequency, cur.weekday,
           cur.day_of_month, cur.start_time, cur.end_time, cur.status as series_status,
           private.rg_rm_month_status(a.unpriced, a.open, a.overdue, a.net, a.expected) as month_status
      from agg a
      join cur on cur.lineage_id = a.lineage_id
      left join public.customers cu on cu.id = cur.customer_id
      left join public.arenas ar on ar.id = cur.arena_id
      left join public.courts co on co.id = cur.court_id
     where p_arena is null or cur.arena_id = p_arena
  ), filtered as (
    select h.*, (h.customer_id is null) as nc, lower(coalesce(h.customer_name, '')) as name_key
      from hdr h
     where (p_status is null or p_status = 'ALL'
            or (p_status = 'NO_CUSTOMER' and h.customer_id is null)
            or (p_status <> 'NO_CUSTOMER' and h.month_status = p_status))
       and (v_q is null or lower(coalesce(h.customer_name, '')) like v_like escape '\'
            or (v_digits is not null and char_length(v_digits) >= 4 and coalesce(h.customer_phone, '') like '%' || v_digits || '%'))
  ), page as (
    select fl.* from filtered fl
     where p_cursor is null or (fl.nc, fl.name_key, fl.lineage_id) > (c_nc, c_name, c_lid)
     order by fl.nc, fl.name_key, fl.lineage_id
     limit v_limit + 1
  )
  select
    (select jsonb_build_object(
       'lineages', count(*), 'games', coalesce(sum(h.games), 0), 'expected', coalesce(sum(h.expected), 0),
       'net', coalesce(sum(h.net), 0), 'retained', coalesce(sum(h.retained), 0), 'open', coalesce(sum(h.open), 0),
       'overdue', coalesce(sum(h.overdue), 0)) from hdr h),
    (select coalesce(jsonb_agg(jsonb_build_object(
       'lineage_id', p.lineage_id, 'series_id', p.series_id, 'customer_id', p.customer_id, 'customer_name', p.customer_name,
       'arena_id', p.arena_id, 'arena_name', p.arena_name, 'court_id', p.court_id, 'court_name', p.court_name,
       'frequency', p.frequency, 'weekday', p.weekday, 'day_of_month', p.day_of_month,
       'start_time', to_char(p.start_time, 'HH24:MI'), 'end_time', to_char(p.end_time, 'HH24:MI'), 'series_status', p.series_status,
       'games', p.games, 'cancelled', p.cancelled, 'unpriced', p.unpriced, 'expected', p.expected, 'net', p.net,
       'retained', p.retained, 'open', p.open, 'overdue', p.overdue, 'has_overdue', p.overdue > 0, 'status', p.month_status)
       order by p.nc, p.name_key, p.lineage_id), '[]'::jsonb)
       from (select * from page order by nc, name_key, lineage_id limit v_limit) p),
    (select count(*) > v_limit from page),
    (select jsonb_build_object('nc', p.nc, 'name', p.name_key, 'lineage', p.lineage_id)
       from (select * from page order by nc, name_key, lineage_id limit v_limit) p
      order by p.nc desc, p.name_key desc, p.lineage_id desc limit 1)
  into v_summary, v_items, v_more, v_last;

  return jsonb_build_object('month', to_char(v_from, 'YYYY-MM-DD'), 'summary', v_summary, 'items', v_items,
    'next_cursor', case when v_more then v_last else null end);
end $$;

-- Busca operacional (qualquer membro ativo). SEM valores financeiros: só identidade, horário e elegibilidade.
create function public.rg_recurring_month_search(p_org uuid, p_month date, p_q text, p_limit integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_from date;
  v_to date;
  v_limit integer := coalesce(p_limit, 20);
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
  v_like text;
  v_digits text;
  v_items jsonb;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_org is null or not private.rg_rm_is_member(p_org, v_uid) then
    raise exception 'rg: organização não encontrada' using errcode = 'P0002';
  end if;
  select m.m_from, m.m_to into v_from, v_to from private.rg_rm_month(p_month) m;
  if v_limit < 1 or v_limit > 20 then
    raise exception 'rg: limite inválido' using errcode = '22023';
  end if;
  if v_q is not null and char_length(v_q) > 100 then
    raise exception 'rg: busca muito longa' using errcode = '22023';
  end if;
  v_like := case when v_q is null then null
                 else '%' || replace(replace(replace(lower(v_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  v_digits := nullif(regexp_replace(coalesce(v_q, ''), '\D', '', 'g'), '');

  with lm as (
    select m.series_id, m.lineage_id from private.rg_rm_lineage_map(p_org) m
  ), occ as (
    select lm.lineage_id, count(*) filter (where r.status <> 'CANCELLED') as games
      from public.reservations r join lm on lm.series_id = r.recurring_reservation_id
     where r.organization_id = p_org and r.recurring_reservation_id is not null
       and r.occurrence_date between v_from and v_to
     group by lm.lineage_id
  ), cur as (
    select distinct on (lm.lineage_id) lm.lineage_id, s.*
      from lm join public.recurring_reservations s on s.id = lm.series_id
     order by lm.lineage_id, (s.status = 'CANCELLED'), s.start_date desc, s.created_at desc, s.id desc
  ), hdr as (
    select o.lineage_id, o.games, cur.customer_id, cu.name as customer_name, cu.phone as customer_phone,
           cur.arena_id, ar.name as arena_name, co.name as court_name, cur.frequency, cur.weekday, cur.day_of_month,
           cur.start_time, cur.end_time
      from occ o
      join cur on cur.lineage_id = o.lineage_id
      left join public.customers cu on cu.id = cur.customer_id
      left join public.arenas ar on ar.id = cur.arena_id
      left join public.courts co on co.id = cur.court_id
     where v_q is null or lower(coalesce(cu.name, '')) like v_like escape '\'
        or (v_digits is not null and char_length(v_digits) >= 4 and coalesce(cu.phone, '') like '%' || v_digits || '%')
     order by (cur.customer_id is null), lower(coalesce(cu.name, '')), o.lineage_id
     limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'lineage_id', h.lineage_id, 'customer_name', h.customer_name, 'has_customer', h.customer_id is not null,
           'arena_name', h.arena_name, 'court_name', h.court_name, 'frequency', h.frequency, 'weekday', h.weekday,
           'day_of_month', h.day_of_month, 'start_time', to_char(h.start_time, 'HH24:MI'), 'end_time', to_char(h.end_time, 'HH24:MI'),
           'games', h.games, 'eligible', h.customer_id is not null)
           order by (h.customer_id is null), lower(coalesce(h.customer_name, '')), h.lineage_id), '[]'::jsonb)
    into v_items from hdr h;
  return jsonb_build_object('month', to_char(v_from, 'YYYY-MM-DD'), 'items', v_items);
end $$;

-- Detalhe de UMA linhagem no mês (qualquer membro ativo). Aceita o id de qualquer série da linhagem.
-- RECEPTIONIST vê preço / recebido (líquido) / em aberto / status dos jogos; "retido" só para gestor.
-- Nunca devolve lançamentos individuais nem quem os registrou.
create function public.rg_recurring_month_detail(p_lineage_id uuid, p_month date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_org uuid;
  v_mgr boolean;
  v_from date;
  v_to date;
  v_series uuid[];
  v_cur public.recurring_reservations;
  v_customer jsonb;
  v_sum record;
  v_status text;
  v_blocked text;
  v_can_apply boolean;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select m.m_from, m.m_to into v_from, v_to from private.rg_rm_month(p_month) m;
  v_root := private.rg_rm_root(p_lineage_id);
  select s.organization_id into v_org from public.recurring_reservations s where s.id = v_root;
  if v_org is null or not private.rg_rm_is_member(v_org, v_uid) then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  v_mgr := private.rg_exp_is_manager(v_org, v_uid);
  v_series := array(select l.series_id from private.rg_rm_lineage(v_root) l);
  select s.* into v_cur from public.recurring_reservations s where s.id = any(v_series)
   order by (s.status = 'CANCELLED'), s.start_date desc, s.created_at desc, s.id desc limit 1;
  select case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name) end into v_customer
    from public.recurring_reservations s left join public.customers c on c.id = s.customer_id where s.id = v_cur.id;

  select count(*) filter (where x.status <> 'CANCELLED') as games,
         count(*) filter (where x.status = 'CANCELLED') as cancelled,
         count(*) filter (where x.collectible and x.price is null) as unpriced,
         coalesce(sum(x.price) filter (where x.collectible and x.price is not null), 0) as expected,
         coalesce(sum(x.net_received) filter (where x.collectible), 0) as net,
         coalesce(sum(x.net_received) filter (where x.status = 'CANCELLED' and x.net_received > 0), 0) as retained,
         coalesce(sum(x.collectible_balance), 0) as open,
         coalesce(sum(x.collectible_balance) filter (where x.overdue), 0) as overdue
    into v_sum from private.rg_rm_rows(v_series, v_from, v_to) x;
  v_status := private.rg_rm_month_status(v_sum.unpriced, v_sum.open, v_sum.overdue, v_sum.net, v_sum.expected);
  v_blocked := case when v_customer is null then 'CUSTOMER_REQUIRED'
                    when v_sum.unpriced > 0 then 'UNPRICED'
                    when v_sum.open = 0 then 'NOTHING_DUE' end;
  v_can_apply := v_mgr and exists (
    select 1 from private.rg_rm_rows(v_series, v_from, v_to) x join public.recurring_reservations s on s.id = x.series_id
     where x.collectible and x.price is null and s.default_price is not null);

  return jsonb_build_object(
    'lineage_id', v_root,
    'month', to_char(v_from, 'YYYY-MM-DD'),
    'is_manager', v_mgr,
    'customer', v_customer,
    'current', (select jsonb_build_object(
        'series_id', v_cur.id, 'status', v_cur.status, 'arena_id', v_cur.arena_id, 'arena_name', a.name,
        'court_id', v_cur.court_id, 'court_name', c.name, 'frequency', v_cur.frequency, 'weekday', v_cur.weekday,
        'day_of_month', v_cur.day_of_month, 'start_time', to_char(v_cur.start_time, 'HH24:MI'),
        'end_time', to_char(v_cur.end_time, 'HH24:MI'), 'default_price', v_cur.default_price)
      from public.arenas a, public.courts c where a.id = v_cur.arena_id and c.id = v_cur.court_id),
    'series', (select coalesce(jsonb_agg(jsonb_build_object(
        'series_id', s.id, 'status', s.status, 'start_date', to_char(s.start_date, 'YYYY-MM-DD'),
        'end_date', to_char(s.end_date, 'YYYY-MM-DD'), 'court_name', c.name, 'frequency', s.frequency,
        'start_time', to_char(s.start_time, 'HH24:MI'), 'end_time', to_char(s.end_time, 'HH24:MI'),
        'default_price', s.default_price, 'previous_series_id', s.previous_series_id)
        order by s.start_date, s.created_at, s.id), '[]'::jsonb)
      from public.recurring_reservations s join public.courts c on c.id = s.court_id where s.id = any(v_series)),
    'summary', jsonb_build_object(
        'games', v_sum.games, 'cancelled', v_sum.cancelled, 'unpriced', v_sum.unpriced, 'expected', v_sum.expected,
        'net', v_sum.net, 'retained', case when v_mgr then v_sum.retained end, 'open', v_sum.open,
        'overdue', v_sum.overdue, 'has_overdue', v_sum.overdue > 0, 'status', v_status),
    'occurrences', (select coalesce(jsonb_agg(jsonb_build_object(
        'reservation_id', x.reservation_id, 'series_id', x.series_id, 'occurrence_date', to_char(x.occurrence_date, 'YYYY-MM-DD'),
        'start_at', x.start_at, 'end_at', x.end_at, 'court_name', c.name, 'status', x.status,
        'is_exception', x.is_exception,
        'moved', (x.start_at at time zone 'America/Sao_Paulo')::date <> x.occurrence_date,
        'price', x.price, 'net_received', x.net_received, 'open', x.collectible_balance,
        'payment_status', x.payment_status, 'collectible', x.collectible, 'overdue', x.overdue)
        order by x.occurrence_date, x.start_at, x.reservation_id), '[]'::jsonb)
      from private.rg_rm_rows(v_series, v_from, v_to) x join public.courts c on c.id = x.court_id),
    'missing_future_dates', (select coalesce(jsonb_agg(to_char(d.d, 'YYYY-MM-DD') order by d.d), '[]'::jsonb)
      from (select distinct g.d::date as d
              from public.recurring_reservations s
              cross join lateral generate_series(
                greatest(v_from, private.rg_today(), s.start_date),
                least(v_to, private.rg_today() + 90, coalesce(s.end_date, v_to)), interval '1 day') g(d)
             where s.id = any(v_series) and s.status = 'ACTIVE'
               and private.rg_is_anchor(s, g.d::date)
               and not exists (select 1 from public.reservations r
                                where r.recurring_reservation_id = s.id and r.occurrence_date = g.d::date)) d),
    'eligible', v_blocked is null,
    'blocked_reason', v_blocked,
    'can_link_customer', v_mgr and v_customer is null,
    'can_apply_series_price', v_can_apply);
end $$;

-- -----------------------------------------------------------------------------
-- 7) RPCs de escrita
-- -----------------------------------------------------------------------------
-- "Receber mês": UMA operação atômica -> 1 batch + N lançamentos 03A reais (um por reserva), distribuídos
-- dos jogos mais antigos para os mais novos. operation_id do cliente pertence ao BATCH; cada lançamento
-- tem operation_id próprio. Membro ativo (RECEPTIONIST incluso, como no recebimento individual da 03A).
create function public.rg_recurring_month_payment_record(
  p_operation_id uuid, p_lineage_id uuid, p_month date, p_amount integer, p_method text,
  p_received_at timestamptz, p_notes text, p_expected_open bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_notes text;
  v_from date;
  v_to date;
  v_root uuid;
  v_org uuid;
  v_series uuid[];
  v_fp bytea;
  v_batch public.reservation_payment_batches;
  v_has_customer boolean;
  v_unpriced bigint;
  v_open bigint;
  v_left bigint;
  v_pay integer;
  v_pos smallint := 0;
  v_batch_id uuid;
  v_pid uuid;
  v_constraint text;
  v_conflict boolean := false;
  v_row record;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  perform private.rg_rm_validate_payment(p_operation_id, p_method, p_amount, p_received_at);
  v_notes := private.rg_fin_notes(p_notes);
  select m.m_from, m.m_to into v_from, v_to from private.rg_rm_month(p_month) m;
  v_root := private.rg_rm_root(p_lineage_id);
  select s.organization_id into v_org from public.recurring_reservations s where s.id = v_root;
  if v_org is null or not private.rg_rm_is_member(v_org, v_uid) then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;

  -- ordem global: séries da linhagem -> reservas do mês
  v_series := private.rg_rm_lock_lineage(v_root, false);
  perform 1 from public.reservations r
   where r.recurring_reservation_id = any(v_series) and r.occurrence_date between v_from and v_to
   order by r.id for update;

  -- idempotência antes do estado mutável
  v_fp := private.rg_rm_fingerprint(v_root, v_from, p_amount, p_method, p_received_at, v_notes);
  select b.* into v_batch from public.reservation_payment_batches b where b.organization_id = v_org and b.operation_id = p_operation_id;
  if found then
    if v_batch.operation_fingerprint = v_fp then
      return private.rg_rm_batch_result(v_batch.id, true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;

  -- estado (depois dos locks)
  select bool_or(s.customer_id is not null) into v_has_customer from public.recurring_reservations s where s.id = any(v_series);
  if not coalesce(v_has_customer, false) then
    raise exception 'rg: mensalista sem cliente cadastrado' using errcode = 'RGP01', hint = 'CUSTOMER_REQUIRED';
  end if;
  select count(*) filter (where x.collectible and x.price is null), coalesce(sum(x.collectible_balance), 0)
    into v_unpriced, v_open from private.rg_rm_rows(v_series, v_from, v_to) x;
  if v_unpriced > 0 then
    raise exception 'rg: há jogos sem valor neste mês' using errcode = 'RGP01', hint = 'UNPRICED';
  end if;
  if v_open = 0 then
    raise exception 'rg: nada a receber neste mês' using errcode = 'RGP01', hint = 'NOTHING_DUE';
  end if;
  if p_expected_open is not null and p_expected_open <> v_open then
    raise exception 'rg: o saldo do mês mudou; confira os valores' using errcode = 'RGP01', hint = 'STATE_CHANGED';
  end if;
  if p_amount > v_open then
    raise exception 'rg: valor acima do saldo do mês' using errcode = 'RGP03', hint = 'OVER_BALANCE';
  end if;

  begin
    insert into public.reservation_payment_batches (organization_id, lineage_id, month, amount, method, received_at, notes,
      operation_id, operation_fingerprint, created_by)
    values (v_org, v_root, v_from, p_amount, p_method, p_received_at, v_notes, p_operation_id, v_fp, v_uid)
    returning id into v_batch_id;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'idx_rp_batches_org_operation' then
        raise;
      end if;
      v_conflict := true;
  end;
  if v_conflict then
    select b.* into v_batch from public.reservation_payment_batches b where b.organization_id = v_org and b.operation_id = p_operation_id;
    if found and v_batch.operation_fingerprint = v_fp then
      return private.rg_rm_batch_result(v_batch.id, true);
    end if;
    raise exception 'rg: operation_id já usado com outra operação' using errcode = 'RGP02';
  end if;
  perform private.rg_fault('month_payment:after_batch');

  -- distribuição determinística: mais antigo primeiro; só o último pode ser parcial
  v_left := p_amount;
  for v_row in
    select x.reservation_id, x.collectible_balance, res.arena_id
      from private.rg_rm_rows(v_series, v_from, v_to) x join public.reservations res on res.id = x.reservation_id
     where x.collectible and x.price is not null and x.collectible_balance > 0
     order by x.occurrence_date, x.start_at, x.reservation_id
  loop
    exit when v_left = 0;
    v_pay := least(v_left, v_row.collectible_balance)::integer;
    v_pos := v_pos + 1;
    insert into public.reservation_payments (organization_id, arena_id, reservation_id, kind, refund_of, method, amount,
      received_at, notes, source, operation_id, operation_fingerprint, created_by)
    values (v_org, v_row.arena_id, v_row.reservation_id, 'PAYMENT', null, p_method, v_pay, p_received_at, v_notes, 'MANUAL',
      gen_random_uuid(), private.rg_fin_fingerprint('PAYMENT', v_row.reservation_id, null, v_pay, p_method, p_received_at, v_notes), v_uid)
    returning id into v_pid;
    insert into public.reservation_payment_batch_items (batch_id, organization_id, position, payment_id, reservation_id, amount)
    values (v_batch_id, v_org, v_pos, v_pid, v_row.reservation_id, v_pay);
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
    values (v_org, v_uid, 'PAYMENT_RECORDED', 'reservation_payment', v_pid,
      jsonb_build_object('reservation_id', v_row.reservation_id, 'amount', v_pay, 'method', p_method, 'batch_id', v_batch_id));
    perform private.rg_fault('month_payment:item_' || v_pos);
    v_left := v_left - v_pay;
  end loop;
  if v_left <> 0 then
    raise exception 'rg: distribuição do recebimento inconsistente' using errcode = 'RGP01', hint = 'STATE_CHANGED';
  end if;
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'RECURRING_MONTH_PAYMENT_RECORDED', 'reservation_payment_batch', v_batch_id,
    jsonb_build_object('lineage_id', v_root, 'month', to_char(v_from, 'YYYY-MM-DD'), 'amount', p_amount, 'method', p_method,
      'items', v_pos));
  perform private.rg_fault('month_payment:after_audit');
  return private.rg_rm_batch_result(v_batch_id, false);
end $$;

-- W1: vincula cliente a uma linhagem SEM cliente (OWNER/MANAGER). Só NULL -> cliente da mesma organização.
-- Mesma chamada repetida com o mesmo cliente => changed=false. Cliente diferente já definido => recusa.
create function public.rg_recurring_link_customer(p_lineage_id uuid, p_customer_id uuid, p_customer jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_org uuid;
  v_arena uuid;
  v_series uuid[];
  v_request jsonb;
  v_customer uuid;
  v_existing uuid[];
  v_sid uuid;
  v_occ integer;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  v_request := private.rg_customer_request(p_customer_id, p_customer);
  if v_request is null then
    raise exception 'rg: informe o cliente' using errcode = '22023';
  end if;
  v_root := private.rg_rm_root(p_lineage_id);
  select s.organization_id, s.arena_id into v_org, v_arena from public.recurring_reservations s where s.id = v_root;
  if v_org is null or not private.rg_rm_is_member(v_org, v_uid) then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão para alterar mensalista' using errcode = '42501';
  end if;
  if v_request ? 'id' and not exists (select 1 from public.customers c where c.id = p_customer_id and c.organization_id = v_org) then
    raise exception 'rg: cliente não encontrado' using errcode = 'P0002';
  end if;

  v_series := private.rg_rm_lock_lineage(v_root, true);
  v_existing := array(select distinct s.customer_id from public.recurring_reservations s
                       where s.id = any(v_series) and s.customer_id is not null);
  if cardinality(v_existing) > 0 then
    if v_request ? 'id' and cardinality(v_existing) = 1 and v_existing[1] = p_customer_id
       and not exists (select 1 from public.recurring_reservations s where s.id = any(v_series) and s.customer_id is null) then
      return jsonb_build_object('lineage_id', v_root, 'customer_id', p_customer_id, 'changed', false);
    end if;
    raise exception 'rg: mensalista já tem cliente cadastrado' using errcode = 'RGR01', hint = 'CUSTOMER_ALREADY_SET';
  end if;

  v_customer := private.rg_resolve_customer(v_org, v_arena, v_request);
  foreach v_sid in array v_series loop
    perform set_config('rg.link_customer_series', v_sid::text, true);
    update public.recurring_reservations s set customer_id = v_customer where s.id = v_sid and s.customer_id is null;
  end loop;
  perform set_config('rg.link_customer_series', '', true);
  perform private.rg_fault('link_customer:after_series');
  update public.reservations r set customer_id = v_customer
   where r.recurring_reservation_id = any(v_series) and r.customer_id is null;
  get diagnostics v_occ = row_count;
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_org, v_uid, 'RECURRING_CUSTOMER_LINKED', 'recurring_reservation', v_root,
    jsonb_build_object('lineage_id', v_root, 'customer_id', v_customer, 'series', cardinality(v_series), 'occurrences', v_occ));
  return jsonb_build_object('lineage_id', v_root, 'customer_id', v_customer, 'changed', true, 'occurrences', v_occ);
end $$;

-- W2: aplica o default_price da PRÓPRIA série às ocorrências cobráveis do mês com price IS NULL
-- (OWNER/MANAGER). Nunca sobrescreve valor existente; snapshot SERIES preservado depois. Idempotente.
create function public.rg_recurring_month_apply_series_price(p_lineage_id uuid, p_month date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_org uuid;
  v_from date;
  v_to date;
  v_series uuid[];
  v_updated integer := 0;
  v_remaining integer;
  v_row record;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select m.m_from, m.m_to into v_from, v_to from private.rg_rm_month(p_month) m;
  v_root := private.rg_rm_root(p_lineage_id);
  select s.organization_id into v_org from public.recurring_reservations s where s.id = v_root;
  if v_org is null or not private.rg_rm_is_member(v_org, v_uid) then
    raise exception 'rg: mensalista não encontrado' using errcode = 'P0002';
  end if;
  if not private.rg_exp_is_manager(v_org, v_uid) then
    raise exception 'rg: sem permissão financeira' using errcode = '42501';
  end if;

  v_series := private.rg_rm_lock_lineage(v_root, false);
  perform 1 from public.reservations r
   where r.recurring_reservation_id = any(v_series) and r.occurrence_date between v_from and v_to
   order by r.id for update;

  for v_row in
    update public.reservations res set price = s.default_price, price_source = 'SERIES'
      from public.recurring_reservations s
     where s.id = res.recurring_reservation_id and res.recurring_reservation_id = any(v_series)
       and res.occurrence_date between v_from and v_to
       and res.price is null and res.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID')
       and s.default_price is not null
    returning res.id, res.recurring_reservation_id, res.price
  loop
    v_updated := v_updated + 1;
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
    values (v_org, v_uid, 'RESERVATION_PRICE_SERIES_APPLIED', 'reservation', v_row.id,
      jsonb_build_object('old_price', null, 'new_price', v_row.price, 'new_source', 'SERIES', 'series_id', v_row.recurring_reservation_id,
        'lineage_id', v_root, 'month', to_char(v_from, 'YYYY-MM-DD')));
    perform private.rg_fault('apply_price:item_' || v_updated);
  end loop;
  select count(*) filter (where x.collectible and x.price is null) into v_remaining
    from private.rg_rm_rows(v_series, v_from, v_to) x;
  return jsonb_build_object('lineage_id', v_root, 'month', to_char(v_from, 'YYYY-MM-DD'), 'updated', v_updated,
    'remaining_unpriced', v_remaining, 'changed', v_updated > 0);
end $$;

-- -----------------------------------------------------------------------------
-- 8) Triggers das tabelas novas
-- -----------------------------------------------------------------------------
create trigger enforce_payment_batch_integrity before insert on public.reservation_payment_batches
  for each row execute function private.enforce_payment_batch_integrity();
create trigger protect_payment_batch_record before update on public.reservation_payment_batches
  for each row execute function private.protect_payment_batch_record();
create trigger guard_payment_batch_delete before delete on public.reservation_payment_batches
  for each row execute function private.guard_finance_delete();
create trigger enforce_payment_batch_item_integrity before insert on public.reservation_payment_batch_items
  for each row execute function private.enforce_payment_batch_item_integrity();
create trigger protect_payment_batch_item_record before update on public.reservation_payment_batch_items
  for each row execute function private.protect_payment_batch_record();
create trigger guard_payment_batch_item_delete before delete on public.reservation_payment_batch_items
  for each row execute function private.guard_finance_delete();

-- -----------------------------------------------------------------------------
-- 9) Owner, RLS, grants
-- -----------------------------------------------------------------------------
alter table public.reservation_payment_batches owner to postgres;
alter table public.reservation_payment_batch_items owner to postgres;
alter table public.reservation_payment_batches enable row level security;
alter table public.reservation_payment_batch_items enable row level security;
-- sem políticas: tudo negado; leitura/escrita só pelas RPCs
revoke all on table public.reservation_payment_batches from public, anon, authenticated, service_role;
revoke all on table public.reservation_payment_batch_items from public, anon, authenticated, service_role;
-- service_role: SELECT/DELETE para limpeza de organizações demo (guard_finance_delete barra não-demo).
-- Ordem de limpeza: itens -> batches -> lançamentos (FKs RESTRICT).
grant select, delete on table public.reservation_payment_batches to service_role;
grant select, delete on table public.reservation_payment_batch_items to service_role;

alter function private.enforce_payment_batch_integrity() owner to postgres;
alter function private.enforce_payment_batch_item_integrity() owner to postgres;
alter function private.protect_payment_batch_record() owner to postgres;
alter function private.rg_rm_is_member(uuid, uuid) owner to postgres;
alter function private.rg_rm_root(uuid) owner to postgres;
alter function private.rg_rm_lineage(uuid) owner to postgres;
alter function private.rg_rm_lineage_map(uuid) owner to postgres;
alter function private.rg_rm_month(date) owner to postgres;
alter function private.rg_rm_validate_payment(uuid, text, integer, timestamptz) owner to postgres;
alter function private.rg_rm_fingerprint(uuid, date, integer, text, timestamptz, text) owner to postgres;
alter function private.rg_rm_rows(uuid[], date, date) owner to postgres;
alter function private.rg_rm_month_status(numeric, numeric, numeric, numeric, numeric) owner to postgres;
alter function private.rg_rm_lock_lineage(uuid, boolean) owner to postgres;
alter function private.rg_rm_batch_result(uuid, boolean) owner to postgres;
alter function public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb) owner to postgres;
alter function public.rg_recurring_month_search(uuid, date, text, integer) owner to postgres;
alter function public.rg_recurring_month_detail(uuid, date) owner to postgres;
alter function public.rg_recurring_month_payment_record(uuid, uuid, date, integer, text, timestamptz, text, bigint) owner to postgres;
alter function public.rg_recurring_link_customer(uuid, uuid, jsonb) owner to postgres;
alter function public.rg_recurring_month_apply_series_price(uuid, date) owner to postgres;

revoke all on function private.enforce_payment_batch_integrity() from public, anon, authenticated, service_role;
revoke all on function private.enforce_payment_batch_item_integrity() from public, anon, authenticated, service_role;
revoke all on function private.protect_payment_batch_record() from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_is_member(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_root(uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_lineage(uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_lineage_map(uuid) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_month(date) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_validate_payment(uuid, text, integer, timestamptz) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_fingerprint(uuid, date, integer, text, timestamptz, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_rows(uuid[], date, date) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_month_status(numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_lock_lineage(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function private.rg_rm_batch_result(uuid, boolean) from public, anon, authenticated, service_role;

revoke all on function public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb) from public, anon, service_role;
revoke all on function public.rg_recurring_month_search(uuid, date, text, integer) from public, anon, service_role;
revoke all on function public.rg_recurring_month_detail(uuid, date) from public, anon, service_role;
revoke all on function public.rg_recurring_month_payment_record(uuid, uuid, date, integer, text, timestamptz, text, bigint) from public, anon, service_role;
revoke all on function public.rg_recurring_link_customer(uuid, uuid, jsonb) from public, anon, service_role;
revoke all on function public.rg_recurring_month_apply_series_price(uuid, date) from public, anon, service_role;

grant execute on function public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb) to authenticated;
grant execute on function public.rg_recurring_month_search(uuid, date, text, integer) to authenticated;
grant execute on function public.rg_recurring_month_detail(uuid, date) to authenticated;
grant execute on function public.rg_recurring_month_payment_record(uuid, uuid, date, integer, text, timestamptz, text, bigint) to authenticated;
grant execute on function public.rg_recurring_link_customer(uuid, uuid, jsonb) to authenticated;
grant execute on function public.rg_recurring_month_apply_series_price(uuid, date) to authenticated;

-- -----------------------------------------------------------------------------
-- 10) Conferência final
-- -----------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('rg_recurring_month_list', 'rg_recurring_month_search',
         'rg_recurring_month_detail', 'rg_recurring_month_payment_record', 'rg_recurring_link_customer',
         'rg_recurring_month_apply_series_price')) <> 6 then
    raise exception '03B.3: conferência final — RPCs públicas ausentes';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public', 'private') and p.prosecdef
                and (p.proname like 'rg_rm_%' or p.proname like 'rg_recurring_month%' or p.proname = 'rg_recurring_link_customer'
                     or p.proname in ('enforce_payment_batch_integrity', 'enforce_payment_batch_item_integrity', 'protect_payment_batch_record'))
                and not ('search_path=""' = any(coalesce(p.proconfig, '{}')))) then
    raise exception '03B.3: conferência final — SECURITY DEFINER sem search_path vazio';
  end if;
  if (select provolatile from pg_proc where oid = 'public.rg_recurring_month_list(uuid, uuid, date, text, text, integer, jsonb)'::regprocedure) <> 's'
     or (select provolatile from pg_proc where oid = 'public.rg_recurring_month_search(uuid, date, text, integer)'::regprocedure) <> 's'
     or (select provolatile from pg_proc where oid = 'public.rg_recurring_month_detail(uuid, date)'::regprocedure) <> 's' then
    raise exception '03B.3: conferência final — RPC de leitura não é STABLE';
  end if;
end $$;

commit;
