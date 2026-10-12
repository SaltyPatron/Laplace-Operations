"""Exercise the real selector's Tier-0 preflight without credentials or a live DB."""
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("substrate_sync", ROOT / "secrets/database-sync.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SubstrateCompatibility(unittest.TestCase):
    def exercise_refresh(self, *, prior=False, application_failure=False, activation_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            credentials = root / 'approle.json'
            credentials.write_text('{}')
            credentials.chmod(0o600)
            substrate = dict(database_host='substrate', database='substrate_db', role='reader', port=5432, password='a' * 64)
            application = dict(database_host='127.0.0.1', database='application', role='runtime', port=5432, password='b' * 64)
            expected = 'substrate:5432:substrate_db:reader:' + substrate['password'] + '\n127.0.0.1:5432:application:runtime:' + application['password'] + '\n'
            pgpass = root / '.pgpass'
            original = expected if prior else 'previous:5432:application:runtime:old\n'
            pgpass.write_text(original)
            pgpass.chmod(0o600)
            requests, activations = [], []
            def request(req, **kwargs):
                path = req.full_url.split('/v1/', 1)[1]
                requests.append(path)
                if path == 'auth/approle/login': body = {'auth': {'client_token': 'test-token'}}
                elif path.endswith('/substrate'): body = {'data': {'data': substrate}}
                elif path.endswith('/application-runtime'): body = {'data': {'data': application}}
                else: body = {}
                return io.BytesIO(json.dumps(body).encode())
            def run(arguments, **kwargs):
                self.assertEqual(pgpass.read_text(), original, 'Credential publication occurred before all authentication checks')
                role = arguments[arguments.index('-U') + 1]
                failed = application_failure and role == 'runtime'
                return subprocess.CompletedProcess(arguments, int(failed), role + ('|receipt' if role == 'reader' else '') + '\n', '')
            def activate(*args):
                activations.append(pgpass.read_text())
                if activation_failure and len(activations) == 1:
                    raise RuntimeError('new credential activation failed')
            argv = ['database-sync', '--host', 'consumer', '--credentials', str(credentials), '--user', 'runtime',
                    '--prefix', str(root), '--machine-file', str(root / 'machine.env'), '--lock', str(root / 'lock'),
                    '--bao-address', 'https://bao.invalid', '--application-record', 'application-runtime',
                    '--restart-on-change', '--verification-base', 'https://api.invalid']
            account = SimpleNamespace(pw_dir=str(root), pw_uid=os.getuid(), pw_gid=os.getgid())
            with patch.object(sys, 'argv', argv), patch.object(selector.pwd, 'getpwnam', return_value=account), \
                    patch.object(selector.urllib.request, 'urlopen', side_effect=request), \
                    patch.object(selector.subprocess, 'run', side_effect=run), patch.object(selector, 'activate', side_effect=activate), \
                    patch.object(sys, 'stdout', io.StringIO()):
                if application_failure:
                    with self.assertRaisesRegex(ValueError, 'not published'): selector.main()
                elif activation_failure:
                    with self.assertRaisesRegex(RuntimeError, 'activation failed'): selector.main()
                else:
                    selector.main()
            self.assertEqual(requests[-1], 'auth/token/revoke-self')
            self.assertEqual(pgpass.stat().st_mode & 0o777, 0o600)
            if application_failure:
                self.assertEqual(pgpass.read_text(), original)
                self.assertEqual(activations, [])
            elif activation_failure:
                self.assertEqual(pgpass.read_text(), original)
                self.assertEqual(activations, [original + expected, original])
            else:
                self.assertEqual(pgpass.read_text(), expected if prior else original + expected)
                self.assertEqual(len(activations), 0 if prior else 1)

    def test_both_logins_authenticate_before_credentials_are_published(self):
        self.exercise_refresh()

    def test_application_authentication_failure_preserves_previous_credentials(self):
        self.exercise_refresh(application_failure=True)

    def test_unchanged_credentials_do_not_restart_the_api(self):
        self.exercise_refresh(prior=True)

    def test_failed_refresh_restores_credentials_before_recovering_service(self):
        self.exercise_refresh(activation_failure=True)

    def test_failed_activation_restores_all_configuration_before_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('machine.env', 'api.env', 'pgpass')]
            for path in paths[:2]:
                path.write_text('ORIGINAL=value\n')
                path.chmod(0o600)
            observed = []
            def recover():
                observed.append([p.read_text() if p.exists() else None for p in paths])
            with self.assertRaisesRegex(RuntimeError, 'activation failed'):
                with selector.configuration_transaction(paths, recover):
                    for path in paths:
                        path.write_text('CANDIDATE=value\n')
                    raise RuntimeError('activation failed')
            self.assertEqual(observed, [['ORIGINAL=value\n', 'ORIGINAL=value\n', None]])
            for path in paths[:2]:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_successful_activation_keeps_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'machine.env'
            path.write_text('before')
            with selector.configuration_transaction([path], lambda: self.fail('unexpected recovery')):
                path.write_text('after')
            self.assertEqual(path.read_text(), 'after')

    def test_selection_uses_identity_not_substrate_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "app").mkdir()
            artifact = root / "tier zero.bin"
            receipt = bytes(range(16))
            artifact.write_bytes(struct.pack("<II", 0x4652504C, 4) + bytes(120) + receipt)
            config = root / "app/laplace-api.env"
            for value in (str(artifact), '"' + str(artifact) + '"'):
                config.write_text("LAPLACE_PERFCACHE_BIN=" + value + "\n")
                before = config.read_bytes(), artifact.read_bytes()
                self.assertEqual(selector.validate_substrate_receipt(root, receipt.hex()), receipt.hex())
                with self.assertRaisesRegex(ValueError, "incompatible"):
                    selector.validate_substrate_receipt(root, "ff" * 16)
                self.assertEqual(before, (config.read_bytes(), artifact.read_bytes()))
            artifact.write_bytes(struct.pack("<II", 0x4652504C, 999) + bytes(120) + receipt)
            with self.assertRaisesRegex(ValueError, "Unsupported"):
                selector.validate_substrate_receipt(root, receipt.hex())


if __name__ == "__main__":
    unittest.main()
