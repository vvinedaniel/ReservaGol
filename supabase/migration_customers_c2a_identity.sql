-- =============================================================================
-- RESERVA GOL — CLIENTES C2A — identidade canônica, autoridades de cliente e troca explícita (banco)
-- Contrato: C1 aprovado (identidade = organização + telefone canônico BR; decisões A–D).
--
-- Cria:
--   private.rg_phone_valid / rg_phone_canonical      telefone BR canônico (DDD + número, 10/11 dígitos, sem 55)
--   private.rg_customer_name / rg_customer_email      normalização de nome/e-mail das RPCs novas
--   private.rg_customer_resolve_core                  criar-ou-reaproveitar SEGURO SOB CONCORRÊNCIA (ON CONFLICT)
--   private.rg_customer_resolve_audited               validação + núcleo + CUSTOMER_CREATED
--   public.rg_customer_resolve / rg_customer_resolve_public (service_role) / rg_customer_update /
--          rg_customer_list / rg_customer_detail / rg_reservation_change_customer
--   private.rg_protect_reservation_customer + trigger protect_reservation_customer (reservations.customer_id)
--   ux_customers_org_phone (UNIQUE parcial) · idx_reservations_customer_start · idx_customers_org_name
-- Altera (helpers PRIVADOS da B3, corpo conferido por md5 antes/depois; rollback restaura byte a byte):
--   private.rg_customer_request  telefone passa pela regra canônica (inválido => 22023 INVALID_PHONE)
--   private.rg_resolve_customer  delega ao núcleo com ON CONFLICT (sem 23505 sob concorrência)
--   => rg_recurring_create e W1 (rg_recurring_link_customer) HERDAM a regra sem mudar de corpo (decisão A).
-- NÃO cria auditoria nova nos caminhos herdados (W1/create mantêm exatamente seus efeitos auditados).
-- NÃO revoga escrita direta em customers (M2, depois do app novo). NÃO toca em dados existentes.
-- Uma transação. Reaplicar => 42710 antes de qualquer efeito. Rollback: rollback_customers_c2a_identity.sql.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 0) Dependências e preflight
-- -----------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.customers') is null or to_regclass('public.reservations') is null
     or to_regclass('public.recurring_reservations') is null or to_regclass('public.audit_logs') is null
     or to_regprocedure('private.rg_customer_request(uuid, jsonb)') is null
     or to_regprocedure('private.rg_resolve_customer(uuid, uuid, jsonb)') is null
     or to_regprocedure('private.rg_rm_is_member(uuid, uuid)') is null
     or to_regprocedure('private.rg_exp_is_manager(uuid, uuid)') is null
     or to_regprocedure('private.rg_rm_root(uuid)') is null
     or to_regprocedure('private.rg_fin_reservation_rows(uuid, uuid, timestamptz, timestamptz)') is null
     or to_regprocedure('public.rg_recurring_link_customer(uuid, uuid, jsonb)') is null then
    raise exception 'C2A: dependência ausente (B3 / 03A / 03B.3)';
  end if;
end $$;

do $$
declare
  v_found text[] := '{}';
  v_name text;
begin
  foreach v_name in array array['public.ux_customers_org_phone', 'public.idx_reservations_customer_start',
                                'public.idx_customers_org_name'] loop
    if to_regclass(v_name) is not null then v_found := v_found || v_name; end if;
  end loop;
  select v_found || coalesce(array_agg(distinct n.nspname || '.' || p.proname || '(*)'), '{}') into v_found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where (n.nspname = 'public' and p.proname in ('rg_customer_resolve', 'rg_customer_resolve_public', 'rg_customer_update',
                                                 'rg_customer_list', 'rg_customer_detail', 'rg_reservation_change_customer'))
      or (n.nspname = 'private' and p.proname in ('rg_phone_valid', 'rg_phone_canonical', 'rg_customer_name', 'rg_customer_email',
                                                  'rg_customer_resolve_core', 'rg_customer_resolve_audited',
                                                  'rg_protect_reservation_customer'));
  if exists (select 1 from pg_trigger where tgrelid = 'public.reservations'::regclass and tgname = 'protect_reservation_customer') then
    v_found := array_append(v_found, 'trigger protect_reservation_customer');
  end if;
  if cardinality(v_found) > 0 then
    raise exception 'C2A: objeto de destino já existe: %', array_to_string(v_found, ', ') using errcode = '42710';
  end if;
  -- corpos B3 esperados dos helpers que serão trocados
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure)
       <> 'e554dd93ff84c08be96a34c90775aef6'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure)
       <> 'c046a257deabd27b82381b1d8f5e99b7' then
    raise exception 'C2A: helper de cliente da B3 difere do corpo esperado (md5)';
  end if;
  -- UNIQUE de identidade: nenhuma duplicata entre telefones de 10/11 dígitos (as linhas legadas fora disso ficam intactas)
  if exists (select 1 from public.customers where phone ~ '^[0-9]{10,11}$'
              group by organization_id, phone having count(*) > 1) then
    raise exception 'C2A: há telefones de 10/11 dígitos duplicados na mesma organização — UNIQUE impossível sem limpeza (gate separado)';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1) Telefone canônico brasileiro
--    Valor canônico = DDD (lista Anatel) + número; 11 dígitos => celular (3º dígito 9); 10 => fixo (3º dígito 2–5).
--    Sem 55. Exibição/wa.me acrescentam o 55. O UNIQUE (regex 10/11 dígitos) contém todo valor canônico.
-- -----------------------------------------------------------------------------
create function private.rg_phone_valid(p_phone text)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select case
    when p_phone is null or p_phone !~ '^[0-9]{10,11}$' then false
    when substr(p_phone, 1, 2)::int <> all (array[11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 24, 27, 28,
                                                   31, 32, 33, 34, 35, 37, 38, 41, 42, 43, 44, 45, 46, 47, 48, 49,
                                                   51, 53, 54, 55, 61, 62, 63, 64, 65, 66, 67, 68, 69, 71, 73, 74, 75, 77, 79,
                                                   81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95, 96, 97, 98, 99]) then false
    when length(p_phone) = 11 then substr(p_phone, 3, 1) = '9'
    else substr(p_phone, 3, 1) between '2' and '5'
  end
$$;

-- Entrada livre -> canônico | NULL (vazio). Inválido => 22023 hint INVALID_PHONE.
--   aceita dígitos, espaço, ( ) - . e UM '+' inicial; '+' só com 55 (estrangeiro rejeitado na V1);
--   55 removido só quando prova ser código do país (12/13 dígitos) — DDD 55 (RS) com 10/11 dígitos fica;
--   um '0' de longa distância removido (11/12 dígitos começando com 0); código de operadora => inválido.
create function private.rg_phone_canonical(p_raw text)
returns text language plpgsql immutable parallel safe set search_path = '' as $$
declare
  v text;
  d text;
begin
  if p_raw is null then
    return null;
  end if;
  v := btrim(p_raw);
  if v = '' then
    return null;
  end if;
  if length(v) > 40 or v !~ '^\+?[0-9 ().-]+$' then
    raise exception 'rg: telefone inválido' using errcode = '22023', hint = 'INVALID_PHONE';
  end if;
  d := regexp_replace(v, '[^0-9]', '', 'g');
  if left(v, 1) = '+' then
    if d !~ '^55' then
      raise exception 'rg: telefone inválido (somente números brasileiros)' using errcode = '22023', hint = 'INVALID_PHONE';
    end if;
    d := substr(d, 3);
  elsif length(d) in (12, 13) and left(d, 2) = '55' then
    d := substr(d, 3);
  elsif length(d) in (11, 12) and left(d, 1) = '0' then
    d := substr(d, 2);
  end if;
  if not private.rg_phone_valid(d) then
    raise exception 'rg: telefone inválido' using errcode = '22023', hint = 'INVALID_PHONE';
  end if;
  return d;
end $$;

create function private.rg_customer_name(p_raw text)
returns text language plpgsql immutable parallel safe set search_path = '' as $$
declare
  v text := regexp_replace(btrim(coalesce(p_raw, '')), '\s+', ' ', 'g');
begin
  if v = '' or length(v) > 120 then
    raise exception 'rg: nome do cliente inválido' using errcode = '22023', hint = 'INVALID_NAME';
  end if;
  return v;
end $$;

create function private.rg_customer_email(p_raw text)
returns text language plpgsql immutable parallel safe set search_path = '' as $$
declare
  v text := lower(btrim(coalesce(p_raw, '')));
begin
  if v = '' then
    return null;
  end if;
  if length(v) > 254 or v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'rg: e-mail inválido' using errcode = '22023', hint = 'INVALID_EMAIL';
  end if;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- 2) UNIQUE de identidade + índices da V1
--    Predicado = regex 10/11 dígitos (estável, alvo de ON CONFLICT). Todo valor canônico satisfaz o predicado.
--    Linhas legadas de 11 dígitos NÃO canônicas (ex.: 3º dígito ≠ 9) também entram: são valores que a função
--    canônica nunca produz, então nunca colidem com um canônico e nunca são reaproveitadas por resolução.
-- -----------------------------------------------------------------------------
create unique index ux_customers_org_phone on public.customers (organization_id, phone)
  where phone ~ '^[0-9]{10,11}$';
create index idx_customers_org_name on public.customers (organization_id, lower(name), id);
create index idx_reservations_customer_start on public.reservations (customer_id, start_at)
  where customer_id is not null;

-- -----------------------------------------------------------------------------
-- 3) Núcleo de resolução (telefone JÁ canônico ou NULL). Seguro sob concorrência; NÃO audita.
-- -----------------------------------------------------------------------------
create function private.rg_customer_resolve_core(p_org uuid, p_arena uuid, p_name text, p_phone text, p_email text,
                                                 out customer_id uuid, out created boolean)
language plpgsql volatile set search_path = '' as $$
begin
  if p_phone is not null then
    insert into public.customers (organization_id, arena_id, name, phone, email)
    values (p_org, p_arena, p_name, p_phone, p_email)
    on conflict (organization_id, phone) where phone ~ '^[0-9]{10,11}$' do nothing
    returning id into customer_id;
    if customer_id is not null then
      created := true;
      return;
    end if;
    -- predicado repetido para o planner usar o UNIQUE parcial
    select c.id into customer_id from public.customers c
     where c.organization_id = p_org and c.phone = p_phone and c.phone ~ '^[0-9]{10,11}$';
    if customer_id is null then
      raise exception 'rg: conflito ao resolver cliente, tente novamente' using errcode = '40001';
    end if;
    created := false;
    return;
  end if;
  insert into public.customers (organization_id, arena_id, name, phone, email)
  values (p_org, p_arena, p_name, null, p_email)
  returning id into customer_id;
  created := true;
end $$;

-- -----------------------------------------------------------------------------
-- 4) Helpers B3 (troca de corpo; CR removido => md5 determinístico)
-- -----------------------------------------------------------------------------
do $do$
begin
  execute replace($fn$
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
  -- C2A: telefone canônico BR (vazio => null; inválido => 22023 INVALID_PHONE)
  return jsonb_build_object(
    'name', v_name,
    'phone', private.rg_phone_canonical(p_customer->>'phone'),
    'email', nullif(p_customer->>'email', ''));
end $$$fn$, chr(13), '');

  execute replace($fn$
create or replace function private.rg_resolve_customer(p_org uuid, p_arena uuid, p_request jsonb)
returns uuid language plpgsql volatile set search_path = '' as $$
begin
  if p_request is null then
    return null;
  end if;
  if p_request ? 'id' then
    return (p_request->>'id')::uuid;
  end if;
  -- C2A: autoridade única (organização + telefone canônico; ON CONFLICT => sem 23505 sob concorrência)
  return (select r.customer_id from private.rg_customer_resolve_core(p_org, p_arena, p_request->>'name',
                                                                     p_request->>'phone', p_request->>'email') r);
end $$$fn$, chr(13), '');
end $do$;

-- -----------------------------------------------------------------------------
-- 5) Resolução auditada (validação + núcleo + CUSTOMER_CREATED). Nunca renomeia cliente existente.
-- -----------------------------------------------------------------------------
create function private.rg_customer_resolve_audited(p_org uuid, p_arena uuid, p_name text, p_phone text, p_email text,
                                                    p_uid uuid, p_origin text)
returns jsonb language plpgsql volatile set search_path = '' as $$
declare
  v_name text := private.rg_customer_name(p_name);
  v_phone text := private.rg_phone_canonical(p_phone);
  v_email text := private.rg_customer_email(p_email);
  v_res record;
  v_existing public.customers;
begin
  if p_arena is not null and not exists (select 1 from public.arenas a where a.id = p_arena and a.organization_id = p_org) then
    raise exception 'rg: arena inválida' using errcode = '22023', hint = 'INVALID_ARENA';
  end if;
  select * into v_res from private.rg_customer_resolve_core(p_org, p_arena, v_name, v_phone, v_email);
  if v_res.created then
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
    values (p_org, p_uid, 'CUSTOMER_CREATED', 'customer', v_res.customer_id,
      jsonb_build_object('origin', p_origin, 'actor', case when p_uid is null then 'PUBLIC' else 'USER' end,
                         'has_phone', v_phone is not null, 'has_email', v_email is not null, 'arena_id', p_arena));
    return jsonb_build_object('customer_id', v_res.customer_id, 'created', true, 'name_differs', false, 'existing', null);
  end if;
  select c.* into v_existing from public.customers c where c.id = v_res.customer_id;
  return jsonb_build_object('customer_id', v_res.customer_id, 'created', false,
    'name_differs', lower(regexp_replace(btrim(v_existing.name), '\s+', ' ', 'g')) <> lower(v_name),
    'existing', jsonb_build_object('name', v_existing.name));
end $$;

-- Membro ACTIVE (qualquer papel). origin: CUSTOMERS (módulo) | RESERVATION (fluxo de reserva).
create function public.rg_customer_resolve(p_org uuid, p_name text, p_phone text default null, p_email text default null,
                                           p_arena uuid default null, p_origin text default 'CUSTOMERS')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if not private.rg_rm_is_member(p_org, v_uid) then
    raise exception 'rg: sem acesso à organização' using errcode = '42501';
  end if;
  if p_origin is null or p_origin not in ('CUSTOMERS', 'RESERVATION') then
    raise exception 'rg: origem inválida' using errcode = '22023', hint = 'INVALID_ORIGIN';
  end if;
  return private.rg_customer_resolve_audited(p_org, p_arena, p_name, p_phone, p_email, v_uid, p_origin);
end $$;

-- Caminho da reserva PÚBLICA (rota do servidor com service role; org/arena derivadas do slug no servidor).
create function public.rg_customer_resolve_public(p_org uuid, p_arena uuid, p_name text, p_phone text, p_email text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'rg: somente o servidor' using errcode = '42501';
  end if;
  if p_org is null or p_arena is null then
    raise exception 'rg: organização/arena obrigatórias' using errcode = '22023', hint = 'INVALID_ARENA';
  end if;
  return private.rg_customer_resolve_audited(p_org, p_arena, p_name, p_phone, p_email, null, 'PUBLIC');
end $$;

-- -----------------------------------------------------------------------------
-- 6) Edição do cliente (lista FECHADA de campos; controle de concorrência por updated_at; PHONE_IN_USE)
-- -----------------------------------------------------------------------------
create function public.rg_customer_update(p_customer_id uuid, p_changes jsonb, p_expected_updated_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old public.customers;
  v_new public.customers;
  v_key text;
  v_changed text[] := '{}';
  v_conflict uuid;
  v_constraint text;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select c.* into v_old from public.customers c where c.id = p_customer_id for update;
  if not found or not private.rg_rm_is_member(v_old.organization_id, v_uid) then
    raise exception 'rg: cliente não encontrado' using errcode = 'P0002';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'rg: informe as alterações' using errcode = '22023', hint = 'INVALID_FIELD';
  end if;
  for v_key in select jsonb_object_keys(p_changes) loop
    if v_key not in ('name', 'phone', 'email', 'arena_id') then
      raise exception 'rg: campo não editável: %', v_key using errcode = '22023', hint = 'INVALID_FIELD';
    end if;
  end loop;
  if p_expected_updated_at is null then
    raise exception 'rg: versão do cliente obrigatória' using errcode = '22023', hint = 'INVALID_FIELD';
  end if;
  if v_old.updated_at <> p_expected_updated_at then
    raise exception 'rg: o cliente foi alterado por outra pessoa; recarregue' using errcode = 'RGC02', hint = 'STALE_UPDATE';
  end if;

  v_new := v_old;
  if p_changes ? 'name' then v_new.name := private.rg_customer_name(p_changes->>'name'); end if;
  if p_changes ? 'phone' then v_new.phone := private.rg_phone_canonical(p_changes->>'phone'); end if;
  if p_changes ? 'email' then v_new.email := private.rg_customer_email(p_changes->>'email'); end if;
  if p_changes ? 'arena_id' then
    begin
      v_new.arena_id := nullif(p_changes->>'arena_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception 'rg: arena inválida' using errcode = '22023', hint = 'INVALID_ARENA';
    end;
    if v_new.arena_id is not null and not exists (select 1 from public.arenas a
                                                    where a.id = v_new.arena_id and a.organization_id = v_old.organization_id) then
      raise exception 'rg: arena inválida' using errcode = '22023', hint = 'INVALID_ARENA';
    end if;
  end if;
  if v_new.name is distinct from v_old.name then v_changed := array_append(v_changed, 'name'); end if;
  if v_new.phone is distinct from v_old.phone then v_changed := array_append(v_changed, 'phone'); end if;
  if v_new.email is distinct from v_old.email then v_changed := array_append(v_changed, 'email'); end if;
  if v_new.arena_id is distinct from v_old.arena_id then v_changed := array_append(v_changed, 'arena_id'); end if;
  if cardinality(v_changed) = 0 then
    return jsonb_build_object('changed', false, 'customer', to_jsonb(v_old));
  end if;

  begin
    update public.customers c
       set name = v_new.name, phone = v_new.phone, email = v_new.email, arena_id = v_new.arena_id
     where c.id = v_old.id
    returning c.* into v_new;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint <> 'ux_customers_org_phone' then
      raise;
    end if;
    select c.id into v_conflict from public.customers c
     where c.organization_id = v_old.organization_id and c.phone = v_new.phone and c.phone ~ '^[0-9]{10,11}$' and c.id <> v_old.id;
    raise exception 'rg: telefone já cadastrado para outro cliente' using errcode = 'RGC01', hint = 'PHONE_IN_USE',
      detail = coalesce(v_conflict::text, '');
  end;

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_old.organization_id, v_uid, 'CUSTOMER_UPDATED', 'customer', v_old.id, jsonb_build_object(
    'changed', to_jsonb(v_changed),
    'name_changed', 'name' = any(v_changed),
    'phone_last4', jsonb_build_object('before', right(v_old.phone, 4), 'after', right(v_new.phone, 4)),
    'email_domain', jsonb_build_object('before', nullif(split_part(coalesce(v_old.email, ''), '@', 2), ''),
                                       'after', nullif(split_part(coalesce(v_new.email, ''), '@', 2), '')),
    'arena_id', jsonb_build_object('before', v_old.arena_id, 'after', v_new.arena_id)));
  return jsonb_build_object('changed', true, 'customer', to_jsonb(v_new));
end $$;

-- -----------------------------------------------------------------------------
-- 7) Listagem (busca server-side, filtro ANTES do LIMIT, cursor por (lower(name), id))
--    fin_flag (OPEN|OVERDUE) só para OWNER/MANAGER; mesma fórmula de collectible_balance do rg_fin_reservation_rows.
-- -----------------------------------------------------------------------------
create function public.rg_customer_list(p_org uuid, p_q text default null, p_filter text default 'ALL', p_limit integer default 25,
                                        p_after_name text default null, p_after_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_manager boolean;
  v_q text := btrim(coalesce(p_q, ''));
  v_digits text;
  v_digits2 text;
  v_pat text;
  v_mode text;
  v_items jsonb;
  v_last record;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if not private.rg_rm_is_member(p_org, v_uid) then
    raise exception 'rg: sem acesso à organização' using errcode = '42501';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception 'rg: limite inválido' using errcode = '22023', hint = 'INVALID_LIMIT';
  end if;
  if p_filter is null or p_filter not in ('ALL', 'MENSALISTA', 'INACTIVE_60D') then
    raise exception 'rg: filtro inválido' using errcode = '22023', hint = 'INVALID_FILTER';
  end if;
  if (p_after_name is null) <> (p_after_id is null) then
    raise exception 'rg: cursor inválido' using errcode = '22023', hint = 'INVALID_CURSOR';
  end if;
  v_manager := private.rg_exp_is_manager(p_org, v_uid);
  if v_q <> '' then
    v_digits := regexp_replace(v_q, '[^0-9]', '', 'g');
    if length(v_digits) >= 4 then
      v_mode := 'phone';
      v_digits2 := case when length(v_digits) in (12, 13) and left(v_digits, 2) = '55' then substr(v_digits, 3) else v_digits end;
    else
      v_mode := 'name';
      v_pat := '%' || replace(replace(replace(lower(v_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
    end if;
  end if;

  with page as (
    select c.id, c.name, c.phone, c.email, c.arena_id, lower(c.name) as lname
      from public.customers c
     where c.organization_id = p_org
       and (v_mode is null
            or (v_mode = 'phone' and (c.phone like '%' || v_digits || '%' or c.phone like '%' || v_digits2 || '%'))
            or (v_mode = 'name' and lower(c.name) like v_pat escape '\'))
       and (p_after_name is null or (lower(c.name), c.id) > (p_after_name, p_after_id))
       and (p_filter <> 'MENSALISTA' or exists (select 1 from public.recurring_reservations s
                                                  where s.customer_id = c.id and s.status = 'ACTIVE'))
       and (p_filter <> 'INACTIVE_60D' or not exists (select 1 from public.reservations r
                                                        where r.customer_id = c.id and r.status not in ('CANCELLED', 'BLOCKED')
                                                          and r.start_at >= now() - interval '60 days'))
     order by lower(c.name), c.id
     limit p_limit + 1
  ), rows as (
    select p.*, row_number() over (order by p.lname, p.id) as rn from page p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'name', r.name, 'phone', r.phone, 'email', r.email, 'arena_id', r.arena_id,
           'is_mensalista', exists (select 1 from public.recurring_reservations s where s.customer_id = r.id and s.status = 'ACTIVE'),
           'next_at', (select min(x.start_at) from public.reservations x
                        where x.customer_id = r.id and x.start_at >= now() and x.status not in ('CANCELLED', 'BLOCKED')),
           'last_at', (select max(x.start_at) from public.reservations x
                        where x.customer_id = r.id and x.start_at < now() and x.status not in ('CANCELLED', 'BLOCKED')),
           'fin_flag', case when not v_manager then null else (
              select case when bool_or(f.bal > 0 and f.start_at < now()) then 'OVERDUE'
                          when bool_or(f.bal > 0) then 'OPEN' end
                from (select x.start_at,
                             x.price - coalesce((select sum(case p.kind when 'PAYMENT' then p.amount when 'REFUND' then -p.amount else 0 end)
                                                   from public.reservation_payments p
                                                  where p.reservation_id = x.id and p.voided_at is null), 0) as bal
                        from public.reservations x
                       where x.customer_id = r.id and x.price is not null
                         and x.status in ('PENDING', 'CONFIRMED', 'NO_SHOW', 'PAID')) f) end)
           order by r.lname, r.id) filter (where r.rn <= p_limit), '[]'::jsonb),
         count(*)
    into v_items, v_count
    from rows r;

  if v_count > p_limit then
    select p.lname, p.id into v_last
      from (select c.id, lower(c.name) as lname from public.customers c
             where c.id in (select (e->>'id')::uuid from jsonb_array_elements(v_items) e)) p
     order by p.lname desc, p.id desc limit 1;
    return jsonb_build_object('items', v_items, 'next_cursor', jsonb_build_object('after_name', v_last.lname, 'after_id', v_last.id));
  end if;
  return jsonb_build_object('items', v_items, 'next_cursor', null);
end $$;

-- -----------------------------------------------------------------------------
-- 8) Ficha (cadastro, próximas, histórico paginado, séries; financeiro SÓ OWNER/MANAGER via 03A)
-- -----------------------------------------------------------------------------
create function public.rg_customer_detail(p_customer_id uuid, p_history_before timestamptz default null,
                                          p_history_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_c public.customers;
  v_history jsonb;
  v_next_before timestamptz;
  v_hcount integer;
  v_fin jsonb := null;
  v_from timestamptz := now() - interval '365 days';
  v_to timestamptz := now() + interval '120 days';
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  select c.* into v_c from public.customers c where c.id = p_customer_id;
  if not found or not private.rg_rm_is_member(v_c.organization_id, v_uid) then
    raise exception 'rg: cliente não encontrado' using errcode = 'P0002';
  end if;
  if p_history_limit is null or p_history_limit < 1 or p_history_limit > 50 then
    raise exception 'rg: limite inválido' using errcode = '22023', hint = 'INVALID_LIMIT';
  end if;

  with h as (
    select r.id, r.start_at, r.end_at, r.status, r.source, r.court_id, r.arena_id, r.recurring_reservation_id, r.occurrence_date
      from public.reservations r
     where r.customer_id = v_c.id and r.start_at < now()
       and (p_history_before is null or r.start_at < p_history_before)
     order by r.start_at desc, r.id desc
     limit p_history_limit + 1
  ), n as (select h.*, row_number() over (order by h.start_at desc, h.id desc) as rn from h)
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'start_at', n.start_at, 'end_at', n.end_at, 'status', n.status,
                                               'source', n.source, 'arena_id', n.arena_id,
                                               'court', (select jsonb_build_object('id', co.id, 'name', co.name) from public.courts co where co.id = n.court_id),
                                               'recurring_reservation_id', n.recurring_reservation_id, 'occurrence_date', n.occurrence_date)
                            order by n.start_at desc, n.id desc) filter (where n.rn <= p_history_limit), '[]'::jsonb),
         count(*), min(n.start_at) filter (where n.rn <= p_history_limit)
    into v_history, v_hcount, v_next_before
    from n;

  if private.rg_exp_is_manager(v_c.organization_id, v_uid) then
    select jsonb_build_object(
             'period', jsonb_build_object('from', v_from, 'to', v_to),
             'expected', coalesce(sum(f.amount_due) filter (where f.collectible and f.amount_due is not null), 0),
             'unpriced_count', count(*) filter (where f.collectible and f.amount_due is null),
             'received', coalesce(sum(f.net_received), 0),
             'open', coalesce(sum(f.collectible_balance), 0),
             'overdue', coalesce(sum(f.collectible_balance) filter (where f.start_at < now()), 0),
             'by_status', coalesce((select jsonb_object_agg(s.payment_status, s.n) from (
                 select g.payment_status, count(*) as n
                   from private.rg_fin_reservation_rows(v_c.organization_id, null, v_from, v_to) g
                  where g.customer_id = v_c.id group by g.payment_status) s), '{}'::jsonb))
      into v_fin
      from private.rg_fin_reservation_rows(v_c.organization_id, null, v_from, v_to) f
     where f.customer_id = v_c.id;
  end if;

  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_c.id, 'name', v_c.name, 'phone', v_c.phone, 'email', v_c.email,
                                   'arena', (select jsonb_build_object('id', a.id, 'name', a.name) from public.arenas a where a.id = v_c.arena_id),
                                   'created_at', v_c.created_at, 'updated_at', v_c.updated_at),
    'upcoming', coalesce((select jsonb_agg(u.j order by u.start_at, u.id) from (
        select r.start_at, r.id, jsonb_build_object('id', r.id, 'start_at', r.start_at, 'end_at', r.end_at, 'status', r.status,
                 'source', r.source, 'arena_id', r.arena_id,
                 'court', (select jsonb_build_object('id', co.id, 'name', co.name) from public.courts co where co.id = r.court_id),
                 'recurring_reservation_id', r.recurring_reservation_id, 'occurrence_date', r.occurrence_date) as j
          from public.reservations r
         where r.customer_id = v_c.id and r.start_at >= now() and r.status not in ('CANCELLED', 'BLOCKED')
         order by r.start_at, r.id limit 10) u), '[]'::jsonb),
    'history', v_history,
    'history_next_before', case when v_hcount > p_history_limit then v_next_before end,
    'series', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', s.id, 'lineage_id', private.rg_rm_root(s.id), 'status', s.status, 'frequency', s.frequency,
                 'weekday', s.weekday, 'day_of_month', s.day_of_month, 'start_time', s.start_time, 'end_time', s.end_time,
                 'start_date', s.start_date, 'end_date', s.end_date, 'has_no_end_date', s.has_no_end_date,
                 'court', (select jsonb_build_object('id', co.id, 'name', co.name) from public.courts co where co.id = s.court_id))
               order by (s.status = 'ACTIVE') desc, s.created_at desc)
          from public.recurring_reservations s where s.customer_id = v_c.id), '[]'::jsonb),
    'finance', v_fin);
end $$;

-- -----------------------------------------------------------------------------
-- 9) Troca EXPLÍCITA do cliente de uma reserva (única autoridade; atômica; auditada)
--    Só reserva avulsa (não ocorrência de série), não bloqueio, não cancelada. NULL não é permitido (V1).
--    Idempotente: cliente já igual => changed=false (antes da checagem de estado obsoleto).
-- -----------------------------------------------------------------------------
create function public.rg_reservation_change_customer(p_reservation_id uuid, p_customer_id uuid, p_expected_customer_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_res public.reservations;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_customer_id is null then
    raise exception 'rg: informe o novo cliente' using errcode = '22023', hint = 'CUSTOMER_REQUIRED';
  end if;
  select r.* into v_res from public.reservations r where r.id = p_reservation_id for update;
  if not found or not private.rg_rm_is_member(v_res.organization_id, v_uid) then
    raise exception 'rg: reserva não encontrada' using errcode = 'P0002';
  end if;
  if v_res.recurring_reservation_id is not null then
    raise exception 'rg: o cliente de uma ocorrência de mensalista é o da série' using errcode = 'RGC03', hint = 'RECURRING_OCCURRENCE';
  end if;
  if v_res.status = 'BLOCKED' then
    raise exception 'rg: bloqueio de horário não tem cliente' using errcode = 'RGC04', hint = 'BLOCKED_SLOT';
  end if;
  if v_res.status = 'CANCELLED' then
    raise exception 'rg: reserva cancelada não troca de cliente' using errcode = 'RGC05', hint = 'CANCELLED_RESERVATION';
  end if;
  if v_res.customer_id is not distinct from p_customer_id then
    return jsonb_build_object('reservation_id', v_res.id, 'customer_id', p_customer_id, 'changed', false);
  end if;
  if v_res.customer_id is distinct from p_expected_customer_id then
    raise exception 'rg: a reserva foi alterada por outra pessoa; recarregue' using errcode = 'RGC02', hint = 'STALE_UPDATE';
  end if;
  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.organization_id = v_res.organization_id) then
    raise exception 'rg: cliente não encontrado' using errcode = 'P0002', hint = 'CUSTOMER_NOT_FOUND';
  end if;

  perform set_config('rg.change_reservation_customer', v_res.id::text, true);
  update public.reservations r set customer_id = p_customer_id where r.id = v_res.id;
  perform set_config('rg.change_reservation_customer', '', true);

  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'RESERVATION_CUSTOMER_CHANGED', 'reservation', v_res.id,
    jsonb_build_object('before_customer_id', v_res.customer_id, 'after_customer_id', p_customer_id));
  return jsonb_build_object('reservation_id', v_res.id, 'customer_id', p_customer_id, 'changed', true);
end $$;

-- -----------------------------------------------------------------------------
-- 10) Proteção estrutural de reservations.customer_id (todo papel)
--     Permitido somente: (a) troca explícita (marcador transacional da RPC acima);
--     (b) ocorrência NULL -> cliente DA PRÓPRIA SÉRIE (W1 / alinhamento estrutural); (c) ON DELETE SET NULL do cliente.
-- -----------------------------------------------------------------------------
create function private.rg_protect_reservation_customer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.customer_id is not distinct from old.customer_id then
    return new;
  end if;
  if coalesce(current_setting('rg.change_reservation_customer', true), '') = new.id::text then
    return new;
  end if;
  if old.customer_id is null and new.customer_id is not null and new.recurring_reservation_id is not null
     and exists (select 1 from public.recurring_reservations s
                  where s.id = new.recurring_reservation_id and s.customer_id = new.customer_id) then
    return new;
  end if;
  if new.customer_id is null and old.customer_id is not null
     and not exists (select 1 from public.customers c where c.id = old.customer_id) then
    return new;
  end if;
  raise exception 'structural_link_immutable: o cliente da reserva só muda pela troca explícita de cliente'
    using errcode = 'RGT02', hint = 'USE_CHANGE_CUSTOMER';
end $$;

create trigger protect_reservation_customer
  before update of customer_id on public.reservations
  for each row execute function private.rg_protect_reservation_customer();

-- -----------------------------------------------------------------------------
-- 11) Owner e privilégios (rotina nova nasce executável por PUBLIC => revogar tudo e conceder o mínimo)
-- -----------------------------------------------------------------------------
alter function private.rg_phone_valid(text) owner to postgres;
alter function private.rg_phone_canonical(text) owner to postgres;
alter function private.rg_customer_name(text) owner to postgres;
alter function private.rg_customer_email(text) owner to postgres;
alter function private.rg_customer_resolve_core(uuid, uuid, text, text, text) owner to postgres;
alter function private.rg_customer_resolve_audited(uuid, uuid, text, text, text, uuid, text) owner to postgres;
alter function private.rg_protect_reservation_customer() owner to postgres;
alter function public.rg_customer_resolve(uuid, text, text, text, uuid, text) owner to postgres;
alter function public.rg_customer_resolve_public(uuid, uuid, text, text, text) owner to postgres;
alter function public.rg_customer_update(uuid, jsonb, timestamptz) owner to postgres;
alter function public.rg_customer_list(uuid, text, text, integer, text, uuid) owner to postgres;
alter function public.rg_customer_detail(uuid, timestamptz, integer) owner to postgres;
alter function public.rg_reservation_change_customer(uuid, uuid, uuid) owner to postgres;

revoke all on function private.rg_phone_valid(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_phone_canonical(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_customer_name(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_customer_email(text) from public, anon, authenticated, service_role;
revoke all on function private.rg_customer_resolve_core(uuid, uuid, text, text, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_customer_resolve_audited(uuid, uuid, text, text, text, uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.rg_protect_reservation_customer() from public, anon, authenticated, service_role;
revoke all on function public.rg_customer_resolve(uuid, text, text, text, uuid, text) from public, anon, service_role;
revoke all on function public.rg_customer_resolve_public(uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.rg_customer_update(uuid, jsonb, timestamptz) from public, anon, service_role;
revoke all on function public.rg_customer_list(uuid, text, text, integer, text, uuid) from public, anon, service_role;
revoke all on function public.rg_customer_detail(uuid, timestamptz, integer) from public, anon, service_role;
revoke all on function public.rg_reservation_change_customer(uuid, uuid, uuid) from public, anon, service_role;
grant execute on function public.rg_customer_resolve(uuid, text, text, text, uuid, text) to authenticated;
grant execute on function public.rg_customer_resolve_public(uuid, uuid, text, text, text) to service_role;
grant execute on function public.rg_customer_update(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.rg_customer_list(uuid, text, text, integer, text, uuid) to authenticated;
grant execute on function public.rg_customer_detail(uuid, timestamptz, integer) to authenticated;
grant execute on function public.rg_reservation_change_customer(uuid, uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 12) Pós-condições
-- -----------------------------------------------------------------------------
do $$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure)
       <> '0e70211cb4d03be0e9925de46a6deeee'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure)
       <> '5ce683d04fd7bda5a3ec42c18c71de6f' then
    raise exception 'C2A: helper de cliente resultou em corpo inesperado (md5)';
  end if;
end $$;

commit;
