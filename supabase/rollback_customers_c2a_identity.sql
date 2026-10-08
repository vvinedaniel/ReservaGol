-- =============================================================================
-- RESERVA GOL — CLIENTES C2A — ROLLBACK
-- 1. recusa rodar se os helpers não forem exatamente os do C2A (md5);
-- 2. restaura BYTE A BYTE os corpos B3 de private.rg_customer_request (e554dd93…) e private.rg_resolve_customer (c046a257…);
-- 3. remove trigger/funções/RPCs/índices novos.
-- NÃO apaga clientes, NÃO altera reservas, NÃO apaga auditoria, NÃO toca no cron. Dados criados pelo C2A permanecem.
-- =============================================================================
begin;

do $$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure)
       <> '0e70211cb4d03be0e9925de46a6deeee'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure)
       <> '5ce683d04fd7bda5a3ec42c18c71de6f' then
    raise exception 'C2A rollback: helpers atuais diferem dos corpos C2A (md5) — rollback manual necessário';
  end if;
end $$;

-- 1) helpers B3 originais (antes de remover as funções das quais o corpo C2A depende)
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
  return jsonb_build_object(
    'name', v_name,
    'phone', nullif(regexp_replace(coalesce(p_customer->>'phone', ''), '\D', '', 'g'), ''),
    'email', nullif(p_customer->>'email', ''));
end $$$fn$, chr(13), '');

  execute replace($fn$
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
end $$$fn$, chr(13), '');
end $do$;

do $$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_customer_request(uuid, jsonb)'::regprocedure)
       <> 'e554dd93ff84c08be96a34c90775aef6'
     or (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'private.rg_resolve_customer(uuid, uuid, jsonb)'::regprocedure)
       <> 'c046a257deabd27b82381b1d8f5e99b7' then
    raise exception 'C2A rollback: helper B3 restaurado difere do corpo original (md5)';
  end if;
end $$;

-- 2) proteção, RPCs, helpers e índices novos
drop trigger protect_reservation_customer on public.reservations;
drop function private.rg_protect_reservation_customer();
drop function public.rg_reservation_change_customer(uuid, uuid, uuid);
drop function public.rg_customer_detail(uuid, timestamptz, integer);
drop function public.rg_customer_list(uuid, text, text, integer, text, uuid);
drop function public.rg_customer_update(uuid, jsonb, timestamptz);
drop function public.rg_customer_resolve_public(uuid, uuid, text, text, text);
drop function public.rg_customer_resolve(uuid, text, text, text, uuid, text);
drop function private.rg_customer_resolve_audited(uuid, uuid, text, text, text, uuid, text);
drop function private.rg_customer_resolve_core(uuid, uuid, text, text, text);
drop function private.rg_customer_email(text);
drop function private.rg_customer_name(text);
drop function private.rg_phone_canonical(text);
drop function private.rg_phone_valid(text);
drop index public.idx_reservations_customer_start;
drop index public.idx_customers_org_name;
drop index public.ux_customers_org_phone;

commit;
