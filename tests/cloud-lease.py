"""Exercise the actual cloud command with a fake control plane; no cloud credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'cloud/lease.sh'


class CloudLease(unittest.TestCase):
    def invoke(self, operation, state='RUNNING', fail=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'gcloud'
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ['FAIL'] == '1': sys.exit(1)
if sys.argv[3] == 'describe': print(os.environ['STATE'])
''')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', PROJECT='project', INSTANCE='worker',
                       ZONE='zone', OPERATION=operation, MINUTES='10', GITHUB_REPOSITORY_ID='123',
                       GITHUB_RUN_ID='456', CALLS=str(root / 'calls'), STATE=state, FAIL=str(int(fail)))
            result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()] if (root / 'calls').exists() else []
            return result, calls

    def test_lease_precedes_state_read_and_is_unique_to_caller(self):
        result, calls = self.invoke('acquire')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[2] for call in calls], ['add-metadata', 'describe'])
        self.assertTrue(calls[0][-1].startswith('laplace-lease-123-456=456 '))

    def test_release_removes_only_this_runs_key(self):
        result, calls = self.invoke('release')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], '--keys=laplace-lease-123-456')
        self.assertEqual(calls[0][2], 'remove-metadata')

    def test_invalid_operation_never_calls_cloud(self):
        result, calls = self.invoke('delete')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_metadata_failure_prevents_start(self):
        result, calls = self.invoke('acquire', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[2] for call in calls], ['add-metadata'])


if __name__ == '__main__':
    unittest.main()
