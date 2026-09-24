#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING A1 — profiles.is_platform_admin.

Rodar SOMENTE depois de aplicar supabase/migration_security_a1.sql.

Cria UM usuário efêmero (via Admin API, o que dispara o trigger handle_new_user como no
signup), testa com o token desse usuário direto no PostgREST (o mesmo acesso que qualquer
navegador logado tem) e, ao final, remove o usuário criado. Nenhum segredo é impresso.

Variáveis de ambiente obrigatórias:
  SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD
Opcionais:
  BASE_URL           se definido, também valida GET /api/me do app em execução
  TEST_EMAIL_DOMAIN  padrão: reservagol.test

Uso: python tests/security_a1_profiles.py
"""
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

REQUIRED = ['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'TEST_ACCOUNT_PASSWORD']
missing = [k for k in REQUIRED if not os.environ.get(k)]
if missing:
    print('Variáveis de ambiente ausentes: ' + ', '.join(missing))
    sys.exit(2)

SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
BASE = (os.environ.get('BASE_URL') or '').rstrip('/')
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
RUN = uuid.uuid4().hex[:8]
results = {}


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


SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}


def user_h(token, prefer='return=representation'):
    return {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}', 'Prefer': prefer}


def svc_profile(uid):
    s, b, raw = http('GET', f'{SB}/rest/v1/profiles?id=eq.{uid}&select=*', SVC)
    assert s == 200, f'leitura service role {s} {raw[:200]}'
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


def denied(status, raw):
    """Escrita recusada: erro HTTP (42501/permission denied) — nunca 2xx."""
    return status >= 400


# ----------------------------------------------------------------------------- setup (signup)
print(f'== Security A1 — profiles — run {RUN} ==')
email = f'a1-{RUN}@{DOMAIN}'
s, created, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {
    'email': email, 'password': PASSWORD, 'email_confirm': True,
    'user_metadata': {'full_name': 'Usuário A1', 'phone': '11999990001'},
})
assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
UID = created['id']
s, tok, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
assert s == 200, f'login {s} {raw[:200]}'
TOKEN = tok['access_token']
P = f'{SB}/rest/v1/profiles?id=eq.{UID}'


def t_signup_profile():
    p = svc_profile(UID)
    assert p is not None, 'handle_new_user não criou o profile'
    assert p['full_name'] == 'Usuário A1' and p['phone'] == '11999990001' and p['email'] == email
    assert p['is_platform_admin'] is False


def t_select_own():
    s, b, raw = http('GET', f'{P}&select=*', user_h(TOKEN))
    assert s == 200 and len(b) == 1 and b[0]['id'] == UID, f'{s} {raw[:200]}'
    s, b, _ = http('GET', f'{SB}/rest/v1/profiles?select=id', user_h(TOKEN))
    assert s == 200 and [r['id'] for r in b] == [UID], 'só pode ver o próprio profile'


def t_update_full_name():
    s, b, raw = http('PATCH', P, user_h(TOKEN), {'full_name': 'Nome Editado A1'})
    assert s == 200 and b and b[0]['full_name'] == 'Nome Editado A1', f'{s} {raw[:200]}'


def t_update_phone():
    s, b, raw = http('PATCH', P, user_h(TOKEN), {'phone': '11988887777'})
    assert s == 200 and b and b[0]['phone'] == '11988887777', f'{s} {raw[:200]}'


def t_block_flag():
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'is_platform_admin': True})
    assert denied(s, raw), f'deveria recusar is_platform_admin: {s}'
    before = svc_profile(UID)['full_name']
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'full_name': 'Misturado', 'is_platform_admin': True})
    assert denied(s, raw), f'deveria recusar a combinação: {s}'
    assert svc_profile(UID)['full_name'] == before, 'nenhuma coluna pode ser gravada quando a flag vem junto'


def t_block_id():
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'id': str(uuid.uuid4())})
    assert denied(s, raw), f'deveria recusar id: {s}'


def t_block_created_at():
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'created_at': '2000-01-01T00:00:00Z'})
    assert denied(s, raw), f'deveria recusar created_at: {s}'


def t_block_email():
    original = svc_profile(UID)['email']
    assert original == email, f'e-mail inicial inesperado: {original}'
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'email': f'outro-{RUN}@{DOMAIN}'})
    assert denied(s, raw), f'deveria recusar email: {s}'
    s, _, raw = http('PATCH', P, user_h(TOKEN), {'full_name': 'Com Email', 'email': f'outro2-{RUN}@{DOMAIN}'})
    assert denied(s, raw), f'deveria recusar email misturado com full_name: {s}'
    assert svc_profile(UID)['email'] == original, 'o e-mail original deveria permanecer intacto'


def t_block_insert():
    s, _, raw = http('POST', f'{SB}/rest/v1/profiles', user_h(TOKEN), {'id': UID, 'is_platform_admin': True})
    assert denied(s, raw), f'INSERT próprio privilegiado deveria falhar: {s}'
    s, _, raw = http('POST', f'{SB}/rest/v1/profiles', user_h(TOKEN, 'return=representation,resolution=merge-duplicates'),
                     {'id': UID, 'full_name': 'Upsert', 'is_platform_admin': True})
    assert denied(s, raw), f'UPSERT privilegiado deveria falhar: {s}'
    s, _, raw = http('POST', f'{SB}/rest/v1/profiles', user_h(TOKEN), {'id': str(uuid.uuid4()), 'is_platform_admin': True})
    assert denied(s, raw), f'INSERT de outro id deveria falhar: {s}'


def t_flag_still_false():
    p = svc_profile(UID)
    assert p['is_platform_admin'] is False and p['id'] == UID, p


def t_service_role_can_admin():
    """Mecanismo confiável (service role) continua administrando a flag. Reverte na hora."""
    try:
        s, b, raw = http('PATCH', P, {**SVC, 'Prefer': 'return=representation'}, {'is_platform_admin': True})
        assert s == 200 and b[0]['is_platform_admin'] is True, f'service role {s} {raw[:200]}'
    finally:
        http('PATCH', P, SVC, {'is_platform_admin': False})
    assert svc_profile(UID)['is_platform_admin'] is False, 'reversão falhou'


def t_api_me():
    if not BASE:
        print('      (BASE_URL não definido: /api/me não validado)')
        return
    s, b, raw = http('GET', f'{BASE}/api/me', {'Authorization': f'Bearer {TOKEN}'})
    assert s == 200 and b['profile'] and b['profile']['id'] == UID and b['profile']['is_platform_admin'] is False, f'{s} {raw[:200]}'


try:
    for name, fn in [
        ('Signup: handle_new_user cria o profile', t_signup_profile),
        ('SELECT do próprio profile (e só dele)', t_select_own),
        ('UPDATE full_name', t_update_full_name),
        ('UPDATE phone', t_update_phone),
        ('Bloqueia is_platform_admin=true (sozinho e misturado)', t_block_flag),
        ('Bloqueia alterar id', t_block_id),
        ('Bloqueia alterar created_at', t_block_created_at),
        ('Bloqueia alterar email', t_block_email),
        ('Bloqueia INSERT/UPSERT privilegiado', t_block_insert),
        ('is_platform_admin continua false', t_flag_still_false),
        ('Service role ainda administra a flag', t_service_role_can_admin),
        ('GET /api/me continua funcionando', t_api_me),
    ]:
        check(name, fn)
finally:
    # Garantia final: flag false e remoção do usuário efêmero desta execução (cascade no profile).
    http('PATCH', P, SVC, {'is_platform_admin': False})
    s, _, _ = http('DELETE', f'{SB}/auth/v1/admin/users/{UID}', SVC)
    print(f'      limpeza do usuário efêmero: HTTP {s}')

ok = sum(1 for v in results.values() if v == 'PASS')
print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
sys.exit(0 if ok == len(results) else 1)
