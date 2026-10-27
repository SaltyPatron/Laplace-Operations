"""Verify installed client input selection without inheriting a developer shell."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import hashlib
import tempfile
import unittest
from types import SimpleNamespace
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
        for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway', 'tier0.highway.nodes'):
            (source / name).write_bytes(name.encode())
        package.copy_prepared(source, destination)
        self.assertEqual({p.name for p in destination.iterdir()}, {'tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway'})
        for file in destination.iterdir():
            self.assertEqual(file.read_bytes(), (source / file.name).read_bytes())

    def test_mcp_installation_requires_initialization_discovery_and_successful_tool(self):
        executable, environment, _ = self.select()
        executable.with_name('lpm.exe' if os.name == 'nt' else 'lpm').touch()
        replies = [
            {'id': 1, 'result': {'serverInfo': {'name': 'laplace'}}},
            {'id': 2, 'result': {'tools': [{'name': name} for name in ('text', 'ingest_status', 'recipe_plan')]}},
            {'id': 3, 'result': {'content': [{'type': 'text', 'text': 'real composition'}]}},
        ]
        def response(values):
            return SimpleNamespace(returncode=0, stderr='', stdout='\n'.join(json.dumps(value) for value in values))
        with patch.object(client.subprocess, 'run', return_value=response(replies)) as invoke:
            self.assertEqual(client.verify_mcp(executable, environment)['text'], 'passed')
            request = [json.loads(line) for line in invoke.call_args.kwargs['input'].splitlines()]
            self.assertEqual(request[-1]['params'], {'name': 'text', 'arguments': {'input': 'Laplace'}})
        for invalid in (replies[:2], [*replies[:2], {'id': 3, 'result': {'isError': True, 'content': [{'type': 'text', 'text': 'failed'}]}}],
                        [*replies[:2], {'id': 3, 'result': {'content': [{'type': 'text', 'text': ''}]}}]):
            with self.subTest(invalid=invalid), patch.object(client.subprocess, 'run', return_value=response(invalid)):
                with self.assertRaisesRegex(ValueError, 'Installed modular MCP'):
                    client.verify_mcp(executable, environment)


class PackageReuse(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        spec = importlib.util.spec_from_file_location('package', ROOT / 'installation/package-windows-client.py')
        self.package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.package)
        self.config = {key: str(self.root / key) for key in
                       ('prefix', 'state', 'ucd', 'build', 'engine', 'prepared', 'grammars', 'mkl_runtime')}
        self.config.update(schema='laplace.modular-installation/v1', host='test', socket='test', port=5432,
                           database='test', threads=2, batch_mb=64, installed_config=str(self.root / 'installed.json'),
                           runtime_directories=[str(self.root / 'runtime')], mkl_runtime_libraries=['mkl_*.dll'])
        self.sources = {
            'bin/laplace.exe': self.root / 'build/laplace.exe',
            'bin/mkl_test.dll': self.root / 'mkl_runtime/mkl_test.dll',
            'bin/dependency.dll': self.root / 'runtime/dependency.dll',
            'share/recipes/order': self.root / 'engine/recipes/order',
            'share/firmware/program.firmware': self.root / 'engine/firmware/program.firmware',
            'share/grammars/test.dll': self.root / 'grammars/test.dll',
            **{'share/prepared/' + name: self.root / 'prepared' / name
               for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway')},
        }
        for key, source in self.sources.items():
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(key.encode())
        package = {'schema': 'laplace.modular-package/v1', 'revisions': {'Laplace-Engine': 'revision'},
                   'files': {key: self.package.digest(source) for key, source in self.sources.items()}}
        identity = hashlib.sha256(json.dumps(package, sort_keys=True).encode()).hexdigest()
        self.release = self.root / 'prefix/releases' / identity
        for key, source in self.sources.items():
            target = self.release / key
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        (self.release / 'package.json').write_text(json.dumps(package))
        Path(self.config['installed_config']).write_text(json.dumps({**self.config, 'release': str(self.release)}))
        self.revisions = package['revisions']

    def test_unchanged_release_is_reused_without_writing_it(self):
        timestamps = {path: path.stat().st_mtime_ns for path in self.release.rglob('*') if path.is_file()}
        for _ in range(2):
            self.assertEqual(self.package.reusable_release(self.config, self.revisions), self.release.resolve())
        self.assertEqual({path: path.stat().st_mtime_ns for path in timestamps}, timestamps)

    def test_changed_inputs_and_corrupted_outputs_are_not_reused(self):
        for relative, source in self.sources.items():
            with self.subTest(input=relative):
                data = source.read_bytes()
                source.write_bytes(data + b'changed')
                self.assertIsNone(self.package.reusable_release(self.config, self.revisions))
                source.write_bytes(data)
            with self.subTest(output=relative):
                target = self.release / relative
                target.write_bytes(data + b'corrupted')
                self.assertIsNone(self.package.reusable_release(self.config, self.revisions))
                target.write_bytes(data)

    def test_new_and_removed_resources_invalidate_the_release(self):
        new = self.root / 'engine/recipes/new.recipe'
        new.write_text('new')
        self.assertIsNone(self.package.reusable_release(self.config, self.revisions))
        new.unlink()
        (self.root / 'grammars/test.dll').unlink()
        self.assertIsNone(self.package.reusable_release(self.config, self.revisions))

    def test_revision_and_installation_changes_invalidate_the_release(self):
        self.assertIsNone(self.package.reusable_release(self.config, {'Laplace-Engine': 'new'}))
        self.config['database'] = 'another'
        self.assertIsNone(self.package.reusable_release(self.config, self.revisions))


if __name__ == '__main__':
    unittest.main()
