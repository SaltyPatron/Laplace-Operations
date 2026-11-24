"""Verify installed client input selection without inheriting a developer shell."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import hashlib
import tempfile
import unittest
import sys
import uuid
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / 'installation') not in sys.path:
    sys.path.insert(0, str(ROOT / 'installation'))
spec = importlib.util.spec_from_file_location('client', ROOT / 'installation/client.py')
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
deploy_spec = importlib.util.spec_from_file_location('deploy_client', ROOT / 'installation/deploy-client.py')
deploy_client = importlib.util.module_from_spec(deploy_spec)
with patch.dict(sys.modules, {'client': client}):
    deploy_spec.loader.exec_module(deploy_client)

install_spec = importlib.util.spec_from_file_location('install_client', ROOT / 'installation/install-client.py')
installer = importlib.util.module_from_spec(install_spec)
install_spec.loader.exec_module(installer)

# `laplace status` as it reads when the database's caches are this Engine's: tier 0, highway and the chess perf-cache.
AGREES = ("\ndatabase   laplace, 53 MB\nextension  laplace 0123456789abcdef; cpu: avx2\n"
          "tier 0     /release/share/prepared/tier0.bin\n           ece5\n           the same as this engine's\n"
          "highway    /release/share/prepared/tier0.highway\n           1841\n           the same as this engine's\n"
          "chess      /release/share/prepared/tier0.chess\n           6940\n           the same as this engine's\n")


class StatusAgreement(unittest.TestCase):
    def test_every_matching_cache_agrees_however_many_there_are(self):
        self.assertTrue(client.artifacts_agree(AGREES))
        without_chess = AGREES.split('chess ')[0] + "chess      (the extension's default)\n           (not generated: laplace chess)\n"
        self.assertTrue(client.artifacts_agree(without_chess))

    def test_a_cache_that_differs_or_is_missing_does_not_agree(self):
        self.assertFalse(client.artifacts_agree(AGREES.replace(
            "6940\n           the same as this engine's",
            "6940\n           DIFFERS from this engine's chess perf-cache: the two hold other positions or another vocabulary")))
        self.assertFalse(client.artifacts_agree(AGREES.replace(
            "1841\n           the same as this engine's", "(not generated: laplace highway)")))
        self.assertFalse(client.artifacts_agree("the same as this engine's\nthe same as this engine's\n"))


class InstallationReadback(unittest.TestCase):
    def test_host_preparation_precedes_mandatory_compatibility_readback(self):
        def run(arguments, **kwargs):
            return SimpleNamespace(returncode=0, stderr='', stdout=AGREES)
        with patch.object(client.subprocess, 'run', side_effect=run) as execute:
            client.verify_engine(Path('laplace'), {}, configure_database=True, database_host=socket.gethostname())
        self.assertEqual([call.args[0][1:] for call in execute.call_args_list],
                         [['deploy', '--configure-server-cache'], ['text', 'Laplace'], ['status'], ['sources']])

    def test_ordinary_client_installation_does_not_mutate_server_selection(self):
        result = SimpleNamespace(returncode=0, stderr='', stdout=AGREES)
        with patch.object(client.subprocess, 'run', return_value=result) as execute:
            client.verify_engine(Path('laplace'), {})
        self.assertEqual([call.args[0][1:] for call in execute.call_args_list],
                         [['text', 'Laplace'], ['status'], ['sources']])

    def test_failed_host_preparation_stops_before_readback(self):
        with patch.object(client.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stderr='prepare refused')) as execute:
            with self.assertRaisesRegex(ValueError, 'deploy failed: prepare refused'):
                client.verify_engine(Path('laplace'), {}, configure_database=True, database_host=socket.gethostname())
        self.assertEqual(execute.call_count, 1)


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

    def test_windows_candidate_prepares_local_database_before_compatibility_readback(self):
        spec = importlib.util.spec_from_file_location('package', ROOT / 'installation/package-windows-client.py')
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        self.select()
        selected = False
        def engine(arguments, **kwargs):
            nonlocal selected
            operation = arguments[1:]
            if operation == ['deploy', '--configure-server-cache']:
                selected = True
            if operation == ['status'] and not selected:
                return SimpleNamespace(returncode=0, stderr='', stdout='old database fingerprint')
            return SimpleNamespace(returncode=0, stderr='', stdout=AGREES)
        with patch.dict(sys.modules, {'client': client}), patch.dict(os.environ, {'SystemRoot': str(self.root)}), \
             patch.object(client.subprocess, 'run', side_effect=engine):
            with self.assertRaisesRegex(ValueError, 'must match both Engine artifact fingerprints'):
                package.verify_candidate(self.configuration)
            self.assertFalse(selected)
            package.verify_candidate(self.configuration, configure_database=True)
            self.assertTrue(selected)

    def test_windows_candidate_cannot_configure_a_remote_database(self):
        spec = importlib.util.spec_from_file_location('package', ROOT / 'installation/package-windows-client.py')
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        self.select()
        installation = Path(self.profile['installation'])
        host = json.loads(installation.read_text())
        host['socket'] = 'another-database-host'
        installation.write_text(json.dumps(host))
        with patch.dict(sys.modules, {'client': client}), patch.dict(os.environ, {'SystemRoot': str(self.root)}), \
             patch.object(client.subprocess, 'run') as execute:
            with self.assertRaisesRegex(ValueError, 'Only a host-local deployment'):
                package.verify_candidate(self.configuration, configure_database=True)
            execute.assert_not_called()

    @unittest.skipIf(os.name == 'nt', 'POSIX release bootstrap and lifetime lease')
    def test_installed_bootstrap_uses_the_packaged_client_and_pins_code_and_native_selection(self):
        spec = importlib.util.spec_from_file_location('install_client', ROOT / 'installation/install-client.py')
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        self.select()
        installation = Path(self.profile['installation'])
        host = json.loads(installation.read_text())
        old = Path(host.pop('release'))
        new = old.with_name('two')
        current = Path(host['prefix']) / 'current'
        current.symlink_to(old)
        installation.write_text(json.dumps(host))
        native = ('#!' + sys.executable + '\nimport fcntl,json,os,pathlib\n'
                  'root=pathlib.Path(os.environ["LAPLACE_TIER0"]).parents[2]\n'
                  'with (root/".runtime-lease").open() as lease:\n'
                  '    try: fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB); held=False\n'
                  '    except BlockingIOError: held=True\n'
                  'print(json.dumps({"release":str(root),"lease_held":held}))\n')
        for release in (old, new):
            (release / 'bin').mkdir(exist_ok=True, parents=True)
            (release / 'bin/laplace').write_text(native)
            (release / 'bin/laplace').chmod(0o755)
            (release / 'libexec').mkdir()
            (release / '.runtime-lease').touch()
            (release / 'package.json').write_text(json.dumps({'schema': 'laplace.modular-package/v1', 'revisions': {}}))
            controller = (ROOT / 'installation/client.py').read_text()
            if release == old:
                controller += ('\nselected_run=run_client\ndef run_client(configuration,release=None):\n'
                               '    current=Path(' + repr(str(current)) + ')\n'
                               '    current.unlink(); current.symlink_to(' + repr(str(new)) + ')\n'
                               '    selected_run(configuration,release)\n')
            (release / 'libexec/laplace-client.py').write_text(controller)
        bootstrap = self.root / 'laplace'
        bootstrap.write_text(installer.linux_launcher(self.configuration))
        for expected in (old, new):
            result = subprocess.run([sys.executable, str(bootstrap), 'status'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            readback = json.loads(result.stdout)
            self.assertEqual(readback, {'release': str(expected), 'lease_held': True})

    def deployment(self):
        executable, environment, _ = self.select()
        for path in (environment['LAPLACE_TIER0'], environment['LAPLACE_FLAGS'],
                     environment['LAPLACE_FLAGS']+'.layout', environment['LAPLACE_HIGHWAY']):
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_bytes(b'prepared')
        psql = self.root / 'psql.exe'
        psql.touch()
        return executable, environment, psql

    def test_recreate_uses_selected_client_and_stops_after_drop_failure(self):
        executable, environment, psql = self.deployment()
        with patch.object(deploy_client.subprocess, 'run', side_effect=deploy_client.subprocess.CalledProcessError(1, 'drop')) as run:
            with self.assertRaises(deploy_client.subprocess.CalledProcessError):
                deploy_client.deploy(self.configuration, psql, drop=True)
        self.assertEqual(run.call_count, 1)
        self.assertTrue(run.call_args.args[0][4].endswith(" dbname='postgres'"))
        self.assertIn('laplace_database=selected', run.call_args.args[0])
        # A requested recreate of a greenfield database ends the sessions holding it (an orphaned sweep, a
        # client that died) rather than failing on them.
        self.assertIn('WITH (FORCE)', run.call_args.kwargs['input'])

    def test_installed_migration_does_not_drop_or_build(self):
        executable, environment, psql = self.deployment()
        with patch.object(deploy_client.subprocess, 'run') as run:
            deploy_client.deploy(self.configuration, psql)
        # The installed deployment, then the web reader's grants through the declared client: no drop, no build.
        self.assertEqual(run.call_count, 2)
        migration, grants = run.call_args_list
        self.assertEqual(migration.args[0], [str(executable), 'deploy', '--configure-server-cache'])
        self.assertEqual(migration.kwargs['env']['LAPLACE_CONNINFO'], environment['LAPLACE_CONNINFO'])
        self.assertEqual(grants.args[0][:4], [str(psql), '-X', '-w', '-d'])
        self.assertEqual(grants.args[0][4], environment['LAPLACE_CONNINFO'])
        self.assertEqual(grants.args[0][-2:], ['-qf', '-'])
        self.assertIn('laplace_modular_web', grants.kwargs['input'])
        self.assertNotIn('DROP', grants.kwargs['input'])

    def test_recreate_refuses_missing_artifacts_before_database_calls(self):
        executable, environment, psql = self.deployment()
        for path in (environment['LAPLACE_TIER0'], environment['LAPLACE_FLAGS'],
                     environment['LAPLACE_FLAGS']+'.layout', environment['LAPLACE_HIGHWAY']):
            Path(path).unlink()
            with patch.object(deploy_client.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'Missing installed deployment artifact'):
                    deploy_client.deploy(self.configuration, psql, drop=True)
                run.assert_not_called()
            Path(path).write_bytes(b'prepared')

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

    def test_code_search_configuration_survives_client_isolation(self):
        search = {'LAPLACE_CODE_SOURCE': 'Laplace Workspace',
                  'LAPLACE_CODE_HUB': '2048',
                  'LAPLACE_CODE_NODES': '200000',
                  'LAPLACE_CODE_BRIDGE': '1',
                  'LAPLACE_CODE_INGEST': 'workspace-code'}
        with patch.dict(os.environ, {**search, 'LAPLACE_CONNINFO': 'wrong database',
                                     'LAPLACE_ENGINE': 'wrong engine'}):
            executable, environment, _ = self.select()
            child = client.process_environment(environment)
        self.assertEqual({key: child.get(key) for key in search}, search)
        self.assertIn("dbname='selected'", child['LAPLACE_CONNINFO'])
        self.assertEqual(child['LAPLACE_ENGINE'], str(executable))

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
        for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway', 'tier0.chess', 'tier0.highway.nodes'):
            (source / name).write_bytes(name.encode())
        package.copy_prepared(source, destination)
        self.assertEqual({p.name for p in destination.iterdir()},
                         {'tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway', 'tier0.chess'})
        for file in destination.iterdir():
            self.assertEqual(file.read_bytes(), (source / file.name).read_bytes())

    def test_mcp_installation_requires_composition_and_selected_database_readback(self):
        executable, environment, _ = self.select()
        executable.with_name('lpm.exe' if os.name == 'nt' else 'lpm').touch()
        replies = [
            {'id': 1, 'result': {'serverInfo': {'name': 'laplace'}}},
            {'id': 2, 'result': {'tools': [{'name': name} for name in ('text', 'ingest_status', 'recipe_plan')]}},
            {'id': 3, 'result': {'content': [{'type': 'text', 'text': 'real composition'}]}},
            {'id': 4, 'result': {'content': [{'type': 'text', 'text': json.dumps({
                'database': 'selected', 'sources': [], 'activity': []})}]}},
        ]
        def response(values):
            return SimpleNamespace(returncode=0, stderr='', stdout='\n'.join(json.dumps(value) for value in values))
        with patch.object(client.subprocess, 'run', return_value=response(replies)) as invoke:
            checked = client.verify_mcp(executable, environment, database='selected')
            self.assertEqual(checked['text'], 'passed')
            self.assertEqual(checked['database_readback'], 'passed')
            request = [json.loads(line) for line in invoke.call_args.kwargs['input'].splitlines()]
            self.assertEqual(request[-2]['params'], {'name': 'text', 'arguments': {'input': 'Laplace'}})
            self.assertEqual(request[-1]['params']['name'], 'ingest_status')
        for invalid in (replies[:3],
                        [*replies[:2], {'id': 3, 'result': {'isError': True}}, replies[3]],
                        [*replies[:2], {'id': 3, 'result': {'content': [{'type': 'text', 'text': ''}]}}, replies[3]],
                        [*replies[:3], {'id': 4, 'error': {'code': -32603, 'message': 'SQL failed'}}],
                        [*replies[:3], {'id': 4, 'result': {'isError': True}}]):
            with self.subTest(invalid=invalid), patch.object(client.subprocess, 'run', return_value=response(invalid)):
                with self.assertRaisesRegex(ValueError, 'Installed modular MCP'):
                    client.verify_mcp(executable, environment, database='selected')
        for value in ({'database': 'another', 'sources': [], 'activity': []},
                      {'database': 'selected', 'error': 'missing witness relation', 'sources': [], 'activity': []},
                      {'database': 'selected', 'sources': []}, [], 'not JSON'):
            payload = value if value == 'not JSON' else json.dumps(value)
            invalid = [*replies[:3], {'id': 4, 'result': {'content': [{'type': 'text', 'text': payload}]}}]
            with self.subTest(readback=value), patch.object(client.subprocess, 'run', return_value=response(invalid)):
                with self.assertRaisesRegex(ValueError, 'Installed modular MCP'):
                    client.verify_mcp(executable, environment, database='selected')


class PackageReuse(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        spec = importlib.util.spec_from_file_location('package', ROOT / 'installation/package-windows-client.py')
        self.package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.package)
        self.config = {key: str(self.root / key) for key in
                       ('prefix', 'state', 'ucd', 'build', 'engine', 'native', 'prepared', 'grammars', 'mkl_runtime')}
        self.config.update(schema='laplace.modular-installation/v1', host='test', socket='test', port=5432,
                           database='test', threads=2, batch_mb=64, installed_config=str(self.root / 'installed.json'),
                           runtime_directories=[str(self.root / 'runtime')], mkl_runtime_libraries=['mkl_*.dll'])
        self.sources = {
            'bin/laplace.exe': self.root / 'build/laplace.exe',
            'bin/mkl_test.dll': self.root / 'mkl_runtime/mkl_test.dll',
            'bin/dependency.dll': self.root / 'runtime/dependency.dll',
            'share/recipes/order': self.root / 'engine/recipes/order',
            'share/firmware/program.firmware': self.root / 'engine/firmware/program.firmware',
            'share/manifest/banks.tsv': self.root / 'native/manifest/banks.tsv',
            'share/grammars/test.dll': self.root / 'grammars/test.dll',
            **{'share/prepared/' + name: self.root / 'prepared' / name
               for name in ('tier0.bin', 'tier0.flags', 'tier0.flags.layout', 'tier0.highway', 'tier0.chess')},
        }
        for key, source in self.sources.items():
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(key.encode())
        package = {'schema': 'laplace.modular-package/v1', 'revisions': {'Laplace-Engine': 'revision'}, 'frozen_manifest_verified': True, 'recipe_sources': 'runtime-v1',
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

    def test_mcp_package_builds_and_selects_one_shared_graph_without_a_legacy_engine_tree(self):
        config = dict(self.config, mcp=str(self.root / 'mcp-source'), mcp_build=str(self.root / 'shared-build'),
                      build=str(self.root / 'absent-legacy-engine-build'))
        package = self.root / 'packages/laplace-native/revision/lib/cmake/LaplaceNative'
        engine = self.root / 'packages/laplace-engine/revision'
        with patch.object(self.package, 'build_run') as build, \
             patch.object(self.package, 'native_package', return_value=package) as native, \
             patch.object(self.package, 'engine_package', return_value=engine):
            self.package.prepare_runtime(config)
            binaries = self.package.runtime_binaries(config)
        native.assert_called_with(config)
        commands = [[str(value) for value in call.args[0]] for call in build.call_args_list]
        self.assertEqual(len(commands), 2)
        self.assertIn('-DLaplaceNative_DIR=' + package.as_posix(), commands[0])
        self.assertIn('-DLaplaceEngine_DIR=' + (engine / 'lib/cmake/LaplaceEngine').as_posix(), commands[0])
        self.assertFalse(any('BUNDLE' in value or 'ENGINE_SRC' in value for value in commands[0]))
        self.assertEqual(commands[1][-2:], ['lpm_program', 'lpm_lib'])
        self.assertFalse(any(config['build'] in command for command in commands))
        self.assertEqual(binaries['bin/laplace.exe'], engine / 'bin/laplace.exe')

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

    def test_packaging_shares_identical_bytes_without_linking_mutable_build_outputs(self):
        source = self.root / 'build-output.dll'
        source.write_bytes(b'first build')
        self.package.STORE = self.root / 'artifacts'
        one, two = self.root / 'first/runtime.dll', self.root / 'second/runtime.dll'
        self.package.stage_file(source, one)
        self.package.stage_file(source, two)
        self.assertTrue(os.path.samefile(one, two))
        self.assertFalse(os.path.samefile(source, one))
        source.write_bytes(b'next build')
        self.assertEqual(one.read_bytes(), b'first build')
        self.assertEqual(two.read_bytes(), b'first build')

    def test_runtime_grammar_snapshot_keeps_external_code_and_the_selected_engine_parser(self):
        prepared, compiled = self.root / 'prepared-grammars', self.root / 'compiled-grammars'
        prepared.mkdir()
        compiled.mkdir()
        (prepared / 'libtree-sitter-c.so').write_bytes(b'prepared C parser')
        (prepared / 'libtree-sitter-pgn.so').write_bytes(b'another product PGN parser')
        (compiled / 'libtree-sitter-pgn.so').write_bytes(b'selected Engine PGN parser')
        target = self.root / 'runtime/grammars'
        store = self.package.artifacts
        result = store.snapshot_grammars(prepared, compiled, target)
        self.assertEqual(result['grammars'], 2)
        self.assertEqual((target / 'libtree-sitter-pgn.so').read_bytes(), b'selected Engine PGN parser')
        (compiled / 'libtree-sitter-pgn.so').write_bytes(b'later Engine parser')
        (prepared / 'libtree-sitter-c.so').write_bytes(b'later C parser')
        self.assertEqual((target / 'libtree-sitter-pgn.so').read_bytes(), b'selected Engine PGN parser')
        self.assertEqual((target / 'libtree-sitter-c.so').read_bytes(), b'prepared C parser')
        with self.assertRaisesRegex(ValueError, 'new absolute'):
            store.snapshot_grammars(prepared, compiled, target)

    def test_foreign_database_reader_is_refused_before_any_acl_write(self):
        config={**self.config, 'socket': 'another-host', 'database_artifact_reader': 'S-1-5-20'}
        with patch.object(self.package, 'run') as invoke, self.assertRaisesRegex(ValueError, 'local database host'):
            self.package.ensure_release_access(config, self.release, 'S-1-5-21-1-2-3-1001')
        invoke.assert_not_called()

    @unittest.skipUnless(os.name == 'nt', 'NTFS access-control acceptance')
    def test_database_reader_survives_another_publishers_hardlink_acl(self):
        sid=self.package.run(['pwsh', '-NoProfile', '-Command', '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'])
        config={**self.config, 'socket': socket.gethostname(), 'database_artifact_reader': 'S-1-5-20'}
        cache=self.release / 'share/prepared/tier0.bin'
        original=cache.read_bytes()
        other=self.root / 'another-publisher.bin'
        os.link(cache, other)
        self.package.ensure_release_access(config, self.release, sid)
        # Another path to the same inode re-evaluates its parent inheritance.
        self.package.run(['icacls.exe', str(other), '/inheritance:r'])
        path=str(cache).replace("'", "''")
        explicit=self.package.run(['pwsh', '-NoProfile', '-Command',
            f"@((Get-Acl -LiteralPath '{path}').GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]) | "
            "Where-Object {$_.IdentityReference.Value -eq 'S-1-5-20' -and $_.AccessControlType -eq 'Allow' -and ([int]$_.FileSystemRights -band 1)}).Count"])
        self.assertGreater(int(explicit), 0)
        self.assertEqual(cache.read_bytes(), original)
        self.package.ensure_release_access(config, self.release, sid)
        self.assertTrue(os.path.samefile(cache, other))


def installed_database_proof(configuration, psql, work):
    """Exercise the installed owner against one disposable real database."""
    import subprocess
    original = json.loads(Path(configuration).read_text())
    host = json.loads(Path(original['installation']).read_text())
    database = 'laplace_deploy_test_' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix='installed-deploy-', dir=work) as directory:
        root = Path(directory)
        host['database'] = database
        (root / 'installation.json').write_text(json.dumps(host))
        original.update(installation=str(root / 'installation.json'), work=str(root / 'work'))
        candidate = root / 'client.json'
        candidate.write_text(json.dumps(original))
        _, environment, _ = client.selected(candidate)
        env = client.process_environment(environment)
        maintenance = environment['LAPLACE_CONNINFO'] + " dbname='postgres'"
        def query(sql):
            return subprocess.check_output([str(psql), '-X', '-w', '-d', environment['LAPLACE_CONNINFO'],
                                            '-Atq', '-v', 'ON_ERROR_STOP=1', '-c', sql], env=env, text=True).strip()
        try:
            deploy_client.deploy(candidate, psql)
            query('CREATE TABLE public.deployment_probe (value integer)')
            before = query('SELECT oid FROM pg_database WHERE datname=current_database()')
            deploy_client.deploy(candidate, psql, drop=True)
            after = query('SELECT oid FROM pg_database WHERE datname=current_database()')
            if before == after or query("SELECT to_regclass('public.deployment_probe') IS NULL") != 't':
                raise AssertionError('The installed reset did not recreate the private database')
            if query("SELECT extversion FROM pg_extension WHERE extname='laplace'") != query("SELECT default_version FROM pg_available_extensions WHERE name='laplace'"):
                raise AssertionError('Recreation did not install the declared extension version')
            print(json.dumps({'database': database, 'recreated': True, 'installed_artifacts': True, 'builds': 0}))
        finally:
            subprocess.run([str(psql), '-X', '-w', '-d', maintenance, '-v', 'ON_ERROR_STOP=1',
                            '-v', 'laplace_database=' + database], env=env, check=True, text=True,
                           input="SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'laplace_database')\n\\gexec\n")


if __name__ == '__main__':
    if sys.argv[1:2] == ['--database']:
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--database', action='store_true')
        parser.add_argument('--configuration', required=True, type=Path)
        parser.add_argument('--psql', required=True, type=Path)
        args = parser.parse_args()
        installed_database_proof(args.configuration, args.psql, os.environ['LAPLACE_ACCEPTANCE_WORK'])
    else:
        unittest.main()
