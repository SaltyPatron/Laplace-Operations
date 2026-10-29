"""Exercise the generated restart controller's actual shell and refusal paths."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('restart', ROOT / 'installation/database-restart.py')
restart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restart)


@unittest.skipIf(os.name == 'nt', 'POSIX restart controller')
class Restart(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='laplace-restart-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = json.loads((ROOT / 'secrets/application-runtime-installation.json').read_text())['production']
        self.config.update(host=socket.gethostname(), database_data=str(self.root / "DATA LOCKS 'cluster"),
                           host_lock=str(self.root / 'locks/host-resource.lock'))
        Path(self.config['database_data']).mkdir()
        (Path(self.config['database_data']) / 'postmaster.pid').write_text('1234\n')
        (self.root / 'locks').mkdir()
        (self.root / 'systemctl').write_text('#!' + sys.executable + '\n' +
            'import json,os,pathlib,sys\n'
            'if sys.argv[1] == "show": print(os.environ["SERVICE_PID"])\n'
            'else: pathlib.Path(os.environ["RESTART_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        (self.root / 'systemctl').chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                                SERVICE_PID='1234', RESTART_LOG=str(self.root / 'restart.json'))

    def execute(self):
        program = restart.files(self.config)['/usr/local/sbin/laplace-pg-restart'][0]
        return subprocess.run(['sh'], input=program, env=self.environment, capture_output=True, text=True)

    def test_matching_service_restarts_only_the_selected_unit(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / 'restart.json').read_text()),
                         ['restart', 'postgresql@18-app.service'])

    def test_mismatched_pid_never_reaches_restart(self):
        self.environment['SERVICE_PID'] = '5678'
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PID disagree', result.stderr)
        self.assertFalse((self.root / 'restart.json').exists())

    def test_foreign_host_and_shell_syntax_are_refused(self):
        for key, value in (('host', 'another-host.invalid'),
                           ('database_service', 'pgdata; touch /tmp/incorrect')):
            original = self.config[key]
            self.config[key] = value
            with self.assertRaises(ValueError):
                restart.files(self.config)
            self.config[key] = original


if __name__ == '__main__':
    unittest.main()
