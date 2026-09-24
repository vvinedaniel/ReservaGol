#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A4 — validação forte da reserva pública.

Rodar com o app local em execução (BASE_URL). Não exige migration.

Cria UMA organização nova e isolada (is_demo), com arena publicada, quadras (1 inativa) e
uma segunda arena NÃO publicada, e ataca DIRETO /api/public/availability e
/api/public/reserve (sem passar pela UI). Horários por dia da semana (relativos a hoje, SP):
  hoje      00:00 -> 00:00 (dia inteiro: permite testar horários já iniciados)
  hoje + 1  08:00 -> 00:00 (inclui o slot 23:00 -> 00:00)
  hoje + 2  08:00 -> 22:00
  hoje + 3  FECHADO
  demais    08:00 -> 00:00

Variáveis de ambiente obrigatórias (nenhum valor é impresso):
  BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcional: TEST_EMAIL_DOMAIN (padrão reservagol.test)

Uso: python tests/security_a4_public_booking.py
"""
import json
import os
import random
import sys
import threading
import time
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
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
RAW_ERR = ['violates', 'constraint', 'duplicate key', 'no_overlap', '23P01', 'RGT0', 'syntax', 'stack']
results = {}


def http(method, url, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, status = r.read().decode(), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(), e.code
    try:
        return status, (json.loads(raw) if raw else None), raw
    except ValueError:
        return status, None, raw


def api(method, path, token=None, body=None, timeout=60):
    return http(method, BASE + path, {'Authorization': f'Bearer {token}'} if token else {}, body, timeout)


def svc(method, table, body=None, query=''):
    return http(method, f'{SB}/rest/v1/{table}{query}', {**SVC, 'Prefer': 'return=representation'}, body)


def rows(table, params):
    s, b, raw = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params)}', SVC)
    assert s == 200, f'svc {table} {s} {raw[:160]}'
    return b


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


def friendly(raw):
    return not any(k.lower() in (raw or '').lower() for k in RAW_ERR)


def phone():
    return '119' + ''.join(random.choice('0123456789') for _ in range(8))


# ----------------------------------------------------------------------------- setup
TODAY = datetime.now(SP).date()


def d(n):
    return str(TODAY + timedelta(days=n))


def wd(n):
    return (TODAY + timedelta(days=n)).isoweekday() % 7


HOURS = {}
for i in range(7):
    HOURS[i] = {'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False}
HOURS[wd(0)] = {'weekday': wd(0), 'open_time': '00:00', 'close_time': '00:00', 'closed': False}
HOURS[wd(2)] = {'weekday': wd(2), 'open_time': '08:00', 'close_time': '22:00', 'closed': False}
HOURS[wd(3)] = {'weekday': wd(3), 'open_time': None, 'close_time': None, 'closed': True}

print(f'== Security A4 — public booking — run {RUN} (hoje {TODAY}) ==')
email = f'a4-owner-{RUN}@{DOMAIN}'
s, u, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
assert s == 200, f'login {s} {raw[:200]}'
TO = t['access_token']
s, b, raw = api('POST', '/onboarding', TO, {
    'organization': {'name': f'A4 Org {RUN}', 'owner_name': 'Teste A4', 'phone': '11999990000', 'is_demo': True},
    'arena': {'name': f'Arena A4 {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
    'courts': [{'name': 'Quadra 1', 'type': 'SOCIETY'}, {'name': 'Quadra 2', 'type': 'SOCIETY'}, {'name': 'Quadra Inativa', 'type': 'SOCIETY', 'active': False}],
    'hours': list(HOURS.values()),
    'default_reservation_minutes': 60,
})
assert s == 200, f'onboarding {s} {raw[:200]}'
ORG = b['organization_id']
_, arenas, _ = api('GET', f'/arenas?organization_id={ORG}', TO)
ARENA = arenas[0]['id']
_, courts, _ = api('GET', f'/courts?organization_id={ORG}', TO)
CN = {c['name']: c['id'] for c in courts}
C1, C2, CINACTIVE = CN['Quadra 1'], CN['Quadra 2'], CN['Quadra Inativa']
SLUG = f'a4-{RUN}'
s, _, raw = api('PUT', f'/arenas/{ARENA}', TO, {'slug': SLUG, 'description': 'Arena de teste A4', 'cover_image_url': 'https://example.com/cover.jpg'})
assert s == 200, f'perfil {s} {raw[:200]}'
s, _, raw = api('PUT', f'/arenas/{ARENA}', TO, {'public_booking_enabled': True})
assert s == 200, f'publicar {s} {raw[:200]}'
# Segunda arena da mesma org, NÃO publicada (V16).
UNPUB_SLUG = f'a4-unpub-{RUN}'
s, b, raw = http('POST', f'{SB}/rest/v1/arenas', {'apikey': PUB_KEY, 'Authorization': f'Bearer {TO}', 'Prefer': 'return=representation'},
                 {'organization_id': ORG, 'name': f'Arena A4 Oculta {RUN}', 'slug': UNPUB_SLUG, 'active': True, 'public_booking_enabled': False})
assert s == 201, f'arena não publicada {s} {raw[:200]}'
UNPUB_ARENA = b[0]['id']
s, b, raw = http('POST', f'{SB}/rest/v1/courts', {'apikey': PUB_KEY, 'Authorization': f'Bearer {TO}', 'Prefer': 'return=representation'},
                 {'organization_id': ORG, 'arena_id': UNPUB_ARENA, 'name': 'Quadra Oculta'})
assert s == 201, f'quadra oculta {s} {raw[:200]}'
UNPUB_COURT = b[0]['id']
print(f'org={ORG} slug={SLUG}')


def payload(**kw):
    p = {'slug': SLUG, 'court_id': C1, 'date': d(1), 'start_time': '10:00', 'end_time': '11:00', 'name': 'Jogador A4',
         'phone': phone(), 'email': None, 'accept_terms': True, 'idempotency_key': str(uuid.uuid4())}
    p.update(kw)
    return p


def reserve(**kw):
    return api('POST', '/public/reserve', None, payload(**kw))


def refused(res, what, status=400):
    s, b, raw = res
    assert s == status and isinstance(b, dict) and b.get('error'), f'{what}: esperado {status}, veio {s} {raw[:160]}'
    assert friendly(raw), f'{what}: detalhe interno exposto: {raw[:160]}'


def avail(date, court=None, slug=None):
    q = urllib.parse.urlencode({'slug': slug or SLUG, 'court_id': court or C1, 'date': date})
    return api('GET', f'/public/availability?{q}', timeout=15)


def counts():
    return len(rows('customers', {'organization_id': f'eq.{ORG}', 'select': 'id'})), len(rows('reservations', {'organization_id': f'eq.{ORG}', 'select': 'id'}))


# ----------------------------------------------------------------------------- data
def v1():
    for bad in ('abc', '24/09/2026', '2026-9-24', '', f'{d(1)}T10:00', 20260924, None):
        refused(reserve(date=bad, start_time='12:00', end_time='13:00'), f'data {bad!r}')


def v2():
    for bad in ('2026-02-31', '2026-13-10', '2027-02-29', '2026-00-10'):
        refused(reserve(date=bad), f'data inexistente {bad}')


def v3():
    refused(reserve(date=d(-1)), 'data passada')


def v4():
    refused(reserve(date=d(91)), 'data > hoje+90')
    s, b, raw = reserve(date=d(90), start_time='10:00', end_time='11:00')
    assert s == 201, f'hoje+90 é o limite inclusivo e deveria aceitar: {s} {raw[:160]}'


# ----------------------------------------------------------------------------- slot
def v5():
    refused(reserve(start_time='07:00', end_time='08:00'), 'antes da abertura')
    refused(reserve(date=d(2), start_time='22:00', end_time='23:00'), 'depois do fechamento (22:00)')


def v6():
    refused(reserve(start_time='08:00', end_time='09:30'), 'duração diferente da padrão')
    refused(reserve(start_time='08:00', end_time='10:00'), 'dois slots juntos')


def v7():
    refused(reserve(start_time='08:30', end_time='09:30'), 'slot desalinhado')
    refused(reserve(start_time='8:00', end_time='9:00'), 'horário sem zero à esquerda')
    refused(reserve(start_time='08:00:00', end_time='09:00:00'), 'horário com segundos')


def v8():
    refused(reserve(start_time='20:00', end_time='19:00'), 'intervalo invertido 20:00->19:00')
    refused(reserve(start_time='23:30', end_time='00:30'), 'meia-noite inventada 23:30->00:30')
    refused(reserve(date=d(2), start_time='23:00', end_time='00:00'), '23:00->00:00 em dia que fecha 22:00')


def v9():
    refused(reserve(date=d(3)), 'dia fechado')


# ----------------------------------------------------------------------------- campos
def v10():
    for bad in ('', '   ', 'a', 'x' * 81, 123, None):
        refused(reserve(name=bad, start_time='09:00', end_time='10:00'), f'nome {bad!r}'[:40])


def v11():
    for bad in ('abc', '---', '', None, 11988887777):
        refused(reserve(phone=bad, start_time='09:00', end_time='10:00'), f'telefone {bad!r}')


def v12():
    for bad in ('123', '119888', '1' * 14, '0119888877776', '9' * 40):
        refused(reserve(phone=bad, start_time='09:00', end_time='10:00'), f'telefone fora dos limites {bad[:15]}')


def v13():
    for bad in ('a@b', 'sem-arroba.com', 'a b@c.com', 'x' * 250 + '@a.com', 42):
        refused(reserve(email=bad, start_time='09:00', end_time='10:00'), f'email {str(bad)[:20]}')


def v14():
    for bad in ('true', 1, 'yes', None, False):
        refused(reserve(accept_terms=bad, start_time='09:00', end_time='10:00'), f'accept_terms {bad!r}')
    p = payload(start_time='09:00', end_time='10:00')
    del p['accept_terms']
    refused(api('POST', '/public/reserve', None, p), 'accept_terms ausente')


def v15():
    for bad in ('x' * 500, 'curta', 'tem espaço aqui', {'a': 1}, ['x' * 10], 12345678):
        refused(reserve(idempotency_key=bad, start_time='09:00', end_time='10:00'), f'idempotency {str(bad)[:20]}')


def v16():
    refused(reserve(slug=UNPUB_SLUG, court_id=UNPUB_COURT), 'arena não publicada', 404)
    refused(avail(d(1), court=UNPUB_COURT, slug=UNPUB_SLUG), 'availability arena não publicada', 404)


def v17():
    refused(reserve(court_id=CINACTIVE), 'quadra inativa', 404)
    refused(reserve(court_id=UNPUB_COURT), 'quadra de outra arena', 404)


def v17b_formats():
    for bad in ('NaoUsaMaiuscula', 'a--b', 'x' * 61, "a4'; drop", None, 5):
        refused(reserve(slug=bad), f'slug {bad!r}'[:40])
    for bad in ('1 or 1=1', 'abc', '', None, str(uuid.uuid4())[:-1]):
        refused(reserve(court_id=bad), f'court_id {bad!r}'[:40])
    refused(api('POST', '/public/reserve', None, [payload()]), 'corpo em array')
    refused(avail(d(1), court='abc'), 'availability court_id inválido')
    refused(avail(d(1), slug='Slug Invalido'), 'availability slug inválido')


# ----------------------------------------------------------------------------- válidos
def v18():
    s, b, raw = reserve(start_time='10:00', end_time='11:00')
    assert s == 201 and b.get('public_code'), f'slot comum: {s} {raw[:160]}'
    r = rows('reservations', {'public_code': f'eq.{b["public_code"]}', 'select': 'start_at,end_at,status,source'})[0]
    assert r['status'] == 'CONFIRMED' and r['source'] == 'PUBLIC_WEB'


def v18b_ignores_extra_fields():
    s, b, raw = reserve(start_time='11:00', end_time='12:00', status='BLOCKED', source='INTERNAL', organization_id=str(uuid.uuid4()),
                        arena_id=str(uuid.uuid4()), customer_id=str(uuid.uuid4()))
    assert s == 201, f'campos extras deveriam ser ignorados: {s} {raw[:160]}'
    r = rows('reservations', {'public_code': f'eq.{b["public_code"]}', 'select': 'organization_id,arena_id,status,source'})[0]
    assert r == {'organization_id': ORG, 'arena_id': ARENA, 'status': 'CONFIRMED', 'source': 'PUBLIC_WEB'}, r


def v19():
    s, b, raw = reserve(start_time='23:00', end_time='00:00')
    assert s == 201, f'23:00->00:00 é slot real (fecha 00:00): {s} {raw[:160]}'
    r = rows('reservations', {'public_code': f'eq.{b["public_code"]}', 'select': 'start_at,end_at'})[0]
    st = datetime.fromisoformat(r['start_at'].replace('Z', '+00:00')).astimezone(SP)
    en = datetime.fromisoformat(r['end_at'].replace('Z', '+00:00')).astimezone(SP)
    assert st.strftime('%Y-%m-%d %H:%M') == f'{d(1)} 23:00' and en.strftime('%Y-%m-%d %H:%M') == f'{d(2)} 00:00', (r['start_at'], r['end_at'])


def v20():
    key = str(uuid.uuid4())
    p = payload(start_time='12:00', end_time='13:00', idempotency_key=key)
    s1, b1, raw1 = api('POST', '/public/reserve', None, p)
    s2, b2, raw2 = api('POST', '/public/reserve', None, p)
    assert s1 == 201 and s2 == 200 and b2.get('idempotent') is True, f'{s1} {raw1[:80]} | {s2} {raw2[:80]}'
    assert b1['public_code'] == b2['public_code']
    assert len(rows('reservations', {'arena_id': f'eq.{ARENA}', 'idempotency_key': f'eq.{key}', 'select': 'id'})) == 1
    # Fallback legado da UI: String(Date.now()) + Math.random()
    legacy = f'{int(time.time() * 1000)}{random.random()}'
    s, b, raw = reserve(start_time='13:00', end_time='14:00', idempotency_key=legacy)
    assert s == 201, f'chave no formato do fallback legado: {s} {raw[:160]}'


def v21():
    bar = threading.Barrier(2)
    out = [None, None]

    def go(i):
        p = payload(court_id=C2, start_time='14:00', end_time='15:00')
        bar.wait()
        out[i] = api('POST', '/public/reserve', None, p)
    ts = [threading.Thread(target=go, args=(i,)) for i in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted([out[0][0], out[1][0]]) == [201, 409], (out[0][0], out[1][0])
    loser = out[0] if out[0][0] == 409 else out[1]
    assert friendly(loser[2]), loser[2][:160]
    act = rows('reservations', {'court_id': f'eq.{C2}', 'status': 'neq.CANCELLED', 'start_at': f'eq.{d(1)}T14:00:00-03:00', 'select': 'id'})
    assert len(act) == 1, f'{len(act)} reservas ativas'


def v22():
    before = counts()
    phones = [phone() for _ in range(9)]
    attempts = [
        payload(phone=phones[0], date=d(-1)), payload(phone=phones[1], date=d(91)), payload(phone=phones[2], date=d(3)),
        payload(phone=phones[3], start_time='08:30', end_time='09:30'), payload(phone=phones[4], start_time='20:00', end_time='19:00'),
        payload(phone=phones[5], accept_terms='true'), payload(phone=phones[6], email='ruim@'),
        payload(phone=phones[7], name='   '), payload(phone=phones[8], court_id=CINACTIVE),
    ]
    for p in attempts:
        s, _, raw = api('POST', '/public/reserve', None, p)
        assert s in (400, 404), f'entrada inválida aceita: {s} {raw[:120]}'
    assert counts() == before, f'contagem mudou: {before} -> {counts()}'
    for ph in phones:
        assert not rows('customers', {'organization_id': f'eq.{ORG}', 'phone': f'eq.{ph}', 'select': 'id'}), 'customer criado por entrada inválida'


# ----------------------------------------------------------------------------- availability
def v23():
    refused(avail(d(-1)), 'availability data passada')


def v24():
    refused(avail(d(91)), 'availability > 90 dias')
    s, b, raw = avail(d(90))
    assert s == 200 and b['closed'] is False and b['slots'], f'availability hoje+90: {s} {raw[:120]}'
    for bad in ('abc', '2026-02-31'):
        refused(avail(bad), f'availability data {bad}')


def v25():
    s, b, raw = avail(d(0))
    assert s == 200 and not b['closed'], f'availability hoje: {s} {raw[:120]}'
    now = datetime.now(SP)
    past = [x for x in b['slots'] if datetime.strptime(f'{d(0)} {x["start"]}', '%Y-%m-%d %H:%M').replace(tzinfo=SP) <= now]
    assert past, 'hoje deveria ter ao menos um slot já iniciado (dia inteiro 00:00->00:00)'
    assert all(x['available'] is False for x in past), [x for x in past if x['available']][:3]
    started = past[-1]
    refused(reserve(date=d(0), start_time=started['start'], end_time=started['end']), f'reservar slot já iniciado {started["start"]}')
    future = [x for x in b['slots'] if x not in past]
    if future:
        assert future[-1]['available'] is True, 'slot futuro livre deveria estar disponível'


def v26():
    s, b, raw = avail(d(1))
    assert s == 200, raw[:120]
    by = {x['start']: x['available'] for x in b['slots']}
    assert by.get('10:00') is False and by.get('23:00') is False, 'slots ocupados (V18/V19) deveriam estar indisponíveis'
    assert by.get('16:00') is True, 'slot futuro livre deveria continuar disponível'
    s, b, raw = avail(d(3))
    assert s == 200 and b == {'closed': True, 'slots': []}, f'dia fechado: {raw[:120]}'
    assert 'customer' not in raw and 'phone' not in raw and 'name' not in raw, 'availability não pode expor PII'


def v27():
    try:
        for bad in (0, 1, -60, 100000):
            s, _, raw = svc('PATCH', 'organizations', {'default_reservation_minutes': bad}, f'?id=eq.{ORG}')
            assert s == 200, f'preparar configuração inválida {bad}: {s} {raw[:120]}'
            t0 = time.time()
            refused(avail(d(1)), f'availability com minutos={bad}', 503)
            refused(reserve(start_time='16:00', end_time='17:00'), f'reserve com minutos={bad}', 503)
            assert time.time() - t0 < 10, f'resposta lenta com minutos={bad}'
    finally:
        svc('PATCH', 'organizations', {'default_reservation_minutes': 60}, f'?id=eq.{ORG}')
    s, b, _ = avail(d(1))
    assert s == 200 and len(b['slots']) == 16, 'configuração restaurada deveria voltar a gerar 16 slots'


for name, fn in [
    ('V1 data em formato inválido', v1), ('V2 data inexistente', v2), ('V3 data passada', v3), ('V4 data > hoje+90 (hoje+90 aceita)', v4),
    ('V5 fora do expediente', v5), ('V6 duração diferente da padrão', v6), ('V7 slot desalinhado / formato de hora', v7),
    ('V8 intervalo inventado cruzando meia-noite', v8), ('V9 dia fechado', v9),
    ('V10 nome inválido', v10), ('V11 telefone que normaliza para vazio', v11), ('V12 telefone fora dos limites', v12),
    ('V13 e-mail inválido', v13), ('V14 accept_terms diferente de true', v14), ('V15 idempotency_key inválida', v15),
    ('V16 arena não publicada', v16), ('V17 quadra inativa / de outra arena', v17), ('V17b formatos de slug/court_id/corpo', v17b_formats),
    ('V18 reserva válida em slot comum', v18), ('V18b campos extras do payload ignorados', v18b_ignores_extra_fields),
    ('V19 slot 23:00 -> 00:00', v19), ('V20 idempotência (mesma chave -> mesma reserva)', v20),
    ('V21 concorrência {201,409}', v21), ('V22 entrada inválida não cria customer/reserva', v22),
    ('V23 availability data passada', v23), ('V24 availability > 90 dias', v24), ('V25 availability hoje: iniciados indisponíveis', v25),
    ('V26 availability normal (ocupados/livres/fechado)', v26), ('V27 default_reservation_minutes inválido', v27),
]:
    check(name, fn)

ok = sum(1 for v in results.values() if v == 'PASS')
print(f'\n== {ok}/{len(results)} PASS (run {RUN}, org {ORG}) ==')
sys.exit(0 if ok == len(results) else 1)
