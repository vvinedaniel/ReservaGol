#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING B1 — fronteiras do navegador (open redirect, framing, CORS).

Rodar depois de `yarn build`. NÃO escreve no banco: só faz GET/OPTIONS em páginas e em
/api/public/arenas (leitura). Sobe o PRÓPRIO servidor Next (`next start`, porta B1_PORT,
padrão 3107) e o encerra no final. O servidor lê o .env.local normalmente.

Casos:
  B1-1..B1-14  testes puros do helper (tests/security_b1_safe_redirect.test.mjs, via node)
  H1           X-Frame-Options=DENY, CSP=frame-ancestors 'none';, nosniff, Referrer-Policy
  C1           Origin: https://evil.example não recebe nenhum header CORS (GET e preflight OPTIONS)
  R1           regressão: /, /login, /jogar e /api/public/arenas respondem
  R2           /dashboard sem sessão continua redirecionando para /login
  R3           /auth/confirm com next malicioso nunca redireciona para fora da origem

Uso: python tests/security_b1_browser_boundaries.py
"""
import http.client
import json
import os
import subprocess
import sys
import time
import uuid
from urllib.parse import urlsplit

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get('B1_PORT', '3107'))
RUN = uuid.uuid4().hex[:8]
EVIL = 'https://evil.example'
PAGES = ['/', '/login', '/jogar', '/api/public/arenas']
CORS_HEADERS = ['access-control-allow-origin', 'access-control-allow-credentials', 'access-control-allow-methods', 'access-control-allow-headers']
results = {}


def req(method, path, headers=None):
    """Request SEM seguir redirects. Retorna (status, headers minúsculos, corpo)."""
    c = http.client.HTTPConnection('localhost', PORT, timeout=30)
    c.request(method, path, headers=headers or {})
    r = c.getresponse()
    body = r.read().decode('utf-8', 'replace')
    hdrs = {k.lower(): v for k, v in r.getheaders()}
    c.close()
    return r.status, hdrs, body


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


SERVER = {'proc': None, 'log': None}


def start_server():
    SERVER['log'] = open(os.path.join(ROOT, f'.b1-next-{RUN}.log'), 'ab')
    SERVER['proc'] = subprocess.Popen(['node', 'node_modules/next/dist/bin/next', 'start', '-p', str(PORT)], cwd=ROOT,
                                      stdout=SERVER['log'], stderr=subprocess.STDOUT, env=os.environ.copy())
    for _ in range(60):
        try:
            if req('GET', '/api/public/arenas')[0] == 200:
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


# ----------------------------------------------------------------------------- casos
def helper_pure():
    out = subprocess.run(['node', 'tests/security_b1_safe_redirect.test.mjs'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
    lines = [ln for ln in out.stdout.splitlines() if ln.startswith(('PASS', 'FAIL', '=='))]
    for ln in lines:
        print('      ' + ln)
    assert out.returncode == 0, 'testes puros do helper falharam'


def h1():
    for path in PAGES:
        s, h, _ = req('GET', path)
        assert s == 200, f'{path}: HTTP {s}'
        assert h.get('x-frame-options') == 'DENY', f'{path}: X-Frame-Options={h.get("x-frame-options")!r}'
        assert h.get('content-security-policy') == "frame-ancestors 'none';", f'{path}: CSP={h.get("content-security-policy")!r}'
        assert h.get('x-content-type-options') == 'nosniff', f'{path}: X-Content-Type-Options={h.get("x-content-type-options")!r}'
        assert h.get('referrer-policy') == 'strict-origin-when-cross-origin', f'{path}: Referrer-Policy={h.get("referrer-policy")!r}'
        print(f'      {path:<20} XFO={h["x-frame-options"]} CSP={h["content-security-policy"]} nosniff Referrer-Policy OK')


def c1():
    for path in PAGES:
        s, h, _ = req('GET', path, {'Origin': EVIL})
        leaked = [k for k in CORS_HEADERS if k in h]
        assert not leaked, f'GET {path} com Origin externa devolveu {leaked}'
    s, h, _ = req('OPTIONS', '/api/public/arenas', {'Origin': EVIL, 'Access-Control-Request-Method': 'POST',
                                                    'Access-Control-Request-Headers': 'content-type, authorization'})
    leaked = [k for k in CORS_HEADERS if k in h]
    assert not leaked, f'preflight OPTIONS devolveu {leaked}'
    print(f'      nenhum header CORS em {len(PAGES)} GETs e 1 preflight com Origin: {EVIL}')


def r1():
    for path in PAGES:
        s, h, body = req('GET', path)
        assert s == 200, f'{path}: HTTP {s}'
    s, _, body = req('GET', '/api/public/arenas')
    assert isinstance(json.loads(body), list), 'API pública deveria devolver uma lista'


def r2():
    for path in ('/dashboard', '/dashboard/agenda', '/onboarding'):
        s, h, _ = req('GET', path)
        loc = h.get('location', '')
        assert s in (302, 303, 307, 308) and urlsplit(loc).path == '/login', f'{path}: HTTP {s} Location={loc!r}'
        assert urlsplit(loc).netloc in ('', f'localhost:{PORT}'), f'{path}: redirect para outra origem {loc!r}'


def r3():
    for payload in ('%2F%2Fevil.example', '%2F%5Cevil.example', 'https%3A%2F%2Fevil.example', '%2F%09%2Fevil.example'):
        for extra in ('', '&token_hash=abc&type=recovery'):
            s, h, _ = req('GET', f'/auth/confirm?next={payload}{extra}')
            loc = h.get('location', '')
            assert s in (302, 303, 307, 308), f'{payload}: HTTP {s}'
            assert urlsplit(loc).netloc in ('', f'localhost:{PORT}') and 'evil' not in loc, f'{payload}: Location externa {loc!r}'


exit_code = 1
try:
    print(f'== Security B1 — browser boundaries — run {RUN} ==')
    check('B1-1..B1-14 helper safeInternalRedirect (testes puros)', helper_pure)
    start_server()
    for name, fn in [
        ('H1 headers de framing/nosniff/referrer em /, /login, /jogar, /api/public/arenas', h1),
        ('C1 sem CORS para Origin externa (GET e preflight)', c1),
        ('R1 páginas e API pública respondem', r1),
        ('R2 /dashboard sem sessão -> /login', r2),
        ('R3 /auth/confirm com next malicioso nunca sai da origem', r3),
    ]:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    stop_server()
    try:
        os.remove(os.path.join(ROOT, f'.b1-next-{RUN}.log'))
    except OSError:
        pass
sys.exit(exit_code)
