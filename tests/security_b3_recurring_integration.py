#!/usr/bin/env python3
"""
Reserva Gol — SECURITY HARDENING B3 — integração HTTP/PostgREST + CONCORRÊNCIA (ETAPA 3).

PRÉ-REQUISITOS:
  * supabase/migration_security_b3.sql (FOUNDATION) aplicada no projeto de SUPABASE_URL;
  * app com o route B3 rodando em BASE_URL;
  * opcional: LOCKDOWN aplicado -> exportar B3_EXPECT_LOCKDOWN=1 (liga os casos L*).

ESTE HARNESS ESCREVE NO SUPABASE DE SUPABASE_URL. Sem B3_ALLOW_WRITE=1 ele não faz NADA.
Fixtures: usuários efêmeros + organizações "B3 IT <run>" (is_demo) criadas por ele mesmo.
Cleanup explícito e verificável no fim (sempre, mesmo com falha): só apaga dados das
organizações criadas NESTA execução (nome conferido antes); se houver dúvida de ownership,
não apaga e reporta como resíduo. Emite created / cleaned / residual; residual deve ser 0.
Não enfraquece A3: a limpeza usa a service key (que já tinha DELETE), na ordem das FKs.

Variáveis (nenhum valor é impresso): BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD, B3_ALLOW_WRITE=1.
Opcionais: TEST_EMAIL_DOMAIN (padrão reservagol.test), B3_ROUNDS (padrão 3), B3_EXPECT_LOCKDOWN.

Uso: B3_ALLOW_WRITE=1 python tests/security_b3_recurring_integration.py
"""
import atexit
import json
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

from harness_cleanup import FixtureTracker

REQUIRED = ['BASE_URL', 'SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_SECRET_KEY', 'TEST_ACCOUNT_PASSWORD']
missing = [k for k in REQUIRED if not os.environ.get(k)]
if missing:
    print('Variáveis de ambiente ausentes: ' + ', '.join(missing))
    sys.exit(2)
if os.environ.get('B3_ALLOW_WRITE') != '1':
    print('B3_ALLOW_WRITE=1 não definido: este harness escreve no Supabase e não foi executado.')
    sys.exit(2)

BASE = os.environ['BASE_URL'].rstrip('/') + '/api'
SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
ROUNDS = int(os.environ.get('B3_ROUNDS', '3'))
EXPECT_LOCKDOWN = os.environ.get('B3_EXPECT_LOCKDOWN') == '1'
SP = timezone(timedelta(hours=-3))
RUN = uuid.uuid4().hex[:8]
ORG_PREFIX = f'B3 IT {RUN}'
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
TODAY = datetime.now(SP).date()
results = {}
# Limpeza verificável compartilhada (created/cleaned/residual): só o que ESTA execução criou.
FX = FixtureTracker(SB, SECRET)
atexit.register(FX.cleanup)
PUBLIC_SERIES_KEYS = {'id', 'organization_id', 'arena_id', 'court_id', 'customer_id', 'frequency', 'weekday', 'day_of_month', 'start_time',
                      'end_time', 'start_date', 'end_date', 'has_no_end_date', 'status', 'default_price', 'notes', 'is_demo', 'created_by',
                      'created_at', 'updated_at'}
B3_INTERNAL_KEYS = {'operation_id', 'operation_kind', 'operation_request', 'previous_series_id'}


# ----------------------------------------------------------------------------- http
def http(method, url, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            raw, status = r.read().decode(), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(), e.code
    try:
        return status, (json.loads(raw) if raw else None), raw
    except ValueError:
        return status, None, raw


def api(method, path, token=None, body=None):
    return http(method, BASE + path, {'Authorization': f'Bearer {token}'} if token else {}, body)


def svc(method, path, body=None, prefer='return=representation'):
    return http(method, f'{SB}/rest/v1/{path}', {**SVC, 'Prefer': prefer}, body)


def svc_get(table, params):
    s, b, raw = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params, doseq=True)}', SVC)
    assert s == 200, f'svc {table} {s} {raw[:200]}'
    return b


def rpc(fn, args, token=None, key=None):
    """PostgREST RPC. token = JWT de usuário; key = 'anon' | 'service'."""
    if key == 'anon':
        h = {'apikey': PUB_KEY}
    elif key == 'service':
        h = SVC
    else:
        h = {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}'}
    return http('POST', f'{SB}/rest/v1/rpc/{fn}', h, args)


def user_rest(method, table, token, body=None, query=''):
    return http(method, f'{SB}/rest/v1/{table}{query}', {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}', 'Prefer': 'return=representation'}, body)


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


def parallel(*calls):
    """Executa as chamadas ao mesmo tempo (Barrier) e devolve os resultados na ordem."""
    bar = threading.Barrier(len(calls))
    out = [None] * len(calls)

    def run(i, fn):
        bar.wait()
        out[i] = fn()
    ts = [threading.Thread(target=run, args=(i, fn)) for i, fn in enumerate(calls)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return out


# ----------------------------------------------------------------------------- fixtures
def create_user(label):
    email = f'b3it-{label}-{RUN}@{DOMAIN}'
    s, b, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    FX.user(b['id'])
    s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    return b['id'], t['access_token']


def create_org(label, members):
    s, b, raw = svc('POST', 'organizations', {'name': f'{ORG_PREFIX} {label}', 'is_demo': True})
    assert s == 201, f'org {s} {raw[:200]}'
    org = FX.org(b[0]['id'], f'{ORG_PREFIX} {label}')
    for uid, role in members:
        s, _, raw = svc('POST', 'organization_members', {'organization_id': org, 'user_id': uid, 'role': role, 'status': 'ACTIVE'}, 'return=minimal')
        assert s in (200, 201), f'membro {s} {raw[:200]}'
    s, b, raw = svc('POST', 'arenas', {'organization_id': org, 'name': f'Arena {label} {RUN}', 'active': True})
    assert s == 201, f'arena {s} {raw[:200]}'
    arena = b[0]['id']
    courts = {}
    for n in ('c1', 'c2', 'c3', 'c4', 'c5', 'c6'):
        s, b, raw = svc('POST', 'courts', {'organization_id': org, 'arena_id': arena, 'name': f'{n} {RUN}'})
        assert s == 201, f'quadra {s} {raw[:200]}'
        courts[n] = b[0]['id']
    s, _, raw = svc('POST', 'business_hours', [{'organization_id': org, 'arena_id': arena, 'weekday': i, 'open_time': '06:00', 'close_time': '00:00', 'closed': False} for i in range(7)], 'return=minimal')
    assert s in (200, 201), f'horários {s} {raw[:200]}'
    return org, arena, courts


def iso(d, hhmm, next_day=False):
    return f'{d + timedelta(days=1) if next_day else d}T{hhmm}:00-03:00'


D1 = TODAY + timedelta(days=7)
WD = D1.isoweekday() % 7
D2, D3, D4 = D1 + timedelta(days=7), D1 + timedelta(days=14), D1 + timedelta(days=21)


def series_body(court, start, end, **extra):
    return {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C[court], 'frequency': 'WEEKLY', 'weekday': WD,
            'start_time': start, 'end_time': end, 'start_date': str(TODAY), 'has_no_end_date': True,
            'customer': {'name': f'Cliente B3 {RUN}', 'phone': '11 90000-0009'}, **extra}


def create_rpc_series(court, start, end, dates, token=None):
    """Série criada direto pela RPC (datas controladas) — base dos testes de concorrência."""
    s, b, raw = rpc('rg_recurring_create', {
        'p_operation_id': str(uuid.uuid4()), 'p_arena_id': ARENA, 'p_court_id': C[court], 'p_customer_id': None, 'p_customer': None,
        'p_frequency': 'WEEKLY', 'p_weekday': WD, 'p_day_of_month': None, 'p_start_time': start, 'p_end_time': end,
        'p_start_date': str(TODAY), 'p_end_date': None, 'p_has_no_end_date': True, 'p_default_price': None, 'p_notes': None,
        'p_is_demo': True, 'p_skip_conflicts': False, 'p_dates': [str(d) for d in dates]}, token or T_OWNER)
    assert s == 200 and b.get('series_id'), f'rpc create {s} {raw[:200]}'
    return b['series_id']


def occ(series_id):
    return svc_get('reservations', {'recurring_reservation_id': f'eq.{series_id}', 'select': 'id,status,occurrence_date,start_at', 'order': 'occurrence_date.asc'})


def series_row(series_id):
    return svc_get('recurring_reservations', {'id': f'eq.{series_id}', 'select': 'id,status,end_date,previous_series_id,operation_kind,operation_id'})[0]


def active_future(series_id):
    now = datetime.now(SP)
    return [o for o in occ(series_id) if o['status'] != 'CANCELLED' and datetime.fromisoformat(o['start_at']) >= now]


# ----------------------------------------------------------------------------- testes: API / idempotência
S = {}


def t01_create_new():
    S['op'] = str(uuid.uuid4())
    S['body'] = series_body('c1', '10:00', '11:00', operation_id=S['op'])
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, S['body'])
    assert s == 201 and b['idempotent'] is False and b['created'] >= 1 and b['id'], f'{s} {raw[:200]}'
    assert 'operation_request' not in raw, 'operation_request exposto na resposta'
    S['series'] = b['id']
    assert series_row(b['id'])['operation_kind'] == 'CREATE'


def t02_replay_same():
    before = len(occ(S['series']))
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, S['body'])
    assert s == 200 and b['idempotent'] is True and b['id'] == S['series'], f'{s} {raw[:200]}'
    assert not any(k in b for k in ('created', 'ignored', 'skipped')), f'replay com contadores: {list(b)}'
    assert len(occ(S['series'])) == before
    assert len(svc_get('recurring_reservations', {'operation_id': f'eq.{S["op"]}', 'select': 'id'})) == 1


def t03_mismatch():
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, {**S['body'], 'court_id': C['c2']})
    assert s == 409 and b.get('code') == 'IDEMPOTENCY_MISMATCH', f'{s} {raw[:200]}'
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, {**S['body'], 'customer': {'name': 'Outro cliente'}})
    assert s == 409 and b.get('code') == 'IDEMPOTENCY_MISMATCH', f'cliente diferente: {s} {raw[:200]}'


def t04_replay_after_patch():
    s, b, raw = api('PATCH', f'/recurring-reservations/{S["series"]}', T_OWNER, {'notes': 'mudou depois', 'default_price': 777})
    assert s == 200 and b['notes'] == 'mudou depois', f'patch {s} {raw[:200]}'
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, S['body'])
    assert s == 200 and b['idempotent'] is True, f'replay após PATCH {s} {raw[:200]}'


def t05_needs_decision_same_op():
    s, _, raw = api('POST', '/reservations', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C['c3'], 'date': str(D2), 'start_time': '20:00', 'end_time': '21:00'})
    assert s == 201, f'reserva avulsa {s} {raw[:200]}'
    op = str(uuid.uuid4())
    body = series_body('c3', '20:00', '21:00', operation_id=op)
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, body)
    assert s == 409 and b.get('needs_decision') and any(c['date'] == str(D2) for c in b['conflicts']), f'{s} {raw[:200]}'
    s, b, raw = api('POST', '/recurring-reservations', T_OWNER, {**body, 'skip_conflicts': True})
    assert s == 201 and b['created'] >= 1, f'skip com o MESMO operation_id: {s} {raw[:200]}'


def t06_reschedule_idempotency():
    sid = create_rpc_series('c4', '08:00', '09:00', [D1, D2])
    op = str(uuid.uuid4())
    body = {'from_date': str(D2), 'court_id': C['c4'], 'start_time': '09:00', 'end_time': '10:00', 'weekday': WD, 'day_of_month': None, 'operation_id': op}
    s, b, raw = api('POST', f'/recurring-reservations/{sid}/reschedule', T_OWNER, body)
    assert s == 201 and b['idempotent'] is False and b['previous'] == sid, f'{s} {raw[:200]}'
    new = b['id']
    assert series_row(new)['previous_series_id'] == sid
    s, b, raw = api('POST', f'/recurring-reservations/{sid}/reschedule', T_OWNER, body)
    assert s == 200 and b['idempotent'] is True and b['id'] == new and 'created' not in b, f'replay {s} {raw[:200]}'
    other = create_rpc_series('c4', '11:00', '12:00', [D1])
    s, b, raw = api('POST', f'/recurring-reservations/{other}/reschedule', T_OWNER, {**body, 'start_time': '12:00', 'end_time': '13:00'})
    assert s == 409 and b.get('code') == 'IDEMPOTENCY_MISMATCH', f'mesmo op em outra série: {s} {raw[:200]}'


def t07_permissions_api():
    sid = S['series']
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/pause', T_REC, {'cancel_future': False})
    assert s == 403, f'receptionist pause {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/cancel', T_REC, {})
    assert s == 403, f'receptionist cancel {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/reschedule', T_REC, {'from_date': str(D2), 'operation_id': str(uuid.uuid4())})
    assert s == 403, f'receptionist reschedule {s} {raw[:160]}'
    s, _, raw = api('PATCH', f'/recurring-reservations/{sid}', T_REC, {'notes': 'x'})
    assert s == 403, f'receptionist patch {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/generate', T_REC, {})
    assert s == 200, f'receptionist generate (D5) {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/pause', T_OUT, {'cancel_future': False})
    assert s == 404, f'outra org {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/pause', T_MGR, {'cancel_future': False})
    assert s == 200, f'manager pause {s} {raw[:160]}'
    s, _, raw = api('POST', f'/recurring-reservations/{sid}/reactivate', T_MGR, {})
    assert s == 200, f'manager reactivate {s} {raw[:160]}'


def t08_rpc_execute_grants():
    args = {'p_series_id': S['series'], 'p_cancel_future': False}
    s, b, raw = rpc('rg_recurring_pause', args, key='anon')
    assert s in (401, 403) and b.get('code') == '42501', f'anon {s} {raw[:160]}'
    s, b, raw = rpc('rg_recurring_pause', args, key='service')
    assert s in (401, 403) and b.get('code') == '42501', f'service_role {s} {raw[:160]}'


def t09_d7_direct_insert():
    sid = create_rpc_series('c5', '07:00', '08:00', [D1])
    base = {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C['c5'], 'customer_id': None, 'start_at': iso(D2, '07:00'), 'end_at': iso(D2, '08:00'),
            'status': 'CONFIRMED', 'source': 'RECORRENTE', 'notes': None, 'price': None, 'recurring_reservation_id': sid,
            'occurrence_date': str(D2), 'is_exception': False, 'created_by': U_OWNER}
    for field, bad in [('status', 'CANCELLED'), ('source', 'INTERNAL'), ('price', 1), ('notes', 'x'), ('is_exception', True),
                       ('occurrence_date', str(D2 + timedelta(days=1))), ('start_at', iso(D2, '07:30')), ('created_by', U_MGR),
                       ('public_code', f'RG-B3{RUN}'), ('idempotency_key', f'b3-{RUN}'), ('customer_id', CUST)]:
        s, b, raw = user_rest('POST', 'reservations', T_OWNER, {**base, field: bad})
        assert s == 400 and isinstance(b, dict) and b.get('code') == '23514', f'D7 {field}: {s} {raw[:160]}'
    assert len(occ(sid)) == 1, 'nenhuma ocorrência forjada pode ter sido gravada'


def t10_projection():
    """Projeção pública = exatamente as 20 colunas de negócio; metadados B3 nunca na resposta."""
    s, rows, raw = api('GET', f'/recurring-reservations?organization_id={ORG}', T_OWNER)
    assert s == 200 and rows, f'lista {s} {raw[:160]}'
    for r in rows:
        assert set(r) == PUBLIC_SERIES_KEYS | {'customer', 'court', 'arena', 'next_occurrence'}, f'chaves da lista: {sorted(set(r) ^ PUBLIC_SERIES_KEYS)}'
    s, d, raw = api('GET', f'/recurring-reservations/{S["series"]}', T_OWNER)
    assert s == 200 and set(d) == PUBLIC_SERIES_KEYS | {'customer', 'court', 'arena', 'upcoming'}, f'detalhe: {s} {sorted(d) if d else raw[:160]}'
    # respostas de mutação também só com a projeção pública
    s, p, raw = api('PATCH', f'/recurring-reservations/{S["series"]}', T_OWNER, {'notes': 'proj'})
    assert s == 200 and set(p) == PUBLIC_SERIES_KEYS, f'PATCH: {sorted(p) if p else raw[:160]}'
    s, p, raw = api('POST', f'/recurring-reservations/{S["series"]}/pause', T_OWNER, {'cancel_future': False})
    assert s == 200 and set(p['series']) == PUBLIC_SERIES_KEYS, f'pause: {raw[:160]}'
    s, p, raw = api('POST', f'/recurring-reservations/{S["series"]}/reactivate', T_OWNER, {})
    assert s == 200 and set(p['series']) == PUBLIC_SERIES_KEYS, f'reactivate: {raw[:160]}'
    s, p, raw = api('POST', '/recurring-reservations', T_OWNER, S['body'])  # replay
    assert s == 200 and set(p['series']) == PUBLIC_SERIES_KEYS, f'replay: {raw[:160]}'
    for k in B3_INTERNAL_KEYS:
        assert f'"{k}"' not in raw, f'metadado B3 {k} exposto'
    # e direto no PostgREST: operation_request nunca legível
    s, b, raw = user_rest('GET', 'recurring_reservations', T_OWNER, query=f'?id=eq.{S["series"]}&select=operation_request')
    assert s in (401, 403) and b.get('code') == '42501', f'SELECT operation_request {s} {raw[:160]}'


def t12_same_op_two_orgs():
    """O MESMO operation_id em duas organizações diferentes é aceito de forma independente."""
    body_out = {'organization_id': ORG_OUT, 'arena_id': ARENA_OUT, 'court_id': C_OUT['c1'], 'frequency': 'WEEKLY', 'weekday': WD,
                'start_time': '10:00', 'end_time': '11:00', 'start_date': str(TODAY), 'has_no_end_date': True,
                'customer': {'name': f'Cliente outra org {RUN}', 'phone': '11 90000-0007'}, 'operation_id': S['op']}
    s, b, raw = api('POST', '/recurring-reservations', T_OUT, body_out)
    assert s == 201 and b['idempotent'] is False and b['id'] != S['series'], f'outra org com o mesmo op: {s} {raw[:200]}'
    rows = svc_get('recurring_reservations', {'operation_id': f'eq.{S["op"]}', 'select': 'id,organization_id'})
    assert sorted(r['organization_id'] for r in rows) == sorted([ORG, ORG_OUT]), rows
    s, b, raw = api('POST', '/recurring-reservations', T_OUT, body_out)  # replay na org de fora continua dela
    assert s == 200 and b['idempotent'] is True and b['id'] != S['series'], f'replay outra org: {s} {raw[:200]}'


def t11_lockdown():
    s, b, raw = user_rest('PATCH', 'recurring_reservations', T_OWNER, {'status': 'PAUSED'}, f'?id=eq.{S["series"]}')
    assert s in (401, 403) and b.get('code') == '42501', f'UPDATE direto {s} {raw[:160]}'
    s, b, raw = user_rest('POST', 'recurring_reservations', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C['c6'], 'frequency': 'WEEKLY', 'weekday': 1,
                                                                        'start_time': '06:00', 'end_time': '07:00', 'start_date': str(TODAY), 'has_no_end_date': True})
    assert s in (401, 403) and b.get('code') == '42501', f'INSERT direto {s} {raw[:160]}'


# ----------------------------------------------------------------------------- concorrência (R rodadas cada)
def gen_call(sid, dates, token=None):
    return lambda: rpc('rg_recurring_generate', {'p_series_id': sid, 'p_dates': [str(d) for d in dates]}, token or T_OWNER)


def c01_generate_x_generate():
    for r in range(ROUNDS):
        sid = create_rpc_series('c6', f'{6 + r:02d}:00', f'{7 + r:02d}:00', [D1])
        a, b = parallel(gen_call(sid, [D2, D3]), gen_call(sid, [D2, D3], T_REC))
        assert a[0] == 200 and b[0] == 200, f'{a[:2]} {b[:2]}'
        rows = occ(sid)
        assert sorted(o['occurrence_date'] for o in rows) == sorted(map(str, [D1, D2, D3])), f'âncoras: {rows}'
        assert len(a[1]['created']) + len(b[1]['created']) == 2, 'cada âncora criada exatamente uma vez'


def c02_generate_x_pause():
    for r in range(ROUNDS):
        sid = create_rpc_series('c6', f'{10 + r:02d}:00', f'{11 + r:02d}:00', [D1])
        g, p = parallel(gen_call(sid, [D2, D3]), lambda: rpc('rg_recurring_pause', {'p_series_id': sid, 'p_cancel_future': True}, T_OWNER))
        assert p[0] == 200 and g[0] in (200, 400), f'gen {g[:2]} pause {p[:2]}'
        if g[0] == 400:
            assert g[1].get('code') == 'RGR01', g
        assert series_row(sid)['status'] == 'PAUSED'
        assert not active_future(sid), 'série PAUSED não pode ganhar ocorrência ativa'


def c03_generate_x_cancel():
    for r in range(ROUNDS):
        sid = create_rpc_series('c6', f'{14 + r:02d}:00', f'{15 + r:02d}:00', [D1])
        g, c = parallel(gen_call(sid, [D2, D3]), lambda: rpc('rg_recurring_cancel', {'p_series_id': sid}, T_OWNER))
        assert c[0] == 200 and g[0] in (200, 400), f'gen {g[:2]} cancel {c[:2]}'
        assert series_row(sid)['status'] == 'CANCELLED'
        assert not active_future(sid), 'série CANCELLED não pode ganhar ocorrência ativa'


def c04_reactivate_x_cancel():
    for r in range(ROUNDS):
        sid = create_rpc_series('c5', f'{10 + r:02d}:00', f'{11 + r:02d}:00', [D1])
        s, _, raw = rpc('rg_recurring_pause', {'p_series_id': sid, 'p_cancel_future': False}, T_OWNER)
        assert s == 200, raw[:160]
        a, c = parallel(lambda: rpc('rg_recurring_reactivate', {'p_series_id': sid, 'p_dates': [str(D2)]}, T_OWNER),
                        lambda: rpc('rg_recurring_cancel', {'p_series_id': sid}, T_MGR))
        assert c[0] == 200 and a[0] in (200, 400), f'react {a[:2]} cancel {c[:2]}'
        assert series_row(sid)['status'] == 'CANCELLED', 'ordem serial: cancel sempre vence no fim'
        assert not active_future(sid)


def c05_reschedule_x_reschedule_same_series():
    for r in range(ROUNDS):
        sid = create_rpc_series('c1', f'{14 + r:02d}:00', f'{15 + r:02d}:00', [D1, D2])
        mk = lambda st: lambda: api('POST', f'/recurring-reservations/{sid}/reschedule', T_OWNER,  # noqa: E731
                                    {'from_date': str(D2), 'start_time': st, 'end_time': f'{int(st[:2]) + 1:02d}:00', 'skip_conflicts': True, 'operation_id': str(uuid.uuid4())})
        a, b = parallel(mk('18:00'), mk('20:00'))
        codes = sorted([a[0], b[0]])
        assert codes == [201, 409], f'esperado um 201 e um 409: {a[:2]} {b[:2]}'
        kids = svc_get('recurring_reservations', {'previous_series_id': f'eq.{sid}', 'status': 'neq.CANCELLED', 'select': 'id'})
        assert len(kids) == 1, f'descendentes vivos: {kids}'
        assert not [o for o in active_future(sid) if o['occurrence_date'] >= str(D2)], 'futuras antigas ativas após reschedule'


def c06_reschedule_a_x_b_same_op():
    for r in range(ROUNDS):
        sa = create_rpc_series('c2', f'{6 + r:02d}:00', f'{7 + r:02d}:00', [D1, D2])
        sb = create_rpc_series('c3', f'{6 + r:02d}:00', f'{7 + r:02d}:00', [D1, D2])
        op = str(uuid.uuid4())
        body = {'from_date': str(D2), 'start_time': f'{12 + r:02d}:00', 'end_time': f'{13 + r:02d}:00', 'skip_conflicts': True, 'operation_id': op}
        a, b = parallel(lambda: api('POST', f'/recurring-reservations/{sa}/reschedule', T_OWNER, body),
                        lambda: api('POST', f'/recurring-reservations/{sb}/reschedule', T_OWNER, body))
        assert sorted([a[0], b[0]]) == [201, 409], f'{a[:2]} {b[:2]}'
        loser = a if a[0] == 409 else b
        assert loser[1].get('code') == 'IDEMPOTENCY_MISMATCH', loser
        assert len(svc_get('recurring_reservations', {'operation_id': f'eq.{op}', 'select': 'id'})) == 1
        untouched = sb if a[0] == 201 else sa
        assert series_row(untouched)['end_date'] is None, 'a série perdedora não pode ter sido encerrada'


def c07_create_x_create_same_op():
    for r in range(ROUNDS):
        op = str(uuid.uuid4())
        body = series_body('c4', f'{14 + r:02d}:00', f'{15 + r:02d}:00', operation_id=op, skip_conflicts=True)
        a, b = parallel(lambda: api('POST', '/recurring-reservations', T_OWNER, body), lambda: api('POST', '/recurring-reservations', T_OWNER, body))
        assert sorted([a[0], b[0]]) == [200, 201], f'{a[:2]} {b[:2]}'
        loser = a if a[0] == 200 else b
        assert loser[1].get('idempotent') is True and 'created' not in loser[1], f'perdedor deve ser replay: {loser}'
        rows = svc_get('recurring_reservations', {'operation_id': f'eq.{op}', 'select': 'id,customer_id'})
        assert len(rows) == 1, f'séries com o mesmo op: {rows}'
        custs = svc_get('customers', {'organization_id': f'eq.{ORG}', 'phone': 'eq.11900000009', 'select': 'id'})
        assert len(custs) == 1, f'cliente duplicado/órfão: {custs}'


def c08_create_same_op_diff_payload():
    for r in range(ROUNDS):
        op = str(uuid.uuid4())
        b1 = series_body('c5', f'{18 + r:02d}:00', f'{19 + r:02d}:00', operation_id=op, skip_conflicts=True)
        b2 = {**b1, 'court_id': C['c6']}
        a, b = parallel(lambda: api('POST', '/recurring-reservations', T_OWNER, b1), lambda: api('POST', '/recurring-reservations', T_OWNER, b2))
        assert sorted([a[0], b[0]]) == [201, 409], f'{a[:2]} {b[:2]}'
        assert len(svc_get('recurring_reservations', {'operation_id': f'eq.{op}', 'select': 'id'})) == 1


def c10_double_click_create_no_skip():
    """Double-click: MESMO operation_id + MESMO payload + skip_conflicts=false, concorrentes.
    Exatamente uma série; o perdedor é replay (200, idempotent, sem contadores) — nunca
    needs_decision falso causado pela própria série, nunca série duplicada."""
    for r in range(ROUNDS):
        op = str(uuid.uuid4())
        body = series_body('c3', f'{6 + r:02d}:00', f'{7 + r:02d}:00', operation_id=op)
        a, b = parallel(lambda: api('POST', '/recurring-reservations', T_OWNER, body), lambda: api('POST', '/recurring-reservations', T_OWNER, body))
        assert sorted([a[0], b[0]]) == [200, 201], f'{a[:2]} {b[:2]}'
        loser = a if a[0] == 200 else b
        assert loser[1].get('idempotent') is True and not any(k in loser[1] for k in ('created', 'ignored', 'skipped')), loser
        rows = svc_get('recurring_reservations', {'operation_id': f'eq.{op}', 'select': 'id'})
        assert len(rows) == 1, f'séries com o mesmo op: {rows}'
        dates = [o['occurrence_date'] for o in occ(rows[0]['id'])]
        assert len(dates) == len(set(dates)), 'ocorrência duplicada'


def c09_reschedule_retry_after_timeout():
    for r in range(ROUNDS):
        sid = create_rpc_series('c2', f'{18 + r:02d}:00', f'{19 + r:02d}:00', [D1, D2])
        body = {'from_date': str(D2), 'start_time': f'{20 + r % 3:02d}:00', 'end_time': f'{21 + r % 3:02d}:00', 'skip_conflicts': True, 'operation_id': str(uuid.uuid4())}
        a, b = parallel(lambda: api('POST', f'/recurring-reservations/{sid}/reschedule', T_OWNER, body),
                        lambda: api('POST', f'/recurring-reservations/{sid}/reschedule', T_OWNER, body))
        assert sorted([a[0], b[0]]) == [200, 201], f'retry concorrente do mesmo op: {a[:2]} {b[:2]}'
        assert len(svc_get('recurring_reservations', {'previous_series_id': f'eq.{sid}', 'select': 'id'})) == 1


# ----------------------------------------------------------------------------- main
exit_code = 1
try:
    print(f'== Security B3 — integração/concorrência — run {RUN} (rounds={ROUNDS}, lockdown={EXPECT_LOCKDOWN}) ==')
    U_OWNER, T_OWNER = create_user('owner')
    U_MGR, T_MGR = create_user('mgr')
    U_REC, T_REC = create_user('rec')
    U_OUT, T_OUT = create_user('out')
    ORG, ARENA, C = create_org('A', [(U_OWNER, 'OWNER'), (U_MGR, 'MANAGER'), (U_REC, 'RECEPTIONIST')])
    ORG_OUT, ARENA_OUT, C_OUT = create_org('Outra', [(U_OUT, 'OWNER')])
    s, b, raw = svc('POST', 'customers', {'organization_id': ORG, 'arena_id': ARENA, 'name': f'Cliente fixo {RUN}', 'phone': '11900000008'})
    assert s == 201, raw[:200]
    CUST = b[0]['id']
    cases = [
        ('T01 create novo (201, operation_kind=CREATE)', t01_create_new), ('T02 replay mesmo request (200 idempotent, sem contadores)', t02_replay_same),
        ('T03 mesmo op + payload/cliente diferente (409 RGR02)', t03_mismatch), ('T04 replay após PATCH continua idempotente', t04_replay_after_patch),
        ('T05 needs_decision + skip com o MESMO op', t05_needs_decision_same_op), ('T06 reschedule: novo, replay, op em outra série', t06_reschedule_idempotency),
        ('T07 permissões via API', t07_permissions_api), ('T08 anon/service_role sem EXECUTE', t08_rpc_execute_grants),
        ('T09 D7: INSERT direto forjado rejeitado', t09_d7_direct_insert), ('T10 projeção pública = 20 colunas, sem metadados B3', t10_projection),
        ('T12 mesmo operation_id em duas organizações', t12_same_op_two_orgs),
        ('C01 generate x generate', c01_generate_x_generate), ('C02 generate x pause', c02_generate_x_pause),
        ('C03 generate x cancel', c03_generate_x_cancel), ('C04 reactivate x cancel', c04_reactivate_x_cancel),
        ('C05 reschedule x reschedule (mesma série)', c05_reschedule_x_reschedule_same_series),
        ('C06 reschedule A op=X x reschedule B op=X', c06_reschedule_a_x_b_same_op),
        ('C07 create x create mesmo op/payload', c07_create_x_create_same_op), ('C08 create mesmo op payload diferente', c08_create_same_op_diff_payload),
        ('C09 reschedule retry concorrente (timeout)', c09_reschedule_retry_after_timeout),
        ('C10 double-click create (mesmo op/payload, skip=false)', c10_double_click_create_no_skip),
    ]
    if EXPECT_LOCKDOWN:
        cases.append(('L01 LOCKDOWN: INSERT/UPDATE direto negados', t11_lockdown))
    for name, fn in cases:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    if FX.cleanup() != 0:
        exit_code = 1
sys.exit(exit_code)
