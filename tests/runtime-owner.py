"""Forward runtime setup to the declared monorepo without swallowing failures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeOwner(unittest.TestCase):
    def test_installed_owner_and_arguments_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / 'mono source'
            script = repo / 'deploy/linux/runtime/install.py'
            script.parent.mkdir(parents=True)
            script.write_text('import json,sys\nprint(json.dumps(sys.argv[1:]))\nsys.exit(37)\n')
            machine = Path(temporary) / 'machine.env'
            machine.write_text('LAPLACE_MONOREPO="' + str(repo) + '"\n')
            env = {key: value for key, value in os.environ.items() if not key.startswith('LAPLACE_')}
            env['LAPLACE_MACHINE_ENV'] = str(machine)
            args = ['--manifest', '/an installed declaration.json', '--check']
            result = subprocess.run([sys.executable, str(ROOT / 'installation/runtime.py'), *args],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 37, result.stderr)
            self.assertEqual(json.loads(result.stdout), args)
            script.unlink()
            result = subprocess.run([sys.executable, str(ROOT / 'installation/runtime.py'), '--check'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('installer missing', result.stderr)


if __name__ == '__main__':
    unittest.main()
