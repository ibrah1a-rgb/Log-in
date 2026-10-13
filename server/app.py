"""Single-shop WSGI API. Local development server; deploy behind HTTPS and a WSGI server."""
import argparse
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from http import HTTPStatus
from pathlib import Path

DB_PATH = os.environ.get('SHOP_DB', 'shop.sqlite3')
ITERATIONS = 600_000
SESSION_SECONDS = 12 * 3600


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


@contextmanager
def db():
    connection = sqlite3.connect(DB_PATH, timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA foreign_keys=ON')
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def init_db():
    with db() as c:
        c.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users (
          id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
          password TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('admin','employee')));
        CREATE TABLE IF NOT EXISTS sessions (
          digest TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS shifts (
          id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), started REAL NOT NULL, ended REAL);
        CREATE UNIQUE INDEX IF NOT EXISTS one_open_shift ON shifts(user_id) WHERE ended IS NULL;
        CREATE TABLE IF NOT EXISTS records (
          id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), shift_id TEXT REFERENCES shifts(id),
          date REAL NOT NULL, kind TEXT NOT NULL, product TEXT NOT NULL DEFAULT '',
          quantity INTEGER NOT NULL DEFAULT 0, halalas INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS requests (
          user_id TEXT NOT NULL REFERENCES users(id), request_id TEXT NOT NULL,
          PRIMARY KEY(user_id, request_id));
        CREATE TABLE IF NOT EXISTS attempts (key TEXT NOT NULL, stamp REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS attempt_lookup ON attempts(key, stamp);
        ''')


def password_hash(password, salt=None):
    salt = salt or secrets.token_hex(16)
    derived = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), ITERATIONS)
    return salt + ':' + derived.hex()


def verify_password(password, saved):
    return hmac.compare_digest(password_hash(password, saved.split(':')[0]), saved)


def clean_user(data):
    username = data.get('username', '')
    name = data.get('name', '')
    password = data.get('password', '')
    if not all(isinstance(x, str) for x in (username, name, password)):
        raise APIError(400, 'بيانات الحساب غير صالحة.')
    username, name = username.strip().lower(), name.strip()
    if not re.fullmatch(r'[a-z0-9._-]{3,40}', username):
        raise APIError(400, 'اسم المستخدم من 3 إلى 40 حرفًا إنجليزيًا أو رقمًا أو . أو _ أو -')
    if not 1 <= len(name) <= 80 or not 12 <= len(password) <= 128:
        raise APIError(400, 'أدخل الاسم وكلمة مرور من 12 إلى 128 حرفًا.')
    return username, name, password


def add_user(c, data, role='employee'):
    username, name, password = clean_user(data)
    identifier = str(uuid.uuid4())
    try:
        c.execute('INSERT INTO users VALUES (?,?,?,?,?)',
                  (identifier, username, name, password_hash(password), role))
    except sqlite3.IntegrityError:
        raise APIError(409, 'اسم المستخدم مستخدم مسبقًا.')
    return identifier


def public_user(row):
    return {key: row[key] for key in ('id', 'username', 'name', 'role')}


def state(c, user):
    shift = c.execute('SELECT started FROM shifts WHERE user_id=? AND ended IS NULL', (user['id'],)).fetchone()
    sql = '''SELECT r.*,u.name AS employee FROM records r JOIN users u ON u.id=r.user_id'''
    params = ()
    if user['role'] != 'admin':
        sql += ' WHERE user_id=?'
        params = (user['id'],)
    rows = c.execute(sql + ' ORDER BY date DESC LIMIT 500', params).fetchall()
    entries = [{k: row[k] for k in ('id', 'date', 'employee', 'kind', 'product', 'quantity', 'halalas')} for row in rows]
    return {'employee': user['name'], 'started': shift['started'] if shift else None, 'entries': entries}


def record(c, user, shift, kind, product='', quantity=0, halalas=0):
    c.execute('INSERT INTO records VALUES (?,?,?,?,?,?,?,?)',
              (str(uuid.uuid4()), user['id'], shift, time.time(), kind, product, quantity, halalas))


def login(data, ip):
    username, password = data.get('username', ''), data.get('password', '')
    if not isinstance(username, str) or not isinstance(password, str) or len(username) > 80 or len(password) > 128:
        raise APIError(400, 'بيانات الدخول غير صالحة.')
    username = username.strip().lower()
    now = time.time()
    keys = ('user:' + username, 'ip:' + ip)
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('DELETE FROM attempts WHERE stamp<?', (now - 900,))
        for key, limit in zip(keys, (8, 40)):
            if c.execute('SELECT COUNT(*) FROM attempts WHERE key=?', (key,)).fetchone()[0] >= limit:
                raise APIError(429, 'محاولات كثيرة. انتظر 15 دقيقة ثم حاول مجددًا.')
        c.executemany('INSERT INTO attempts VALUES (?,?)', [(key, now) for key in keys])
        row = c.execute('SELECT * FROM users WHERE username=?', (username,)).fetchone()
    # Same expensive password calculation for an unknown account; attempts persist on failure.
    saved = row['password'] if row else ('00' * 16 + ':' + '00' * 32)
    valid = verify_password(password, saved)
    if not row or not valid:
        raise APIError(401, 'اسم المستخدم أو كلمة المرور غير صحيحة.')
    token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(token.encode()).hexdigest()
    with db() as c:
        c.execute('DELETE FROM sessions WHERE expires<?', (now,))
        c.execute('INSERT INTO sessions VALUES (?,?,?)', (digest, row['id'], now + SESSION_SECONDS))
        c.execute('DELETE FROM attempts WHERE key=?', (keys[0],))
    return {'token': token, 'user': public_user(row)}


def route(method, path, data, auth, ip):
    if method == 'GET' and path == '/health':
        return {'ok': True}
    if method == 'POST' and path == '/v1/login':
        return login(data, ip)
    if not auth.startswith('Bearer ') or len(auth) > 200:
        raise APIError(401, 'سجّل الدخول أولًا.')
    digest = hashlib.sha256(auth[7:].encode()).hexdigest()
    with db() as c:
        if method == 'POST':
            c.execute('BEGIN IMMEDIATE')
        user = c.execute('''SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id
                            WHERE s.digest=? AND s.expires>?''', (digest, time.time())).fetchone()
        if not user:
            raise APIError(401, 'انتهت الجلسة. سجّل الدخول مرة ثانية.')
        if method == 'GET' and path == '/v1/me':
            return {'user': public_user(user), 'state': state(c, user)}
        if method == 'POST' and path == '/v1/logout':
            c.execute('DELETE FROM sessions WHERE digest=?', (digest,))
            return {'ok': True}
        if path == '/v1/employees':
            if user['role'] != 'admin':
                raise APIError(403, 'هذه العملية للمدير فقط.')
            if method == 'POST':
                # The client can never grant administrator privileges.
                if 'role' in data:
                    raise APIError(400, 'إنشاء حسابات الموظفين فقط متاح من التطبيق.')
                add_user(c, data)
            elif method != 'GET':
                raise APIError(405, 'طريقة غير مسموحة.')
            return {'employees': [public_user(r) for r in c.execute("SELECT * FROM users WHERE role='employee' ORDER BY name")]}
        if method == 'POST' and path in ('/v1/check-in', '/v1/check-out', '/v1/sales'):
            if user['role'] != 'employee':
                raise APIError(403, 'هذا الإجراء مخصص لحساب موظف.')
            request_id = data.get('requestID', '')
            if not isinstance(request_id, str) or not re.fullmatch(r'[a-zA-Z0-9-]{16,80}', request_id):
                raise APIError(400, 'معرّف الطلب غير صالح.')
            if c.execute('SELECT 1 FROM requests WHERE user_id=? AND request_id=?', (user['id'], request_id)).fetchone():
                return {'state': state(c, user)}
            shift = c.execute('SELECT id FROM shifts WHERE user_id=? AND ended IS NULL', (user['id'],)).fetchone()
            if path == '/v1/check-in':
                if not shift:
                    shift_id = str(uuid.uuid4())
                    c.execute('INSERT INTO shifts VALUES (?,?,?,NULL)', (shift_id, user['id'], time.time()))
                    record(c, user, shift_id, 'حضور')
            elif path == '/v1/check-out':
                if shift:
                    c.execute('UPDATE shifts SET ended=? WHERE id=?', (time.time(), shift['id']))
                    record(c, user, shift['id'], 'انصراف')
            else:
                if not shift:
                    raise APIError(409, 'سجّل حضورك قبل إضافة المبيعات.')
                if data.get('none') is True:
                    record(c, user, shift['id'], 'ما بعت شي')
                else:
                    product, qty, amount = data.get('product'), data.get('quantity'), data.get('halalas')
                    if not isinstance(product, str) or not 1 <= len(product.strip()) <= 200 or type(qty) is not int or not 1 <= qty <= 100000 or type(amount) is not int or not 1 <= amount <= 1_000_000_000:
                        raise APIError(400, 'بيانات البيع غير صالحة.')
                    record(c, user, shift['id'], 'بيع', product.strip(), qty, amount)
            c.execute('INSERT INTO requests VALUES (?,?)', (user['id'], request_id))
            return {'state': state(c, user)}
        raise APIError(404, 'الطلب غير موجود.')


def application(environ, start_response):
    status = 200
    try:
        length = int(environ.get('CONTENT_LENGTH') or 0)
        if not 0 <= length <= 16384:
            raise APIError(413, 'الطلب أكبر من الحد المسموح.')
        data = json.loads(environ['wsgi.input'].read(length)) if length else {}
        if not isinstance(data, dict):
            raise APIError(400, 'الطلب غير صالح.')
        result = route(environ['REQUEST_METHOD'], environ['PATH_INFO'], data,
                       environ.get('HTTP_AUTHORIZATION', ''), environ.get('REMOTE_ADDR', 'local'))
    except APIError as error:
        status, result = error.status, {'error': error.message}
    except (ValueError, UnicodeError):
        status, result = 400, {'error': 'الطلب غير صالح.'}
    except Exception:
        # Never return credentials, SQL, or tracebacks to the caller.
        status, result = 500, {'error': 'تعذر إكمال العملية. حاول مجددًا.'}
    body = json.dumps(result, ensure_ascii=False).encode()
    start_response(f'{status} {HTTPStatus(status).phrase}', [
        ('Content-Type', 'application/json; charset=utf-8'), ('Content-Length', str(len(body))),
        ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')])
    return [body]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['init-admin', 'serve', 'init-db'])
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    init_db()
    if args.command == 'init-admin':
        data = {'username': input('Admin username: '), 'name': input('Display name: '),
                'password': getpass.getpass('Password (12+ characters): ')}
        if data['password'] != getpass.getpass('Confirm password: '):
            raise SystemExit('Passwords do not match.')
        with db() as c:
            if c.execute("SELECT 1 FROM users WHERE role='admin'").fetchone():
                raise SystemExit('Administrator already exists; no account was changed.')
            add_user(c, data, 'admin')
        print('Administrator created. No password is stored in source code.')
    elif args.command == 'serve':
        from wsgiref.simple_server import make_server
        print(f'LOCAL DEVELOPMENT ONLY: http://127.0.0.1:{args.port}')
        with make_server('127.0.0.1', args.port, application) as server:
            server.serve_forever()


if __name__ == '__main__':
    main()
