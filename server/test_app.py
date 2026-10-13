import io
import json
import tempfile
import time
import unittest
import uuid
from pathlib import Path
import app


class APITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        app.DB_PATH = str(Path(self.temp.name) / 'test.sqlite3')
        app.init_db()
        self.password = 'Test-only-password-2026!'
        with app.db() as c:
            app.add_user(c, {'username': 'manager', 'name': 'Manager', 'password': self.password}, 'admin')
        self.admin = self.sign_in('manager')
        for name in ['employee-one', 'employee-two']:
            status, _ = self.call('/v1/employees', {'username': name, 'name': name, 'password': self.password}, self.admin)
            self.assertEqual(status, 200)
        self.one = self.sign_in('employee-one')
        self.two = self.sign_in('employee-two')

    def tearDown(self):
        self.temp.cleanup()

    def call(self, path, body=None, token=None, method=None):
        payload = json.dumps(body).encode() if body is not None else b''
        captured = []
        result = app.application({'REQUEST_METHOD': method or ('POST' if body is not None else 'GET'),
            'PATH_INFO': path, 'CONTENT_LENGTH': str(len(payload)), 'wsgi.input': io.BytesIO(payload),
            'HTTP_AUTHORIZATION': 'Bearer ' + token if token else '', 'REMOTE_ADDR': '127.0.0.1'},
            lambda status, headers: captured.append((status, headers)))
        return int(captured[0][0].split()[0]), json.loads(b''.join(result))

    def sign_in(self, username):
        status, data = self.call('/v1/login', {'username': username, 'password': self.password})
        self.assertEqual(status, 200)
        return data['token']

    def action(self, path, token, **fields):
        return self.call(path, {'requestID': str(uuid.uuid4()), **fields}, token)

    def test_roles_and_no_self_registration(self):
        self.assertEqual(self.call('/v1/employees', {}, self.one)[0], 403)
        self.assertEqual(self.call('/v1/employees', {}, None)[0], 401)
        self.assertEqual(self.call('/v1/employees', {'username': 'attacker', 'name': 'A',
            'password': self.password, 'role': 'admin'}, self.admin)[0], 400)
        self.assertEqual(self.action('/v1/check-in', self.admin)[0], 403)

    def test_password_and_token_are_not_stored_in_plaintext(self):
        with app.db() as c:
            password = c.execute("SELECT password FROM users WHERE username='manager'").fetchone()[0]
            tokens = [x[0] for x in c.execute('SELECT digest FROM sessions')]
        self.assertNotEqual(password, self.password)
        self.assertNotIn(self.admin, tokens)
        self.assertTrue(app.verify_password(self.password, password))

    def test_employee_isolation_and_manager_visibility(self):
        self.action('/v1/check-in', self.one)
        self.action('/v1/sales', self.one, product='خاتم', quantity=2, halalas=1250)
        _, other = self.call('/v1/me', token=self.two)
        _, manager = self.call('/v1/me', token=self.admin)
        self.assertEqual(other['state']['entries'], [])
        self.assertEqual(len(manager['state']['entries']), 2)
        self.assertEqual(manager['state']['entries'][0]['halalas'], 1250)

    def test_sales_require_active_shift_and_positive_integers(self):
        fields = {'product': 'Ring', 'quantity': 2, 'halalas': 1250}
        self.assertEqual(self.action('/v1/sales', self.one, **fields)[0], 409)
        self.action('/v1/check-in', self.one)
        for changes in [{'quantity': 0}, {'quantity': True}, {'halalas': -1}, {'halalas': 12.5}, {'product': ' '}]:
            self.assertEqual(self.action('/v1/sales', self.one, **(fields | changes))[0], 400)
        self.assertEqual(self.action('/v1/sales', self.one, **fields)[0], 200)
        self.action('/v1/check-out', self.one)
        self.assertEqual(self.action('/v1/sales', self.one, **fields)[0], 409)

    def test_retry_does_not_duplicate_and_server_controls_identity_and_time(self):
        self.action('/v1/check-in', self.one)
        self.action('/v1/check-in', self.one)
        payload = {'requestID': str(uuid.uuid4()), 'product': 'Ring', 'quantity': 1, 'halalas': 2500,
                   'employee': 'Forged manager', 'date': 1}
        first = self.call('/v1/sales', payload, self.one)
        second = self.call('/v1/sales', payload, self.one)
        self.assertEqual(first[0], 200)
        self.assertEqual(first, second)
        records = second[1]['state']['entries']
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]['employee'], 'employee-one')
        self.assertGreater(records[0]['date'], time.time() - 60)

    def test_session_revocation_and_expiration(self):
        self.assertEqual(self.call('/v1/logout', {}, self.one)[0], 200)
        self.assertEqual(self.call('/v1/me', token=self.one)[0], 401)
        with app.db() as c:
            c.execute('UPDATE sessions SET expires=0')
        self.assertEqual(self.call('/v1/me', token=self.two)[0], 401)

    def test_login_rate_limit_and_generic_errors(self):
        with app.db() as c:
            c.execute('DELETE FROM attempts')
        for _ in range(8):
            status, response = self.call('/v1/login', {'username': 'missing', 'password': 'wrong'})
            self.assertEqual(status, 401)
            self.assertEqual(response['error'], 'اسم المستخدم أو كلمة المرور غير صحيحة.')
        self.assertEqual(self.call('/v1/login', {'username': 'missing', 'password': 'wrong'})[0], 429)


if __name__ == '__main__':
    unittest.main()
