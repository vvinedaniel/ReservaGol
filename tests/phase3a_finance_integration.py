#!/usr/bin/env python3
"""
Reserva Gol — FASE 03A — integração HTTP/PostgREST + CONCORRÊNCIA do financeiro.

PRÉ-REQUISITOS:
  * supabase/migration_phase3a_foundation.sql aplicada no projeto de SUPABASE_URL (B3 já aplicada);
  * app com o route 03A rodando em BASE_URL;
  * modo explícito e OBRIGATÓRIO: P3A_EXPECT_GUARDS=0 (só FOUNDATION) ou 1 (GUARDS aplicados).

ESTE HARNESS ESCREVE NO SUPABASE DE SUPABASE_URL. Sem P3A_ALLOW_WRITE=1 ele não faz NADA.
Fixtures: usuários efêmeros + organizações "P3A IT <run>" (is_demo) criadas por ele mesmo; cada
caso de concorrência usa quadra/reserva exclusivas por rodada. Cleanup verificável no fim
(sempre, mesmo com falha) via FixtureTracker: created / cleaned / residual; residual deve ser 0.

Variáveis (nenhum valor é impresso): BASE_URL, SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
SUPABASE_SECRET_KEY, TEST_ACCOUNT_PASSWORD, P3A_ALLOW_WRITE=1, P3A_EXPECT_GUARDS=0|1.
Opcionais: TEST_EMAIL_DOMAIN (padrão reservagol.test), P3A_ROUNDS (padrão 3).

Uso: P3A_ALLOW_WRITE=1 P3A_EXPECT_GUARDS=0 python tests/phase3a_finance_integration.py
"""
import atexit
import json
import os
import random
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
if os.environ.get('P3A_ALLOW_WRITE') != '1':
    print('P3A_ALLOW_WRITE=1 não definido: este harness escreve no Supabase e não foi executado.')
    sys.exit(2)
if os.environ.get('P3A_EXPECT_GUARDS') not in ('0', '1'):
    print('Defina P3A_EXPECT_GUARDS=0 (FOUNDATION) ou P3A_EXPECT_GUARDS=1 (GUARDS aplicados).')
    sys.exit(2)

BASE = os.environ['BASE_URL'].rstrip('/') + '/api'
SB = os.environ['SUPABASE_URL'].rstrip('/')
PUB_KEY = os.environ['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY']
SECRET = os.environ['SUPABASE_SECRET_KEY']
PASSWORD = os.environ['TEST_ACCOUNT_PASSWORD']
DOMAIN = os.environ.get('TEST_EMAIL_DOMAIN', 'reservagol.test')
ROUNDS = int(os.environ.get('P3A_ROUNDS', '3'))
GUARDS = os.environ['P3A_EXPECT_GUARDS'] == '1'
SP = timezone(timedelta(hours=-3))
RUN = uuid.uuid4().hex[:8]
ORG_PREFIX = f'P3A IT {RUN}'
SVC = {'apikey': SECRET, 'Authorization': f'Bearer {SECRET}'}
TODAY = datetime.now(SP).date()
D1 = TODAY + timedelta(days=7)
WD = D1.isoweekday() % 7          # 0 = domingo (igual ao banco)
results = {}
FX = FixtureTracker(SB, SECRET)
atexit.register(FX.cleanup)


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


def api(method, path, token=None, body=None, headers=None):
    h = {'Authorization': f'Bearer {token}'} if token else {}
    return http(method, BASE + path, {**h, **(headers or {})}, body)


def svc(method, path, body=None, prefer='return=representation'):
    return http(method, f'{SB}/rest/v1/{path}', {**SVC, 'Prefer': prefer}, body)


def svc_get(table, params):
    s, b, raw = http('GET', f'{SB}/rest/v1/{table}?{urllib.parse.urlencode(params, doseq=True)}', SVC)
    assert s == 200, f'svc {table} {s} {raw[:200]}'
    return b


def rpc(fn, args, token):
    return http('POST', f'{SB}/rest/v1/rpc/{fn}', {'apikey': PUB_KEY, 'Authorization': f'Bearer {token}'}, args)


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
    email = f'p3ait-{label}-{RUN}@{DOMAIN}'
    s, b, raw = http('POST', f'{SB}/auth/v1/admin/users', SVC, {'email': email, 'password': PASSWORD, 'email_confirm': True})
    assert s in (200, 201), f'criar usuário {s} {raw[:200]}'
    FX.user(b['id'])
    s, t, raw = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'apikey': PUB_KEY}, {'email': email, 'password': PASSWORD})
    assert s == 200, f'login {s} {raw[:200]}'
    return b['id'], t['access_token']


def create_org(label, members, slug=None):
    s, b, raw = svc('POST', 'organizations', {'name': f'{ORG_PREFIX} {label}', 'is_demo': True, 'onboarding_completed': True})
    assert s == 201, f'org {s} {raw[:200]}'
    org = FX.org(b[0]['id'], f'{ORG_PREFIX} {label}')
    for uid, role in members:
        s, _, raw = svc('POST', 'organization_members', {'organization_id': org, 'user_id': uid, 'role': role, 'status': 'ACTIVE'}, 'return=minimal')
        assert s in (200, 201), f'membro {s} {raw[:200]}'
    arena_row = {'organization_id': org, 'name': f'Arena {label} {RUN}', 'active': True}
    if slug:
        arena_row.update({'slug': slug, 'public_booking_enabled': True, 'address': 'Rua Teste', 'city': 'São Paulo', 'whatsapp': '11999990000',
                          'cover_image_url': 'https://example.com/cover.jpg'})
    s, b, raw = svc('POST', 'arenas', arena_row)
    assert s == 201, f'arena {s} {raw[:200]}'
    arena = b[0]['id']
    s, _, raw = svc('POST', 'business_hours', [{'organization_id': org, 'arena_id': arena, 'weekday': i, 'open_time': '06:00', 'close_time': '00:00', 'closed': False} for i in range(7)], 'return=minimal')
    assert s in (200, 201), f'horários {s} {raw[:200]}'
    return org, arena


def new_court(org, arena, tag):
    s, b, raw = svc('POST', 'courts', {'organization_id': org, 'arena_id': arena, 'name': f'{tag} {RUN}'})
    assert s == 201, f'quadra {tag} {s} {raw[:200]}'
    return b[0]['id']


def iso(d, hhmm):
    return f'{d}T{hhmm}:00-03:00'


def svc_reservation(court, d, st, et, price=None, status='CONFIRMED', arena=None, org=None):
    """Reserva de fixture via service_role (price explícito permitido; NULL => snapshot)."""
    row = {'organization_id': org or ORG, 'arena_id': arena or ARENA, 'court_id': court, 'start_at': iso(d, st),
           'end_at': iso(d + timedelta(days=1) if et <= st else d, et), 'status': status, 'source': 'TESTE_P3A'}
    if price is not None:
        row['price'] = price
    s, b, raw = svc('POST', 'reservations', row)
    assert s == 201, f'reserva fixture {s} {raw[:200]}'
    return b[0]['id']


def now_iso(minutes=-5):
    return (datetime.now(SP) + timedelta(minutes=minutes)).replace(microsecond=0).isoformat()


def pay(token, res, amount, method='PIX', op=None, received_at=None, notes=None):
    return api('POST', f'/reservations/{res}/payments', token, {'operation_id': op or str(uuid.uuid4()), 'method': method, 'amount': amount,
                                                                'received_at': received_at or now_iso(), 'notes': notes})


def refund(token, payment, amount, method='PIX', op=None, received_at=None, notes=None):
    return api('POST', f'/payments/{payment}/refund', token, {'operation_id': op or str(uuid.uuid4()), 'method': method, 'amount': amount,
                                                              'received_at': received_at or now_iso(), 'notes': notes})


def fin(token, res):
    s, b, raw = api('GET', f'/reservations/{res}/financials', token)
    assert s == 200, f'financials {s} {raw[:200]}'
    return b


def rule(token, court, wds, st, et, price, arena=None, valid_from=None, valid_until=None):
    """UMA intenção = UM POST (lista de dias; um inteiro vira lista de 1 dia)."""
    wds = wds if isinstance(wds, list) else [wds]
    return api('POST', '/pricing-rules', token, {'arena_id': arena or ARENA, 'court_id': court, 'weekdays': wds, 'start_time': st, 'end_time': et,
                                                 'price_per_hour': price, 'valid_from': valid_from, 'valid_until': valid_until})


# ----------------------------------------------------------------------------- testes: pricing
S = {}


def t01_rules_and_quote():
    for args in [(None, WD, '08:00', '18:00', 10000), (None, WD, '18:00', '00:00', 17000), (None, (WD + 1) % 7, '00:00', '02:00', 20000)]:
        s, b, raw = rule(T_MGR, *args)
        assert s == 201 and len(b['rule_ids']) == 1 and b['split'] is False, f'regra {args}: {s} {raw[:200]}'
    s, q, raw = api('GET', f'/pricing/quote?court_id={C1}&date={D1}&start_time=17:30&end_time=19:00', T_REC)
    assert s == 200 and q['price'] == 22000 and q['covered'] is True, f'10000*30 + 17000*60 -> 22000: {s} {raw[:200]}'
    s, q, raw = api('GET', f'/pricing/quote?court_id={C1}&date={D1}&start_time=23:00&end_time=01:00', T_REC)
    assert s == 200 and q['price'] == 37000, f'meia-noite -> 37000: {s} {raw[:200]}'
    s, q, raw = api('GET', f'/pricing/quote?court_id={C1}&date={D1}&start_time=07:00&end_time=08:30', T_REC)
    assert s == 200 and q['price'] is None and q['covered'] is False, f'cobertura parcial -> NULL: {s} {raw[:200]}'


def t02_cross_midnight_atomic():
    s, b, raw = rule(T_OWNER, C2, WD, '22:00', '02:00', 15000)
    assert s == 201 and b['split'] is True and len(b['rule_ids']) == 2, f'{s} {raw[:200]}'
    rows = svc_get('court_pricing_rules', {'id': f'in.({",".join(b["rule_ids"])})', 'select': 'weekday,start_minute,end_minute,price_per_hour,scope_kind'})
    got = sorted((r['weekday'], r['start_minute'], r['end_minute']) for r in rows)
    assert got == sorted([(WD, 1320, 1440), ((WD + 1) % 7, 0, 120)]) and all(r['price_per_hour'] == 15000 and r['scope_kind'] == 'COURT' for r in rows), rows
    audits = svc_get('audit_logs', {'organization_id': f'eq.{ORG}', 'action': 'eq.PRICING_RULE_CREATED', 'entity_id': f'eq.{b["rule_ids"][0]}', 'select': 'metadata'})
    assert len(audits) == 1 and audits[0]['metadata']['split'] is True and len(audits[0]['metadata']['rule_ids']) == 2, audits
    # conflito só na 2ª metade: nada fica
    s, _, raw = rule(T_OWNER, C3, (WD + 1) % 7, '01:00', '03:00', 1000)
    assert s == 201, raw[:200]
    s, b, raw = rule(T_OWNER, C3, WD, '22:00', '02:00', 15000)
    assert s == 409 and b.get('code') == 'PRICING_OVERLAP', f'{s} {raw[:200]}'
    left = svc_get('court_pricing_rules', {'court_id': f'eq.{C3}', 'weekday': f'eq.{WD}', 'start_minute': 'eq.1320', 'select': 'id'})
    assert left == [], f'metade persistida: {left}'


def t02b_multiday_atomic():
    court = new_court(ORG, ARENA, 'md')
    days = [(WD + i) % 7 for i in range(4)]
    s, b, raw = rule(T_OWNER, court, days, '18:00', '22:00', 15000)
    assert s == 201 and b['rules_created'] == 4 and len(b['rule_ids']) == 4 and b['weekdays'] == sorted(days), f'4 dias: {s} {raw[:200]}'
    court2 = new_court(ORG, ARENA, 'md2')
    s, b, raw = rule(T_OWNER, court2, days, '22:00', '02:00', 15000)
    assert s == 201 and b['rules_created'] == 8 and b['split'] is True, f'4 dias cross-midnight: {s} {raw[:200]}'
    # conflito no dia INTERMEDIÁRIO: nenhuma regra nova em nenhum dia
    court3 = new_court(ORG, ARENA, 'md3')
    s, _, raw = rule(T_OWNER, court3, days[2], '19:00', '20:00', 1000)
    assert s == 201, raw[:160]
    s, b, raw = rule(T_OWNER, court3, days, '18:00', '22:00', 15000)
    assert s == 409 and b.get('code') == 'PRICING_OVERLAP', f'{s} {raw[:200]}'
    assert len(svc_get('court_pricing_rules', {'court_id': f'eq.{court3}', 'select': 'id'})) == 1, 'dias persistidos pela metade'
    for bad in [[], [1, 1], [7], [-1], [0, 1, 2, 3, 4, 5, 6, 0]]:
        s, _, raw = rule(T_OWNER, court3, bad, '08:00', '09:00', 1000)
        assert s == 400, f'weekdays {bad}: {s} {raw[:160]}'


def t03_rule_permissions():
    s, _, raw = rule(T_REC, None, (WD + 3) % 7, '08:00', '09:00', 1000)
    assert s == 403, f'recepção cria regra {s} {raw[:160]}'
    s, rows, raw = api('GET', f'/pricing-rules?arena_id={ARENA}', T_REC)
    assert s == 200 and len(rows) >= 3, f'recepção lê regras {s} {raw[:160]}'
    s, _, raw = rule(T_OUT, None, (WD + 3) % 7, '08:00', '09:00', 1000)
    assert s == 404, f'outra org {s} {raw[:160]}'
    s, b, raw = user_rest('POST', 'court_pricing_rules', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'weekday': 0, 'start_time': '06:00', 'end_time': '07:00', 'price_per_hour': 1})
    assert s in (401, 403) and b.get('code') == '42501', f'INSERT direto {s} {raw[:160]}'
    rid = svc_get('court_pricing_rules', {'arena_id': f'eq.{ARENA}', 'court_id': 'is.null', 'weekday': f'eq.{WD}', 'start_minute': 'eq.480', 'select': 'id'})[0]['id']
    s, b, raw = api('PUT', f'/pricing-rules/{rid}', T_MGR, {'end_time': '07:00'})
    assert s == 400, f'UPDATE atravessando meia-noite {s} {raw[:160]}'


# ----------------------------------------------------------------------------- testes: reservas / snapshot
def t04_internal_snapshot_and_status():
    s, r, raw = api('POST', '/reservations', T_REC, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'date': str(D1), 'start_time': '17:30', 'end_time': '19:00',
                                                     'customer': {'name': f'Cliente P3A {RUN}', 'phone': '11911110000'}})
    assert s == 201 and r['price'] == 22000, f'snapshot interno {s} {raw[:200]}'
    S['res'] = r['id']
    s, _, raw = api('POST', '/reservations', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'date': str(D1), 'start_time': '06:00', 'end_time': '07:00', 'price': 1})
    assert s == 400, f'price do cliente {s} {raw[:160]}'
    s, _, raw = api('POST', '/reservations', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'date': str(D1), 'start_time': '06:00', 'end_time': '07:00', 'status': 'PAID'})
    assert s == 400, f'status PAID {s} {raw[:160]}'
    s, _, raw = api('PUT', f'/reservations/{S["res"]}', T_OWNER, {'price': 1})
    assert s == 400, f'PUT price {s} {raw[:160]}'
    s, _, raw = api('PUT', f'/reservations/{S["res"]}', T_OWNER, {'status': 'PAID'})
    assert s == 400, f'PUT PAID {s} {raw[:160]}'
    assert svc_get('reservations', {'id': f'eq.{S["res"]}', 'select': 'price,status'})[0] == {'price': 22000, 'status': 'CONFIRMED'}


def t05_public_booking_snapshot_not_exposed():
    ip = f'198.{random.randint(18, 19)}.{random.randint(0, 255)}.{random.randint(1, 254)}'
    phone = '11922220000'
    FX.public_reserve(ARENA, phone, ip)
    body = {'slug': SLUG, 'court_id': C4, 'date': str(D1), 'start_time': '17:00', 'end_time': '18:00', 'name': 'Jogador P3A', 'phone': phone,
            'email': None, 'accept_terms': True, 'idempotency_key': f'p3a-{RUN}'}
    s, b, raw = api('POST', '/public/reserve', None, body, {'X-Forwarded-For': ip})
    assert s == 201 and b.get('public_code'), f'reserva pública {s} {raw[:200]}'
    assert 'price' not in raw, 'preço exposto na resposta pública'
    row = svc_get('reservations', {'public_code': f'eq.{b["public_code"]}', 'select': 'price,source'})[0]
    assert row == {'price': 10000, 'source': 'PUBLIC_WEB'}, f'snapshot público: {row}'
    s, lk, raw = api('GET', f'/public/reservation/{b["public_code"]}', None, None, {'X-Forwarded-For': ip})
    FX.lookup(ip)
    assert s == 200 and 'price' not in raw and 'amount' not in raw, f'lookup público com dado financeiro: {raw[:200]}'


# ----------------------------------------------------------------------------- testes: pagamentos
def t06_payments_flow():
    res = S['res']
    s, b, raw = pay(T_REC, res, 5000)
    assert s == 201 and b['idempotent'] is False, f'recepção paga {s} {raw[:200]}'
    S['p1'] = b['payment_id']
    f = fin(T_REC, res)
    assert f['payment_status'] == 'PARTIAL' and f['amount_due'] == 22000 and f['collectible_balance'] == 17000, f
    s, b, raw = pay(T_OWNER, res, 17000, 'CASH')
    assert s == 201, f'{s} {raw[:200]}'
    S['p2'] = b['payment_id']
    assert fin(T_OWNER, res)['payment_status'] == 'PAID'
    s, b, raw = pay(T_OWNER, res, 1)
    assert s == 409 and b.get('code') == 'FINANCE_LIMIT', f'sobrepagamento {s} {raw[:160]}'


def t07_idempotency_api():
    res = svc_reservation(C1, D1 + timedelta(days=7), '10:00', '11:00', price=30000)
    op = str(uuid.uuid4())
    at = now_iso(-30)
    s, b, raw = pay(T_REC, res, 10000, op=op, received_at=at, notes='nota')
    assert s == 201, raw[:200]
    s, b2, raw = pay(T_REC, res, 10000, op=op, received_at=at, notes='nota')
    assert s == 200 and b2['idempotent'] is True and b2['payment_id'] == b['payment_id'], f'replay {s} {raw[:200]}'
    for field, value in [('amount', 10001), ('method', 'CASH'), ('notes', 'outra')]:
        kw = {'op': op, 'received_at': at, 'notes': 'nota', 'method': 'PIX'}
        amount = 10000
        if field == 'amount':
            amount = value
        else:
            kw[field] = value
        s, bb, raw = pay(T_REC, res, amount, **kw)
        assert s == 409 and bb.get('code') == 'IDEMPOTENCY_MISMATCH', f'{field}: {s} {raw[:160]}'
    # replay depois de cancelar a reserva continua devolvendo a operação original
    s, _, raw = api('POST', f'/reservations/{res}/cancel', T_OWNER, {'reason': 'P3A replay'})
    assert s == 200, raw[:160]
    s, b3, raw = pay(T_REC, res, 10000, op=op, received_at=at, notes='nota')
    assert s == 200 and b3['idempotent'] is True, f'replay após cancelamento {s} {raw[:200]}'
    assert fin(T_OWNER, res)['payment_status'] == 'RETAINED'


def t07b_notes_validation():
    """notes de PAYMENT/REFUND: mesma regra de private.rg_fin_notes (trim, vazio => NULL, máx. 500), nunca truncada."""
    res = svc_reservation(new_court(ORG, ARENA, 't07b'), D1, '10:00', '11:00', price=30000)
    s, b, raw = pay(T_REC, res, 100, notes='x' * 500)
    assert s == 201, f'500 caracteres recusados {s} {raw[:160]}'
    p500 = b['payment_id']
    s, b, raw = pay(T_REC, res, 100, notes='   ')
    assert s == 201, f'só espaços {s} {raw[:160]}'
    p_blank = b['payment_id']
    base = 'y' * 500
    for bad in ['x' * 501, base + 'A', base + 'B', 123, {'a': 1}, ['a'], True]:
        s, _, raw = pay(T_REC, res, 100, notes=bad)
        assert s == 400, f'PAYMENT aceitou notes inválida ({type(bad).__name__}) {s} {raw[:160]}'
    # mesmos 500 primeiros caracteres com o MESMO operation_id: nunca vira replay da intenção anterior
    op, at = str(uuid.uuid4()), now_iso(-20)
    s, b1, raw = pay(T_REC, res, 100, op=op, received_at=at, notes=base)
    assert s == 201, raw[:160]
    s, _, raw = pay(T_REC, res, 100, op=op, received_at=at, notes=base + 'diferente')
    assert s == 400, f'prefixo igual tratado como a mesma intenção {s} {raw[:160]}'
    # REFUND usa exatamente a mesma normalização
    for bad in ['z' * 501, base + 'A', 7, ['a']]:
        s, _, raw = refund(T_MGR, p500, 10, notes=bad)
        assert s == 400, f'REFUND aceitou notes inválida ({type(bad).__name__}) {s} {raw[:160]}'
    s, rb, raw = refund(T_MGR, p500, 10, notes='z' * 500)
    assert s == 201, f'REFUND 500 caracteres {s} {raw[:160]}'
    s, rb2, raw = refund(T_MGR, p500, 10, notes='  ')
    assert s == 201, f'REFUND só espaços {s} {raw[:160]}'
    by_id = {e['id']: e for e in fin(T_OWNER, res)['entries']}
    assert by_id[p500]['notes'] == 'x' * 500 and by_id[p_blank]['notes'] is None, 'PAYMENT: notes gravada diferente do enviado'
    assert by_id[b1['payment_id']]['notes'] == base
    assert by_id[rb['payment_id']]['notes'] == 'z' * 500 and by_id[rb2['payment_id']]['notes'] is None, 'REFUND: notes gravada diferente'


def t08_refund_void_permissions():
    s, _, raw = refund(T_REC, S['p2'], 1000)
    assert s == 403, f'recepção estorna {s} {raw[:160]}'
    s, b, raw = refund(T_MGR, S['p2'], 7000, 'CASH')
    assert s == 201, f'{s} {raw[:200]}'
    ref = b['payment_id']
    assert fin(T_MGR, S['res'])['payment_status'] == 'PARTIAL'
    s, _, raw = api('POST', f'/payments/{ref}/void', T_REC, {'reason': 'x'})
    assert s == 403, f'recepção anula {s} {raw[:160]}'
    s, b, raw = api('POST', f'/payments/{S["p2"]}/void', T_MGR, {'reason': 'x'})
    assert s == 409 and b.get('code') == 'FINANCE_STATE', f'void com estorno {s} {raw[:160]}'
    s, _, raw = api('POST', f'/payments/{ref}/void', T_MGR, {'reason': 'lançado por engano'})
    assert s == 200, f'void do estorno {s} {raw[:160]}'
    assert fin(T_MGR, S['res'])['payment_status'] == 'PAID'


def t09_set_price_and_summaries():
    res = S['res']
    s, _, raw = api('PUT', f'/reservations/{res}/price', T_REC, {'mode': 'MANUAL', 'price': 1000, 'reason': 'DISCOUNT'})
    assert s == 403, f'recepção altera valor {s} {raw[:160]}'
    s, b, raw = api('PUT', f'/reservations/{res}/price', T_MGR, {'mode': 'MANUAL', 'price': 20000, 'reason': 'DISCOUNT'})
    assert s == 200 and b['price'] == 20000, f'{s} {raw[:160]}'
    assert fin(T_MGR, res)['payment_status'] == 'OVERPAID'
    s, b, raw = api('PUT', f'/reservations/{res}/price', T_MGR, {'mode': 'RULE', 'price': None, 'reason': 'RULE_RECALC'})
    assert s == 200 and b['price'] == 22000, f'RULE {s} {raw[:160]}'
    s, rows, raw = api('POST', '/reservations/financial-summaries', T_REC, {'reservation_ids': [res]})
    assert s == 200 and len(rows) == 1 and 'payment_status' in rows[0] and 'amount_due' not in rows[0] and 'net_received' not in rows[0], f'recepção: {raw[:200]}'
    s, rows, raw = api('POST', '/reservations/financial-summaries', T_OWNER, {'reservation_ids': [res]})
    assert s == 200 and rows[0]['amount_due'] == 22000, raw[:200]
    s, rows, raw = api('POST', '/reservations/financial-summaries', T_OUT, {'reservation_ids': [res]})
    assert s == 200 and rows == [], f'outra org: {raw[:200]}'


def t10_ledger_rls():
    s, rows, raw = user_rest('GET', 'reservation_payments', T_REC, query=f'?organization_id=eq.{ORG}&select=id,amount')
    assert s == 200 and rows == [], f'recepção lê ledger direto: {raw[:160]}'
    s, rows, raw = user_rest('GET', 'reservation_payments', T_MGR, query=f'?organization_id=eq.{ORG}&select=id,amount')
    assert s == 200 and len(rows) >= 2, f'manager lê ledger: {raw[:160]}'
    s, b, raw = user_rest('GET', 'reservation_payments', T_OWNER, query='?select=operation_fingerprint')
    assert s in (401, 403) and b.get('code') == '42501', f'fingerprint legível: {s} {raw[:160]}'
    s, b, raw = user_rest('PATCH', 'reservation_payments', T_OWNER, {'amount': 1}, f'?id=eq.{S["p1"]}')
    assert s in (401, 403) and b.get('code') == '42501', f'UPDATE direto: {s} {raw[:160]}'


def t11_cancel_retained_refunded():
    res = svc_reservation(C1, D1 + timedelta(days=7), '12:00', '13:00', price=20000)
    s, b, raw = pay(T_OWNER, res, 20000)
    assert s == 201, raw[:200]
    s, _, raw = api('POST', f'/reservations/{res}/cancel', T_REC, {'reason': 'P3A'})
    assert s == 200, raw[:160]
    assert svc_get('reservations', {'id': f'eq.{res}', 'select': 'price'})[0]['price'] == 20000, 'snapshot mudou no cancelamento'
    s, _, raw = refund(T_MGR, b['payment_id'], 15000)
    assert s == 201, raw[:160]
    f = fin(T_REC, res)
    assert f['payment_status'] == 'RETAINED' and f['net_received'] == 5000 and f['collectible_balance'] == 0, f
    s, _, raw = refund(T_MGR, b['payment_id'], 5000)
    assert s == 201, raw[:160]
    assert fin(T_REC, res)['payment_status'] == 'REFUNDED'


# ----------------------------------------------------------------------------- concorrência (R rodadas cada; fixtures exclusivas)
def c01_payments_over_balance():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c01-r{r}'), D1, '10:00', '11:00', price=10000)
        a, b = parallel(lambda: pay(T_REC, res, 6000), lambda: pay(T_OWNER, res, 6000, 'CASH'))
        assert sorted([a[0], b[0]]) == [201, 409], f'{a[:2]} {b[:2]}'
        assert fin(T_OWNER, res)['net_received'] == 6000


def c02_double_click_same_op():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c02-r{r}'), D1, '10:00', '11:00', price=10000)
        op, at = str(uuid.uuid4()), now_iso(-10)
        a, b = parallel(lambda: pay(T_REC, res, 4000, op=op, received_at=at), lambda: pay(T_REC, res, 4000, op=op, received_at=at))
        assert sorted([a[0], b[0]]) == [200, 201], f'{a[:2]} {b[:2]}'
        assert len(svc_get('reservation_payments', {'organization_id': f'eq.{ORG}', 'operation_id': f'eq.{op}', 'select': 'id'})) == 1


def c03_payment_x_cancel():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c03-r{r}'), D1, '10:00', '11:00', price=10000)
        p, c = parallel(lambda: pay(T_REC, res, 10000), lambda: api('POST', f'/reservations/{res}/cancel', T_OWNER, {'reason': 'corrida'}))
        assert c[0] == 200 and p[0] in (201, 409), f'pay {p[:2]} cancel {c[:2]}'
        f = fin(T_OWNER, res)
        assert f['payment_status'] == ('RETAINED' if p[0] == 201 else 'CANCELLED'), f'{p[0]} {f}'


def c04_refund_x_void():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c04-r{r}'), D1, '10:00', '11:00', price=10000)
        s, b, raw = pay(T_OWNER, res, 10000)
        assert s == 201, raw[:160]
        rf, vd = parallel(lambda: refund(T_MGR, b['payment_id'], 3000), lambda: api('POST', f'/payments/{b["payment_id"]}/void', T_OWNER, {'reason': 'corrida'}))
        assert sorted([rf[0], vd[0]]) in ([201, 409], [200, 409]), f'refund {rf[:2]} void {vd[:2]}'
        f = fin(T_OWNER, res)
        assert f['net_received'] == (7000 if rf[0] == 201 else 0), f


def c05_payment_x_set_price():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c05-r{r}'), D1, '10:00', '11:00', price=10000)
        p, sp = parallel(lambda: pay(T_REC, res, 10000), lambda: api('PUT', f'/reservations/{res}/price', T_MGR, {'mode': 'MANUAL', 'price': 5000, 'reason': 'DISCOUNT'}))
        assert sp[0] == 200 and p[0] in (201, 409), f'pay {p[:2]} price {sp[:2]}'
        f = fin(T_OWNER, res)
        assert f['amount_due'] == 5000 and f['payment_status'] == ('OVERPAID' if p[0] == 201 else 'PENDING'), f'{p[0]} {f}'


def c06_refunds_over_payment():
    for r in range(ROUNDS):
        res = svc_reservation(new_court(ORG, ARENA, f'c06-r{r}'), D1, '10:00', '11:00', price=10000)
        s, b, raw = pay(T_OWNER, res, 10000)
        assert s == 201, raw[:160]
        a, c = parallel(lambda: refund(T_MGR, b['payment_id'], 6000), lambda: refund(T_OWNER, b['payment_id'], 6000))
        assert sorted([a[0], c[0]]) == [201, 409], f'{a[:2]} {c[:2]}'
        assert fin(T_OWNER, res)['amount_refunded'] == 6000


def c07_rules_overlap_and_atomic_split():
    for r in range(ROUNDS):
        court = new_court(ORG, ARENA, f'c07-r{r}')
        a, b = parallel(lambda: rule(T_OWNER, court, WD, '08:00', '10:00', 1000), lambda: rule(T_MGR, court, WD, '09:00', '11:00', 2000))
        assert sorted([a[0], b[0]]) == [201, 409], f'sobreposição: {a[:2]} {b[:2]}'
        # faixa split x regra que conflita só com a 2ª metade: nunca sobra meia faixa
        x, y = parallel(lambda: rule(T_OWNER, court, (WD + 2) % 7, '22:00', '02:00', 3000), lambda: rule(T_MGR, court, (WD + 3) % 7, '01:00', '03:00', 4000))
        assert sorted([x[0], y[0]]) == [201, 409], f'split: {x[:2]} {y[:2]}'
        first = svc_get('court_pricing_rules', {'court_id': f'eq.{court}', 'weekday': f'eq.{(WD + 2) % 7}', 'start_minute': 'eq.1320', 'select': 'id'})
        second = svc_get('court_pricing_rules', {'court_id': f'eq.{court}', 'weekday': f'eq.{(WD + 3) % 7}', 'start_minute': 'eq.0', 'select': 'id'})
        assert len(first) == len(second) == (1 if x[0] == 201 else 0), f'meia faixa: {first} {second}'


# ----------------------------------------------------------------------------- GUARDS (ou FOUNDATION) + D7
def g01_guards():
    res = svc_reservation(C1, D1 + timedelta(days=14), '10:00', '11:00', price=10000)
    s, b, raw = user_rest('PATCH', 'reservations', T_OWNER, {'price': 1}, f'?id=eq.{res}')
    if GUARDS:
        assert s in (401, 403) and b.get('code') == '42501', f'PATCH price owner {s} {raw[:160]}'
        s, b, raw = http('PATCH', f'{SB}/rest/v1/reservations?id=eq.{res}', {**SVC, 'Prefer': 'return=representation'}, {'price': 1})
        assert s in (401, 403) and b.get('code') == '42501', f'PATCH price service_role {s} {raw[:160]}'
        s, b, raw = user_rest('PATCH', 'reservations', T_OWNER, {'status': 'PAID'}, f'?id=eq.{res}')
        assert s == 400 and b.get('code') == '23514', f'PATCH PAID {s} {raw[:160]}'
        s, b, raw = user_rest('POST', 'reservations', T_OWNER, {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C1, 'start_at': iso(D1 + timedelta(days=14), '12:00'),
                                                               'end_at': iso(D1 + timedelta(days=14), '13:00'), 'status': 'CONFIRMED', 'source': 'TESTE_P3A', 'price': 1, 'created_by': U_OWNER})
        assert s in (401, 403) and b.get('code') == '42501', f'INSERT com price {s} {raw[:160]}'
    else:
        assert s == 200, f'FOUNDATION: PATCH price ainda permitido {s} {raw[:160]}'
    assert svc_get('reservations', {'id': f'eq.{res}', 'select': 'status'})[0]['status'] == 'CONFIRMED'


def g02_recurring_d7_and_set_price():
    s, b, raw = rpc('rg_recurring_create', {
        'p_operation_id': str(uuid.uuid4()), 'p_arena_id': ARENA, 'p_court_id': C2, 'p_customer_id': None, 'p_customer': {'name': f'Mensalista {RUN}'},
        'p_frequency': 'WEEKLY', 'p_weekday': WD, 'p_day_of_month': None, 'p_start_time': '08:00', 'p_end_time': '09:00',
        'p_start_date': str(TODAY), 'p_end_date': None, 'p_has_no_end_date': True, 'p_default_price': 12345, 'p_notes': None,
        'p_is_demo': True, 'p_skip_conflicts': False, 'p_dates': [str(D1)]}, T_OWNER)
    assert s == 200, f'série {s} {raw[:200]}'
    sid = b['series_id']
    occ = svc_get('reservations', {'recurring_reservation_id': f'eq.{sid}', 'select': 'id,price,customer_id'})[0]
    assert occ['price'] == 12345, f'ocorrência não usa a tabela: {occ}'
    # D7 continua a autoridade do INSERT recorrente forjado (23514), nos dois modos
    forged = {'organization_id': ORG, 'arena_id': ARENA, 'court_id': C2, 'customer_id': occ['customer_id'], 'start_at': iso(D1 + timedelta(days=7), '08:00'),
              'end_at': iso(D1 + timedelta(days=7), '09:00'), 'status': 'CONFIRMED', 'source': 'RECORRENTE', 'notes': None, 'price': 1,
              'recurring_reservation_id': sid, 'occurrence_date': str(D1 + timedelta(days=7)), 'is_exception': False, 'created_by': U_OWNER}
    s, b, raw = user_rest('POST', 'reservations', T_OWNER, forged)
    assert s == 400 and b.get('code') == '23514', f'D7 {s} {raw[:160]}'
    if GUARDS:
        s, b, raw = user_rest('PATCH', 'reservations', T_REC, {'price': 1}, f'?id=eq.{occ["id"]}')
        assert s in (401, 403) and b.get('code') == '42501', f'PATCH price ocorrência {s} {raw[:160]}'
        s, b, raw = user_rest('PATCH', 'reservations', T_OWNER, {'status': 'PAID'}, f'?id=eq.{occ["id"]}')
        assert s == 400 and b.get('code') == '23514', f'PATCH PAID ocorrência {s} {raw[:160]}'
    s, b, raw = api('PUT', f'/reservations/{occ["id"]}/price', T_MGR, {'mode': 'MANUAL', 'price': 15000, 'reason': 'CORRECTION'})
    assert s == 200 and b['price'] == 15000, f'set_price ocorrência {s} {raw[:160]}'
    row = svc_get('reservations', {'id': f'eq.{occ["id"]}', 'select': 'price,is_exception,occurrence_date'})[0]
    assert row == {'price': 15000, 'is_exception': False, 'occurrence_date': str(D1)}, row


# ----------------------------------------------------------------------------- main
exit_code = 1
try:
    print(f'== Fase 03A — financeiro — integração/concorrência — run {RUN} (rounds={ROUNDS}, guards={GUARDS}) ==')
    U_OWNER, T_OWNER = create_user('owner')
    U_MGR, T_MGR = create_user('mgr')
    U_REC, T_REC = create_user('rec')
    U_OUT, T_OUT = create_user('out')
    SLUG = f'p3a-{RUN}'
    ORG, ARENA = create_org('A', [(U_OWNER, 'OWNER'), (U_MGR, 'MANAGER'), (U_REC, 'RECEPTIONIST')], slug=SLUG)
    ORG_OUT, ARENA_OUT = create_org('Outra', [(U_OUT, 'OWNER')])
    C1, C2, C3, C4 = (new_court(ORG, ARENA, n) for n in ('c1', 'c2', 'c3', 'c4'))
    cases = [
        ('T01 regras (1 id) + cotação 22000 / meia-noite 37000 / parcial NULL', t01_rules_and_quote),
        ('T02 faixa 22:00->02:00 atômica (2 linhas, 1 audit; conflito na 2ª metade = nada)', t02_cross_midnight_atomic),
        ('T02b multi-day atômico (4 dias = 4 / 8 regras; conflito intermediário = nada; weekdays inválidos)', t02b_multiday_atomic),
        ('T03 regras: permissões, escrita direta negada, UPDATE sem cruzar meia-noite', t03_rule_permissions),
        ('T04 snapshot interno + sem price/PAID do cliente', t04_internal_snapshot_and_status),
        ('T05 reserva pública recebe snapshot e nunca expõe preço', t05_public_booking_snapshot_not_exposed),
        ('T06 pagamentos: parcial, pago, sobrepagamento', t06_payments_flow),
        ('T07 idempotência (replay, RGP02 por campo, replay após cancelamento)', t07_idempotency_api),
        ('T07b notes: 500 aceita, 501/tipo inválido = 400, espaços = NULL, sem truncar (PAYMENT e REFUND)', t07b_notes_validation),
        ('T08 estorno/anulação e permissões', t08_refund_void_permissions),
        ('T09 set_price (MANUAL/RULE) e resumos por papel', t09_set_price_and_summaries),
        ('T10 ledger: RLS e fingerprint', t10_ledger_rls),
        ('T11 cancelamento: RETAINED -> REFUNDED, snapshot preservado', t11_cancel_retained_refunded),
        ('C01 pagamentos concorrentes acima do saldo', c01_payments_over_balance),
        ('C02 duplo clique com o mesmo operation_id', c02_double_click_same_op),
        ('C03 pagamento x cancelamento', c03_payment_x_cancel),
        ('C04 estorno x anulação', c04_refund_x_void),
        ('C05 pagamento x set_price', c05_payment_x_set_price),
        ('C06 estornos concorrentes acima do pagamento', c06_refunds_over_payment),
        ('C07 regras sobrepostas + faixa split nunca pela metade', c07_rules_overlap_and_atomic_split),
        ('G01 ' + ('GUARDS: price/PAID diretos negados' if GUARDS else 'FOUNDATION: comportamento atual'), g01_guards),
        ('G02 D7 continua autoridade + set_price em ocorrência recorrente', g02_recurring_d7_and_set_price),
    ]
    for name, fn in cases:
        check(name, fn)
    ok = sum(1 for v in results.values() if v == 'PASS')
    print(f'\n== {ok}/{len(results)} PASS (run {RUN}) ==')
    exit_code = 0 if ok == len(results) else 1
finally:
    if FX.cleanup() != 0:
        exit_code = 1
sys.exit(exit_code)
