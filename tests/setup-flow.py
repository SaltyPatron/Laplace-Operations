"""Execute the real setup dispatcher with external provisioning stages isolated."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SetupFlow(unittest.TestCase):
    def run_setup(self, arguments=(), fail='', declared=True):
        with tempfile.TemporaryDirectory() as temporary:
            trace = Path(temporary) / 'stages'
            env = dict(os.environ, TRACE=str(trace), FLOW=str(ROOT / 'installation/setup-flow.sh'),
                       FAIL_STAGE=fail, DECLARED='1' if declared else '')
            # Stage boundaries are isolated; appdb(), runtime() and dispatcher are real.
            program = r'''
set -euo pipefail
source "$FLOW"
here='/fixture checkout with spaces'
setup_runtime_manifest=${DECLARED:+/fixture manifest with spaces.json}
setup_runtime_verified=0
stage() { printf '%s\n' "$1" >> "$TRACE"; [[ $1 != "$FAIL_STAGE" ]] || return 37; }
part() { :; }
say() { :; }
for name in volumes packages rights kernel deps cluster settings access backup landing site agents idlestop report drop; do
  eval "$name() { stage $name; }"
done
appdb_cluster() { stage separate_cluster; }
python3() {
  if [[ $# == 2 && $1 == "$here/installation/modular.py" && $2 == install ]]; then
    stage modular
    return
  fi
  [[ $# == 3 && $1 == "$here/installation/runtime.py" && $2 == --manifest && $3 == "$setup_runtime_manifest" ]]
  stage runtime
}
setup_dispatch "$@"
printf 'complete:%s\n' "$setup_runtime_verified" >> "$TRACE"
'''
            result = subprocess.run(['bash', '-c', program, 'setup-fixture', *arguments],
                                    text=True, capture_output=True, env=env, timeout=15)
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_default_and_all_include_verified_runtime_without_another_cluster(self):
        for args in ((), ('all',)):
            with self.subTest(args=args):
                result, stages = self.run_setup(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(stages.count('runtime'), 1)
                self.assertLess(stages.index('site'), stages.index('runtime'))
                self.assertLess(stages.index('runtime'), stages.index('report'))
                self.assertLess(stages.index('runtime'), stages.index('modular'))
                self.assertLess(stages.index('modular'), stages.index('report'))
                self.assertNotIn('separate_cluster', stages)
                self.assertEqual(stages[-1], 'complete:1')

    def test_failures_stop_before_success_report(self):
        for failed in ('packages', 'site', 'runtime', 'modular'):
            with self.subTest(failed=failed):
                result, stages = self.run_setup(fail=failed)
                self.assertEqual(result.returncode, 37, result.stderr)
                self.assertEqual(stages[-1], failed)
                self.assertNotIn('report', stages)
                self.assertFalse(any(s.startswith('complete:') for s in stages))

    def test_explicit_stages_do_not_reprovision_everything(self):
        result, stages = self.run_setup(('site', 'runtime', 'report'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stages, ['site', 'runtime', 'report', 'complete:1'])

    def test_undeclared_runtime_retains_existing_cluster_provisioning(self):
        result, stages = self.run_setup(declared=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('separate_cluster', stages)
        self.assertNotIn('runtime', stages)
        self.assertEqual(stages[-1], 'complete:0')

    def test_unknown_stage_fails_before_any_stage(self):
        result, stages = self.run_setup(('site', 'misspelled-stage'))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(stages, [])


if __name__ == '__main__':
    unittest.main()
