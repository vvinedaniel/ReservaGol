#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A3 — DELETE físico, grants e histórico.

Rodar SOMENTE depois de aplicar supabase/migration_security_a3.sql.

Cria UMA organização nova e isolada (is_demo) com OWNER, MANAGER e RECEPTIONIST efêmeros,
arena, quadras, cliente, reserva e série recorrente, e testa DIRETO no PostgREST com o
token de cada papel (o mesmo acesso de qualquer navegador logado) e pela API do app.

As checagens de TRUNCATE/TRIGGER/REFERENCES são feitas pelo catálogo (SQL somente leitura
listado no fim de supabase/migration_security_a3.sql), pois o PostgREST não expõe TRUNCATE.

Os testes de FK (seção F) tentam apagar, com service role, quadra/arena/organização QUE TÊM
histórico e devem falhar por RESTRICT. Por segurança só rodam se o bloco D confirmar que a
migration está aplicada; nunca tocam dados fora da organização criada por este teste.

Variáveis de ambiente obrigatórias (nenhum valor é impresso):
  BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcional: TEST_EMAIL_DOMAIN (padrão reservagol.test)

Uso: python tests/security_a3_delete_history.py
"""
import atexit
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from harness_cleanup import FixtureTracker
from datetime import datetime, timedelta, timezone

REQUIRED = ['BASE_URL', 'SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'TEST_ACCOUNT_PASSWORD']
missing = [k for k in REQUIRED if not os.environ.get(k)]
if missing:
    print('Variáveis de ambiente ausentes: ' + ', '.join(missing))
    sys.exit(2)

BASE = os.environ['BASE_URL'].rstrip('/') + '/api'
SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
SP = timezone(timedelta(hours=-3))
RUN = uuid.uuid4().hex[:8]
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
results = {}
# Limpeza verificável (created/cleaned/residual): só o que ESTA execução criou.
FX = FixtureTracker(SB, SECRET)
atexit.register(FX.cleanup)


def http(method, url, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw, status = r.read().decode(), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(), e.code
    try:
        return status, (json.loads(raw) if raw else None), raw
    except ValueError:
        return status, None, raw


def api(method, path, token=None, body=None):
    return http(method, BASE + path, {'Authorization': f'Bearer {token}'} if token else {}, body)


def rest(method, table, token, body=None, query=''):
    h = {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}', 'Prefer': 'return=representation'}
    return http(method, f'{SB}/rest/v1/{table}{query}', h, body)


def svc(method, table, body=None, query=''):
    return http(method, f'{SB}/rest/v1/{table}{query}', {**SVC, 'Prefer': 'return=representation'}, body)


def exists(table, row_id):
    s, b, raw = svc('GET', table, query=f'?id=eq.{row_id}&select=id')
    assert s == 200, f'svc {table} {s} {raw[:160]}'
    return len(b) == 1


def create_user(label):
    email = f'a3-{label}-{RUN}@{DOMAIN}'
    s, b, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    FX.user(b['id'])
    s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    return b['id'], t['access_token']


def check(name, fn):
    try:
        fn()
        results[name] = 'PASS'
        print(f'PASS  {name}')
    except AssertionError as e:
        results[name] = 'FAIL'
        print(f'FAIL  {name}: {e}')
    except Exception as e:  # noqa: BLE001
        results[name] = 'ERROR'
        print(f'ERROR {name}: {type(e).__name__}: {e}')


def denied_delete(token, table, row_id, who):
    s, b, raw = rest('DELETE', table, token, query=f'?id=eq.{row_id}')
    assert s in (401, 403), f'{who} DELETE {table}: esperado 401/403 (sem privilégio), veio {s} {raw[:160]}'
    assert exists(table, row_id), f'{who} DELETE {table}: linha sumiu'


def rgt(s, b, raw, code, what):
    assert s == 400 and isinstance(b, dict) and b.get('code') == code, f'{what}: esperado 400/{code}, veio {s} {raw[:160]}'


# ----------------------------------------------------------------------------- setup
print(f'== Security A3 — delete/history — run {RUN} ==')
UO, TO = create_user('owner')
UM, TM = create_user('manager')
UR, TR = create_user('recep')
s, b, raw = api('POST', '/onboarding', TO, {
    'organization': {'name': f'A3 Org {RUN}', 'owner_name': 'Teste A3', 'phone': '11999990000', 'is_demo': True},
    'arena': {'name': f'Arena A3 {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
    'courts': [{'name': 'Quadra 1', 'type': 'SOCIETY'}, {'name': 'Quadra 2', 'type': 'SOCIETY'}],
    'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)],
    'default_reservation_minutes': 60,
})
assert s == 200, f'onboarding {s} {raw[:200]}'
ORG = FX.org(b['organization_id'], f'A3 Org {RUN}')
for uid, role in ((UM, 'MANAGER'), (UR, 'RECEPTIONIST')):
    s, _, raw = svc('POST', 'organization_members', {'organization_id': ORG, 'user_id': uid, 'role': role, 'status': 'ACTIVE'})
    assert s == 201, f'membro {role} {s} {raw[:160]}'
_, arenas, _ = api('GET', f'/arenas?organization_id={ORG}', TO)
ARENA = arenas[0]['id']
_, courts, _ = api('GET', f'/courts?organization_id={ORG}', TO)
C1, C2 = [c['id'] for c in sorted(courts, key=lambda c: c['name'])]
s, cust, raw = api('POST', '/customers', TO, {'organization_id': ORG, 'arena_id': ARENA, 'name': 'Cliente A3', 'phone': '11911110003'})
assert s == 201, f'cliente {s} {raw[:160]}'
CUST = cust['id']
D = datetime.now(SP).date() + timedelta(days=40)
s, res, raw = api('POST', '/reservations', TO, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'date': str(D), 'start_time': '10:00', 'end_time': '11:00', 'customer_id': CUST})
assert s == 201, f'reserva {s} {raw[:160]}'
RES = res['id']
s, ser, raw = api('POST', '/recurring-reservations', TO, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C2, 'frequency': 'WEEKLY', 'weekday': D.isoweekday() % 7,
                                                         'start_time': '19:00', 'end_time': '20:00', 'start_date': str(D), 'has_no_end_date': True, 'customer_id': CUST,
                                                         'operation_id': str(uuid.uuid4())})
assert s == 201 and ser['created'] > 0, f'série {s} {raw[:160]}'
SERIES = ser['id']
s, occ, _ = svc('GET', 'reservations', query=f'?recurring_reservation_id=eq.{SERIES}&select=id&order=occurrence_date.asc')
OCC = occ[0]['id']
s, bh, _ = svc('GET', 'business_hours', query=f'?arena_id=eq.{ARENA}&weekday=eq.1&select=id')
BH = bh[0]['id']
print(f'org={ORG}')

ROLES = {'OWNER': TO, 'MANAGER': TM, 'RECEPTIONIST': TR}


# ----------------------------------------------------------------------------- D: DELETE físico negado
def d1():
    for who, tok in ROLES.items():
        denied_delete(tok, 'reservations', RES, who)
        denied_delete(tok, 'reservations', OCC, who)


def d2():
    for who in ('OWNER', 'MANAGER'):
        denied_delete(ROLES[who], 'recurring_reservations', SERIES, who)


def d3():
    for who in ('OWNER', 'MANAGER'):
        denied_delete(ROLES[who], 'courts', C1, who)


def d4():
    for who in ('OWNER', 'MANAGER'):
        denied_delete(ROLES[who], 'arenas', ARENA, who)


def d5():
    for who, tok in ROLES.items():
        denied_delete(tok, 'customers', CUST, who)


def d6():
    for who in ('OWNER', 'MANAGER'):
        denied_delete(ROLES[who], 'business_hours', BH, who)


def d7():
    denied_delete(TO, 'organizations', ORG, 'OWNER')
    s, _, raw = rest('POST', 'organizations', TO, {'name': f'Org direta {RUN}'})
    assert s in (401, 403), f'INSERT direto em organizations deveria ser negado: {s} {raw[:160]}'


# ----------------------------------------------------------------------------- L: audit_logs append-only
def l1():
    s, b, raw = rest('POST', 'audit_logs', TO, {'organization_id': ORG, 'user_id': UO, 'action': 'A3_TEST', 'entity_type': 'test'})
    assert s == 201, f'INSERT próprio: {s} {raw[:160]}'
    log_id = b[0]['id']
    s, _, raw = rest('POST', 'audit_logs', TO, {'organization_id': ORG, 'user_id': UM, 'action': 'A3_FORJADO', 'entity_type': 'test'})
    assert s in (401, 403), f'INSERT com user_id de outro usuário deveria falhar: {s} {raw[:160]}'
    s, _, raw = rest('POST', 'audit_logs', TR, {'organization_id': ORG, 'user_id': None, 'action': 'A3_NULO', 'entity_type': 'test'})
    assert s in (401, 403), f'INSERT com user_id nulo deveria falhar: {s} {raw[:160]}'
    s, _, raw = rest('PATCH', 'audit_logs', TO, {'action': 'ALTERADO'}, f'?id=eq.{log_id}')
    assert s in (401, 403), f'UPDATE audit_logs deveria falhar: {s} {raw[:160]}'
    s, _, raw = rest('DELETE', 'audit_logs', TO, query=f'?id=eq.{log_id}')
    assert s in (401, 403), f'DELETE audit_logs deveria falhar: {s} {raw[:160]}'
    s, b, _ = svc('GET', 'audit_logs', query=f'?id=eq.{log_id}&select=action')
    assert b == [{'action': 'A3_TEST'}], b


# ----------------------------------------------------------------------------- H: fluxos de histórico continuam
def h1():
    s, b, raw = api('POST', f'/reservations/{RES}/cancel', TR, {'reason': 'A3'})
    assert s == 200 and b['status'] == 'CANCELLED', f'cancelar reserva (recepção): {s} {raw[:160]}'


def h2():
    s, b, raw = api('PUT', f'/courts/{C1}', TM, {'active': False})
    assert s == 200 and b['active'] is False, f'desativar quadra: {s} {raw[:160]}'
    s, b, raw = api('PUT', f'/courts/{C1}', TM, {'active': True})
    assert s == 200 and b['active'] is True, f'reativar quadra: {s} {raw[:160]}'


def h3():
    s, b, raw = api('PUT', f'/arenas/{ARENA}', TO, {'active': False})
    assert s == 200 and b['active'] is False, f'desativar arena: {s} {raw[:160]}'
    s, b, raw = api('PUT', f'/arenas/{ARENA}', TO, {'active': True})
    assert s == 200 and b['active'] is True, f'reativar arena: {s} {raw[:160]}'


def h4():
    s, b, raw = rest('PATCH', 'customers', TR, {'name': 'Cliente A3 editado'}, f'?id=eq.{CUST}')
    assert s == 200 and b and b[0]['name'] == 'Cliente A3 editado', f'editar cliente (recepção): {s} {raw[:160]}'
    s, _, raw = rest('POST', 'customers', TR, {'organization_id': ORG, 'arena_id': ARENA, 'name': 'Cliente novo A3'})
    assert s == 201, f'criar cliente (recepção): {s} {raw[:160]}'


def h5():
    s, _, raw = api('PUT', '/business-hours', TM, {'organization_id': ORG, 'arena_id': ARENA,
                                                   'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00'} for i in range(7)]})
    assert s == 200, f'upsert horários (manager): {s} {raw[:160]}'


def h6():
    s, _, raw = api('POST', f'/recurring-reservations/{SERIES}/pause', TO, {'cancel_future': False})
    assert s == 200, f'pausar série: {s} {raw[:160]}'
    s, b, raw = api('POST', f'/recurring-reservations/{SERIES}/cancel', TO, {})
    assert s == 200 and b['series']['status'] == 'CANCELLED', f'cancelar série: {s} {raw[:160]}'
    assert exists('recurring_reservations', SERIES), 'série deve continuar existindo'


def h7():
    s, b, raw = api('POST', '/reservations', TR, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'date': str(D + timedelta(days=1)),
                                                 'start_time': '10:00', 'end_time': '11:00', 'customer': {'name': 'Walk-in A3', 'phone': '11922220003'}})
    assert s == 201, f'criar reserva (recepção): {s} {raw[:160]}'


# ----------------------------------------------------------------------------- F: FK RESTRICT (tentativa administrativa controlada)
def f_guard():
    assert results.get('D1 DELETE reserva negado (OWNER/MANAGER/RECEPTIONIST)') == 'PASS', \
        'bloco D não confirmou a migration A3 — testes de FK não executados por segurança'


def f1():
    f_guard()
    s, _, raw = svc('DELETE', 'courts', query=f'?id=eq.{C1}')
    assert s == 409 and exists('courts', C1), f'service role apagando quadra com reservas: esperado 409 (RESTRICT), veio {s} {raw[:160]}'


def f2():
    f_guard()
    s, _, raw = svc('DELETE', 'arenas', query=f'?id=eq.{ARENA}')
    assert s == 409 and exists('arenas', ARENA), f'service role apagando arena com histórico: esperado 409, veio {s} {raw[:160]}'


def f3():
    f_guard()
    s, _, raw = svc('DELETE', 'organizations', query=f'?id=eq.{ORG}')
    assert s == 409 and exists('organizations', ORG), f'service role apagando organização com histórico: esperado 409, veio {s} {raw[:160]}'
    assert exists('reservations', RES), 'reserva histórica deveria continuar'


def f4():
    """Quadra SEM histórico continua podendo ser removida administrativamente (RESTRICT só protege histórico)."""
    f_guard()
    s, b, raw = svc('POST', 'courts', {'organization_id': ORG, 'arena_id': ARENA, 'name': 'Quadra sem histórico'})
    assert s == 201, f'quadra temporária {s} {raw[:160]}'
    cid = b[0]['id']
    s, _, raw = svc('DELETE', 'courts', query=f'?id=eq.{cid}')
    assert s in (200, 204) and not exists('courts', cid), f'apagar quadra sem histórico (service role): {s} {raw[:160]}'


# ----------------------------------------------------------------------------- M: último OWNER
def mem_id(uid):
    s, b, _ = svc('GET', 'organization_members', query=f'?organization_id=eq.{ORG}&user_id=eq.{uid}&select=id,role,status')
    return b[0] if b else None


def m1():
    me = mem_id(UO)
    rgt(*rest('DELETE', 'organization_members', TO, query=f'?id=eq.{me["id"]}'), 'RGT03', 'remover o último OWNER')
    rgt(*rest('PATCH', 'organization_members', TO, {'role': 'MANAGER'}, f'?id=eq.{me["id"]}'), 'RGT03', 'rebaixar o último OWNER')
    rgt(*rest('PATCH', 'organization_members', TO, {'status': 'SUSPENDED'}, f'?id=eq.{me["id"]}'), 'RGT03', 'suspender o último OWNER')
    assert mem_id(UO) == {**me, 'role': 'OWNER', 'status': 'ACTIVE'}, 'vínculo do OWNER alterado'


def m2():
    rgt(*svc('DELETE', 'organization_members', query=f'?id=eq.{mem_id(UO)["id"]}'), 'RGT03', 'service role removendo o último OWNER')


def m3():
    r = mem_id(UR)
    s, b, raw = rest('PATCH', 'organization_members', TO, {'status': 'SUSPENDED'}, f'?id=eq.{r["id"]}')
    assert s == 200 and b[0]['status'] == 'SUSPENDED', f'suspender recepção: {s} {raw[:160]}'
    s, b, raw = rest('PATCH', 'organization_members', TO, {'status': 'ACTIVE'}, f'?id=eq.{r["id"]}')
    assert s == 200 and b[0]['status'] == 'ACTIVE', f'reativar recepção: {s} {raw[:160]}'


def m4():
    m = mem_id(UM)
    s, b, raw = rest('PATCH', 'organization_members', TO, {'role': 'OWNER'}, f'?id=eq.{m["id"]}')
    assert s == 200 and b[0]['role'] == 'OWNER', f'promover manager a OWNER: {s} {raw[:160]}'
    s, _, raw = rest('DELETE', 'organization_members', TO, query=f'?id=eq.{m["id"]}')
    assert s in (200, 204) and mem_id(UM) is None, f'com 2 OWNERs, remover 1 deve funcionar: {s} {raw[:160]}'
    rgt(*rest('DELETE', 'organization_members', TO, query=f'?id=eq.{mem_id(UO)["id"]}'), 'RGT03', 'voltou a ser o último OWNER')


# ----------------------------------------------------------------------------- M5: último OWNER em lote (mesmo statement)
M5 = {}


def m5_setup():
    """Organização efêmera isolada, SEM dependências protegidas, com exatamente 2 OWNERs ativos.
    Tudo via service role, para isolar o comportamento do trigger da RLS."""
    u1, _ = create_user('m5-owner1')
    u2, _ = create_user('m5-owner2')
    M5['users'] = [u1, u2]
    s, b, raw = svc('POST', 'organizations', {'name': f'A3 M5 {RUN}', 'is_demo': True, 'onboarding_completed': True})
    assert s == 201, f'org M5 {s} {raw[:160]}'
    M5['org'] = FX.org(b[0]['id'], f'A3 M5 {RUN}')
    for uid in (u1, u2):
        s, _, raw = svc('POST', 'organization_members', {'organization_id': M5['org'], 'user_id': uid, 'role': 'OWNER', 'status': 'ACTIVE'})
        assert s == 201, f'OWNER M5 {s} {raw[:160]}'
    assert m5_active_owners() == 2


def m5_active_owners():
    s, b, raw = svc('GET', 'organization_members', query=f'?organization_id=eq.{M5["org"]}&role=eq.OWNER&status=eq.ACTIVE&select=id')
    assert s == 200, f'contagem OWNERs {s} {raw[:160]}'
    return len(b)


def m5_members():
    s, b, _ = svc('GET', 'organization_members', query=f'?organization_id=eq.{M5["org"]}&select=id,role,status&order=id')
    return b


def m5a():
    """Um único DELETE (um statement) tentando remover os DOIS OWNERs ativos."""
    before = m5_members()
    s, b, raw = svc('DELETE', 'organization_members', query=f'?organization_id=eq.{M5["org"]}&role=eq.OWNER&status=eq.ACTIVE')
    after = m5_active_owners()
    assert after >= 1, f'CRÍTICO: DELETE em lote deixou {after} OWNER ativo (HTTP {s}) — PARAR e revisar o desenho'
    rgt(s, b, raw, 'RGT03', 'DELETE em lote dos 2 OWNERs')
    assert after == 2 and m5_members() == before, 'operação deveria ser totalmente revertida (2 OWNERs intactos)'


def m5b():
    """Uma única operação rebaixando / suspendendo os DOIS OWNERs ativos.
    (status 'INACTIVE' não existe: o check aceita ACTIVE/INVITED/SUSPENDED; usar INACTIVE
    falharia no check constraint e não provaria o trigger.)"""
    before = m5_members()
    for patch, what in (({'role': 'MANAGER'}, 'rebaixar os 2 OWNERs para MANAGER'),
                        ({'status': 'SUSPENDED'}, 'suspender os 2 OWNERs')):
        s, b, raw = svc('PATCH', 'organization_members', patch, f'?organization_id=eq.{M5["org"]}&role=eq.OWNER&status=eq.ACTIVE')
        after = m5_active_owners()
        assert after >= 1, f'CRÍTICO: {what} em lote deixou {after} OWNER ativo (HTTP {s}) — PARAR e revisar o desenho'
        rgt(s, b, raw, 'RGT03', f'{what} em lote')
        assert after == 2 and m5_members() == before, f'{what}: nenhuma atualização parcial pode ficar gravada'


def m5_cleanup():
    """Remove a org efêmera (sem dependências: cascata dos vínculos) e os 2 usuários."""
    if M5.get('org'):
        svc('DELETE', 'organizations', query=f'?id=eq.{M5["org"]}')
    for uid in M5.get('users', []):
        http('DELETE', f'{SB}/auth/v1/admin/users/{uid}', SVC)


# ----------------------------------------------------------------------------- N: cascata da organização x último OWNER
def n1():
    """Organização efêmera SEM dependências protegidas (sem arena/quadra/cliente/reserva),
    com exatamente 1 OWNER ativo. DELETE administrativo da organização deve PASSAR e o
    vínculo sumir pela cascata — sem RGT03 (a exceção do trigger para org removida)."""
    uid, _ = create_user('cascade-owner')
    try:
        s, b, raw = svc('POST', 'organizations', {'name': f'A3 Cascade {RUN}', 'is_demo': True, 'onboarding_completed': True})
        assert s == 201, f'org efêmera {s} {raw[:160]}'
        oid = FX.org(b[0]['id'], f'A3 Cascade {RUN}')
        s, b, raw = svc('POST', 'organization_members', {'organization_id': oid, 'user_id': uid, 'role': 'OWNER', 'status': 'ACTIVE'})
        assert s == 201, f'OWNER único {s} {raw[:160]}'
        mid = b[0]['id']
        # Sanidade: nesta org o OWNER é o último — DELETE direto do vínculo continua RGT03.
        rgt(*svc('DELETE', 'organization_members', query=f'?id=eq.{mid}'), 'RGT03', 'DELETE direto do último OWNER (org efêmera)')
        s, _, raw = svc('DELETE', 'organizations', query=f'?id=eq.{oid}')
        assert s in (200, 204), f'DELETE administrativo da org sem dependências deveria passar: {s} {raw[:200]}'
        assert 'RGT03' not in raw, f'cascata não pode retornar RGT03: {raw[:200]}'
        assert not exists('organizations', oid), 'organização deveria ter sido removida'
        assert not exists('organization_members', mid), 'vínculo deveria ter sumido pela cascata'
    finally:
        http('DELETE', f'{SB}/auth/v1/admin/users/{uid}', SVC)  # usuário efêmero deste caso


for name, fn in [
    ('D1 DELETE reserva negado (OWNER/MANAGER/RECEPTIONIST)', d1), ('D2 DELETE série negado', d2),
    ('D3 DELETE quadra negado', d3), ('D4 DELETE arena negado', d4), ('D5 DELETE cliente negado', d5),
    ('D6 DELETE horário negado', d6), ('D7 DELETE/INSERT direto em organizations negado', d7),
    ('L1 audit_logs append-only (user_id = auth.uid())', l1),
    ('H1 cancelar reserva continua', h1), ('H2 desativar/reativar quadra continua', h2), ('H3 desativar/reativar arena continua', h3),
    ('H4 editar/criar cliente continua', h4), ('H5 upsert de horários continua', h5), ('H6 pausar/cancelar série continua', h6),
    ('H7 criar reserva (recepção) continua', h7),
    ('F1 RESTRICT: quadra com histórico', f1), ('F2 RESTRICT: arena com histórico', f2), ('F3 RESTRICT: organização com histórico', f3),
    ('F4 quadra sem histórico pode ser removida (admin)', f4),
    ('M1 último OWNER: DELETE/rebaixar/suspender negado', m1), ('M2 último OWNER: service role também negado', m2),
    ('M3 mudar status de outro papel continua', m3), ('M4 com 2 OWNERs remover 1 funciona', m4),
    ('M5 setup: org efêmera com exatamente 2 OWNERs ativos', m5_setup),
    ('M5-A DELETE em lote dos 2 OWNERs -> RGT03, nada removido', m5a),
    ('M5-B rebaixar/suspender os 2 OWNERs em lote -> RGT03, nada gravado', m5b),
    ('N1 DELETE administrativo de org sem dependências remove o último OWNER por cascata', n1),
]:
    check(name, fn)
m5_cleanup()

ok = sum(1 for v in results.values() if v == 'PASS')
print(f'\n== {ok}/{len(results)} PASS (run {RUN}, org {ORG}) ==')
residual = FX.cleanup()
sys.exit(0 if ok == len(results) and residual == 0 else 1)
