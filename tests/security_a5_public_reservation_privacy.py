#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A5 — privacidade da consulta pública de reserva.

Rodar com o app local em execução (BASE_URL). Não exige migration.

AUTOSSUFICIENTE E AUTOLIMPANTE: cria uma organização isolada (is_demo) com OWNER efêmero,
arena publicada, quadra e horários; executa os casos; e no `finally` remove, via service
role e na ordem segura para as FKs RESTRICT do A3:
  reservations -> customers -> courts -> business_hours -> arenas -> organization -> usuário Auth.
Se a limpeza falhar, os IDs restantes são impressos e o processo sai com erro.

Caso central (P1): um cliente "Maria" já existe com telefone X; um visitante reserva
publicamente com o MESMO telefone e outro nome; a reserva reaproveita o cadastro da Maria
(customer_id igual); a consulta pública por código NÃO pode revelar nada dela.

Variáveis de ambiente obrigatórias (nenhum valor é impresso):
  BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcional: TEST_EMAIL_DOMAIN (padrão reservagol.test)

Uso: python tests/security_a5_public_reservation_privacy.py
"""
import json
import os
import random
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
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
results = {}

TOP_KEYS = {'public_code', 'start_at', 'end_at', 'status', 'court', 'arena'}
COURT_KEYS = {'name'}
ARENA_KEYS = {'name', 'slug', 'address', 'number', 'neighborhood', 'city', 'state', 'whatsapp', 'latitude', 'longitude'}


def http(method, url, headers=None, body=None):
    """Retorna (status, json|None, raw, headers)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw, status, hdrs = r.read().decode(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw, status, hdrs = e.read().decode(), e.code, dict(e.headers)
    try:
        return status, (json.loads(raw) if raw else None), raw, {k.lower(): v for k, v in hdrs.items()}
    except ValueError:
        return status, None, raw, {k.lower(): v for k, v in hdrs.items()}


def api(method, path, token=None, body=None):
    return http(method, BASE + path, {'Authorization': f'Bearer {token}'} if token else {}, body)


def svc(method, table, body=None, query=''):
    return http(method, f'{SB}/rest/v1/{table}{query}', {**SVC, 'Prefer': 'return=representation'}, body)


def rows(table, params):
    s, b, raw, _ = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params)}', SVC)
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


def unique_phone():
    return '119' + ''.join(random.choice('0123456789') for _ in range(8))


# ----------------------------------------------------------------------------- estado / limpeza
ST = {'org': None, 'user': None}
D = str(datetime.now(SP).date() + timedelta(days=2))  # dentro da janela pública do A4


def cleanup():
    """Remove tudo o que este teste criou, na ordem segura para as FKs RESTRICT (A3)."""
    org, uid = ST['org'], ST['user']
    problems = []
    if org:
        for table, q in (('reservations', f'?organization_id=eq.{org}'), ('customers', f'?organization_id=eq.{org}'),
                         ('courts', f'?organization_id=eq.{org}'), ('business_hours', f'?organization_id=eq.{org}'),
                         ('arenas', f'?organization_id=eq.{org}'), ('organizations', f'?id=eq.{org}')):
            try:
                s, _, raw, _ = svc('DELETE', table, query=q)
                if s not in (200, 204):
                    problems.append(f'{table} (org {org}): HTTP {s} {raw[:160]}')
            except Exception as e:  # noqa: BLE001
                problems.append(f'{table} (org {org}): {type(e).__name__}: {e}')
        try:
            left = {t: len(rows(t, {'organization_id': f'eq.{org}', 'select': 'id'})) for t in ('reservations', 'customers', 'courts', 'business_hours', 'arenas')}
            left['organizations'] = len(rows('organizations', {'id': f'eq.{org}', 'select': 'id'}))
            if any(left.values()):
                problems.append(f'restantes na org {org}: {left}')
        except Exception as e:  # noqa: BLE001
            problems.append(f'conferência da limpeza (org {org}): {type(e).__name__}: {e}')
    if uid:
        s, _, raw, _ = http('DELETE', f'{SB}/auth/v1/admin/users/{uid}', SVC)
        if s not in (200, 204):
            problems.append(f'usuário Auth {uid}: HTTP {s} {raw[:160]}')
    return problems


def setup():
    email = f'a5-owner-{RUN}@{DOMAIN}'
    s, u, raw, _ = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    ST['user'] = u['id']
    s, t, raw, _ = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    ST['token'] = t['access_token']
    s, b, raw, _ = api('POST', '/onboarding', ST['token'], {
        'organization': {'name': f'A5 Org {RUN}', 'owner_name': 'Teste A5', 'phone': '11999990000', 'is_demo': True},
        'arena': {'name': f'Arena A5 {RUN}', 'address': 'Rua Teste', 'number': '1', 'neighborhood': 'Centro', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
        'courts': [{'name': 'Quadra A5', 'type': 'SOCIETY'}],
        'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)],
        'default_reservation_minutes': 60,
    })
    assert s == 200, f'onboarding {s} {raw[:200]}'
    ST['org'] = b['organization_id']
    _, arenas, _, _ = api('GET', f'/arenas?organization_id={ST["org"]}', ST['token'])
    ST['arena'] = arenas[0]['id']
    _, courts, _, _ = api('GET', f'/courts?organization_id={ST["org"]}', ST['token'])
    ST['court'] = courts[0]['id']
    ST['slug'] = f'a5-{RUN}'
    s, _, raw, _ = api('PUT', f'/arenas/{ST["arena"]}', ST['token'], {'slug': ST['slug'], 'description': 'Arena de teste A5', 'cover_image_url': 'https://example.com/cover.jpg'})
    assert s == 200, f'perfil {s} {raw[:200]}'
    s, _, raw, _ = api('PUT', f'/arenas/{ST["arena"]}', ST['token'], {'public_booking_enabled': True})
    assert s == 200, f'publicar {s} {raw[:200]}'
    # Cliente "Maria" pré-existente (cadastro interno da arena).
    ST['maria'] = {'name': 'Maria Privacidade A5', 'phone': unique_phone(), 'email': 'maria-private-a5@example.test'}
    s, c, raw, _ = api('POST', '/customers', ST['token'], {'organization_id': ST['org'], 'arena_id': ST['arena'], **ST['maria']})
    assert s == 201, f'cliente Maria {s} {raw[:200]}'
    ST['maria']['id'] = c['id']


def book(start, phone, name='Atacante Teste', key=None):
    end = f'{int(start[:2]) + 1:02d}:00'
    return api('POST', '/public/reserve', None, {'slug': ST['slug'], 'court_id': ST['court'], 'date': D, 'start_time': start, 'end_time': end,
                                                 'name': name, 'phone': phone, 'email': None, 'accept_terms': True,
                                                 'idempotency_key': key or str(uuid.uuid4())})


def lookup(code):
    return api('GET', f'/public/reservation/{urllib.parse.quote(code)}')


def assert_private(b, raw, extra_forbidden=()):
    """Allowlist positiva + ausência de qualquer identidade de cliente."""
    assert isinstance(b, dict), f'resposta não é objeto: {raw[:120]}'
    assert set(b) == TOP_KEYS, f'chaves de 1º nível fora da allowlist: {sorted(set(b) ^ TOP_KEYS)}'
    assert isinstance(b['court'], dict) and set(b['court']) == COURT_KEYS, f'court fora da allowlist: {b["court"]}'
    assert isinstance(b['arena'], dict) and set(b['arena']) == ARENA_KEYS, f'arena fora da allowlist: {sorted(set(b["arena"]) ^ ARENA_KEYS)}'
    low = raw.lower()
    for word in ('customer', 'phone', 'email', 'organization_id', 'created_by', 'idempotency', 'notes'):
        assert word not in low, f'termo proibido na resposta: {word}'
    m = ST['maria']
    for secret in (m['name'], m['phone'], m['email'], m['id'], 'Maria', 'Atacante', *extra_forbidden):
        assert secret.lower() not in low, 'dado pessoal presente na resposta pública'


# ----------------------------------------------------------------------------- casos
def p1():
    m = ST['maria']
    s, b, raw, _ = book('10:00', m['phone'], name='Atacante Teste')
    assert s == 201, f'reserva pública com o telefone da Maria: {s} {raw[:160]}'
    ST['p1_code'] = b['public_code']
    r = rows('reservations', {'public_code': f'eq.{b["public_code"]}', 'select': 'customer_id'})[0]
    assert r['customer_id'] == m['id'], 'cenário não reproduzido: a reserva deveria reaproveitar o cadastro da Maria'
    s, b, raw, _ = lookup(ST['p1_code'])
    assert s == 200, f'consulta pública: {s} {raw[:160]}'
    assert_private(b, raw)
    assert b['public_code'] == ST['p1_code'] and b['status'] == 'CONFIRMED' and b['court'] == {'name': 'Quadra A5'}


def p2():
    ph = unique_phone()
    s, b, raw, _ = book('11:00', ph, name='Novo Jogador A5')
    assert s == 201, f'reserva com cliente novo: {s} {raw[:160]}'
    s, b2, raw2, _ = lookup(b['public_code'])
    assert s == 200, raw2[:160]
    assert_private(b2, raw2, extra_forbidden=(ph, 'Novo Jogador'))


def p3():
    ph = unique_phone()
    s, b, raw, _ = book('12:00', ph)
    assert s == 201, raw[:160]
    code = b['public_code']
    rid = rows('reservations', {'public_code': f'eq.{code}', 'select': 'id'})[0]['id']
    s, _, raw, _ = api('POST', f'/reservations/{rid}/cancel', ST['token'], {'reason': 'A5 P3'})
    assert s == 200, f'cancelar pelo fluxo interno: {s} {raw[:160]}'
    s, b2, raw2, _ = lookup(code)
    assert s == 200 and b2['status'] == 'CANCELLED', f'{s} {raw2[:160]}'
    assert_private(b2, raw2, extra_forbidden=(ph,))


def p4():
    ph, key = unique_phone(), str(uuid.uuid4())
    s1, b1, raw1, _ = book('13:00', ph, key=key)
    s2, b2, raw2, _ = book('13:00', ph, key=key)
    assert s1 == 201 and s2 == 200 and b2.get('idempotent') is True and b1['public_code'] == b2['public_code'], f'{s1} {raw1[:80]} | {s2} {raw2[:80]}'
    s, b3, raw3, _ = lookup(b1['public_code'])
    assert s == 200, raw3[:160]
    assert_private(b3, raw3, extra_forbidden=(ph,))


def p5():
    code = f'RG-A5{RUN[:4].upper()}'
    ST['internal_code'] = code
    s, _, raw, _ = svc('POST', 'reservations', {'organization_id': ST['org'], 'arena_id': ST['arena'], 'court_id': ST['court'],
                                                'customer_id': ST['maria']['id'], 'start_at': f'{D}T15:00:00-03:00', 'end_at': f'{D}T16:00:00-03:00',
                                                'status': 'CONFIRMED', 'source': 'INTERNAL', 'public_code': code})
    assert s == 201, f'reserva INTERNAL com public_code artificial: {s} {raw[:160]}'
    s, b, raw, _ = lookup(code)
    assert s == 404, f'reserva interna não pode ser consultada publicamente: {s} {raw[:160]}'
    assert set(b or {}) == {'error'}, f'404 não pode conter dados: {raw[:160]}'


def p6():
    s1, b1, raw1, _ = lookup(f'RG-ZZ{RUN[:4].upper()}')
    s2, b2, raw2, _ = lookup(ST['internal_code'])
    assert s1 == 404 and s2 == 404, (s1, s2)
    assert b1 == b2, 'código inexistente e código não público devem ter resposta idêntica'


def p7():
    s, _, _, h = lookup(ST['p1_code'])
    assert s == 200 and 'no-store' in h.get('cache-control', ''), f'200 sem no-store: {h.get("cache-control")}'
    s, _, _, h = lookup(f'RG-ZZ{RUN[:4].upper()}')
    assert s == 404 and 'no-store' in h.get('cache-control', ''), f'404 sem no-store: {h.get("cache-control")}'


def p8():
    m = ST['maria']
    c = rows('customers', {'id': f'eq.{m["id"]}', 'select': 'name,phone,email'})[0]
    assert c == {'name': m['name'], 'phone': m['phone'], 'email': m['email']}, f'cadastro da Maria foi alterado: {c}'


def p9():
    s, b, raw, _ = http('GET', f'{SB}/rest/v1/customers?select=id,name,phone&limit=1', {'apikey': PUB_KEY})
    assert s in (401, 403), f'anon não pode ler customers: {s} {raw[:120]}'


exit_code = 1
try:
    print(f'== Security A5 — public reservation privacy — run {RUN} ==')
    setup()
    print(f'org={ST["org"]} slug={ST["slug"]}')
    for name, fn in [
        ('P1 ataque por telefone: reserva reaproveita Maria e consulta não revela nada', p1),
        ('P2 cliente novo: consulta sem dados pessoais', p2), ('P3 reserva cancelada: sem dados pessoais', p3),
        ('P4 idempotência: consulta sem dados pessoais', p4), ('P5 reserva INTERNAL com public_code -> 404', p5),
        ('P6 404 idêntico para inexistente e não público', p6), ('P7 Cache-Control no-store (200 e 404)', p7),
        ('P8 cadastro da Maria intacto', p8), ('P9 anon sem SELECT direto em customers', p9),
    ]:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    problems = cleanup()
    if problems:
        print('LIMPEZA FALHOU:')
        for p in problems:
            print('  - ' + p)
        exit_code = 3
    else:
        print(f'limpeza OK: organização {ST["org"]}, dados e usuário efêmero removidos')
sys.exit(exit_code)
