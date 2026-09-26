"""
Reserva Gol — limpeza verificável de fixtures dos harnesses (created / cleaned / residual).

Uso (em cada harness):
    from harness_cleanup import FixtureTracker
    FX = FixtureTracker(SUPABASE_URL, SUPABASE_SECRET_KEY)
    atexit.register(FX.cleanup)              # garante limpeza mesmo se o setup falhar
    FX.user(uid); FX.org(org_id, 'nome exato criado pelo harness')
    FX.public_reserve(arena_id, phone, ip)   # reserva pública com X-Forwarded-For conhecido
    ...
    residual = FX.cleanup()                  # sempre no finally; residual deve ser 0

Regras:
  * só apaga dados de organizações criadas PELO PRÓPRIO harness nesta execução, e só depois de
    conferir o nome exato no banco; se houver dúvida de ownership, NÃO apaga e conta como resíduo;
  * usa a service key (que já tinha DELETE) na ordem das FKs; não enfraquece o A3;
  * buckets de rate limit (A6): só os pares (scope, key_hash) calculados pelo harness com o mesmo
    HMAC do servidor — por isso as chamadas públicas devem enviar X-Forwarded-For conhecido;
  * usuários efêmeros: removidos pela Admin API.
Apenas biblioteca padrão. Nenhum valor secreto é impresso.
"""
import hashlib
import hmac
import json
import re
import urllib.error
import urllib.parse
import urllib.request

ORG_TABLES = ['reservations', 'recurring_reservations', 'customers', 'business_hours', 'courts', 'arenas', 'audit_logs', 'organization_members']


def clean_br_phone(v):
    """Mesma regra de cleanBrPhone (lib/reserva/public-booking.js)."""
    if not isinstance(v, str) or len(v) > 30:
        return None
    d = re.sub(r'\D', '', v)
    if len(d) in (12, 13) and d.startswith('55'):
        d = d[2:]
    return d if re.fullmatch(r'[1-9]\d{9,10}', d) else None


class FixtureTracker:
    def __init__(self, sb_url, secret):
        self.sb = sb_url.rstrip('/')
        self.headers = {'apikey': secret, 'Authorization': f'Bearer {secret}'}
        self.orgs = {}
        self.users = []
        self.buckets = set()
        self._residual = None
        self._subkey = hmac.new(secret.encode(), b'reservagol-rate-limit-v1', hashlib.sha256).digest()

    # ------------------------------------------------------------------ registro
    def org(self, org_id, expected_name):
        self.orgs[org_id] = expected_name
        return org_id

    def user(self, uid):
        if uid and uid not in self.users:
            self.users.append(uid)
        return uid

    def bucket(self, scope, *parts):
        enc = '|'.join(f'{len(str(p).encode())}:{p}' for p in (scope, *parts))
        self.buckets.add((scope, hmac.new(self._subkey, enc.encode(), hashlib.sha256).hexdigest()))

    def public_reserve(self, arena_id, phone, ip):
        p = clean_br_phone(phone)
        if p:
            self.bucket('public_reserve_phone', arena_id, p)
        if ip:
            self.bucket('public_reserve_ip', arena_id, ip)

    def lookup(self, ip):
        if ip:
            self.bucket('public_reservation_lookup_ip', ip)

    # ------------------------------------------------------------------ http
    def _http(self, method, path, prefer=None):
        h = {**self.headers, **({'Prefer': prefer} if prefer else {})}
        req = urllib.request.Request(f'{self.sb}{path}', headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw, status = r.read().decode(), r.status
        except urllib.error.HTTPError as e:
            raw, status = e.read().decode(), e.code
        try:
            return status, (json.loads(raw) if raw else None)
        except ValueError:
            return status, None

    def _rows(self, table, params):
        s, b = self._http('GET', f'/rest/v1/{table}?{urllib.parse.urlencode(params, doseq=True)}')
        if s != 200 or not isinstance(b, list):
            raise RuntimeError(f'leitura {table}: HTTP {s}')
        return b

    def _count(self, owned):
        counts = {}
        if owned:
            flt = f'in.({",".join(owned)})'
            for t in ORG_TABLES:
                counts[t] = len(self._rows(t, {'organization_id': flt, 'select': 'organization_id'}))
            counts['organizations'] = len(self._rows('organizations', {'id': flt, 'select': 'id'}))
        counts['auth_users'] = sum(1 for u in self.users if self._http('GET', f'/auth/v1/admin/users/{u}')[0] == 200)
        counts['rate_limit_buckets'] = sum(
            len(self._rows('rate_limit_buckets', {'scope': f'eq.{sc}', 'key_hash': f'eq.{h}', 'select': 'scope'})) for sc, h in self.buckets)
        return counts

    # ------------------------------------------------------------------ limpeza
    def cleanup(self):
        """Idempotente: pode ser registrado no atexit (falha no setup) e chamado no fim normal."""
        if self._residual is not None:
            return self._residual
        try:
            self._residual = self._cleanup()
        except Exception as e:  # noqa: BLE001 — nunca mascarar: resíduo desconhecido = falha
            print(f'CLEANUP ERROR {type(e).__name__}: {e}')
            self._residual = -1
        return self._residual

    def _cleanup(self):
        owned, doubtful = [], []
        for oid, name in self.orgs.items():
            rows = self._rows('organizations', {'id': f'eq.{oid}', 'select': 'id,name'})
            if rows and rows[0]['name'] == name:
                owned.append(oid)
            elif rows:
                doubtful.append(oid)
                print(f'CLEANUP: organização {oid} com nome inesperado — NÃO apagada (dúvida de ownership)')
        created = self._count(owned + doubtful)
        if owned:
            flt = f'in.({",".join(owned)})'
            self._http('DELETE', f'/rest/v1/reservations?organization_id={flt}', 'return=minimal')
            for _ in range(50):  # séries: folhas primeiro (previous_series_id é FK RESTRICT)
                rows = self._rows('recurring_reservations', {'organization_id': flt, 'select': 'id,previous_series_id'})
                if not rows:
                    break
                parents = {r['previous_series_id'] for r in rows if r.get('previous_series_id')}
                leaves = [r['id'] for r in rows if r['id'] not in parents]
                self._http('DELETE', f'/rest/v1/recurring_reservations?id=in.({",".join(leaves)})', 'return=minimal')
            for t in ('customers', 'business_hours', 'courts', 'arenas'):
                self._http('DELETE', f'/rest/v1/{t}?organization_id={flt}', 'return=minimal')
            self._http('DELETE', f'/rest/v1/organizations?id={flt}', 'return=minimal')  # membros e audit em cascata
        for sc, h in sorted(self.buckets):
            self._http('DELETE', f'/rest/v1/rate_limit_buckets?scope=eq.{sc}&key_hash=eq.{h}', 'return=minimal')
        for u in self.users:
            self._http('DELETE', f'/auth/v1/admin/users/{u}')
        residual = self._count(owned + doubtful)
        tc, tr = sum(created.values()), sum(residual.values())
        print(f'\nCLEANUP created={tc} cleaned={tc - tr} residual={tr}')
        print(f'  created por tabela: {created}')
        print(f'  residual por tabela: {residual}')
        return tr
