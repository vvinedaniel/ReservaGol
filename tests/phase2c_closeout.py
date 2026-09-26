#!/usr/bin/env python3
"""
Reserva Gol — Fase 02C — harness reproduzível de fechamento.

Cria uma organização de teste NOVA e isolada (is_demo) a cada execução, com usuários
OWNER / MANAGER / RECEPTIONIST efêmeros, e executa:
  T10, EXTRA meia-noite, C4 e regressão (T1, T5, T6, T7, T9, C1, C2, C3,
  CANCELLED libera horário, reschedule OWNER/MANAGER, RECEPTIONIST 403 sem efeitos).

NENHUMA credencial fica neste arquivo. Variáveis de ambiente obrigatórias:
  BASE_URL                              URL do app Next.js em execução (ex.: http://localhost:3000)
  SUPABASE_URL                          URL do projeto Supabase
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY  chave publishable (login dos usuários de teste)
  SUPABASE_SECRET_KEY                   chave secreta (cria usuários de teste e confere o banco)
  TEST_ACCOUNT_PASSWORD                 senha usada nos usuários efêmeros criados pelo teste
Opcional:
  TEST_EMAIL_DOMAIN                     domínio dos e-mails efêmeros (padrão: reservagol.test)

Apenas biblioteca padrão do Python. Uso: python tests/phase2c_closeout.py

B3: create/reschedule de mensalista enviam operation_id (UUID novo por intenção). Chamadas
públicas enviam X-Forwarded-For de teste (198.18.0.0/15) para que os buckets de rate limit
sejam rastreáveis. No fim há limpeza verificável (tests/harness_cleanup.py):
created / cleaned / residual — residual != 0 faz o harness falhar.
"""
import atexit
import json
import random
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import date, datetime, timedelta, timezone

from harness_cleanup import FixtureTracker

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

SP = timezone(timedelta(hours=-3))  # America/Sao_Paulo (sem horário de verão desde 2019)
RUN = uuid.uuid4().hex[:8]
ACTIVE = '(PENDING,CONFIRMED,PAID,BLOCKED)'
RAW_ERR = ['no_overlap', '23P01', 'exclusion', 'violates', 'duplicate key', 'constraint']
results = {}
# Limpeza verificável (created/cleaned/residual): só o que ESTA execução criou.
FX = FixtureTracker(SB, SECRET)
atexit.register(FX.cleanup)


# ----------------------------------------------------------------------------- http
def http(method, url, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {'Content-Type': 'application/json', **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        status = e.code
    try:
        return status, json.loads(raw) if raw else None, raw
    except ValueError:
        return status, None, raw


def api(method, path, token=None, body=None, headers=None):
    h = {'Authorization': f'Bearer {token}'} if token else {}
    return http(method, BASE + path, {**h, **(headers or {})}, body)


def public_reserve(body):
    """Reserva pública com IP de teste conhecido (bucket A6 rastreado para a limpeza)."""
    ip = f'198.{random.randint(18, 19)}.{random.randint(0, 255)}.{random.randint(1, 254)}'
    FX.public_reserve(ARENA, body.get('phone'), ip)
    return api('POST', '/public/reserve', None, body, {'X-Forwarded-For': ip})


def svc_headers():
    return {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}


def rest_get(table, params):
    qs = urllib.parse.urlencode(params, doseq=True)
    s, b, raw = http('GET', f'{SB}/rest/v1/{table}?{qs}', svc_headers())
    assert s == 200, f'REST {table} {s} {raw[:200]}'
    return b


def rest_post(table, row):
    s, b, raw = http('POST', f'{SB}/rest/v1/{table}', {**svc_headers(), 'Prefer': 'return=representation'}, row)
    assert s in (200, 201), f'REST insert {table} {s} {raw[:200]}'
    return b


# ----------------------------------------------------------------------------- helpers
def create_user(label):
    email = f'p2c-{label}-{RUN}@{DOMAIN}'
    s, b, raw = http('POST', f'{SB}/auth/v1/admin/users', svc_headers(), {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'create user {s} {raw[:200]}'
    FX.user(b['id'])
    s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    return b['id'], t['access_token']


def today():
    return datetime.now(SP).date()


def js_wd(d):
    return d.isoweekday() % 7  # 0=domingo .. 6=sábado (convenção do app)


def next_wd(wd, min_offset=1):
    d = today() + timedelta(days=min_offset)
    while js_wd(d) != wd:
        d += timedelta(days=1)
    return d


def local(iso):
    return datetime.fromisoformat(iso.replace('Z', '+00:00')).astimezone(SP)


def day_range(d, hh):
    """Intervalo [d hh:00, d hh:59:59] (SP) para filtrar start_at."""
    return [('start_at', f'gte.{d}T{hh}:00:00-03:00'), ('start_at', f'lte.{d}T{hh}:59:59-03:00')]


def active_at(court_id, d, hh):
    return rest_get('reservations', [('select', 'id,status,start_at,end_at,source'), ('court_id', f'eq.{court_id}'), ('status', f'in.{ACTIVE}')] + day_range(d, hh))


def occurrences(series_id):
    return rest_get('reservations', {'select': 'id,status,start_at,end_at,occurrence_date,is_exception,court_id,recurring_reservation_id',
                                     'recurring_reservation_id': f'eq.{series_id}', 'order': 'occurrence_date.asc'})


def friendly(raw):
    return not any(k.lower() in (raw or '').lower() for k in RAW_ERR)


def race(fa, fb):
    """Executa duas chamadas de forma realmente concorrente (barreira)."""
    bar = threading.Barrier(2)
    out = [None, None]

    def run(i, f):
        bar.wait()
        out[i] = f()
    ts = [threading.Thread(target=run, args=(0, fa)), threading.Thread(target=run, args=(1, fb))]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return out


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
print(f'== Fase 02C closeout — run {RUN} ==')
owner_id, OWNER = create_user('owner')
manager_id, MANAGER = create_user('manager')
recep_id, RECEP = create_user('recep')

s, b, raw = api('POST', '/onboarding', OWNER, {
    'organization': {'name': f'P2C Closeout {RUN}', 'owner_name': 'Teste 02C', 'phone': '11999990000', 'is_demo': True},
    'arena': {'name': f'Arena P2C {RUN}', 'address': 'Rua Teste', 'number': '1', 'city': 'São Paulo', 'state': 'SP', 'whatsapp': '11999990000'},
    'courts': [{'name': 'Quadra 1', 'type': 'SOCIETY'}, {'name': 'Quadra 2', 'type': 'SOCIETY'}, {'name': 'Quadra 3', 'type': 'SOCIETY'}],
    # Funcionamento 08:00 -> 00:00 (fecha à meia-noite) em todos os dias.
    'hours': [{'weekday': i, 'open_time': '08:00', 'close_time': '00:00', 'closed': False} for i in range(7)],
    'default_reservation_minutes': 60,
})
assert s == 200, f'onboarding {s} {raw[:200]}'
ORG = FX.org(b['organization_id'], f'P2C Closeout {RUN}')
rest_post('organization_members', {'organization_id': ORG, 'user_id': manager_id, 'role': 'MANAGER', 'status': 'ACTIVE'})
rest_post('organization_members', {'organization_id': ORG, 'user_id': recep_id, 'role': 'RECEPTIONIST', 'status': 'ACTIVE'})
_, arenas, _ = api('GET', f'/arenas?organization_id={ORG}', OWNER)
ARENA = arenas[0]['id']
_, courts, _ = api('GET', f'/courts?organization_id={ORG}', OWNER)
C1, C2, C3 = [c['id'] for c in sorted(courts, key=lambda c: c['name'])]
SLUG = f'p2c-{RUN}'
s, _, raw = api('PUT', f'/arenas/{ARENA}', OWNER, {'slug': SLUG, 'description': 'Arena de teste 02C', 'cover_image_url': 'https://example.com/cover.jpg'})
assert s == 200, f'arena perfil {s} {raw[:200]}'
s, _, raw = api('PUT', f'/arenas/{ARENA}', OWNER, {'public_booking_enabled': True})
assert s == 200, f'publicar arena {s} {raw[:200]}'
s, pa, _ = api('GET', f'/public/arena/{SLUG}')
assert s == 200, 'arena pública não encontrada'
print(f'org={ORG} arena={ARENA} slug={SLUG}')


def base(**kw):
    return {'organization_id': ORG, 'arena_id': ARENA, **kw}


def series(token, court, wd, st, et, start_d, **kw):
    kw.setdefault('operation_id', str(uuid.uuid4()))  # B3: uma chave por intenção
    return api('POST', '/recurring-reservations', token, base(court_id=court, frequency='WEEKLY', weekday=wd, start_time=st, end_time=et,
                                                               start_date=str(start_d), has_no_end_date=True,
                                                               customer={'name': f'Mensalista {st}', 'phone': f'119800000{st[:2]}'}, **kw))


def internal(token, court, d, st, et, name='Cliente Interno'):
    return api('POST', '/reservations', token, base(court_id=court, date=str(d), start_time=st, end_time=et, customer={'name': name, 'phone': '11977770000'}))


# ----------------------------------------------------------------------------- T1
def t1():
    d = next_wd(3)
    s, b, raw = series(OWNER, C1, 3, '20:00', '21:00', d)
    assert s == 201, f'{s} {raw[:200]}'
    occ = occurrences(b['id'])
    assert len(occ) >= 12, f'{len(occ)} ocorrências'
    for o in occ:
        st = local(o['start_at'])
        assert js_wd(st.date()) == 3 and st.strftime('%H:%M') == '20:00', f'ocorrência fora do padrão: {o["start_at"]}'
        assert str(st.date()) == o['occurrence_date']
    globals()['T1_OCC'] = occ


# ----------------------------------------------------------------------------- T5 / T6
T5_DATE = next_wd(4, 2)


def t5():
    s, _, raw = internal(OWNER, C2, T5_DATE, '15:00', '16:00')
    assert s == 201, f'reserva bloqueadora {s} {raw[:200]}'
    s, b, raw = series(OWNER, C2, 4, '15:00', '16:00', T5_DATE, dry_run=True)
    assert s == 200, f'{s} {raw[:200]}'
    assert [c['date'] for c in b['conflicts']] == [str(T5_DATE)], b['conflicts']
    assert b['toCreate'] > 0


def t6():
    s, b, raw = series(OWNER, C2, 4, '15:00', '16:00', T5_DATE)
    assert s == 409 and b.get('needs_decision'), f'sem skip deveria 409: {s}'
    s, b, raw = series(OWNER, C2, 4, '15:00', '16:00', T5_DATE, skip_conflicts=True)
    assert s == 201, f'{s} {raw[:200]}'
    assert [c['date'] for c in b['ignored']] == [str(T5_DATE)] and b['created'] > 0, b
    act = active_at(C2, T5_DATE, '15')
    assert len(act) == 1 and act[0]['source'] != 'RECORRENTE', 'reserva original deveria continuar intacta'


# ----------------------------------------------------------------------------- T7
def t7():
    o = T1_OCC[0]
    st = local(o['start_at'])
    s, b, raw = internal(OWNER, C1, st.date(), '20:00', '21:00')
    assert s == 409, f'{s}'
    assert friendly(raw) and 'indisponível' in b['error'], raw[:200]


# ----------------------------------------------------------------------------- T9 / reschedule
def t9_owner():
    d = next_wd(5)
    s, b, raw = series(OWNER, C1, 5, '18:00', '19:00', d)
    assert s == 201, raw[:200]
    old = b['id']
    occ = occurrences(old)
    from_date = occ[2]['occurrence_date']
    s, r, raw = api('POST', f'/recurring-reservations/{old}/reschedule', OWNER, {'from_date': from_date, 'weekday': 6, 'start_time': '19:00', 'end_time': '20:00', 'court_id': C1,
                                                                                  'operation_id': str(uuid.uuid4())})
    assert s == 201, f'{s} {raw[:200]}'
    after = occurrences(old)
    kept = [o for o in after if o['occurrence_date'] < from_date]
    moved = [o for o in after if o['occurrence_date'] >= from_date]
    assert len(kept) == 2 and all(o['status'] == 'CONFIRMED' for o in kept), 'anteriores devem ficar intactas'
    assert moved and all(o['status'] == 'CANCELLED' for o in moved), 'futuras da série antiga devem ser canceladas'
    new = occurrences(r['id'])
    assert new and r['created'] == len(new)
    for o in new:
        st = local(o['start_at'])
        assert js_wd(st.date()) == 6 and st.strftime('%H:%M') == '19:00' and o['occurrence_date'] >= from_date
    s, sd, _ = api('GET', f'/recurring-reservations/{old}', OWNER)
    assert sd['end_date'] == str(date.fromisoformat(from_date) - timedelta(days=1)) and sd['has_no_end_date'] is False


def t9_same_slot():
    """Correção 3: reagendar mantendo quadra/horário (só preço) não conflita com a própria série."""
    d = next_wd(1)
    s, b, raw = series(OWNER, C2, 1, '10:00', '11:00', d)
    assert s == 201, raw[:200]
    old = b['id']
    from_date = occurrences(old)[1]['occurrence_date']
    s, r, raw = api('POST', f'/recurring-reservations/{old}/reschedule', OWNER, {'from_date': from_date, 'default_price': 15000, 'operation_id': str(uuid.uuid4())})
    assert s == 201, f'deveria aplicar sem conflito: {s} {raw[:300]}'
    assert r['ignored'] == [], r['ignored']
    cancelled = [o for o in occurrences(old) if o['status'] == 'CANCELLED']
    assert r['created'] == len(cancelled) > 0, (r['created'], len(cancelled))


def t9_manager():
    d = next_wd(2)
    s, b, raw = series(OWNER, C2, 2, '12:00', '13:00', d)
    assert s == 201, raw[:200]
    from_date = occurrences(b['id'])[1]['occurrence_date']
    s, r, raw = api('POST', f'/recurring-reservations/{b["id"]}/reschedule', MANAGER, {'from_date': from_date, 'start_time': '13:00', 'end_time': '14:00',
                                                                                              'operation_id': str(uuid.uuid4())})
    assert s == 201, f'MANAGER deveria reagendar: {s} {raw[:200]}'
    assert r['created'] > 0


def t9_receptionist():
    d = next_wd(3)
    s, b, raw = series(OWNER, C2, 3, '08:00', '09:00', d)
    assert s == 201, raw[:200]
    sid = b['id']
    before_series = rest_get('recurring_reservations', {'select': 'status,end_date,has_no_end_date,updated_at', 'id': f'eq.{sid}'})[0]
    before_active = [o for o in occurrences(sid) if o['status'] != 'CANCELLED']
    n_series_before = len(rest_get('recurring_reservations', {'select': 'id', 'organization_id': f'eq.{ORG}'}))
    from_date = before_active[1]['occurrence_date']
    for extra in ({}, {'skip_conflicts': True}):
        s, r, raw = api('POST', f'/recurring-reservations/{sid}/reschedule', RECEP, {'from_date': from_date, 'start_time': '09:00', 'end_time': '10:00',
                                                                                     'operation_id': str(uuid.uuid4()), **extra})
        assert s == 403, f'RECEPTIONIST deveria receber 403: {s} {raw[:200]}'
    after_series = rest_get('recurring_reservations', {'select': 'status,end_date,has_no_end_date,updated_at', 'id': f'eq.{sid}'})[0]
    after_active = [o for o in occurrences(sid) if o['status'] != 'CANCELLED']
    assert after_series == before_series, (before_series, after_series)
    assert len(after_active) == len(before_active), 'nenhuma ocorrência pode ser cancelada'
    assert len(rest_get('recurring_reservations', {'select': 'id', 'organization_id': f'eq.{ORG}'})) == n_series_before, 'nenhuma série nova'
    # RECEPTIONIST continua podendo usar "Apenas esta" (regra atual).
    o = after_active[0]
    st = local(o['start_at'])
    s, r, raw = api('PUT', f'/reservations/{o["id"]}', RECEP, base(court_id=C2, date=str(st.date()), start_time='08:00', end_time='09:00', notes='editada pela recepção'))
    assert s == 200 and r['is_exception'] is True, f'Apenas esta (recepção) {s} {raw[:200]}'


# ----------------------------------------------------------------------------- T10
def t10():
    d = next_wd(0)
    s, b, raw = series(OWNER, C1, 0, '09:00', '10:00', d)
    assert s == 201, raw[:200]
    sid = b['id']
    _, det0, _ = api('GET', f'/recurring-reservations/{sid}', OWNER)
    n0 = len(det0['upcoming'])
    target = occurrences(sid)[1]
    s, _, raw = api('POST', f'/reservations/{target["id"]}/cancel', OWNER, {'reason': 'T10'})
    assert s == 200, raw[:200]
    s, g, raw = api('POST', f'/recurring-reservations/{sid}/generate', OWNER)  # força top-up
    assert s == 200 and g['created'] == 0, f'top-up não pode recriar a âncora: {g}'
    _, det1, _ = api('GET', f'/recurring-reservations/{sid}', OWNER)
    assert det1['status'] == 'ACTIVE'
    assert len(det1['upcoming']) == n0 - 1, (n0, len(det1['upcoming']))
    assert target['id'] not in [u['id'] for u in det1['upcoming']]
    same_anchor = [o for o in occurrences(sid) if o['occurrence_date'] == target['occurrence_date']]
    assert len(same_anchor) == 1 and same_anchor[0]['status'] == 'CANCELLED', same_anchor


# ----------------------------------------------------------------------------- EXTRA: meia-noite
def extra_midnight():
    # (a) igual = inválido
    s, _, _ = series(OWNER, C1, 2, '23:00', '23:00', next_wd(2))
    assert s == 400, f'recorrência início=fim {s}'
    s, _, _ = internal(OWNER, C2, next_wd(2), '22:00', '22:00')
    assert s == 400, f'reserva início=fim {s}'
    # (b) recorrência 23:00 -> 00:00 com funcionamento 08:00 -> 00:00
    d = next_wd(2)
    s, b, raw = series(OWNER, C1, 2, '23:00', '00:00', d)
    assert s == 201 and b['created'] > 0 and b['ignored'] == [], f'{s} {raw[:300]}'
    occ = occurrences(b['id'])
    for o in occ:
        st, en = local(o['start_at']), local(o['end_at'])
        assert st.strftime('%H:%M') == '23:00' and str(st.date()) == o['occurrence_date']
        assert en.strftime('%H:%M') == '00:00' and en.date() == st.date() + timedelta(days=1), (o['start_at'], o['end_at'])
    # (c) Agenda DIA: a ocorrência aparece no dia; slots vão até 00:00
    s, ag, _ = api('GET', f'/agenda?arena_id={ARENA}&date={occ[0]["occurrence_date"]}', OWNER)
    assert s == 200 and any(r['id'] == occ[0]['id'] for r in ag['reservations'])
    # (d) disponibilidade pública: último slot 23:00-00:00, ocupado
    s, av, _ = api('GET', f'/public/availability?slug={SLUG}&court_id={C1}&date={occ[0]["occurrence_date"]}')
    assert s == 200 and av['slots'][-1]['start'] == '23:00' and av['slots'][-1]['end'] == '00:00', av['slots'][-2:]
    assert av['slots'][-1]['available'] is False, 'slot 23:00 ocupado deveria aparecer indisponível'
    assert len(av['slots']) == 16
    # (e) "Apenas esta": move ocorrência para o dia seguinte 23:00 -> 00:00
    o = occ[1]
    nd = date.fromisoformat(o['occurrence_date']) + timedelta(days=1)
    s, r, raw = api('PUT', f'/reservations/{o["id"]}', OWNER, base(court_id=C1, date=str(nd), start_time='23:00', end_time='00:00'))
    assert s == 200, f'apenas esta {s} {raw[:200]}'
    assert local(r['end_at']).date() == nd + timedelta(days=1) and r['is_exception'] and r['occurrence_date'] == o['occurrence_date']
    # (f) reserva interna e bloqueio 23:00 -> 00:00
    x = next_wd(5, 3)
    s, r, raw = internal(OWNER, C2, x, '23:00', '00:00')
    assert s == 201 and local(r['end_at']).date() == x + timedelta(days=1), f'interna {s} {raw[:200]}'
    s, r, raw = api('POST', '/reservations/block', OWNER, base(court_id=C2, date=str(x + timedelta(days=1)), start_time='23:00', end_time='00:00', reason='Manutenção'))
    assert s == 201 and local(r['end_at']).date() == x + timedelta(days=2), f'bloqueio {s} {raw[:200]}'
    # (g) reserva pública 23:00 -> 00:00 (contrato do frontend)
    pd = x + timedelta(days=2)
    s, r, raw = public_reserve({'slug': SLUG, 'court_id': C2, 'date': str(pd), 'start_time': '23:00', 'end_time': '00:00',
                                                      'name': 'Jogador Meia-noite', 'phone': '11966660000', 'email': None, 'accept_terms': True, 'idempotency_key': f'mid-{RUN}'})
    assert s == 201, f'pública {s} {raw[:200]}'
    act = active_at(C2, pd, '23')
    assert len(act) == 1 and local(act[0]['end_at']).date() == pd + timedelta(days=1)
    # (h) anti-overlap continua autoridade: 23:30 -> 00:30 colide com a pública
    s, _, raw = internal(OWNER, C2, pd, '23:30', '00:30')
    assert s == 409 and friendly(raw), f'overlap após meia-noite {s}'


# ----------------------------------------------------------------------------- concorrência
def cdate(offset):
    return today() + timedelta(days=offset)


def c1():
    d = cdate(20)
    a, b = race(lambda: internal(OWNER, C3, d, '08:00', '09:00', 'C1-A'), lambda: internal(MANAGER, C3, d, '08:00', '09:00', 'C1-B'))
    assert sorted([a[0], b[0]]) == [201, 409], (a[0], b[0])
    loser = a if a[0] == 409 else b
    assert friendly(loser[2]), loser[2][:200]
    assert len(active_at(C3, d, '08')) == 1


def c2():
    d = cdate(21)
    a, b = race(lambda: series(OWNER, C3, js_wd(d), '09:00', '10:00', d), lambda: internal(MANAGER, C3, d, '09:00', '10:00', 'C2'))
    assert a[0] in (201, 409) and b[0] in (201, 409), (a[0], b[0])
    assert friendly(a[2]) and friendly(b[2])
    assert len(active_at(C3, d, '09')) == 1


def c3():
    d = cdate(22)
    a, b = race(lambda: series(OWNER, C3, js_wd(d), '10:00', '11:00', d), lambda: series(MANAGER, C3, js_wd(d), '10:00', '11:00', d))
    assert a[0] in (201, 409) and b[0] in (201, 409), (a[0], b[0])
    assert friendly(a[2]) and friendly(b[2])
    assert len(active_at(C3, d, '10')) == 1


def c4():
    d = cdate(23)
    pub = {'slug': SLUG, 'court_id': C3, 'date': str(d), 'start_time': '14:00', 'end_time': '15:00',
           'name': 'Jogador C4', 'phone': '11955550000', 'email': None, 'accept_terms': True, 'idempotency_key': f'c4-{RUN}'}
    a, b = race(lambda: public_reserve(pub), lambda: internal(OWNER, C3, d, '14:00', '15:00', 'C4 interna'))
    assert sorted([a[0], b[0]]) == [201, 409], f'pública={a[0]} {a[2][:120]} | interna={b[0]} {b[2][:120]}'
    loser = a if a[0] == 409 else b
    assert friendly(loser[2]) and 'Dados obrigatórios' not in loser[2], loser[2][:200]
    assert len(active_at(C3, d, '14')) == 1
    print(f'      C4 vencedor: {"pública" if a[0] == 201 else "interna"}')


def cancelled_frees():
    d = cdate(24)
    s, r, raw = internal(OWNER, C3, d, '16:00', '17:00')
    assert s == 201, raw[:200]
    s, _, _ = api('POST', f'/reservations/{r["id"]}/cancel', OWNER, {'reason': 'regressão'})
    assert s == 200
    s, _, raw = internal(OWNER, C3, d, '16:00', '17:00', 'Rebook')
    assert s == 201, f'rebook {s} {raw[:200]}'
    assert len(active_at(C3, d, '16')) == 1


for name, fn in [
    ('T1 WEEKLY fuso/dia da semana', t1), ('T5 dry_run conflito', t5), ('T6 skip_conflicts', t6), ('T7 anti-overlap 409 amigável', t7),
    ('T9 reschedule OWNER', t9_owner), ('T9b reschedule mesmo horário (sem autoconflito)', t9_same_slot),
    ('T9c reschedule MANAGER', t9_manager), ('T9d RECEPTIONIST 403 sem efeitos', t9_receptionist),
    ('T10 cancelar ocorrência única', t10), ('EXTRA meia-noite', extra_midnight),
    ('C1 interna x interna', c1), ('C2 recorrente x interna', c2), ('C3 recorrente x recorrente', c3), ('C4 pública x interna', c4),
    ('REG CANCELLED libera horário', cancelled_frees),
]:
    check(name, fn)

ok = sum(1 for v in results.values() if v == 'PASS')
print(f'\n== {ok}/{len(results)} PASS (run {RUN}, org {ORG}) ==')
residual = FX.cleanup()
sys.exit(0 if ok == len(results) and residual == 0 else 1)
