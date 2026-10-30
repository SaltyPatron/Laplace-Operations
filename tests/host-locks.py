#!/usr/bin/env python3
"""Read an actual child-held flock without exposing command arguments or credentials."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('host_locks', Path(__file__).resolve().parents[1] / 'installation/host-locks.py')
host_locks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host_locks)


@unittest.skipUnless(sys.platform == 'linux', 'Linux procfs and flock diagnostic')
class HostLocks(unittest.TestCase):
    def test_live_descriptor_owner_and_secret_suppression(self):
        with tempfile.TemporaryDirectory(prefix='laplace-host-lock-') as scratch:
            lock = Path(scratch) / 'host-resource.lock'
            lock.touch()
            lock.with_name(lock.name + '.turnstile').touch()
            child = subprocess.Popen([sys.executable, '-c', '''
import fcntl, sys
with open(sys.argv[1], 'r+') as lock:
    fcntl.flock(lock, fcntl.LOCK_SH)
    print('ready', flush=True)
    sys.stdin.read()
''', str(lock), 'PRIVATE_COMMAND_CANARY'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
                env=dict(os.environ, PRIVATE_TOKEN='PRIVATE_ENV_CANARY', GITHUB_RUN_ID='lock-owner-test'))
            try:
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                report = host_locks.inspect(lock)
                owner = next(item for item in report['descriptor_owners'] if item['pid'] == child.pid)
                self.assertEqual(owner['parent_pid'], os.getpid())
                self.assertEqual(owner['job']['GITHUB_RUN_ID'], 'lock-owner-test')
                self.assertTrue(any(item['path'] == str(lock) for item in owner['descriptors']))
                self.assertTrue(report['kernel_locks'])
                self.assertEqual(report['ownership_complete'], report['unobservable_processes'] == 0)
                serialized = json.dumps(report)
                for private in ('PRIVATE_ENV_CANARY', 'PRIVATE_COMMAND_CANARY', 'PRIVATE_TOKEN'):
                    self.assertNotIn(private, serialized)
            finally:
                child.communicate(timeout=10)
            self.assertFalse(host_locks.inspect(lock)['kernel_locks'])


if __name__ == '__main__':
    unittest.main()
