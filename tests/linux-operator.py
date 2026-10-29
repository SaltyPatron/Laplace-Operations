"""Execute the operator dispatcher while recording its GitHub CLI boundary."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.name == 'nt', 'Linux operator shell')
class Operator(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='laplace-operator-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'gh').write_text('#!' + sys.executable + '\nimport json,os,pathlib,sys\n'
            'p=pathlib.Path(os.environ["CALLS"])\n'
            'with p.open("a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
            'print("https://github.com/SaltyPatron/Laplace/actions/runs/12345")\n')
        (self.root / 'gh').chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                                CALLS=str(self.root / 'calls.jsonl'))

    def invoke(self, *arguments):
        result = subprocess.run(['bash', str(ROOT / 'laplace-ops'), *arguments],
                                 env=self.environment, text=True, capture_output=True)
        trace = self.root / 'calls.jsonl'
        calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
        return result, calls

    def test_hosted_status_verify_deploy_use_the_product_owner(self):
        for operation in ('status', 'verify', 'deploy'):
            result, calls = self.invoke(operation, '--target', 'production', '--wait')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls[-2], ['workflow', 'run', 'product-operator.yml', '-f', 'target=production',
                '-f', 'operation=' + operation, '--repo', 'SaltyPatron/Laplace', '--ref', 'main'])
            self.assertIn('watch', calls[-1])
            self.assertIn('12345', calls[-1])

    def test_misplaced_options_never_dispatch(self):
        for arguments in (('deploy', '--target', 'production', '--force'), ('status', '--target'),
                          ('verify', '--target', 'production', '--typo'), ('deploy', '--target', 'cloud')):
            result, calls = self.invoke(*arguments)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, [])

    def test_recent_runs_cover_every_declared_delivery_repository(self):
        result, calls = self.invoke('runs')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 6)
        self.assertTrue(all(call[:2] == ['run', 'list'] for call in calls))


if __name__ == '__main__':
    unittest.main()
