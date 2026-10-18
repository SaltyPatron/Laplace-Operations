"""Exercise installation declarations, SQL scope and failed release activation."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
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

    def test_repair_converges_a_missing_listener_credential_once(self):
        config = self.token_config()
        units = self.directory / 'units'
        units.mkdir()
        unit = units / modular.UNIT
        unit.write_text(modular.unit_text(config))
        self.assertNotIn('modular-mcp.env', unit.read_text())
        commands = []

        def command(argv, **kwargs):
            commands.append(tuple(argv))
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(modular, 'UNITS', units), \
             patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular.os, 'chown'), \
             patch.object(modular.grp, 'getgrnam', return_value=modular.grp.struct_group(('laplace-runner', 'x', os.getgid(), []))), \
             patch.object(modular, 'checked', side_effect=command):
            first = modular.converge_listener_credential(config)
            body = first.read_text()
            named = unit.read_text()
            self.assertRegex(body, r'^LAPLACE_MCP_TOKEN="[0-9a-f]{64}"\n$')
            self.assertEqual(first.stat().st_mode & 0o777, 0o640)
            self.assertIn('EnvironmentFile=' + config['environment_file'] + '\nEnvironmentFile=' + str(first) + '\n', named)
            self.assertEqual(commands, [('systemctl', 'daemon-reload')])
            commands.clear()
            self.assertEqual(modular.converge_listener_credential(config).read_text(), body)
            self.assertEqual(unit.read_text(), named)
            self.assertEqual(commands, [])
            first.write_text('LAPLACE_MCP_TOKEN=short\n')
            with self.assertRaisesRegex(ValueError, 'rotation'):
                modular.converge_listener_credential(config)
            self.assertEqual(first.read_text(), 'LAPLACE_MCP_TOKEN=short\n')
            self.assertEqual(unit.read_text(), named)
        self.assertFalse(modular.credential_signal(config).exists())

    def test_deployment_asks_the_installed_helper_and_does_not_create_the_credential(self):
        config = self.token_config()
        config['restart_signal'] = str(self.directory / 'restart-modular-mcp')
        units = self.directory / 'units'
        units.mkdir()
        with patch.object(modular.os, 'geteuid', return_value=1000):
            with self.assertRaisesRegex(ValueError, 'installed by setup'):
                modular.converge_listener_credential(config)
            with self.assertRaisesRegex(ValueError, 'installed by setup'):
                modular.install_credential_helper(config)
        self.assertFalse(modular.token_file(config).exists())
        with patch.object(modular, 'UNITS', units), \
             patch.object(modular.os, 'geteuid', return_value=1000), \
             patch.object(modular.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, 'not installed'):
                modular.ensure_listener_credential(config)
        self.assertFalse(modular.token_file(config).exists())
        self.assertFalse(modular.credential_signal(config).exists())

        token = modular.token_file(config)
        token.parent.mkdir(parents=True)
        token.write_text('LAPLACE_MCP_TOKEN="' + ('cd' * 32) + '"\n')
        (units / modular.UNIT).write_text('EnvironmentFile=' + config['environment_file'] + '\nEnvironmentFile=' + str(token) + '\n')
        with patch.object(modular, 'UNITS', units), patch.object(modular.os, 'geteuid', return_value=1000):
            modular.ensure_listener_credential(config)
        self.assertFalse(modular.credential_signal(config).exists())
        token.unlink()
        (units / modular.UNIT).unlink()

        calls = {'n': 0}

        def show(argv, **kwargs):
            calls['n'] += 1
            if calls['n'] == 1:
                return subprocess.CompletedProcess(argv, 0, 'ExecMainStartTimestamp=\n', '')
            path = modular.token_file(config)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('LAPLACE_MCP_TOKEN="' + ('ab' * 32) + '"\n')
            (units / modular.UNIT).write_text('EnvironmentFile=' + config['environment_file'] + '\nEnvironmentFile=' + str(path) + '\n')
            return subprocess.CompletedProcess(argv, 0, 'ActiveState=inactive\nResult=success\nExecMainStartTimestamp=later\n', '')

        ticks = {'n': 0}

        def clock():
            ticks['n'] += 1
            return 0 if ticks['n'] < 8 else 1000

        with patch.object(modular, 'UNITS', units), \
             patch.object(modular.os, 'geteuid', return_value=1000), \
             patch.object(modular.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(modular, 'checked', side_effect=show), \
             patch.object(modular.time, 'sleep'), \
             patch.object(modular.time, 'monotonic', side_effect=clock):
            modular.ensure_listener_credential(config)
            self.assertTrue(modular.listener_credential_ready(config))
        signal = modular.credential_signal(config)
        self.assertTrue(signal.is_file())
        self.assertNotIn('LAPLACE_MCP_TOKEN', signal.read_text())
        self.assertIn('EnvironmentFile=' + str(modular.token_file(config)), (units / modular.UNIT).read_text())

    def test_credential_helper_is_root_code_and_not_the_checkout(self):
        config = self.token_config()
        config['restart_signal'] = str(self.directory / 'restart-modular-mcp')
        config['installed_config'] = str(self.directory / 'declared' / 'modular.json')
        program = self.directory / 'libexec' / 'laplace-modular.py'
        binary = self.directory / 'sbin' / 'laplace-modular-credential'
        units = self.directory / 'units'
        commands = []

        def command(argv, **kwargs):
            commands.append(tuple(argv))
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(modular, 'HELPER_PROGRAM', program), \
             patch.object(modular, 'HELPER_BIN', binary), \
             patch.object(modular, 'UNITS', units), \
             patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular.os, 'chown') as chown, \
             patch.object(modular, 'checked', side_effect=command):
            modular.install_credential_helper(config)
        self.assertEqual(program.read_text(), Path(modular.__file__).read_text())
        self.assertEqual(binary.read_text(), '#!/bin/sh\nexec python3 /usr/local/libexec/laplace-modular.py converge '
                         + shlex.quote(config['installed_config']) + '\n')
        self.assertNotIn('/etc/laplace/modular.json', binary.read_text())
        self.assertNotIn(str(ROOT), binary.read_text())
        service = (units / (modular.HELPER + '.service')).read_text()
        path_unit = (units / (modular.HELPER + '.path')).read_text()
        self.assertIn('ExecStart=/usr/local/sbin/laplace-modular-credential\n', service)
        self.assertNotIn(str(ROOT), service)
        self.assertNotIn(str(ROOT), path_unit)
        self.assertIn('PathChanged=' + str(modular.credential_signal(config)) + '\n', path_unit)
        self.assertIn(('systemctl', 'daemon-reload'), commands)
        self.assertIn(('systemctl', 'enable', '--now', modular.HELPER + '.path'), commands)
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual({call.args[0] for call in chown.call_args_list}, {program, binary})
        self.assertTrue(all(call.args[1:] == (0, 0) for call in chown.call_args_list))

    def test_checkout_converge_installs_the_helper_and_the_installed_copy_does_not(self):
        config = self.token_config()
        declared = self.directory / 'other-host' / 'modular.json'
        order = []
        with patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular, 'config_load', return_value=config) as load, \
             patch.object(modular, 'HELPER_PROGRAM', self.directory / 'installed.py'), \
             patch.object(modular, 'install_credential_helper', side_effect=lambda c: order.append(('helper', c))), \
             patch.object(modular, 'converge_listener_credential', side_effect=lambda c: order.append(('credential', c))):
            modular.converge_operation(declared)
        self.assertEqual(order, [('helper', config), ('credential', config)])
        self.assertEqual(load.call_args.args[0], declared)
        order.clear()
        with patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular, 'config_load', return_value=config) as load, \
             patch.object(modular, 'HELPER_PROGRAM', Path(modular.__file__)), \
             patch.object(modular, 'install_credential_helper', side_effect=lambda c: order.append('helper')), \
             patch.object(modular, 'converge_listener_credential', side_effect=lambda c: order.append(('credential', c))):
            modular.converge_operation(declared)
        self.assertEqual(order, [('credential', config)])
        self.assertEqual(load.call_args.args[0], declared)
        with patch.object(modular.os, 'geteuid', return_value=1000), \
             patch.object(modular, 'config_load') as load:
            with self.assertRaisesRegex(ValueError, 'installed by setup'):
                modular.converge_operation(declared)
        load.assert_not_called()

    def test_checkout_converge_uses_the_host_declaration_when_no_path_is_given(self):
        config = self.token_config()
        manifest = self.directory / 'installation' / 'this-host-modular.json'
        with patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular, 'select_manifest', return_value=manifest), \
             patch.object(modular, 'config_load', return_value=config) as load, \
             patch.object(modular, 'HELPER_PROGRAM', self.directory / 'installed.py'), \
             patch.object(modular, 'install_credential_helper'), \
             patch.object(modular, 'converge_listener_credential', return_value=Path('token')):
            modular.converge_operation()
        self.assertEqual(load.call_args.args[0], manifest)
        with patch.object(modular.os, 'geteuid', return_value=0), \
             patch.object(modular, 'select_manifest', return_value=None), \
             patch.object(modular, 'config_load') as load:
            with self.assertRaisesRegex(ValueError, 'No modular runtime declared'):
                modular.converge_operation()
        load.assert_not_called()

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

    def test_host_lock_waiting_deployment_is_not_overtaken_by_a_later_reader(self):
        import fcntl, threading, time
        lock = self.directory / 'host-resource.lock'
        config = {'lock': str(lock)}
        reader = os.open(lock, os.O_WRONLY | os.O_CREAT, 0o660)
        self.addCleanup(os.close, reader)
        fcntl.flock(reader, fcntl.LOCK_SH)
        got = []

        def deploy():
            with patch.dict(os.environ, {'LAPLACE_HOST_LOCK_WAIT_SECONDS': '20'}):
                with modular.host_lock(config):
                    got.append(time.monotonic())
                    time.sleep(0.5)
        deployment = threading.Thread(target=deploy)
        deployment.start()
        turnstile = str(lock) + '.turnstile'
        for _ in range(100):
            if os.path.exists(turnstile):
                break
            time.sleep(0.02)
        time.sleep(0.3)
        # a later ingest, as operation-lock.sh takes it, waits at the turnstile the deployment holds
        helper = Path(__file__).resolve().parent.parent / 'operation-lock.sh'
        env = dict(os.environ, LAPLACE_HOST_LOCK=str(lock), LAPLACE_HOST_LOCK_WAIT_SECONDS='0', HELPER=str(helper))
        later = subprocess.run(['bash', '-c', '. "$HELPER"; laplace_host_lock shared'], env=env, capture_output=True, text=True)
        self.assertEqual(later.returncode, 3, later.stderr)
        self.assertEqual(got, [])
        fcntl.flock(reader, fcntl.LOCK_UN)
        deployment.join(10)
        self.assertEqual(len(got), 1)

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
