#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A6 — rate limit persistente/distribuído.

Rodar SOMENTE depois de aplicar supabase/migration_security_a6.sql e de `yarn build`.

AUTOSSUFICIENTE E AUTOLIMPANTE:
  * sobe o PRÓPRIO servidor Next (`next start`, porta A6_PORT, padrão 3106) — necessário para
    o caso R15, que reinicia o servidor e prova que o bloqueio não vive na memória do processo;
  * cria organização isolada (is_demo) com OWNER efêmero e duas arenas publicadas;
  * usa IPs aleatórios da faixa de benchmark 198.18.0.0/15 (nunca IP real) via X-Forwarded-For;
  * no `finally` remove reservas -> clientes -> quadras -> horários -> arenas -> organização ->
    usuário Auth e APENAS os buckets cujos hashes o próprio teste calculou (nunca DELETE sem filtro).
    Falhas de limpeza são impressas com IDs/hashes e o processo sai com erro.

Os hashes são calculados como o servidor: subchave = HMAC(SUPABASE_SECRET_KEY, contexto) e
key_hash = HMAC(subchave, "<bytes>:<valor>|..."). Nenhum valor secreto, telefone ou IP é impresso.

Variáveis de ambiente obrigatórias:
  SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcionais: A6_PORT (padrão 3106), TEST_EMAIL_DOMAIN (padrão reservagol.test)

Uso: python tests/security_a6_persistent_rate_limit.py
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
PORT = int(os.environ.get('A6_PORT', '3106'))
BASE = f'http://localhost:{PORT}/api'
SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
SP = timezone(timedelta(hours=-3))
RUN = uuid.uuid4().hex[:8]
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
LIMITS = {'public_reserve_phone': 5, 'public_reserve_ip': 20, 'public_reservation_lookup_ip': 30}
results = {}

# ----------------------------------------------------------------------------- HMAC idêntico ao servidor
_SUBKEY = hmac.new(SECRET.encode(), b'reservagol-rate-limit-v1', hashlib.sha256).digest()


def key_hash(scope, *parts):
    enc = '|'.join(f'{len(str(p).encode())}:{p}' for p in (scope, *parts))
    return hmac.new(_SUBKEY, enc.encode(), hashlib.sha256).hexdigest()


TRACKED = set()     # (scope, key_hash) criados/afetados pelo teste — os únicos que a limpeza remove
RAW_IDS = set()     # telefones/IPs usados (para o caso R14)


def track(scope, *parts):
    h = key_hash(scope, *parts)
    TRACKED.add((scope, h))
    return h


def new_ip():
    ip = f'198.{random.randint(18, 19)}.{random.randint(0, 255)}.{random.randint(1, 254)}'
    RAW_IDS.add(ip)
    return ip


def new_phone():
    ph = '119' + ''.join(random.choice('0123456789') for _ in range(8))
    RAW_IDS.add(ph)
    return ph


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


def svc(method, path, body=None, prefer='return=representation'):
    return http(method, f'{SB}/rest/v1/{path}', {**SVC, 'Prefer': prefer}, body)


def rows(table, params):
    s, b, raw, _ = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params)}', SVC)
    assert s == 200, f'svc {table} {s} {raw[:160]}'
    return b


def rpc(scope, h, limit, window, headers=None):
    return http('POST', f'{SB}/rest/v1/rpc/consume_rate_limit', headers or SVC,
                {'p_scope': scope, 'p_key_hash': h, 'p_limit': limit, 'p_window_seconds': window})


def bucket(scope, h):
    b = rows('rate_limit_buckets', {'scope': f'eq.{scope}', 'key_hash': f'eq.{h}', 'select': '*'})
    return b[0] if b else None


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
    log = open(os.path.join(ROOT, f'.a6-next-{RUN}.log'), 'ab')
    SERVER['log'] = log
    SERVER['proc'] = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '-p', str(PORT)], cwd=ROOT,
                                      stdout=log, stderr=subprocess.STDOUT, env=os.environ.copy())
    for _ in range(60):
        try:
            s, _, _, _ = http('GET', f'{BASE}/public/arenas', timeout=5)
            if s == 200:
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
    SERVER['proc'] = None
    if SERVER['log']:
        SERVER['log'].close()
        SERVER['log'] = None


# ----------------------------------------------------------------------------- dados
ST = {'org': None, 'user': None}
TODAY = datetime.now(SP).date()
_slots = []


def next_slot(court_key='a1'):
    """Slot público real e ainda livre (hours 08:00 -> 00:00 todos os dias, datas hoje+2 ...)."""
    i = sum(1 for k in _slots if k[0] == court_key)
    day, hour = 2 + i // 16, 8 + i % 16
    _slots.append((court_key, day, hour))
    end = '00:00' if hour == 23 else f'{hour + 1:02d}:00'
    return str(TODAY + timedelta(days=day)), f'{hour:02d}:00', end


def reserve(arena='a1', phone=None, ip=None, key=None, date=None, start=None, end=None):
    if date is None:
        date, start, end = next_slot(arena)
    a = ST[arena]
    body = {'slug': a['slug'], 'court_id': a['court'], 'date': date, 'start_time': start, 'end_time': end, 'name': 'Jogador A6',
            'phone': phone, 'email': None, 'accept_terms': True, 'idempotency_key': key or str(uuid.uuid4())}
    return api('POST', '/public/reserve', body=body, ip=ip)


def lookup(code, ip):
    return api('GET', f'/public/reservation/{urllib.parse.quote(code)}', ip=ip)


def setup():
    email = f'a6-owner-{RUN}@{DOMAIN}'
    s, u, raw, _ = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    ST['user'] = u['id']
    s, t, raw, _ = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    tok = ST['token'] = t['access_token']
    hours = [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)]
    s, b, raw, _ = api('POST', '/onboarding', tok, {
        'organization': {'name': f'A6 Org {RUN}', 'owner_name': 'Teste A6', 'phone': '11999990000', 'is_demo': True},
        'arena': {'name': f'Arena A6-1 {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
        'courts': [{'name': 'Quadra A6-1', 'type': 'SOCIETY'}], 'hours': hours, 'default_reservation_minutes': 60})
    assert s == 200, f'onboarding {s} {raw[:200]}'
    org = ST['org'] = b['organization_id']
    _, arenas, _, _ = api('GET', f'/arenas?organization_id={org}', tok)
    _, courts, _, _ = api('GET', f'/courts?organization_id={org}', tok)
    ST['a1'] = {'id': arenas[0]['id'], 'court': courts[0]['id'], 'slug': f'a6-1-{RUN}'}
    # Segunda arena da mesma organização (R6).
    uh = {'apikey': PUB_KEY, 'Authorization': f'Bearer {tok}', 'Prefer': 'return=representation'}
    s, b, raw, _ = http('POST', f'{SB}/rest/v1/arenas', uh, {'organization_id': org, 'name': f'Arena A6-2 {RUN}', 'active': True,
                                                          'address': 'Rua Teste', 'city': 'São Paulo', 'whatsapp': '11999990000'})
    assert s == 201, f'arena 2 {s} {raw[:200]}'
    a2 = b[0]['id']
    s, b, raw, _ = http('POST', f'{SB}/rest/v1/courts', uh, {'organization_id': org, 'arena_id': a2, 'name': 'Quadra A6-2'})
    assert s == 201, f'quadra 2 {s} {raw[:200]}'
    ST['a2'] = {'id': a2, 'court': b[0]['id'], 'slug': f'a6-2-{RUN}'}
    s, _, raw, _ = api('PUT', '/business-hours', tok, {'organization_id': org, 'arena_id': a2, 'hours': hours})
    assert s == 200, f'horários arena 2 {s} {raw[:200]}'
    for k in ('a1', 'a2'):
        s, _, raw, _ = api('PUT', f'/arenas/{ST[k]["id"]}', tok, {'slug': ST[k]['slug'], 'description': 'Arena de teste A6', 'cover_image_url': 'https://example.com/c.jpg'})
        assert s == 200, f'perfil {k} {s} {raw[:200]}'
        s, _, raw, _ = api('PUT', f'/arenas/{ST[k]["id"]}', tok, {'public_booking_enabled': True})
        assert s == 200, f'publicar {k} {s} {raw[:200]}'


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
    if uid:
        s, _, raw, _ = http('DELETE', f'{SB}/auth/v1/admin/users/{uid}', SVC)
        if s not in (200, 204):
            problems.append(f'usuário Auth {uid}: HTTP {s} {raw[:160]}')
    for scope, h in sorted(TRACKED):  # somente buckets calculados por este teste
        try:
            s, _, raw, _ = svc('DELETE', f'rate_limit_buckets?scope=eq.{scope}&key_hash=eq.{h}')
            if s not in (200, 204) or bucket(scope, h):
                problems.append(f'bucket {scope}/{h}: HTTP {s} {raw[:120]}')
        except Exception as e:  # noqa: BLE001
            problems.append(f'bucket {scope}/{h}: {type(e).__name__}: {e}')
    return problems


# ----------------------------------------------------------------------------- casos
def r1():
    h = track('public_reservation_lookup_ip', new_ip())
    out = [rpc('public_reservation_lookup_ip', h, 3, 600) for _ in range(5)]
    assert all(o[0] == 200 for o in out), [o[0] for o in out]
    rs = [o[1][0] for o in out]
    assert [r['allowed'] for r in rs] == [True, True, True, False, False], rs
    assert [r['remaining'] for r in rs] == [2, 1, 0, 0, 0] and [r['current_count'] for r in rs] == [1, 2, 3, 4, 5], rs
    assert all(r['retry_after_seconds'] == 0 for r in rs[:3]) and all(0 < r['retry_after_seconds'] <= 600 for r in rs[3:]), rs


def r2():
    h = track('public_reservation_lookup_ip', new_ip())
    n, limit = 16, 5
    bar = threading.Barrier(n)
    out = [None] * n

    def go(i):
        bar.wait()
        out[i] = rpc('public_reservation_lookup_ip', h, limit, 600)
    ts = [threading.Thread(target=go, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert all(o and o[0] == 200 for o in out), [o and o[0] for o in out]
    allowed = sum(1 for o in out if o[1][0]['allowed'])
    counts = sorted(o[1][0]['current_count'] for o in out)
    assert allowed == limit, f'{allowed} permitidos em {n} chamadas simultâneas (limite {limit})'
    assert counts == list(range(1, n + 1)), f'contagens não sequenciais (incremento perdido): {counts}'
    ST['r2'] = (h, n)


def r3():
    h, n = ST['r2']
    b = bucket('public_reservation_lookup_ip', h)
    assert b and int(b['count']) == n, f'bucket persistido: {b}'
    assert b['window_started_at'] and b['updated_at']


def r4():
    for scope, h in TRACKED:
        assert re.fullmatch(r'[0-9a-f]{64}', h)
    bad = rows('rate_limit_buckets', {'key_hash': 'not.match.^[0-9a-f]{64}$', 'select': 'scope'})
    assert bad == [], f'{len(bad)} bucket(s) com key_hash fora do formato'


def r5():
    ph, ip = new_phone(), new_ip()
    track('public_reserve_phone', ST['a1']['id'], ph)
    track('public_reserve_ip', ST['a1']['id'], ip)
    for i in range(5):
        s, b, raw, _ = reserve('a1', phone=ph, ip=ip)
        assert s == 201, f'tentativa {i + 1} deveria passar: {s} {raw[:120]}'
    s, b, raw, h = reserve('a1', phone=ph, ip=ip)
    assert s == 429, f'6ª tentativa do mesmo telefone deveria ser 429: {s} {raw[:120]}'
    ST['r5'] = {'phone': ph, 'status': s, 'body': b, 'raw': raw, 'headers': h}
    assert int(bucket('public_reserve_phone', key_hash('public_reserve_phone', ST['a1']['id'], ph))['count']) == 6


def r6():
    ph = ST['r5']['phone']
    ip = new_ip()
    track('public_reserve_phone', ST['a2']['id'], ph)
    track('public_reserve_ip', ST['a2']['id'], ip)
    s, _, raw, _ = reserve('a2', phone=ph, ip=ip)
    assert s == 201, f'mesmo telefone em outra arena não herda o bloqueio: {s} {raw[:120]}'


def r7():
    ip = new_ip()
    track('public_reserve_ip', ST['a1']['id'], ip)
    for i in range(20):
        ph = new_phone()
        track('public_reserve_phone', ST['a1']['id'], ph)
        s, _, raw, _ = reserve('a1', phone=ph, ip=ip)
        assert s == 201, f'tentativa {i + 1} (telefone novo, mesmo IP) deveria passar: {s} {raw[:120]}'
    ph = new_phone()
    track('public_reserve_phone', ST['a1']['id'], ph)
    s, _, raw, h = reserve('a1', phone=ph, ip=ip)
    assert s == 429 and 'retry-after' in h, f'21ª tentativa do mesmo IP deveria ser 429: {s} {raw[:120]}'


def r8():
    ph, ip, key = new_phone(), new_ip(), str(uuid.uuid4())
    hp = track('public_reserve_phone', ST['a1']['id'], ph)
    track('public_reserve_ip', ST['a1']['id'], ip)
    date, start, end = next_slot('a1')
    s1, b1, raw1, _ = reserve('a1', phone=ph, ip=ip, key=key, date=date, start=start, end=end)
    assert s1 == 201, raw1[:120]
    for _ in range(10):
        s, b, raw, _ = reserve('a1', phone=ph, ip=ip, key=key, date=date, start=start, end=end)
        assert s == 200 and b.get('idempotent') is True and b['public_code'] == b1['public_code'], f'{s} {raw[:120]}'
    assert int(bucket('public_reserve_phone', hp)['count']) == 1, 'retry idempotente não pode consumir quota nova'
    ST['code'] = b1['public_code']


def r9():
    ip = new_ip()
    track('public_reservation_lookup_ip', ip)
    for i in range(30):
        s, _, raw, _ = lookup(f'RG-Z{random.randint(10000, 99999)}', ip)
        assert s == 404, f'consulta {i + 1}: {s} {raw[:120]}'
    s, b, raw, h = lookup(f'RG-Z{random.randint(10000, 99999)}', ip)
    assert s == 429, f'31ª consulta do mesmo IP deveria ser 429: {s} {raw[:120]}'
    ST['r9'] = (s, b, raw, h)


def r10():
    ip = new_ip()
    hl = track('public_reservation_lookup_ip', ip)
    seen = []
    for i in range(30):
        code = ST['code'] if i % 2 == 0 else f'RG-Z{random.randint(10000, 99999)}'
        seen.append(lookup(code, ip)[0])
    assert seen == [200, 404] * 15, seen
    s, _, raw, _ = lookup(ST['code'], ip)
    assert s == 429, f'código EXISTENTE também é bloqueado ao exceder: {s} {raw[:120]}'
    assert int(bucket('public_reservation_lookup_ip', hl)['count']) == 31, 'consumo antes da consulta, independente da existência'


def r11():
    for label, (s, _, _, h) in (('reserve', (ST['r5']['status'], None, None, ST['r5']['headers'])), ('lookup', ST['r9'])):
        ra = h.get('retry-after', '')
        assert s == 429 and ra.isdigit() and 0 < int(ra) <= 600, f'{label}: Retry-After inválido {ra!r}'


def r12():
    for label, (s, b, raw, h) in (('reserve 429', (ST['r5']['status'], ST['r5']['body'], ST['r5']['raw'], ST['r5']['headers'])), ('lookup 429', ST['r9'])):
        assert 'no-store' in h.get('cache-control', ''), f'{label} sem no-store'
        assert set(b) == {'error'}, f'{label}: corpo expõe detalhes: {raw[:160]}'
        low = raw.lower()
        assert not any(w in low for w in ('scope', 'count', 'limit', 'hash', '198.', 'phone')), f'{label}: detalhe interno: {raw[:160]}'
    s, b, raw, h = lookup(ST['code'], 'nao-e-um-ip')  # sem identificador utilizável -> 503 fail-closed
    assert s == 503 and 'no-store' in h.get('cache-control', '') and set(b) == {'error'}, f'503 do limiter: {s} {raw[:160]}'


def r13():
    h = key_hash('public_reservation_lookup_ip', 'r13-' + RUN)
    anon = {'apikey': PUB_KEY}
    user = {'apikey': PUB_KEY, 'Authorization': f'Bearer {ST["token"]}'}
    for who, hdr in (('anon', anon), ('authenticated', user)):
        s, _, raw, _ = http('GET', f'{SB}/rest/v1/rate_limit_buckets?select=scope&limit=1', hdr)
        assert s in (401, 403), f'{who} SELECT rate_limit_buckets: {s} {raw[:120]}'
        s, _, raw, _ = rpc('public_reservation_lookup_ip', h, 5, 600, headers=hdr)
        assert s in (401, 403, 404), f'{who} EXECUTE consume_rate_limit: {s} {raw[:120]}'
    assert bucket('public_reservation_lookup_ip', h) is None, 'chamada negada não pode criar bucket'
    for bad in (('outro_scope', h, 5, 600), ('public_reservation_lookup_ip', 'ABC', 5, 600),
                ('public_reservation_lookup_ip', h, 0, 600), ('public_reservation_lookup_ip', h, 5, 0)):
        s, _, raw, _ = rpc(*bad)
        assert s >= 400, f'argumento inválido aceito pela RPC: {bad[0]} {s}'
    assert bucket('public_reservation_lookup_ip', h) is None


def r14():
    mine = [bucket(sc, h) for sc, h in TRACKED]
    dump = json.dumps([b for b in mine if b])
    for raw_id in RAW_IDS:
        assert raw_id not in dump, 'telefone/IP em texto puro nos buckets'
    for col in ('key_hash', 'scope'):
        found = rows('rate_limit_buckets', {col: f'in.({",".join(RAW_IDS)})', 'select': 'scope'})
        assert found == [], f'valor cru encontrado em {col}'


def r15():
    ip = new_ip()
    track('public_reservation_lookup_ip', ip)
    for _ in range(30):
        lookup(f'RG-Z{random.randint(10000, 99999)}', ip)
    assert lookup('RG-ZZZZZZ', ip)[0] == 429, 'bucket deveria estar esgotado antes do restart'
    stop_server()
    start_server()
    assert lookup('RG-ZZZZZZ', ip)[0] == 429, 'após reiniciar o Next, a mesma identidade deveria continuar bloqueada'
    other = new_ip()
    track('public_reservation_lookup_ip', other)
    assert lookup('RG-ZZZZZZ', other)[0] == 404, 'outra identidade continua liberada após o restart'


def r16():
    src = open(os.path.join(ROOT, 'app', 'api', '[[...path]]', 'route.js'), encoding='utf-8').read()
    assert 'const RL = new Map()' not in src and 'rateLimited(' not in src, 'limiter em memória ainda presente'
    assert 'consumeRateLimit(' in src


def r17():
    ip = new_ip()
    track('public_reservation_lookup_ip', ip)
    s, b, raw, h = lookup(ST['code'], ip)
    assert s == 200 and 'no-store' in h.get('cache-control', ''), raw[:120]
    assert set(b) == {'public_code', 'start_at', 'end_at', 'status', 'court', 'arena'} and set(b['court']) == {'name'}, sorted(b)
    assert not any(w in raw.lower() for w in ('customer', 'phone', 'email')), 'PII na consulta pública'


def r18():
    ph, ip = new_phone(), new_ip()
    hp = track('public_reserve_phone', ST['a1']['id'], ph)
    track('public_reserve_ip', ST['a1']['id'], ip)
    date, _, _ = next_slot('a1')
    s, _, raw, _ = reserve('a1', phone=ph, ip=ip, date=date, start='08:30', end='09:30')
    assert s == 400, f'slot inválido continua 400 (A4): {s} {raw[:120]}'
    assert bucket('public_reserve_phone', hp) is None, 'tentativa inválida não pode consumir quota'
    s, _, raw, _ = reserve('a1', phone=ph, ip=ip)
    assert s == 201, f'reserva válida abaixo do limite (A4): {s} {raw[:120]}'
    assert int(bucket('public_reserve_phone', hp)['count']) == 1


def r19():
    ip = new_ip()
    q = urllib.parse.urlencode({'slug': ST['a1']['slug'], 'court_id': ST['a1']['court'], 'date': str(TODAY + timedelta(days=5))})
    for _ in range(40):
        s, _, raw, _ = api('GET', f'/public/availability?{q}', ip=ip)
        assert s == 200, f'availability não tem rate limit no A6: {s} {raw[:120]}'


exit_code = 1
try:
    print(f'== Security A6 — persistent rate limit — run {RUN} ==')
    start_server()
    setup()
    print(f'org={ST["org"]}')
    for name, fn in [
        ('R1 RPC atômica básica (limit=3)', r1), ('R2 concorrência: 16 chamadas simultâneas, exatamente o limite', r2),
        ('R3 estado persistido no PostgreSQL', r3), ('R4 somente HMAC 64-hex', r4),
        ('R5 arena+telefone: 5 passam, 6ª = 429', r5), ('R6 mesmo telefone em outra arena não herda', r6),
        ('R7 mesmo IP com telefones diferentes: 21ª = 429', r7), ('R8 idempotência não consome quota', r8),
        ('R9 lookup: 30 passam, 31ª = 429', r9), ('R10 lookup consome antes da consulta (existente = inexistente)', r10),
        ('R11 Retry-After inteiro > 0', r11), ('R12 429/503 com no-store e corpo genérico', r12),
        ('R13 anon/authenticated sem SELECT/EXECUTE; RPC valida argumentos', r13), ('R14 nenhum telefone/IP em texto puro', r14),
        ('R15 bloqueio persiste após reiniciar o Next', r15), ('R16 limiter em memória removido', r16),
        ('R17 A5 preservado (allowlist, sem PII)', r17), ('R18 A4 preservado; inválido não consome quota', r18),
        ('R19 availability sem rate limit', r19),
    ]:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    try:
        stop_server()
    except Exception as e:  # noqa: BLE001
        print(f'aviso: falha ao parar o servidor: {e}')
    problems = cleanup()
    try:
        os.remove(os.path.join(ROOT, f'.a6-next-{RUN}.log'))
    except OSError:
        pass
    if problems:
        print('LIMPEZA FALHOU:')
        for p in problems:
            print('  - ' + p)
        exit_code = 3
    else:
        print(f'limpeza OK: organização {ST["org"]}, usuário efêmero e {len(TRACKED)} bucket(s) do teste removidos')
sys.exit(exit_code)
