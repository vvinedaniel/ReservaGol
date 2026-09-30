-- =============================================================================
-- RESERVA GOL — FASE 03A — ROLLBACK do FIX2 (price_source e recálculo ao editar)
-- Remove os triggers/funções novos, restaura o snapshot e rg_reservation_set_price EXATAMENTE
-- como na FOUNDATION (supabase/migration_phase3a_foundation.sql) e remove a coluna price_source.
-- ATENÇÃO: descarta os valores de price_source gravados desde a aplicação do FIX2 (price e o
-- restante das reservas NÃO mudam). O guard dos GUARDS não é tocado.
-- =============================================================================
begin;

drop trigger if exists enforce_reservation_zz_price_reprice on public.reservations;
drop trigger if exists enforce_reservation_zz_price_origin_guard on public.reservations;
drop function if exists private.enforce_reservation_price_reprice();
drop function if exists private.enforce_reservation_price_origin_guard();

create or replace function private.enforce_reservation_price_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_price integer;
begin
  if new.recurring_reservation_id is not null or new.status = 'BLOCKED' or new.price is not null then
    return new;
  end if;
  select q.price into v_price from private.rg_price_quote(new.court_id, new.start_at, new.end_at) q;
  new.price := v_price;
  return new;
end $$;

create or replace function public.rg_reservation_set_price(p_reservation_id uuid, p_mode text, p_price integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_res public.reservations;
  v_new integer;
  v_rules uuid[] := '{}'::uuid[];
  v_fin record;
begin
  if v_uid is null then
    raise exception 'rg: autenticação obrigatória' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('MANUAL', 'RULE') then
    raise exception 'rg: modo inválido' using errcode = '22023';
  end if;
  if p_reason is null or p_reason not in ('CORRECTION', 'DISCOUNT', 'COURTESY', 'RULE_RECALC', 'OTHER') then
    raise exception 'rg: motivo inválido' using errcode = '22023';
  end if;
  if p_mode = 'MANUAL' and p_price is not null and (p_price < 0 or p_price > 10000000) then
    raise exception 'rg: valor inválido' using errcode = '22023';
  end if;
  v_res := private.rg_fin_lock_reservation(p_reservation_id, true);
  if v_res.status = 'BLOCKED' then
    raise exception 'rg: bloqueio de horário não tem valor' using errcode = 'RGP01', hint = 'BLOCKED';
  end if;
  if p_mode = 'RULE' then
    select q.price, q.rule_ids into v_new, v_rules from private.rg_price_quote(v_res.court_id, v_res.start_at, v_res.end_at) q;
    if v_new is null then
      raise exception 'rg: nenhuma regra de preço cobre este horário' using errcode = 'RGP01', hint = 'NO_RULE';
    end if;
  else
    v_new := p_price;
  end if;
  if v_new is not distinct from v_res.price then
    return jsonb_build_object('reservation_id', v_res.id, 'price', v_res.price, 'changed', false);
  end if;
  if v_new is null then
    select f.* into v_fin from private.rg_financials(array[v_res.id]) f;
    if v_fin.net_received > 0 then
      raise exception 'rg: reserva com valor recebido não pode ficar sem preço' using errcode = 'RGP01', hint = 'PRICE_REQUIRED';
    end if;
  end if;
  update public.reservations r set price = v_new where r.id = v_res.id;
  perform private.rg_fault('set_price:after_update');
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, metadata)
  values (v_res.organization_id, v_uid, 'RESERVATION_PRICE_SET', 'reservation', v_res.id, jsonb_build_object(
    'old_price', v_res.price, 'new_price', v_new, 'mode', p_mode, 'reason', p_reason, 'rule_ids', to_jsonb(v_rules)));
  perform private.rg_fault('set_price:after_audit');
  return jsonb_build_object('reservation_id', v_res.id, 'price', v_new, 'changed', true);
end $$;

alter function private.enforce_reservation_price_snapshot() owner to postgres;
alter function public.rg_reservation_set_price(uuid, text, integer, text) owner to postgres;
revoke all on function private.enforce_reservation_price_snapshot() from public, anon, authenticated, service_role;
revoke all on function public.rg_reservation_set_price(uuid, text, integer, text) from public, anon, service_role;
grant execute on function public.rg_reservation_set_price(uuid, text, integer, text) to authenticated;

alter table public.reservations drop constraint if exists reservations_price_source_chk;
alter table public.reservations drop column if exists price_source;

commit;
