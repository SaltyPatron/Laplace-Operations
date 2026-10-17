"""Exercise installation declarations, SQL scope and failed release activation."""
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

    def test_peer_refusals_reach_real_process_execution_with_numeric_port(self):
        config = self.load()
        launcher = self.directory / 'runuser'
        trace = self.directory / 'commands.jsonl'
        # Isolate only the privileged identity transition and SQL server here.
        # Real Popen argument handling must execute all four commands. The former
        # direct subprocess.run raised TypeError before executing the first refusal.
        launcher.write_text('#!' + sys.executable + '\n' +
            'import json,os,sys\n' +
            'with open(os.environ["PEER_TRACE"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n' +
            'if "SELECT current_user" in sys.argv[-1]:\n' +
            ' print(os.environ["PEER_ROLE"]); sys.exit(0)\n' +
            'sys.exit(1)\n')
        launcher.chmod(0o755)
        with patch.dict(os.environ, PATH=str(self.directory) + os.pathsep + os.environ['PATH'],
                        PEER_TRACE=str(trace), PEER_ROLE=config['role']):
            modular.peer_check(config)
        commands = [json.loads(line) for line in trace.read_text().splitlines()]
        self.assertEqual(len(commands), 4)
        self.assertTrue(all(str(config['port']) in command for command in commands))
        self.assertIn('SET ROLE laplace;', commands[1])

    def test_failed_peer_preflight_never_stops_a_service(self):
        config = self.load()
        config['prefix'] = str(self.directory / 'prefix')
        config['environment_file'] = str(self.directory / 'runtime.env')
        release = Path(config['prefix']) / 'releases/prepared'
        release.mkdir(parents=True)
        called = []
        def command(args, **kwargs):
            called.append(args)
            return subprocess.CompletedProcess(args, 0, stdout='')
        with patch.object(modular, 'UNITS', self.directory / 'units'), \
             patch.object(modular, 'checked', side_effect=command), \
             patch.object(modular, 'legacy_command', return_value=subprocess.CompletedProcess([], 1)), \
             patch.object(modular, 'peer_check', side_effect=ValueError('denied preflight')), \
             patch.object(modular.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, 'denied preflight'):
                modular.activate(config, release, self.directory, True)
        self.assertFalse(any('stop' in args or 'restart' in args or 'daemon-reload' in args for args in called))
        self.assertFalse((Path(config['prefix']) / 'current').exists())

    def test_invalid_declarations_cannot_reach_mutation(self):
        for key, value in (('runtime_user', 'root'), ('runtime_user', 'ahart'),
                           ('role', 'x; ALTER ROLE laplace SUPERUSER'), ('bind', '0.0.0.0'),
                           ('http_port', 65536), ('source', '/tmp/../etc'), ('build', self.value['prefix']),
                           ('threads', 0), ('connection_limit', 7), ('host', 'wrong-host')):
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

    def test_failed_install_restores_service_configuration_and_legacy_listener(self):
        config = self.load()
        config['prefix'] = str(self.directory / 'prefix')
        config['environment_file'] = str(self.directory / 'runtime.env')
        config['state'] = str(self.directory / 'state')
        prefix = Path(config['prefix'])
        old, new = prefix / 'releases/old', prefix / 'releases/new'
        old.mkdir(parents=True)
        new.mkdir()
        (prefix / 'current').symlink_to(old)
        units = self.directory / 'units'
        units.mkdir()
        unit = units / modular.UNIT
        unit.write_text('old unit')
        Path(config['environment_file']).write_text('old configuration')
        called, legacy = [], []

        def command(args, **kwargs):
            called.append([str(v) for v in args])
            if 'systemd-analyze' in args:
                raise RuntimeError('injected unit verification failure')
            return subprocess.CompletedProcess(args, 0, stdout='old invocation')

        def legacy_command(config, *args, **kwargs):
            legacy.append(args)
            return subprocess.CompletedProcess(args, 0)

        with patch.object(modular, 'UNITS', units), patch.object(modular, 'checked', side_effect=command), \
             patch.object(modular, 'legacy_command', side_effect=legacy_command), patch.object(modular, 'peer_check'), \
             patch.object(modular, 'unit_text', return_value='new unit'), \
             patch.object(modular.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(RuntimeError, 'injected'):
                modular.activate(config, new, self.directory, True)
        self.assertEqual(unit.read_text(), 'old unit')
        self.assertEqual(Path(config['environment_file']).read_text(), 'old configuration')
        self.assertEqual((prefix / 'current').resolve(), old)
        self.assertIn(('start',), legacy)

    def token_config(self):
        config = self.load()
        config['environment_file'] = str(self.directory / 'etc/modular.env')
        config['source'] = str(self.directory / 'source')
        template = Path(config['source']) / 'Laplace-MCP/laplace-modular-mcp.service.in'
        template.parent.mkdir(parents=True)
        template.write_text('[Service]\nUser={user}\nEnvironmentFile={environment_file}\nExecStart={executable} serve\n')
        return config

    def test_token_is_made_once_and_named_by_the_unit_only_once_made(self):
        config = self.token_config()
        before = modular.unit_text(config)
        self.assertNotIn('modular-mcp.env', before)
        with patch.object(modular.os, 'chown'), \
             patch.object(modular.grp, 'getgrnam', return_value=modular.grp.struct_group(('laplace-runner', 'x', os.getgid(), []))):
            path = modular.provision_token(config)
            first = path.read_text()
            self.assertRegex(first, r'^LAPLACE_MCP_TOKEN="[0-9a-f]{64}"\n$')
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o750)
            self.assertEqual(modular.provision_token(config).read_text(), first)
            after = modular.unit_text(config)
            self.assertIn('EnvironmentFile=' + config['environment_file'] + '\nEnvironmentFile=' + str(path) + '\n', after)
            self.assertEqual(after.count('modular-mcp.env'), 1)
            path.write_text('LAPLACE_MCP_TOKEN=short\n')
            with self.assertRaisesRegex(ValueError, 'rotation'):
                modular.provision_token(config)
            self.assertEqual(path.read_text(), 'LAPLACE_MCP_TOKEN=short\n')

    def test_host_lock_waits_for_the_declared_deadline_then_refuses(self):
        import fcntl, threading, time
        lock = self.directory / 'host-resource.lock'
        config = {'lock': str(lock)}
        held = os.open(lock, os.O_WRONLY | os.O_CREAT, 0o660)
        self.addCleanup(lambda: os.close(held) if held is not None else None)
        fcntl.flock(held, fcntl.LOCK_EX)
        with patch.dict(os.environ, {'LAPLACE_HOST_LOCK_WAIT_SECONDS': '0'}):
            with self.assertRaisesRegex(ValueError, 'deadline expired'):
                with modular.host_lock(config):
                    self.fail('acquired a held lock')
        with patch.dict(os.environ, {'LAPLACE_HOST_LOCK_WAIT_SECONDS': 'soon'}):
            with self.assertRaisesRegex(ValueError, 'nonnegative integer'):
                with modular.host_lock(config):
                    self.fail('acquired under an invalid deadline')
        threading.Timer(1.0, lambda: fcntl.flock(held, fcntl.LOCK_UN)).start()
        started = time.monotonic()
        with patch.dict(os.environ, {'LAPLACE_HOST_LOCK_WAIT_SECONDS': '20'}):
            with modular.host_lock(config):
                waited = time.monotonic() - started
        self.assertTrue(0.5 < waited < 10, waited)

    def test_non_root_sql_uses_operator_role(self):
        config = self.load()
        called = []

        def command(args, **kwargs):
            called.append([str(v) for v in args])
            return subprocess.CompletedProcess(args, 0, stdout='ok\n')

        with patch.object(modular.os, 'geteuid', return_value=1000), \
             patch.object(modular, 'checked', side_effect=command):
            result = modular.sql(config, 'SELECT 1;')
        self.assertEqual(result, 'ok')
        self.assertEqual(len(called), 1)
        self.assertNotIn('runuser', called[0])
        self.assertIn('-U', called[0])
        self.assertIn('laplace', called[0])


if __name__ == '__main__':
    unittest.main()
