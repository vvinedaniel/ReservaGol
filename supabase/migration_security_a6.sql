-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING A6 — rate limit persistente e distribuído
-- Rodar no SQL Editor do Supabase. IDEMPOTENTE e segura para reaplicar.
-- NÃO altera dados existentes nem objetos de A1/A2/A3/A4/A5/02C.
--
-- Substitui o limiter em memória (Map por processo) por buckets no PostgreSQL:
--   * compartilhado entre instâncias/serverless e persistente a restarts;
--   * atômico: um único INSERT ... ON CONFLICT DO UPDATE por consumo;
--   * sem PII: key_hash = HMAC-SHA256 (64 hex) calculado no servidor Node;
--   * inacessível para anon/authenticated (nem tabela, nem RPC).
--
-- ATENÇÃO (default privileges do schema public neste projeto): tabelas e funções novas
-- recebem automaticamente ALL/EXECUTE para anon e authenticated. Por isso os REVOKE
-- explícitos logo após a criação são obrigatórios.
-- =============================================================================
begin;

-- 1) Tabela de buckets (janela fixa) ---------------------------------------------
create table if not exists public.rate_limit_buckets (
  scope             text        not null,
  key_hash          text        not null,
  window_started_at timestamptz not null,
  count             bigint      not null,
  updated_at        timestamptz not null,
  constraint rate_limit_buckets_pkey primary key (scope, key_hash)
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'rate_limit_buckets_scope_chk'
                  and conrelid = 'public.rate_limit_buckets'::regclass) then
    alter table public.rate_limit_buckets add constraint rate_limit_buckets_scope_chk
      check (scope in ('public_reserve_phone', 'public_reserve_ip', 'public_reservation_lookup_ip'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rate_limit_buckets_key_hash_chk'
                  and conrelid = 'public.rate_limit_buckets'::regclass) then
    alter table public.rate_limit_buckets add constraint rate_limit_buckets_key_hash_chk
      check (key_hash ~ '^[0-9a-f]{64}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rate_limit_buckets_count_chk'
                  and conrelid = 'public.rate_limit_buckets'::regclass) then
    alter table public.rate_limit_buckets add constraint rate_limit_buckets_count_chk
      check (count >= 0);
  end if;
end $$;

-- Limpeza eficiente dos buckets antigos (ver seção 2).
create index if not exists rate_limit_buckets_updated_at_idx on public.rate_limit_buckets (updated_at);

-- RLS ativa e NENHUMA policy: anon/authenticated não leem nem escrevem linha alguma.
alter table public.rate_limit_buckets enable row level security;

-- Grants: nada para PUBLIC/anon/authenticated. service_role só SELECT/DELETE (inspeção e
-- limpeza de buckets de teste). Criação/incremento acontece apenas via RPC (SECURITY DEFINER).
revoke all on table public.rate_limit_buckets from public, anon, authenticated, service_role;
grant select, delete on table public.rate_limit_buckets to service_role;

-- 2) RPC atômica ---------------------------------------------------------------------
-- Um único INSERT ... ON CONFLICT (scope, key_hash) DO UPDATE: o PostgreSQL trava a linha do
-- bucket e reavalia o UPDATE sobre a versão mais recente, então consumos simultâneos são
-- serializados por bucket e nenhum incremento se perde (sem SELECT seguido de UPDATE).
-- Janela FIXA: se a janela expirou, count volta para 1 e window_started_at = agora;
-- senão, count = count + 1. allowed = count <= limite.
--
-- Limpeza BOUNDED (sem pg_cron, sem nova extensão): a cada chamada, apaga no máximo 100
-- buckets com updated_at < agora - 24 h (bem acima da maior janela, 600 s), pelo índice
-- updated_at, com FOR UPDATE SKIP LOCKED (nunca espera por outro request). O bucket
-- corrente acabou de receber updated_at = agora, então nunca é elegível.
--
-- SECURITY DEFINER (dono postgres) + search_path = '' + referências qualificadas.
-- Argumentos validados; erros com SQLSTATE 22023 (o backend converte em 503 genérico).
create or replace function public.consume_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
returns table (allowed boolean, remaining integer, retry_after_seconds integer, current_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now     timestamptz := pg_catalog.now();
  v_window  interval;
  v_count   bigint;
  v_started timestamptz;
begin
  if p_scope is null or p_scope not in ('public_reserve_phone', 'public_reserve_ip', 'public_reservation_lookup_ip') then
    raise exception 'consume_rate_limit: scope inválido' using errcode = '22023';
  end if;
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'consume_rate_limit: key_hash inválido' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception 'consume_rate_limit: limit inválido' using errcode = '22023';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'consume_rate_limit: window inválida' using errcode = '22023';
  end if;
  v_window := pg_catalog.make_interval(secs => p_window_seconds);

  insert into public.rate_limit_buckets as b (scope, key_hash, window_started_at, count, updated_at)
  values (p_scope, p_key_hash, v_now, 1, v_now)
  on conflict (scope, key_hash) do update
    set window_started_at = case when b.window_started_at <= v_now - v_window then v_now else b.window_started_at end,
        count             = case when b.window_started_at <= v_now - v_window then 1 else b.count + 1 end,
        updated_at        = v_now
  returning b.count, b.window_started_at into v_count, v_started;

  delete from public.rate_limit_buckets d
   where (d.scope, d.key_hash) in (
     select o.scope, o.key_hash
       from public.rate_limit_buckets o
      where o.updated_at < v_now - interval '24 hours'
      order by o.updated_at
      limit 100
      for update skip locked
   );

  allowed := v_count <= p_limit;
  remaining := greatest(p_limit - v_count, 0)::integer;
  retry_after_seconds := case
    when allowed then 0
    else greatest(1, pg_catalog.ceil(extract(epoch from (v_started + v_window - v_now)))::integer)
  end;
  current_count := v_count;
  return next;
end $$;

revoke all on function public.consume_rate_limit(text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text, text, integer, integer) to service_role;

commit;

-- -----------------------------------------------------------------------------
-- Verificação (somente leitura) após aplicar:
--   select relname, relrowsecurity from pg_class where oid = 'public.rate_limit_buckets'::regclass;
--     -> rate_limit_buckets | true
--   select grantee, string_agg(privilege_type, ',' order by privilege_type) from information_schema.table_privileges
--    where table_schema = 'public' and table_name = 'rate_limit_buckets' group by 1;
--     -> somente service_role: DELETE,SELECT (nenhuma linha para anon/authenticated/PUBLIC)
--   select count(*) from pg_policies where schemaname = 'public' and tablename = 'rate_limit_buckets';   -> 0
--   select conname, pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.rate_limit_buckets'::regclass;
--     -> pkey (scope, key_hash), scope_chk, key_hash_chk, count_chk
--   select indexname from pg_indexes where tablename = 'rate_limit_buckets';
--     -> rate_limit_buckets_pkey, rate_limit_buckets_updated_at_idx
--   select p.prosecdef, p.proconfig,
--          exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') as public_exec,
--          has_function_privilege('anon',          p.oid, 'EXECUTE') as anon_exec,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
--          has_function_privilege('service_role',  p.oid, 'EXECUTE') as service_exec
--     from pg_proc p where p.oid = 'public.consume_rate_limit(text,text,integer,integer)'::regprocedure;
--     -> true | {search_path=""} | false | false | false | true
-- -----------------------------------------------------------------------------
