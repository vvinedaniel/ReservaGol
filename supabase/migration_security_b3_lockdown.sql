-- =============================================================================
-- RESERVA GOL — SECURITY HARDENING B3 — LOCKDOWN (Revision 3.2: revoke explícito por coluna)
-- DRAFT PARA REVISÃO. ETAPA 4 do rollout, AINDA DENTRO da janela de manutenção
-- (iniciada na ETAPA 1). Aplicar SOMENTE depois que:
--   0) o route usar allowlist de colunas em recurring_reservations (ETAPA 0);
--   1) migration_security_b3.sql (FOUNDATION) estiver aplicada (ETAPA 1); e
--   2) route/frontend usarem exclusivamente as RPCs rg_recurring_* para mutar séries
--      (ETAPA 2), com smoke tests B3 e regressões necessárias verdes (ETAPA 3).
-- Depois de aplicar: rodar a VERIFICAÇÃO abaixo (grants + estado terminal). Só com tudo
-- verde a janela de manutenção é encerrada (ETAPA 5).
-- IDEMPOTENTE e segura para reaplicar. NÃO altera nem apaga dados.
--
-- Fecha a fronteira de segurança do B3:
--   * authenticated perde INSERT/UPDATE diretos em public.recurring_reservations
--     (SELECT continua POR COLUNA, sem operation_request, como na FOUNDATION;
--      DELETE/TRUNCATE/REFERENCES/TRIGGER continuam revogados — A3).
--     Toda mutação de série passa a ocorrer SOMENTE pelas RPCs SECURITY DEFINER do B3,
--     que rodam como o owner postgres e aplicam trava, estado, materialização e audit.
--   * CANCELLED terminal também no banco (D1), para qualquer escritor restante
--     (service_role / SQL Editor). Fica aqui, e não na foundation, porque o route antigo
--     restaura status (inclusive CANCELLED -> ACTIVE) no rollback manual do reschedule.
--   * As policies antigas de INSERT/UPDATE (OWNER/MANAGER) permanecem como defesa em
--     profundidade/documentação; sem o GRANT elas não são alcançáveis por authenticated.
--
-- Dependências verificadas por grep (repo inteiro, fora de supabase/):
--   * app/api/[[...path]]/route.js — INSERT/UPDATE diretos (create, PATCH, pause, reactivate,
--     cancel, reschedule): DEVEM migrar para as RPCs antes deste lockdown.
--   * tests/security_a2_tenant_integrity.py — PATCH direto com token de usuário e
--     Prefer: return=representation em recurring_reservations (espera RGT02 / sucesso em
--     notes/preço): JÁ a partir da FOUNDATION o RETURNING * exige SELECT em
--     operation_request e falha com 42501; após o lockdown o próprio UPDATE falha com 42501.
--     O teste deve ser atualizado junto com o route (ETAPA 2), provando "vínculo imutável"
--     via RPC/service_role.
--   * tests/phase2c_closeout.py, tests/security_a3_delete_history.py — só leitura /
--     DELETE negado: sem dependência de INSERT/UPDATE diretos.
--   * Nenhum outro código (frontend, lib, scripts) escreve em recurring_reservations.
-- service_role mantém seus grants (limpeza de fixtures dos harnesses usa a service key);
-- continua sujeito aos triggers B3 (D7, linhagem, estado terminal).
-- =============================================================================
begin;

-- 1) Fronteira: sem escrita direta de authenticated.
--    Revogação EXPLÍCITA e verificável das allowlists transitórias concedidas por coluna na
--    FOUNDATION (INSERT = 17 colunas, UPDATE = 5), seguida do REVOKE no nível da tabela.
--    (O PostgreSQL também revoga privilégios de coluna num REVOKE de tabela; a forma explícita
--    garante o resultado independentemente disso e é conferida pelos testes estáticos B3.)
revoke insert (organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
               start_time, end_time, start_date, end_date, has_no_end_date, status, default_price,
               notes, is_demo, created_by)
  on public.recurring_reservations from authenticated;
revoke update (notes, default_price, end_date, has_no_end_date, status)
  on public.recurring_reservations from authenticated;
revoke insert, update on public.recurring_reservations from authenticated;
-- Reafirma o que o A3/02C já garantiam.
revoke delete, truncate, references, trigger on public.recurring_reservations from authenticated;
revoke all on public.recurring_reservations from anon;
-- SELECT continua POR COLUNA, sem operation_request (NÃO conceder SELECT de tabela aqui:
-- isso voltaria a expor operation_request). Reafirma exatamente o grant da FOUNDATION.
grant select (id, organization_id, arena_id, court_id, customer_id, frequency, weekday, day_of_month,
              start_time, end_time, start_date, end_date, has_no_end_date, status, default_price,
              notes, is_demo, created_by, created_at, updated_at,
              operation_id, operation_kind, previous_series_id)
  on public.recurring_reservations to authenticated;

-- 2) D1 no banco: CANCELLED é terminal para qualquer escritor.
create or replace function private.enforce_recurring_terminal_state()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'CANCELLED' and new.status is distinct from 'CANCELLED' then
    raise exception 'recurring_series_terminal: mensalista cancelado não pode mudar de status'
      using errcode = 'RGR01';
  end if;
  return new;
end $$;

-- Nome com "zz_" (último BEFORE UPDATE): as validações existentes (RGT02, tenant) e a de
-- linhagem continuam disparando antes, sem mudar seus erros.
drop trigger if exists validate_recurring_zz_terminal_state on public.recurring_reservations;
create trigger validate_recurring_zz_terminal_state
  before update on public.recurring_reservations
  for each row execute function private.enforce_recurring_terminal_state();

alter function private.enforce_recurring_terminal_state() owner to postgres;
revoke all on function private.enforce_recurring_terminal_state() from public, anon, authenticated, service_role;

commit;

-- =============================================================================
-- VERIFICAÇÃO (somente leitura; rodar após aplicar — NÃO fazem parte da migration)
-- =============================================================================
-- 1) Privilégios de tabela e de coluna (esperado: nenhum privilégio de TABELA para
--    authenticated; nenhuma coluna com INSERT/UPDATE; SELECT em tudo menos operation_request):
--   select has_table_privilege('authenticated', 'public.recurring_reservations', 'INSERT') as ins,
--          has_table_privilege('authenticated', 'public.recurring_reservations', 'UPDATE') as upd,
--          has_table_privilege('authenticated', 'public.recurring_reservations', 'DELETE') as del,
--          has_table_privilege('authenticated', 'public.recurring_reservations', 'SELECT') as tbl_sel;
--          -- esperado: f, f, f, f
--   select a.attname from pg_attribute a
--    where a.attrelid = 'public.recurring_reservations'::regclass and a.attnum > 0 and not a.attisdropped
--      and (has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT')
--        or has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE'));   -- esperado: 0 linhas
--   select has_column_privilege('authenticated', 'public.recurring_reservations', 'operation_request', 'SELECT');
--          -- esperado: f
--   select count(*) filter (where has_column_privilege('authenticated', a.attrelid, a.attnum, 'SELECT')) as sel_cols,
--          count(*) filter (where has_column_privilege('authenticated', a.attrelid, a.attnum, 'INSERT')) as ins_cols,
--          count(*) filter (where has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE')) as upd_cols
--     from pg_attribute a
--    where a.attrelid = 'public.recurring_reservations'::regclass and a.attnum > 0 and not a.attisdropped;
--          -- esperado: 23, 0, 0 (SELECT exatamente como na FOUNDATION; nenhuma escrita)
--
-- 2) Demonstração (em transação descartada; como postgres, simulando um OWNER autenticado):
--   begin;
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<uuid de um OWNER>","role":"authenticated"}';
--   update public.recurring_reservations set status = 'PAUSED' where id = '<série da org>';
--     -- esperado: ERROR 42501 permission denied for table recurring_reservations
--   rollback;
--   (idem para INSERT; já via RPC: select public.rg_recurring_pause('<série>', false); -> ok)
--
-- 3) Trigger de estado terminal presente e por último no BEFORE UPDATE:
--   select t.tgname from pg_trigger t
--    where t.tgrelid = 'public.recurring_reservations'::regclass and not t.tgisinternal
--      and t.tgtype & 2 = 2 and t.tgtype & 16 = 16 order by t.tgname;
