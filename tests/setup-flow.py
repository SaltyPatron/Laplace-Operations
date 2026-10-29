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
LAPLACE_PGDATA='/fixture database'
LAPLACE_APP_PGDATA=${DECLARED:+$LAPLACE_PGDATA}
LAPLACE_APP_DBNAME=${DECLARED:+laplace-app}
setup_runtime_verified=0
stage() { printf '%s\n' "$1" >> "$TRACE"; [[ $1 != "$FAIL_STAGE" ]] || return 37; }
part() { :; }
say() { :; }
for name in volumes packages rights kernel deps cluster settings access backup landing configured_secrets site agents idlestop report drop; do
  eval "$name() { stage $name; }"
done
appdb_cluster() { stage application_database; }
python3() {
  if [[ $# == 1 && $1 == "$here/installation/postgres-installation.py" ]]; then
    stage postgres
    return
  fi
  if [[ $# == 2 && $1 == "$here/installation/modular.py" && $2 == install ]]; then
    stage modular
    return
  fi
  if [[ $# == 3 && $1 == "$here/installation/database-restart.py" && $2 == --environment && $3 == --install ]]; then
    stage restart_controller
    return
  fi
  [[ $# == 1 && $1 == "$here/installation/runtime.py" ]]
  stage runtime
}
setup_dispatch "$@"
printf 'complete:%s\n' "$setup_runtime_verified" >> "$TRACE"
'''
            result = subprocess.run(['bash', '-c', program, 'setup-fixture', *arguments],
                                    text=True, capture_output=True, env=env, timeout=15)
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_default_and_all_own_shared_and_modular_without_monorepo_mutations(self):
        for args in ((), ('all',)):
            with self.subTest(args=args):
                result, stages = self.run_setup(args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('runtime', stages)
                self.assertNotIn('site', stages)
                self.assertLess(stages.index('modular'), stages.index('report'))
                self.assertLess(stages.index('cluster'), stages.index('postgres'))
                self.assertLess(stages.index('postgres'), stages.index('restart_controller'))
                self.assertLess(stages.index('restart_controller'), stages.index('settings'))
                self.assertLess(stages.index('postgres'), stages.index('application_database'))
                self.assertEqual(stages[-1], 'complete:0')

    def test_failures_stop_before_success_report(self):
        for failed in ('packages', 'postgres', 'restart_controller', 'modular'):
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

    def test_no_application_database_is_created_without_a_declaration(self):
        result, stages = self.run_setup(declared=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('application_database', stages)
        self.assertNotIn('runtime', stages)
        self.assertEqual(stages[-1], 'complete:0')

    def test_unknown_stage_fails_before_any_stage(self):
        result, stages = self.run_setup(('site', 'misspelled-stage'))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(stages, [])


if __name__ == '__main__':
    unittest.main()
