"""Failure boundaries for runtime setup. No installed services or databases are changed."""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'installation/runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
CONFIG = json.loads((ROOT / 'installation/hart-server-runtime.json').read_text())


class RuntimeBoundaries(unittest.TestCase):
    def test_manifest_selection_honors_explicit_process_and_machine_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            installed, process, explicit = (root / name for name in ('installed manifest.json', 'process.json', 'explicit.json'))
            for path in (installed, process, explicit):
                path.write_text('{}')
            machine = root / 'machine.env'
            machine.write_text('LAPLACE_RUNTIME_MANIFEST=' + str(installed) + '\n')
            with patch.dict(os.environ, {'LAPLACE_MACHINE_ENV': str(machine)}, clear=True):
                self.assertEqual(runtime.selected_manifest(), installed)
                with patch.dict(os.environ, {'LAPLACE_RUNTIME_MANIFEST': str(process)}):
                    self.assertEqual(runtime.selected_manifest(), process)
                    self.assertEqual(runtime.selected_manifest(explicit), explicit)
                machine.write_text('LAPLACE_RUNTIME_MANIFEST=/missing/declared-runtime.json\n')
                with self.assertRaisesRegex(ValueError, 'Missing declared'):
                    runtime.selected_manifest()
                machine.write_text('LAPLACE_RUNTIME_MANIFEST=relative.json\n')
                with self.assertRaisesRegex(ValueError, 'absolute path'):
                    runtime.selected_manifest()
                machine.write_text('')
                with patch.object(runtime.socket, 'gethostname', return_value='hart-server'):
                    self.assertEqual(runtime.selected_manifest(), ROOT / 'installation/hart-server-runtime.json')
                with patch.object(runtime.socket, 'gethostname', return_value='not-a-declared-host'):
                    self.assertIsNone(runtime.selected_manifest())

    def test_application_connection_cannot_request_another_cluster(self):
        current = {'LAPLACE_INSTALL_PREFIX': CONFIG['prefix'], 'LAPLACE_PGDATA': CONFIG['database_data'],
                   'LAPLACE_PG_DIR': str(Path(CONFIG['pgbin']).parent), 'LAPLACE_ROLE': CONFIG['database_owner']}
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, 'declarations', return_value=current), \
             patch.object(runtime.socket, 'gethostname', return_value=CONFIG['host']), patch.object(runtime, 'checked') as command:
            runtime.validate_declaration(CONFIG)
            for key, value in {'LAPLACE_APP_DBNAME': 'another-db', 'LAPLACE_APP_PGDATA': '/another/cluster',
                               'LAPLACE_APP_PGPORT': '5433', 'LAPLACE_APP_PGHOST': 'remote-host'}.items():
                with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                    with self.assertRaisesRegex(ValueError, 'differs from runtime declaration'):
                        runtime.validate_declaration(CONFIG)
            command.assert_not_called()

    def test_command_diagnostics_do_not_leak_into_public_exception(self):
        with self.assertRaises(runtime.CommandFailure) as failure:
            runtime.checked([sys.executable, '-c', "import sys; print('sensitive diagnostic',file=sys.stderr); sys.exit(1)"])
        self.assertNotIn('sensitive diagnostic', str(failure.exception))
        self.assertIn('sensitive diagnostic', failure.exception.diagnostics)

    def test_certificate_identity_key_and_renewal_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key, certificate = root / 'server.key', root / 'server.crt'
            runtime.TLS.command(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(key)])
            policy = copy.deepcopy(CONFIG['tls'])
            runtime.TLS.generate(certificate, key, policy)
            self.assertTrue(runtime.TLS.desired(certificate, key, policy))
            policy['ip_addresses'] = ['127.0.0.2']
            self.assertFalse(runtime.TLS.desired(certificate, key, policy))
            policy = copy.deepcopy(CONFIG['tls'])
            policy['renew_before_days'] = policy['valid_days'] + 1
            self.assertFalse(runtime.TLS.desired(certificate, key, policy))

    def test_wrong_host_never_runs_commands(self):
        with patch.object(runtime.socket, 'gethostname', return_value='another-host'), patch.object(runtime, 'checked') as run:
            with self.assertRaisesRegex(ValueError, 'another host'):
                runtime.preflight(CONFIG)
            run.assert_not_called()

    def test_invalid_privilege_and_path_declarations(self):
        for change in ('role', 'pool', 'state', 'user'):
            config = copy.deepcopy(CONFIG)
            if change == 'role':
                config['knowledge']['role'] = config['database_owner']
            elif change == 'pool':
                config['mcp']['pool_max'] = config['mcp']['connection_limit'] + 1
            elif change == 'state':
                config['mcp']['state'] = config['state']
            else:
                config['mcp']['user'] = 'root'
            with self.subTest(change=change), self.assertRaises(ValueError):
                runtime.validate(config)

    def test_existing_bao_selection_is_preserved_and_conflict_refused(self):
        bao = runtime.Bao.__new__(runtime.Bao)
        selectors = {'database_host': '127.0.0.1', 'database': 'app', 'role': 'runtime', 'port': 5432}
        record = dict(selectors, password='a' * 64)
        with patch.object(bao, 'call', return_value=json.dumps({'data': {'data': record}})) as call:
            self.assertEqual(bao.record('hosts/example/application', selectors), record)
            self.assertEqual(call.call_count, 1)
            with self.assertRaisesRegex(ValueError, 'different installation'):
                bao.record('hosts/example/application', dict(selectors, database='other'))
            self.assertTrue(all(c.args[0][:2] == ['kv', 'get'] for c in call.call_args_list))

    def test_failed_activation_restores_files_and_removes_only_new_dropin(self):
        with tempfile.TemporaryDirectory() as temporary:
            existing, created = Path(temporary) / 'api.env', Path(temporary) / 'dropin.conf'
            existing.write_text('original\n')
            existing.chmod(0o640)
            recovered = []
            with self.assertRaisesRegex(RuntimeError, 'injected readiness failure'):
                with runtime.SYNC.configuration_transaction([existing, created], lambda: recovered.append(existing.read_text())):
                    existing.write_text('changed\n')
                    created.write_text('new service identity\n')
                    raise RuntimeError('injected readiness failure')
            self.assertEqual(recovered, ['original\n'])
            self.assertEqual(existing.stat().st_mode & 0o777, 0o640)
            self.assertFalse(created.exists())

    def test_nested_helper_reuses_host_lock_without_releasing_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock_path = Path(temporary) / 'host.lock'
            with lock_path.open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                config = {'database': 'fixture', 'role': 'runtime', 'admin_role': 'owner',
                          'password': 'a' * 64, 'client_address': '127.0.0.1', 'lock': str(lock_path),
                          'psql': '/no-executable', 'admin_socket': temporary, 'port': 5432}
                env = dict(os.environ, LAPLACE_HOST_LOCK_FD=str(lock.fileno()))
                command = [sys.executable, str(ROOT / 'secrets/knowledge-role.py')]
                result = subprocess.run(command, input=json.dumps(config), text=True, capture_output=True,
                                        env=env, pass_fds=(lock.fileno(),), timeout=10)
                # It passed the nested lock, reaching the deliberately missing SQL executable.
                self.assertIn('FileNotFoundError', result.stderr)
                self.assertNotIn('BlockingIOError', result.stderr)
                with lock_path.open('a') as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                other = Path(temporary) / 'other.lock'
                other.touch()
                config['lock'] = str(other)
                result = subprocess.run(command, input=json.dumps(config), text=True, capture_output=True,
                                        env=env, pass_fds=(lock.fileno(),), timeout=10)
                self.assertIn('different installation', result.stderr)
                self.assertNotIn('FileNotFoundError', result.stderr)


if __name__ == '__main__':
    unittest.main()
