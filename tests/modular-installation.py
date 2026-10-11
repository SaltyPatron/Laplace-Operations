"""Exercise installation declarations, SQL scope and failed release activation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('modular', ROOT / 'installation/modular.py')
modular = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modular)


class Installation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.value = json.loads((ROOT / 'installation/hart-server-modular.json').read_text())
        self.value['host'] = modular.socket.gethostname().lower()

    def load(self):
        path = self.directory / 'host.json'
        path.write_text(json.dumps(self.value))
        return modular.config_load(path)

    def test_alternate_paths_and_independent_identities(self):
        for key in ('source', 'build', 'state', 'prefix'):
            self.value[key] = str(self.directory / ('alternate ' + key))
        config = self.load()
        environment = modular.runtime_environment(config, Path(config['prefix']) / 'current')
        self.assertIn(config['prefix'] + '/current/bin/laplace', environment)
        self.assertIn('LAPLACE_WORK="' + config['state'] + '"', environment)
        self.assertNotIn('/repos/build/Laplace-Engine', environment)
        self.assertNotIn('/home/ahart', environment)

    def test_invalid_declarations_cannot_reach_mutation(self):
        for key, value in (('runtime_user', 'root'), ('runtime_user', 'ahart'),
                           ('role', 'x; ALTER ROLE laplace SUPERUSER'), ('bind', '0.0.0.0'),
                           ('http_port', 65536), ('source', '/tmp/../etc'), ('build', self.value['prefix']),
                           ('threads', 0), ('host', 'wrong-host')):
            with self.subTest(key=key, value=value):
                original = self.value[key]
                self.value[key] = value
                with self.assertRaises(ValueError):
                    self.load()
                self.value[key] = original

    def test_failed_activation_restores_previous_release(self):
        config = self.load()
        config['prefix'] = str(self.directory / 'installation')
        prefix = Path(config['prefix'])
        old, new = prefix / 'releases/old', prefix / 'releases/new'
        old.mkdir(parents=True)
        new.mkdir()
        current = prefix / 'current'
        current.symlink_to(old)
        config['restart_signal'] = str(self.directory / 'restart')
        observed_switch = []

        def command(args, **kwargs):
            if 'InvocationID' in args and '-p' in args and 'ActiveState' not in args:
                return subprocess.CompletedProcess(args, 0, stdout='previous\n')
            observed_switch.append(current.resolve())
            raise RuntimeError('injected activation failure')

        with patch.object(modular, 'checked', side_effect=command), patch.object(modular.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(RuntimeError, 'injected'):
                modular.activate(config, new, self.directory, False)
        self.assertEqual(observed_switch, [new])
        self.assertEqual(current.resolve(), old)
        self.assertTrue(Path(config['restart_signal']).exists())

    def test_configuration_rejects_linked_destinations(self):
        elsewhere = self.directory / 'elsewhere'
        elsewhere.mkdir()
        link = self.directory / 'linked'
        link.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked'):
            modular.atomic(link / 'configuration', 'bad')
        self.assertFalse((elsewhere / 'configuration').exists())


if __name__ == '__main__':
    unittest.main()
