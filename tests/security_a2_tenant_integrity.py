#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A2 — integridade multi-tenant (P0-2).

Rodar SOMENTE depois de aplicar supabase/migration_security_a2.sql.

Cria DUAS organizações novas e isoladas (is_demo), com usuários efêmeros:
  Org A: Arena A (Quadra A1, Quadra A1b) + Arena A2 (Quadra A2) + Customer A
  Org B: Arena B (Quadra B) + Customer B
e testa as combinações cruzadas DIRETO no PostgREST com o token do usuário (o mesmo
acesso de qualquer navegador logado) e também pela API do app.

Variáveis de ambiente obrigatórias (nenhum valor é impresso):
  BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcional: TEST_EMAIL_DOMAIN (padrão reservagol.test)

Uso: python tests/security_a2_tenant_integrity.py
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
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
TENANT_MSG = 'Dados da reserva não pertencem à mesma organização.'
ARENA_MSG = 'A arena informada não pertence à mesma organização.'
RAW_ERR = ['tenant_mismatch', 'RGT01', 'violates', 'constraint', 'duplicate key', 'no_overlap']
results = {}
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}


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


def uh(token):
    return {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}', 'Prefer': 'return=representation'}


def rest(method, table, token, body=None, query=''):
    return http(method, f'{SB}/rest/v1/{table}{query}', uh(token), body)


def svc_get(table, params):
    s, b, raw = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params, doseq=True)}', SVC)
    assert s == 200, f'svc {table} {s} {raw[:200]}'
    return b


def create_user(label):
    email = f'a2-{label}-{RUN}@{DOMAIN}'
    s, b, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    return b['id'], t['access_token']


def onboard(token, label, courts):
    s, b, raw = api('POST', '/onboarding', token, {
        'organization': {'name': f'A2 Org {label} {RUN}', 'owner_name': f'Teste A2 {label}', 'phone': '11999990000', 'is_demo': True},
        'arena': {'name': f'Arena {label} {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
        'courts': [{'name': n, 'type': 'SOCIETY'} for n in courts],
        'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)],
        'default_reservation_minutes': 60,
    })
    assert s == 200, f'onboarding {label} {s} {raw[:200]}'
    org = b['organization_id']
    _, arenas, _ = api('GET', f'/arenas?organization_id={org}', token)
    _, courts_l, _ = api('GET', f'/courts?organization_id={org}', token)
    return org, arenas[0]['id'], {c['name']: c['id'] for c in courts_l}


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


# ----------------------------------------------------------------------------- setup
print(f'== Security A2 — tenant integrity — run {RUN} ==')
UA, TA = create_user('owner-a')
_, TB = create_user('owner-b')
ORG_A, ARENA_A, CA = onboard(TA, 'A', ['Quadra A1', 'Quadra A1b'])
ORG_B, ARENA_B, CB = onboard(TB, 'B', ['Quadra B'])
COURT_A, COURT_A1B, COURT_B = CA['Quadra A1'], CA['Quadra A1b'], CB['Quadra B']

# Arena A2 + Quadra A2 (mesma Org A) via PostgREST com o token do OWNER A.
s, b, raw = rest('POST', 'arenas', TA, {'organization_id': ORG_A, 'name': f'Arena A2 {RUN}', 'active': True})
assert s == 201, f'arena A2 {s} {raw[:200]}'
ARENA_A2 = b[0]['id']
s, b, raw = rest('POST', 'courts', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A2, 'name': 'Quadra A2'})
assert s == 201, f'quadra A2 {s} {raw[:200]}'
COURT_A2 = b[0]['id']
s, b, raw = rest('POST', 'customers', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'name': 'Cliente A', 'phone': '11911110001'})
assert s == 201, f'customer A {s} {raw[:200]}'
CUST_A = b[0]['id']
s, b, raw = rest('POST', 'customers', TB, {'organization_id': ORG_B, 'arena_id': ARENA_B, 'name': 'Cliente B', 'phone': '11922220002'})
assert s == 201, f'customer B {s} {raw[:200]}'
CUST_B = b[0]['id']

# Arena A publicada (para a reserva pública válida).
SLUG = f'a2-{RUN}'
s, _, raw = api('PUT', f'/arenas/{ARENA_A}', TA, {'slug': SLUG, 'description': 'Arena de teste A2', 'cover_image_url': 'https://example.com/cover.jpg'})
assert s == 200, f'perfil arena A {s} {raw[:200]}'
s, _, raw = api('PUT', f'/arenas/{ARENA_A}', TA, {'public_booking_enabled': True})
assert s == 200, f'publicar arena A {s} {raw[:200]}'
print(f'org A={ORG_A} org B={ORG_B}')

LEAK = [ORG_B, ARENA_B, COURT_B, CUST_B, f'Arena B {RUN}', f'A2 Org B {RUN}', 'Cliente B']
DAY = (datetime.now(SP).date() + timedelta(days=30))
_hour = [8]


def slot():
    """Horário exclusivo por caso (evita que a anti-overlap mascare o resultado)."""
    h = _hour[0]
    _hour[0] += 1
    d = DAY + timedelta(days=h // 15)
    hh = 8 + h % 15
    return f'{d}T{hh:02d}:00:00-03:00', f'{d}T{hh:02d}:59:00-03:00', str(d), f'{hh:02d}:00', f'{hh:02d}:59'


def res_row(org, arena, court, customer=None):
    st, en, *_ = slot()
    return {'organization_id': org, 'arena_id': arena, 'court_id': court, 'customer_id': customer,
            'start_at': st, 'end_at': en, 'status': 'CONFIRMED', 'source': 'TESTE_A2'}


def no_leak(raw):
    return not any(x in (raw or '') for x in LEAK)


def rejected_tenant(s, b, raw, what, codes=('RGT01',)):
    assert s == 400 and isinstance(b, dict) and b.get('code') in codes, f'{what}: esperado 400/{"|".join(codes)}, veio {s} {raw[:160]}'
    assert no_leak(raw), f'{what}: resposta vazou dado da outra organização'


def rejected_immutable(s, b, raw, what):
    rejected_tenant(s, b, raw, what, codes=('RGT02',))


def api_friendly(s, b, raw, msg, what):
    assert s == 400 and b.get('error') == msg, f'{what}: {s} {raw[:160]}'
    assert no_leak(raw) and not any(k.lower() in raw.lower() for k in RAW_ERR), f'{what}: erro cru ou vazamento: {raw[:160]}'


# ----------------------------------------------------------------------------- reservations (PostgREST direto)
def r1():
    rejected_tenant(*rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_B)), 'org A + arena A + quadra B')


def r2():
    rejected_tenant(*rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_B, COURT_B)), 'org A + arena B + quadra B')


def r3():
    rejected_tenant(*rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_B, COURT_A)), 'org A + arena B + quadra A')


def r4():
    rejected_tenant(*rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_A, CUST_B)), 'cliente B')


VALID = {}


def r8():
    s, b, raw = rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_A, CUST_A))
    assert s == 201, f'válida A/A/A/cliente A: {s} {raw[:160]}'
    VALID['id'] = b[0]['id']


def r5():
    s, b, raw = rest('PATCH', 'reservations', TA, {'court_id': COURT_B}, f'?id=eq.{VALID["id"]}')
    rejected_tenant(s, b, raw, 'UPDATE quadra -> B')


def r6():
    s, b, raw = rest('PATCH', 'reservations', TA, {'arena_id': ARENA_B}, f'?id=eq.{VALID["id"]}')
    rejected_tenant(s, b, raw, 'UPDATE arena -> B mantendo quadra A')


def r6b():
    s, b, raw = rest('PATCH', 'reservations', TA, {'customer_id': CUST_B}, f'?id=eq.{VALID["id"]}')
    rejected_tenant(s, b, raw, 'UPDATE cliente -> B')
    row = svc_get('reservations', {'id': f'eq.{VALID["id"]}', 'select': 'organization_id,arena_id,court_id,customer_id'})[0]
    assert row == {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A, 'customer_id': CUST_A}, f'reserva alterada: {row}'


def r7():
    rejected_tenant(*rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_A2)), 'arena A1 + quadra A2 (mesma org)')


def r7b():
    s, b, raw = rest('PATCH', 'reservations', TA, {'court_id': COURT_A1B}, f'?id=eq.{VALID["id"]}')
    assert s == 200 and b and b[0]['court_id'] == COURT_A1B, f'troca de quadra válida na mesma arena: {s} {raw[:160]}'


def r9():
    s, _, raw = rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_A, None))
    assert s == 201, f'customer_id NULL: {s} {raw[:160]}'


def r10():
    _, _, d, st, en = slot()
    s, b, raw = api('POST', '/reservations', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A, 'date': d, 'start_time': st, 'end_time': en,
                                                   'customer': {'name': 'Cliente API', 'phone': '11933330003'}})
    assert s == 201, f'API válida: {s} {raw[:160]}'
    _, _, d, st, en = slot()
    s, b, raw = api('POST', '/reservations', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_B, 'date': d, 'start_time': st, 'end_time': en})
    api_friendly(s, b, raw, TENANT_MSG, 'API reserva com quadra B')
    s, b, raw = api('PUT', f'/reservations/{VALID["id"]}', TA, {'court_id': COURT_B})
    api_friendly(s, b, raw, TENANT_MSG, 'API PUT quadra B')


def r11():
    _, _, d, st, en = slot()
    s, _, raw = api('POST', '/reservations/block', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A, 'date': d, 'start_time': st, 'end_time': en, 'reason': 'Manutenção'})
    assert s == 201, f'bloqueio válido: {s} {raw[:160]}'
    _, _, d, st, en = slot()
    s, b, raw = api('POST', '/reservations/block', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_B, 'date': d, 'start_time': st, 'end_time': en, 'reason': 'Manutenção'})
    api_friendly(s, b, raw, TENANT_MSG, 'API bloqueio na quadra B')


def r12():
    d = str(DAY + timedelta(days=5))
    body = {'slug': SLUG, 'court_id': COURT_A, 'date': d, 'start_time': '10:00', 'end_time': '11:00', 'name': 'Jogador A2',
            'phone': '11944440004', 'email': None, 'accept_terms': True, 'idempotency_key': f'a2-{RUN}'}
    s, b, raw = api('POST', '/public/reserve', None, body)
    assert s == 201 and b.get('public_code'), f'pública válida: {s} {raw[:160]}'
    s, b, raw = api('POST', '/public/reserve', None, {**body, 'court_id': COURT_B, 'start_time': '11:00', 'end_time': '12:00', 'idempotency_key': f'a2b-{RUN}'})
    assert s == 404 and no_leak(raw), f'pública com quadra B deveria 404: {s} {raw[:160]}'


def r13_recurring():
    """Recorrência: criação continua funcionando e a ocorrência materializada valida o cliente."""
    wd = (DAY.isoweekday() % 7)
    s, b, raw = api('POST', '/recurring-reservations', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A1B, 'frequency': 'WEEKLY',
                                                            'weekday': wd, 'start_time': '22:00', 'end_time': '23:00', 'start_date': str(DAY), 'has_no_end_date': True,
                                                            'customer_id': CUST_A})
    assert s == 201 and b['created'] > 0, f'criar mensalista: {s} {raw[:160]}'
    occ = svc_get('reservations', {'recurring_reservation_id': f'eq.{b["id"]}', 'select': 'id', 'order': 'occurrence_date.asc'})
    s, bb, raw = rest('PATCH', 'reservations', TA, {'customer_id': CUST_B}, f'?id=eq.{occ[0]["id"]}')
    rejected_tenant(s, bb, raw, 'ocorrência recorrente com cliente B')
    s, bb, raw = rest('PATCH', 'reservations', TA, {'court_id': COURT_B, 'is_exception': True}, f'?id=eq.{occ[1]["id"]}')
    rejected_tenant(s, bb, raw, 'ocorrência recorrente movida para quadra B')
    s, bb, raw = rest('PATCH', 'reservations', TA, {'court_id': COURT_A, 'is_exception': True}, f'?id=eq.{occ[1]["id"]}')
    assert s == 200, f'"Apenas esta" com quadra da mesma arena: {s} {raw[:160]}'


# ----------------------------------------------------------------------------- courts / business_hours / customers
def c1():
    rejected_tenant(*rest('POST', 'courts', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'name': 'Intrusa'}), 'quadra org A + arena B')
    s, b, raw = api('POST', '/courts', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'name': 'Intrusa API'})
    api_friendly(s, b, raw, ARENA_MSG, 'API quadra com arena B')
    assert not svc_get('courts', {'arena_id': f'eq.{ARENA_B}', 'organization_id': f'eq.{ORG_A}', 'select': 'id'}), 'quadra intrusa gravada'


def c2():
    s, b, raw = rest('POST', 'courts', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'name': 'Quadra A nova'})
    assert s == 201, f'quadra válida: {s} {raw[:160]}'
    cid = b[0]['id']
    rejected_tenant(*rest('PATCH', 'courts', TA, {'arena_id': ARENA_B}, f'?id=eq.{cid}'), 'UPDATE quadra -> arena B')
    s, b, raw = api('PUT', f'/courts/{cid}', TA, {'name': 'Quadra A renomeada'})
    assert s == 200, f'API editar quadra válida: {s} {raw[:160]}'


def h1():
    rejected_tenant(*rest('POST', 'business_hours', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'weekday': 3, 'open_time': '08:00', 'close_time': '22:00'}), 'horário org A + arena B')
    s, b, raw = api('PUT', '/business-hours', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'hours': [{'weekday': 3, 'open_time': '08:00', 'close_time': '22:00'}]})
    api_friendly(s, b, raw, ARENA_MSG, 'API horário com arena B')
    bh = svc_get('business_hours', {'arena_id': f'eq.{ARENA_B}', 'weekday': 'eq.3', 'select': 'organization_id,close_time'})
    assert bh == [{'organization_id': ORG_B, 'close_time': '00:00:00'}], f'horário da arena B alterado: {bh}'


def h2():
    s, _, raw = rest('POST', 'business_hours', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A2, 'weekday': 1, 'open_time': '08:00', 'close_time': '22:00'})
    assert s == 201, f'horário válido (arena A2): {s} {raw[:160]}'
    s, _, raw = api('PUT', '/business-hours', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00'} for i in range(7)]})
    assert s == 200, f'API horário válido: {s} {raw[:160]}'


def k1():
    rejected_tenant(*rest('POST', 'customers', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'name': 'Intruso'}), 'cliente org A + arena B')
    s, b, raw = api('POST', '/customers', TA, {'organization_id': ORG_A, 'arena_id': ARENA_B, 'name': 'Intruso API', 'phone': '11955550005'})
    api_friendly(s, b, raw, ARENA_MSG, 'API cliente com arena B')
    rejected_tenant(*rest('PATCH', 'customers', TA, {'arena_id': ARENA_B}, f'?id=eq.{CUST_A}'), 'UPDATE cliente -> arena B')


def k2():
    s, _, raw = rest('POST', 'customers', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'name': 'Cliente A2', 'phone': '11966660006'})
    assert s == 201, f'cliente org A + arena A: {s} {raw[:160]}'
    s, _, raw = rest('POST', 'customers', TA, {'organization_id': ORG_A, 'arena_id': None, 'name': 'Cliente sem arena', 'phone': '11977770007'})
    assert s == 201, f'cliente org A + arena NULL: {s} {raw[:160]}'


# ----------------------------------------------------------------------------- vínculos estruturais imutáveis
P = {}


def p_setup():
    """OWNER A passa a ser OWNER também da Org B: prova que nem quem tem autorização
    nos dois tenants consegue quebrar a integridade estrutural."""
    s, _, raw = http('POST', f'{SB}/rest/v1/organization_members', {**SVC, 'Prefer': 'return=minimal'},
                     {'organization_id': ORG_B, 'user_id': UA, 'role': 'OWNER', 'status': 'ACTIVE'})
    assert s in (200, 201), f'vínculo de A na Org B: {s} {raw[:160]}'
    # Sanidade: com o vínculo, A consegue ler a arena B (a recusa abaixo vem do trigger, não da RLS).
    s, b, _ = rest('GET', 'arenas', TA, query=f'?id=eq.{ARENA_B}&select=id')
    assert s == 200 and len(b) == 1, 'A deveria enxergar a arena B após o vínculo'


def p1():
    s, b, raw = rest('POST', 'courts', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'name': 'Quadra X'})
    assert s == 201, f'quadra X: {s} {raw[:160]}'
    P['court_x'] = b[0]['id']
    s, b, raw = rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, P['court_x'], CUST_A))
    assert s == 201, f'reserva na quadra X: {s} {raw[:160]}'
    P['res_x'] = b[0]['id']
    rejected_immutable(*rest('PATCH', 'courts', TA, {'arena_id': ARENA_A2}, f'?id=eq.{P["court_x"]}'), 'quadra X -> arena A2 (mesma org)')
    court = svc_get('courts', {'id': f'eq.{P["court_x"]}', 'select': 'organization_id,arena_id'})[0]
    assert court == {'organization_id': ORG_A, 'arena_id': ARENA_A}, court
    s, _, raw = api('POST', f'/reservations/{P["res_x"]}/cancel', TA, {'reason': 'A2 P1'})
    assert s == 200, f'reserva da quadra X deveria continuar cancelável: {s} {raw[:160]}'
    s, _, raw = rest('PATCH', 'courts', TA, {'name': 'Quadra X renomeada', 'active': False}, f'?id=eq.{P["court_x"]}')
    assert s == 200, f'editar nome/status da quadra continua permitido: {s} {raw[:160]}'


def p2():
    rejected_tenant(*rest('PATCH', 'courts', TA, {'organization_id': ORG_B}, f'?id=eq.{P["court_x"]}'), 'quadra -> org B', codes=('RGT01', 'RGT02'))
    # Par coerente org B + arena B: passa na checagem de tenant e cai na imutabilidade.
    rejected_immutable(*rest('PATCH', 'courts', TA, {'organization_id': ORG_B, 'arena_id': ARENA_B}, f'?id=eq.{P["court_x"]}'), 'quadra -> org B + arena B')


def p3():
    rejected_immutable(*rest('PATCH', 'arenas', TA, {'organization_id': ORG_B}, f'?id=eq.{ARENA_A2}'), 'arena A2 -> org B')
    arena = svc_get('arenas', {'id': f'eq.{ARENA_A2}', 'select': 'organization_id'})[0]
    assert arena == {'organization_id': ORG_A}, arena
    s, _, raw = rest('PATCH', 'arenas', TA, {'description': 'editada A2'}, f'?id=eq.{ARENA_A2}')
    assert s == 200, f'editar dados da arena continua permitido: {s} {raw[:160]}'


def p4():
    bh = svc_get('business_hours', {'arena_id': f'eq.{ARENA_A2}', 'weekday': 'eq.1', 'select': 'id'})[0]['id']
    P['bh'] = bh
    rejected_immutable(*rest('PATCH', 'business_hours', TA, {'arena_id': ARENA_A}, f'?id=eq.{bh}'), 'horário -> outra arena')
    s, _, raw = rest('PATCH', 'business_hours', TA, {'close_time': '23:00'}, f'?id=eq.{bh}')
    assert s == 200, f'editar horário continua permitido: {s} {raw[:160]}'


def p5():
    rejected_tenant(*rest('PATCH', 'business_hours', TA, {'organization_id': ORG_B}, f'?id=eq.{P["bh"]}'), 'horário -> org B', codes=('RGT01', 'RGT02'))
    rejected_immutable(*rest('PATCH', 'business_hours', TA, {'organization_id': ORG_B, 'arena_id': ARENA_B}, f'?id=eq.{P["bh"]}'), 'horário -> org B + arena B')


def p6():
    rejected_tenant(*rest('PATCH', 'customers', TA, {'organization_id': ORG_B}, f'?id=eq.{CUST_A}'), 'cliente -> org B', codes=('RGT01', 'RGT02'))
    # arena NULL: passa na checagem de tenant e cai na imutabilidade.
    rejected_immutable(*rest('PATCH', 'customers', TA, {'organization_id': ORG_B, 'arena_id': None}, f'?id=eq.{CUST_A}'), 'cliente -> org B (arena NULL)')


def p7():
    s, b, raw = rest('PATCH', 'customers', TA, {'arena_id': ARENA_A2}, f'?id=eq.{CUST_A}')
    assert s == 200 and b and b[0]['arena_id'] == ARENA_A2, f'cliente arena A1 -> A2 (mesma org): {s} {raw[:160]}'


def p8():
    rejected_tenant(*rest('PATCH', 'customers', TA, {'arena_id': ARENA_B}, f'?id=eq.{CUST_A}'), 'cliente -> arena B')
    cust = svc_get('customers', {'id': f'eq.{CUST_A}', 'select': 'organization_id,arena_id'})[0]
    assert cust == {'organization_id': ORG_A, 'arena_id': ARENA_A2}, cust


# ----------------------------------------------------------------------------- reservations: vínculos imutáveis
Q = {}


def q_setup():
    s, b, raw = rest('POST', 'reservations', TA, res_row(ORG_A, ARENA_A, COURT_A, CUST_A))
    assert s == 201, f'reserva base Q: {s} {raw[:160]}'
    Q['res'] = b[0]['id']
    s, b, raw = rest('POST', 'customers', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'name': 'Cliente A3', 'phone': '11988880008'})
    assert s == 201, f'cliente A3: {s} {raw[:160]}'
    Q['cust_a3'] = b[0]['id']


def q_intact():
    row = svc_get('reservations', {'id': f'eq.{Q["res"]}', 'select': 'organization_id,arena_id'})[0]
    assert row == {'organization_id': ORG_A, 'arena_id': ARENA_A}, f'reserva alterada: {row}'


def q1():
    rejected_tenant(*rest('PATCH', 'reservations', TA, {'organization_id': ORG_B}, f'?id=eq.{Q["res"]}'), 'reserva -> org B', codes=('RGT01', 'RGT02'))
    q_intact()


def q2():
    rejected_immutable(*rest('PATCH', 'reservations', TA, {'organization_id': ORG_B, 'arena_id': ARENA_B, 'court_id': COURT_B, 'customer_id': CUST_B},
                             f'?id=eq.{Q["res"]}'), 'reserva -> conjunto coerente da org B')
    q_intact()


def q3():
    rejected_tenant(*rest('PATCH', 'reservations', TA, {'arena_id': ARENA_A2}, f'?id=eq.{Q["res"]}'), 'reserva -> só arena A2', codes=('RGT01', 'RGT02'))
    rejected_immutable(*rest('PATCH', 'reservations', TA, {'arena_id': ARENA_A2, 'court_id': COURT_A2}, f'?id=eq.{Q["res"]}'), 'reserva -> arena A2 + quadra A2 (coerente)')
    q_intact()


def q4():
    s, b, raw = rest('PATCH', 'reservations', TA, {'court_id': COURT_A1B}, f'?id=eq.{Q["res"]}')
    assert s == 200 and b and b[0]['court_id'] == COURT_A1B, f'quadra da mesma arena: {s} {raw[:160]}'


def q5():
    s, b, raw = rest('PATCH', 'reservations', TA, {'customer_id': Q['cust_a3']}, f'?id=eq.{Q["res"]}')
    assert s == 200 and b and b[0]['customer_id'] == Q['cust_a3'], f'cliente da mesma org: {s} {raw[:160]}'


# ----------------------------------------------------------------------------- recurring_reservations: vínculos imutáveis
S = {}


def s_setup():
    d = DAY + timedelta(days=2)
    s, b, raw = api('POST', '/recurring-reservations', TA, {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A, 'frequency': 'WEEKLY',
                                                            'weekday': d.isoweekday() % 7, 'start_time': '23:00', 'end_time': '00:00', 'start_date': str(d),
                                                            'has_no_end_date': True, 'customer_id': CUST_A, 'skip_conflicts': True})
    assert s == 201 and b['created'] > 0, f'série S: {s} {raw[:160]}'
    S['id'] = b['id']
    S['start'] = str(d)


def s_intact():
    row = svc_get('recurring_reservations', {'id': f'eq.{S["id"]}', 'select': 'organization_id,arena_id,court_id,customer_id'})[0]
    assert row == {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A, 'customer_id': CUST_A}, f'série alterada: {row}'


def s1():
    rejected_immutable(*rest('PATCH', 'recurring_reservations', TA, {'organization_id': ORG_B, 'arena_id': ARENA_B, 'court_id': COURT_B, 'customer_id': CUST_B},
                             f'?id=eq.{S["id"]}'), 'série -> conjunto coerente da org B')
    s_intact()


def s2():
    rejected_immutable(*rest('PATCH', 'recurring_reservations', TA, {'court_id': COURT_A1B}, f'?id=eq.{S["id"]}'), 'série -> só court_id (mesma arena)')
    rejected_immutable(*rest('PATCH', 'recurring_reservations', TA, {'customer_id': Q['cust_a3']}, f'?id=eq.{S["id"]}'), 'série -> só customer_id (mesma org)')
    s_intact()


def s3():
    s, b, raw = rest('PATCH', 'recurring_reservations', TA, {'notes': 'nota A2', 'default_price': 12000}, f'?id=eq.{S["id"]}')
    assert s == 200 and b and b[0]['notes'] == 'nota A2' and b[0]['default_price'] == 12000, f'PostgREST notes/price: {s} {raw[:160]}'
    s, b, raw = api('PATCH', f'/recurring-reservations/{S["id"]}', TA, {'notes': 'nota via API', 'default_price': 13000, 'customer_id': Q['cust_a3']})
    assert s == 200 and b['notes'] == 'nota via API' and b['default_price'] == 13000, f'API PATCH: {s} {raw[:160]}'
    s_intact()  # customer_id enviado pela API é ignorado (fora da lista permitida)
    s, _, raw = api('POST', f'/recurring-reservations/{S["id"]}/pause', TA, {'cancel_future': False})
    assert s == 200, f'pausar: {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{S["id"]}/reactivate', TA, {})
    assert s == 200, f'reativar: {s} {raw[:160]}'
    s_intact()


def s4():
    occ = svc_get('reservations', {'recurring_reservation_id': f'eq.{S["id"]}', 'select': 'occurrence_date', 'order': 'occurrence_date.asc'})
    from_date = occ[1]['occurrence_date']
    s, b, raw = api('POST', f'/recurring-reservations/{S["id"]}/reschedule', TA, {'from_date': from_date, 'court_id': COURT_A1B, 'start_time': '21:00', 'end_time': '22:00',
                                                                                'skip_conflicts': True})
    assert s == 201, f'"Esta e as próximas": {s} {raw[:160]}'
    new = svc_get('recurring_reservations', {'id': f'eq.{b["id"]}', 'select': 'organization_id,arena_id,court_id,customer_id'})[0]
    assert new == {'organization_id': ORG_A, 'arena_id': ARENA_A, 'court_id': COURT_A1B, 'customer_id': CUST_A}, new
    s_intact()  # série antiga mantém os vínculos; só status/end_date mudam


def p9_consistency():
    """Invariantes em TODOS os registros das duas organizações de teste."""
    orgs = f'in.({ORG_A},{ORG_B})'
    bad = []
    for r in svc_get('reservations', {'organization_id': orgs, 'select': 'id,organization_id,arena_id,court:courts(organization_id,arena_id),arena:arenas(organization_id),customer:customers(organization_id)'}):
        if r['arena']['organization_id'] != r['organization_id']:
            bad.append(('reserva x arena', r['id']))
        if r['court']['organization_id'] != r['organization_id'] or r['court']['arena_id'] != r['arena_id']:
            bad.append(('reserva x quadra', r['id']))
        if r['customer'] and r['customer']['organization_id'] != r['organization_id']:
            bad.append(('reserva x cliente', r['id']))
    for t in ('courts', 'business_hours'):
        for r in svc_get(t, {'organization_id': orgs, 'select': 'id,organization_id,arena:arenas(organization_id)'}):
            if r['arena']['organization_id'] != r['organization_id']:
                bad.append((t, r['id']))
    for r in svc_get('customers', {'organization_id': orgs, 'select': 'id,organization_id,arena:arenas(organization_id)'}):
        if r['arena'] and r['arena']['organization_id'] != r['organization_id']:
            bad.append(('customers', r['id']))
    for r in svc_get('recurring_reservations', {'organization_id': orgs, 'select': 'id,organization_id,arena_id,court:courts(organization_id,arena_id),arena:arenas(organization_id),customer:customers(organization_id)'}):
        if (r['arena']['organization_id'] != r['organization_id'] or r['court']['organization_id'] != r['organization_id']
                or r['court']['arena_id'] != r['arena_id'] or (r['customer'] and r['customer']['organization_id'] != r['organization_id'])):
            bad.append(('recurring_reservations', r['id']))
    for a in svc_get('arenas', {'id': f'in.({ARENA_A},{ARENA_A2},{ARENA_B})', 'select': 'id,organization_id'}):
        expected = ORG_B if a['id'] == ARENA_B else ORG_A
        if a['organization_id'] != expected:
            bad.append(('arena', a['id']))
    assert not bad, f'{len(bad)} inconsistência(s): {bad[:5]}'


def final_state():
    bad = svc_get('reservations', {'organization_id': f'eq.{ORG_A}', 'court_id': f'eq.{COURT_B}', 'select': 'id'})
    bad += svc_get('reservations', {'organization_id': f'eq.{ORG_A}', 'arena_id': f'eq.{ARENA_B}', 'select': 'id'})
    bad += svc_get('reservations', {'organization_id': f'eq.{ORG_A}', 'customer_id': f'eq.{CUST_B}', 'select': 'id'})
    assert not bad, f'{len(bad)} reserva(s) cruzada(s) gravada(s)'
    assert not svc_get('customers', {'organization_id': f'eq.{ORG_A}', 'arena_id': f'eq.{ARENA_B}', 'select': 'id'})
    assert not svc_get('business_hours', {'organization_id': f'eq.{ORG_A}', 'arena_id': f'eq.{ARENA_B}', 'select': 'id'})


for name, fn in [
    ('R1 FAIL org A + arena A + quadra B', r1), ('R2 FAIL org A + arena B + quadra B', r2), ('R3 FAIL org A + arena B + quadra A', r3),
    ('R4 FAIL cliente de outra org', r4), ('R8 PASS reserva A/A/A + cliente A', r8), ('R5 FAIL UPDATE quadra -> B', r5),
    ('R6 FAIL UPDATE arena -> B', r6), ('R6b FAIL UPDATE cliente -> B (linha intacta)', r6b), ('R7 FAIL arena A1 + quadra A2 (mesma org)', r7),
    ('R7b PASS troca de quadra na mesma arena', r7b), ('R9 PASS customer_id NULL', r9), ('R10 API interna válida + recusa amigável', r10),
    ('R11 bloqueio válido + recusa amigável', r11), ('R12 reserva pública válida', r12), ('R13 recorrência: criação + ocorrência protegida', r13_recurring),
    ('C1 FAIL quadra org A + arena B', c1), ('C2 PASS quadra válida + FAIL UPDATE -> arena B', c2),
    ('H1 FAIL horário org A + arena B', h1), ('H2 PASS horário org A + arena A', h2),
    ('K1 FAIL cliente org A + arena B', k1), ('K2 PASS cliente arena A e arena NULL', k2),
    ('P0 setup: OWNER A também OWNER da Org B', p_setup),
    ('P1 FAIL quadra -> outra arena da mesma org (reserva segue cancelável)', p1), ('P2 FAIL quadra -> org B', p2),
    ('P3 FAIL arena -> org B', p3), ('P4 FAIL horário -> outra arena', p4), ('P5 FAIL horário -> org B', p5),
    ('P6 FAIL cliente -> org B', p6), ('P7 PASS cliente arena A1 -> A2 (mesma org)', p7), ('P8 FAIL cliente -> arena B', p8),
    ('Q0 setup reserva/cliente', q_setup), ('Q1 FAIL reserva -> org B (membro das duas)', q1),
    ('Q2 FAIL reserva -> conjunto coerente da org B (RGT02)', q2), ('Q3 FAIL reserva -> outra arena da mesma org', q3),
    ('Q4 PASS reserva -> outra quadra da mesma arena', q4), ('Q5 PASS reserva -> outro cliente da mesma org', q5),
    ('S0 setup série', s_setup), ('S1 FAIL série -> conjunto coerente da org B (RGT02)', s1),
    ('S2 FAIL série -> só court_id / só customer_id', s2), ('S3 PASS notes/price/pausar/reativar', s3),
    ('S4 PASS "Esta e as próximas"', s4),
    ('P9 consistência: zero inconsistências', p9_consistency),
    ('FINAL nenhum registro cruzado gravado', final_state),
]:
    check(name, fn)

ok = sum(1 for v in results.values() if v == 'PASS')
print(f'\n== {ok}/{len(results)} PASS (run {RUN}, org A {ORG_A}, org B {ORG_B}) ==')
sys.exit(0 if ok == len(results) else 1)
