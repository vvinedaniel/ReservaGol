#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING B2 — códigos públicos fortes (RG- + 16 símbolos, CSPRNG).

Rodar depois de `yarn build`. Não exige migration.

AUTOSSUFICIENTE E AUTOLIMPANTE:
  * sobe o PRÓPRIO servidor Next (`next start`, porta B2_PORT, padrão 3109);
  * cria organização isolada (is_demo) com OWNER efêmero, arena publicada, quadra e horários;
  * usa IPs aleatórios da faixa de benchmark 198.18.0.0/15 via X-Forwarded-For;
  * no `finally` remove reservas -> clientes -> quadras -> horários -> arenas -> organização ->
    usuário Auth e APENAS os buckets de rate limit (A6) cujos hashes o teste calculou.
Nenhum segredo, telefone ou IP é impresso.

Variáveis obrigatórias: SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY,
TEST_ACCOUNT_PASSWORD. Opcionais: B2_PORT, TEST_EMAIL_DOMAIN.

Uso: python tests/security_b2_strong_public_codes.py
"""
import hashlib
import hmac
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

REQUIRED = ['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'TEST_ACCOUNT_PASSWORD']
missing = [k for k in REQUIRED if not os.environ.get(k)]
if missing:
    print('Variáveis de ambiente ausentes: ' + ', '.join(missing))
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('B2_PORT', '3109'))
BASE = f'http://localhost:{PORT}/api'
SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
SP = timezone(timedelta(hours=-3))
RUN = uuid.uuid4().hex[:8]
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
NEW_FORMAT = re.compile(rf'^RG-[{ALPHABET}]{{16}}$')
ALLOW_TOP = {'public_code', 'start_at', 'end_at', 'status', 'court', 'arena'}
ALLOW_ARENA = {'name', 'slug', 'address', 'number', 'neighborhood', 'city', 'state', 'whatsapp', 'latitude', 'longitude'}
results = {}

# ----------------------------------------------------------------------------- buckets A6 (HMAC igual ao servidor)
_SUBKEY = hmac.new(SECRET.encode(), b'reservagol-rate-limit-v1', hashlib.sha256).digest()
TRACKED = set()


def track(scope, *parts):
    enc = '|'.join(f'{len(str(p).encode())}:{p}' for p in (scope, *parts))
    h = hmac.new(_SUBKEY, enc.encode(), hashlib.sha256).hexdigest()
    TRACKED.add((scope, h))
    return h


def new_ip():
    return f'198.{random.randint(18, 19)}.{random.randint(0, 255)}.{random.randint(1, 254)}'


def new_phone():
    return '119' + ''.join(random.choice('0123456789') for _ in range(8))


def legacy_code():
    return 'RG-' + ''.join(random.choice(ALPHABET) for _ in range(6))


def new_style_code():
    return 'RG-' + ''.join(random.choice(ALPHABET) for _ in range(16))


# ----------------------------------------------------------------------------- HTTP
def http(method, url, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, status, hdrs = r.read().decode(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw, status, hdrs = e.read().decode(), e.code, dict(e.headers)
    try:
        body = json.loads(raw) if raw else None
    except ValueError:
        body = None
    return status, body, raw, {k.lower(): v for k, v in hdrs.items()}


def api(method, path, token=None, body=None, ip=None):
    h = {}
    if token:
        h['Authorization'] = f'Bearer {token}'
    if ip is not None:
        h['X-Forwarded-For'] = ip
    return http(method, BASE + path, h, body)


def svc(method, path, body=None):
    return http(method, f'{SB}/rest/v1/{path}', {**SVC, 'Prefer': 'return=representation'}, body)


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


# ----------------------------------------------------------------------------- servidor Next próprio
SERVER = {'proc': None, 'log': None}


def start_server():
    SERVER['log'] = open(os.path.join(ROOT, f'.b2-next-{RUN}.log'), 'ab')
    SERVER['proc'] = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '-p', str(PORT)], cwd=ROOT,
                                      stdout=SERVER['log'], stderr=subprocess.STDOUT, env=os.environ.copy())
    for _ in range(60):
        try:
            if http('GET', f'{BASE}/public/arenas', timeout=5)[0] == 200:
                return
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1)
    raise RuntimeError('servidor Next não subiu (rode `yarn build` antes)')


def stop_server():
    p = SERVER['proc']
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
    if SERVER['log']:
        SERVER['log'].close()


# ----------------------------------------------------------------------------- fixtures
ST = {'org': None, 'user': None}
TODAY = datetime.now(SP).date()
_slot = [0]


def next_slot():
    i = _slot[0]
    _slot[0] += 1
    day, hour = 2 + i // 16, 8 + i % 16
    return str(TODAY + timedelta(days=day)), f'{hour:02d}:00', ('00:00' if hour == 23 else f'{hour + 1:02d}:00')


def setup():
    email = f'b2-owner-{RUN}@{DOMAIN}'
    s, u, raw, _ = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    ST['user'] = u['id']
    s, t, raw, _ = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    tok = ST['token'] = t['access_token']
    s, b, raw, _ = api('POST', '/onboarding', tok, {
        'organization': {'name': f'B2 Org {RUN}', 'owner_name': 'Teste B2', 'phone': '11999990000', 'is_demo': True},
        'arena': {'name': f'Arena B2 {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
        'courts': [{'name': 'Quadra B2', 'type': 'SOCIETY'}],
        'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)],
        'default_reservation_minutes': 60})
    assert s == 200, f'onboarding {s} {raw[:200]}'
    ST['org'] = b['organization_id']
    _, arenas, _, _ = api('GET', f'/arenas?organization_id={ST["org"]}', tok)
    _, courts, _, _ = api('GET', f'/courts?organization_id={ST["org"]}', tok)
    ST['arena'], ST['court'], ST['slug'] = arenas[0]['id'], courts[0]['id'], f'b2-{RUN}'
    s, _, raw, _ = api('PUT', f'/arenas/{ST["arena"]}', tok, {'slug': ST['slug'], 'description': 'Arena de teste B2', 'cover_image_url': 'https://example.com/c.jpg'})
    assert s == 200, f'perfil {s} {raw[:200]}'
    s, _, raw, _ = api('PUT', f'/arenas/{ST["arena"]}', tok, {'public_booking_enabled': True})
    assert s == 200, f'publicar {s} {raw[:200]}'


def cleanup():
    problems = []
    org, uid = ST['org'], ST['user']
    if org:
        for table, q in (('reservations', f'organization_id=eq.{org}'), ('customers', f'organization_id=eq.{org}'),
                         ('courts', f'organization_id=eq.{org}'), ('business_hours', f'organization_id=eq.{org}'),
                         ('arenas', f'organization_id=eq.{org}'), ('organizations', f'id=eq.{org}')):
            try:
                s, _, raw, _ = svc('DELETE', f'{table}?{q}')
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
            problems.append(f'conferência (org {org}): {type(e).__name__}: {e}')
    if uid:
        s, _, raw, _ = http('DELETE', f'{SB}/auth/v1/admin/users/{uid}', SVC)
        if s not in (200, 204):
            problems.append(f'usuário Auth {uid}: HTTP {s} {raw[:160]}')
    for scope, h in sorted(TRACKED):
        try:
            s, _, raw, _ = svc('DELETE', f'rate_limit_buckets?scope=eq.{scope}&key_hash=eq.{h}')
            if s not in (200, 204) or rows('rate_limit_buckets', {'scope': f'eq.{scope}', 'key_hash': f'eq.{h}', 'select': 'scope'}):
                problems.append(f'bucket {scope}/{h}: HTTP {s}')
        except Exception as e:  # noqa: BLE001
            problems.append(f'bucket {scope}/{h}: {type(e).__name__}: {e}')
    return problems


def reserve(key=None, date=None, start=None, end=None, phone=None, ip=None):
    if date is None:
        date, start, end = next_slot()
    phone, ip = phone or new_phone(), ip or new_ip()
    track('public_reserve_phone', ST['arena'], phone)
    track('public_reserve_ip', ST['arena'], ip)
    return api('POST', '/public/reserve', ip=ip, body={'slug': ST['slug'], 'court_id': ST['court'], 'date': date, 'start_time': start,
                                                      'end_time': end, 'name': 'Jogador B2', 'phone': phone, 'email': None,
                                                      'accept_terms': True, 'idempotency_key': key or str(uuid.uuid4())})


def lookup(code, ip=None):
    ip = ip or new_ip()
    track('public_reservation_lookup_ip', ip)
    return api('GET', f'/public/reservation/{urllib.parse.quote(code)}', ip=ip)


def fixture_reservation(code, source, key=None):
    date, start, end = next_slot()
    end_date = str(datetime.strptime(date, '%Y-%m-%d').date() + timedelta(days=1)) if end == '00:00' else date
    row = {'organization_id': ST['org'], 'arena_id': ST['arena'], 'court_id': ST['court'], 'start_at': f'{date}T{start}:00-03:00',
           'end_at': f'{end_date}T{end}:00-03:00', 'status': 'CONFIRMED', 'source': source, 'public_code': code, 'idempotency_key': key}
    return svc('POST', 'reservations', row)


# ----------------------------------------------------------------------------- casos
def p0():
    """Formato REAL do 23505 do PostgREST (premissa de isPublicCodeCollision)."""
    code, key = new_style_code(), f'b2-fixture-{RUN}'
    s, _, raw, _ = fixture_reservation(code, 'INTERNAL', key=key)
    assert s == 201, f'fixture base {s} {raw[:160]}'
    s, b, raw, _ = fixture_reservation(code, 'INTERNAL')
    assert s == 409 and b.get('code') == '23505' and 'idx_reservations_public_code_unique' in b.get('message', ''), f'public_code duplicado: {s} {raw[:200]}'
    s, b, raw, _ = fixture_reservation(new_style_code(), 'INTERNAL', key=key)
    assert s == 409 and b.get('code') == '23505' and 'idx_reservations_arena_idempotency_unique' in b.get('message', ''), f'idempotency duplicada: {s} {raw[:200]}'
    print('      23505 identifica o índice em `message` (public_code e idempotência distinguíveis)')


def p1():
    s, b, raw, _ = reserve()
    assert s == 201, f'{s} {raw[:160]}'
    code = b['public_code']
    assert NEW_FORMAT.match(code), f'formato inesperado: {len(code)} chars'
    assert rows('reservations', {'public_code': f'eq.{code}', 'select': 'source'}) == [{'source': 'PUBLIC_WEB'}]
    ST['new_code'] = code


def p2():
    s, b, raw, _ = lookup(ST['new_code'])
    assert s == 200 and b['public_code'] == ST['new_code'], f'{s} {raw[:160]}'
    ST['p2'] = (b, raw)


def p3():
    b, raw = ST['p2']
    assert set(b) == ALLOW_TOP and set(b['court']) == {'name'} and set(b['arena']) == ALLOW_ARENA, sorted(b)
    assert not any(w in raw.lower() for w in ('customer', 'phone', 'email', 'idempotency', 'organization_id'))


def p4():
    code = legacy_code()
    s, _, raw, _ = fixture_reservation(code, 'PUBLIC_WEB')
    assert s == 201, f'fixture legada {s} {raw[:160]}'
    s, b, raw, _ = lookup(code)
    assert s == 200 and b['public_code'] == code, f'legado {s} {raw[:160]}'
    assert rows('reservations', {'public_code': f'eq.{code}', 'select': 'public_code'}) == [{'public_code': code}], 'código legado alterado'


def p5():
    code = new_style_code()
    s, _, raw, _ = fixture_reservation(code, 'INTERNAL')
    assert s == 201, raw[:160]
    s, b, raw, _ = lookup(code)
    assert s == 404, f'INTERNAL deveria ser 404: {s} {raw[:160]}'
    ST['p5'] = b


def p6():
    s, b, raw, _ = lookup(new_style_code())
    assert s == 404 and b == ST['p5'], f'inexistente deveria ser 404 idêntico ao INTERNAL: {s} {raw[:160]}'
    s, b, raw, _ = lookup(legacy_code())
    assert s == 404 and b == ST['p5']


def p7():
    key = str(uuid.uuid4())
    date, start, end = next_slot()
    s1, b1, raw1, _ = reserve(key=key, date=date, start=start, end=end)
    s2, b2, raw2, _ = reserve(key=key, date=date, start=start, end=end)
    assert s1 == 201 and s2 == 200 and b2.get('idempotent') is True and b2['public_code'] == b1['public_code'], f'{s1} {raw1[:80]} | {s2} {raw2[:80]}'
    assert len(rows('reservations', {'arena_id': f'eq.{ST["arena"]}', 'idempotency_key': f'eq.{key}', 'select': 'id'})) == 1


def p8():
    for rnd in range(3):  # algumas rodadas para cobrir a corrida
        key = str(uuid.uuid4())
        date, start, end = next_slot()
        bar = threading.Barrier(2)
        out = [None, None]

        def go(i):
            bar.wait()
            out[i] = reserve(key=key, date=date, start=start, end=end)
        ts = [threading.Thread(target=go, args=(i,)) for i in range(2)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        statuses = sorted(o[0] for o in out)
        codes = {o[1].get('public_code') for o in out if o[1]}
        assert statuses == [200, 201], f'rodada {rnd}: {statuses} {[o[2][:80] for o in out]}'
        assert len(codes) == 1 and all(NEW_FORMAT.match(c) for c in codes), f'rodada {rnd}: códigos {len(codes)}'
        rs = rows('reservations', {'arena_id': f'eq.{ST["arena"]}', 'idempotency_key': f'eq.{key}', 'select': 'public_code'})
        assert len(rs) == 1 and rs[0]['public_code'] in codes, f'rodada {rnd}: {len(rs)} reservas persistidas'


def p9():
    ip = new_ip()
    track('public_reservation_lookup_ip', ip)
    for i in range(30):
        s, _, raw, _ = api('GET', f'/public/reservation/{new_style_code()}', ip=ip)
        assert s == 404, f'consulta {i + 1}: {s}'
    s, _, raw, h = api('GET', f'/public/reservation/{ST["new_code"]}', ip=ip)
    assert s == 429 and 'no-store' in h.get('cache-control', ''), f'31ª consulta (código existente) deveria ser 429: {s}'


exit_code = 1
try:
    print(f'== Security B2 — strong public codes — run {RUN} ==')
    start_server()
    setup()
    print(f'org={ST["org"]}')
    for name, fn in [
        ('P0 formato real do 23505 (índice do código x idempotência)', p0), ('P1 novo código RG- + 16 símbolos', p1),
        ('P2 lookup do código novo -> 200', p2), ('P3 allowlist A5 intacta', p3), ('P4 código legado PUBLIC_WEB -> 200', p4),
        ('P5 INTERNAL com public_code -> 404', p5), ('P6 inexistente -> 404 idêntico ao INTERNAL', p6),
        ('P7 idempotência sequencial -> mesmo código', p7), ('P8 corrida com a mesma chave -> 1 reserva, 1 código', p8),
        ('P9 rate limit A6 do lookup ativo (31ª = 429)', p9),
    ]:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    stop_server()
    try:
        os.remove(os.path.join(ROOT, f'.b2-next-{RUN}.log'))
    except OSError:
        pass
    problems = cleanup()
    if problems:
        print('LIMPEZA FALHOU (P10):')
        for p in problems:
            print('  - ' + p)
        exit_code = 3
    else:
        print(f'P10 limpeza OK: organização {ST["org"]}, usuário efêmero e {len(TRACKED)} bucket(s) removidos; zero fixtures B2')
sys.exit(exit_code)
