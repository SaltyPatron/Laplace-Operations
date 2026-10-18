"""Refusal and recovery boundaries for the privileged host repair entrypoint."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('repair', ROOT / 'installation/repair.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairBoundaries(unittest.TestCase):
    def test_declaration_idempotence_and_conflict_preservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'machine.env'
            path.write_text('LAPLACE_WORK=/existing/work\nEXISTING_OPTION=keep\n')
            proposed = repair.machine_text(path, {'LAPLACE_WORK': '/existing/work', 'LAPLACE_BUILD': '/existing/build'})
            self.assertIn('EXISTING_OPTION=keep', proposed)
            path.write_text(proposed)
            self.assertEqual(proposed, repair.machine_text(path, {'LAPLACE_WORK': '/existing/work', 'LAPLACE_BUILD': '/existing/build'}))
            with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
                repair.machine_text(path, {'LAPLACE_WORK': '/different/work'})
            self.assertEqual(proposed, path.read_text())

    def test_corrupt_landed_backup_never_connects_to_postgres(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'hart-prod-laplace-app-test.dump'
            archive.write_bytes(b'corrupt archive')
            Path(str(archive) + '.sha256').write_text('0' * 64 + '  ' + archive.name)
            config = {'machine': {}, 'backup': {'landing': temporary, 'source_database': 'laplace-app'}}
            with patch.object(repair, 'checked') as command:
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    repair.restore_landing(config)
                command.assert_not_called()

    def test_restore_failure_removes_only_created_scratch_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = json.loads((ROOT / 'installation/hart-server.json').read_text())
            config['backup']['landing'] = temporary
            archive = Path(temporary) / 'hart-prod-laplace-app-test.dump'
            archive.write_bytes(b'dump placeholder')
            Path(str(archive) + '.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest())
            statements = []

            def run(argv, **kwargs):
                if any('pg_restore' in str(arg) for arg in argv):
                    raise RuntimeError('injected restore failure')
                statement = kwargs['input']
                statements.append(statement)
                return '/data/pgdata' if statement == 'SHOW data_directory' else ''

            with patch.object(repair, 'checked', run):
                with self.assertRaisesRegex(RuntimeError, 'injected restore failure'):
                    repair.restore_landing(config)
            created = next(s.split('"')[1] for s in statements if s.startswith('CREATE DATABASE'))
            self.assertRegex(created, '^laplace_repair_[0-9a-f]{32}$')
            self.assertIn(f'DROP DATABASE "{created}" WITH (FORCE);', statements)

    def test_vaultwarden_extracts_database_without_extracting_other_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'vaultwarden').mkdir()
            db = root / 'source.db'
            with sqlite3.connect(db) as connection:
                connection.execute('CREATE TABLE proof (id INTEGER)')
            archive = root / 'vaultwarden/vw-fixture.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(db, arcname='./db.sqlite3')
                bad = tarfile.TarInfo('../escape')
                bad.size = 3
                tar.addfile(bad, io.BytesIO(b'bad'))
            result = repair.restore_vaultwarden(root)
            self.assertEqual(result['sqlite_integrity'], 'ok')
            self.assertEqual(result['tables'], 1)
            self.assertFalse((root / 'escape').exists())

    def test_repair_converges_a_declared_modular_listener_credential(self):
        modular = Mock()
        modular.select_manifest.return_value = Path('/declared/hart-server-modular.json')
        modular.config_load.return_value = {'environment_file': '/etc/laplace/modular.env'}
        modular.converge_listener_credential.return_value = Path('/etc/laplace/secrets/modular-mcp.env')
        with patch.object(repair, 'load_module', return_value=modular):
            result = repair.converge_modular_listener()
        modular.install_credential_helper.assert_called_once_with(modular.config_load.return_value)
        modular.converge_listener_credential.assert_called_once_with(modular.config_load.return_value)
        self.assertEqual(result, {'state': 'converged', 'token_file': '/etc/laplace/secrets/modular-mcp.env'})
        self.assertNotIn('LAPLACE_MCP_TOKEN=', json.dumps(result))

    def test_repair_records_when_no_modular_runtime_is_declared(self):
        modular = Mock()
        modular.select_manifest.return_value = None
        with patch.object(repair, 'load_module', return_value=modular):
            result = repair.converge_modular_listener()
        self.assertEqual(result, {'state': 'no modular runtime declared'})
        modular.install_credential_helper.assert_not_called()
        modular.converge_listener_credential.assert_not_called()


unittest.main()
