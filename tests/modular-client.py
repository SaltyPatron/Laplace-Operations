"""Verify installed client input selection without inheriting a developer shell."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('client', ROOT / 'installation/client.py')
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ClientInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        release = self.root / 'installed/releases/one'
        (release / 'bin').mkdir(parents=True)
        (release / ('bin/laplace.exe' if os.name == 'nt' else 'bin/laplace')).touch()
        (release / 'package.json').write_text(json.dumps({
            'schema': 'laplace.modular-package/v1', 'revisions': {}}))
        host = dict(schema='laplace.modular-installation/v1', host=socket.gethostname(),
                    prefix=str(release.parents[1]), release=str(release),
                    socket=socket.gethostname(), port=5432, database='selected', threads=2, batch_mb=64)
        host.update({key: str(release / key) for key in ('tier0', 'flags', 'highway', 'grammars', 'ucd')})
        installation = self.root / 'installation.json'
        installation.write_text(json.dumps(host))
        data = self.root / 'data'
        data.mkdir()
        self.profile = dict(schema='laplace.modular-client/v1', installation=str(installation),
                            role='operator', work=str(self.root / 'work'), data=str(data),
                            source=str(self.root / 'source estate'), models=str(self.root / 'absent models'),
                            connection={'sslmode': 'verify-full'})
        self.configuration = self.root / 'client.json'

    def select(self):
        self.configuration.write_text(json.dumps(self.profile))
        return client.selected(self.configuration)

    def test_declared_inputs_survive_a_conflicting_developer_environment(self):
        with patch.dict(os.environ, {'LAPLACE_SRC': 'wrong source', 'LAPLACE_MODELS': 'wrong models',
                                     'LAPLACE_CONNINFO': 'wrong database'}):
            _, environment, where = self.select()
            child = client.process_environment(environment)
        self.assertEqual(child['LAPLACE_SRC'], self.profile['source'])
        self.assertEqual(child['LAPLACE_MODELS'], self.profile['models'])
        self.assertIn("dbname='selected'", child['LAPLACE_CONNINFO'])
        self.assertEqual(where['inputs'], {key: self.profile[key] for key in ('source', 'models')})

    def test_an_absent_local_model_estate_does_not_break_other_sources(self):
        self.assertFalse(Path(self.profile['models']).exists())
        _, environment, _ = self.select()
        self.assertEqual(environment['LAPLACE_MODELS'], self.profile['models'])

    def test_undeclared_inputs_are_not_taken_from_the_shell(self):
        del self.profile['source'], self.profile['models']
        with patch.dict(os.environ, {'LAPLACE_SRC': 'wrong', 'LAPLACE_MODELS': 'wrong'}):
            _, environment, _ = self.select()
            child = client.process_environment(environment)
        self.assertNotIn('LAPLACE_SRC', child)
        self.assertNotIn('LAPLACE_MODELS', child)

    def test_relative_and_ambiguous_input_roots_are_rejected(self):
        for value in ('relative/path', str(self.root / '..' / 'escape'), str(self.root) + '\nextra'):
            with self.subTest(value=value):
                self.profile['source'] = value
                with self.assertRaisesRegex(ValueError, 'input root must be absolute'):
                    self.select()

    def test_package_caches_do_not_depend_on_build_sidecars(self):
        spec = importlib.util.spec_from_file_location('package', ROOT / 'installation/package-windows-client.py')
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        source, destination = self.root / 'prepared', self.root / 'packaged'
        source.mkdir()
        for name in ('tier0.bin', 'tier0.flags', 'tier0.highway', 'tier0.highway.nodes'):
            (source / name).write_bytes(name.encode())
        package.copy_prepared(source, destination)
        self.assertEqual({p.name for p in destination.iterdir()}, {'tier0.bin', 'tier0.flags', 'tier0.highway'})
        for file in destination.iterdir():
            self.assertEqual(file.read_bytes(), (source / file.name).read_bytes())


if __name__ == '__main__':
    unittest.main()
