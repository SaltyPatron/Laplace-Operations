"""Exercise setup's real resource convergence with OS/database boundaries isolated."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'setup.sh').read_text()
GROUP = SOURCE[SOURCE.index('hugepage_access_group(){'):SOURCE.index('\nkernel()')]
SETTINGS = SOURCE[SOURCE.index('settings()'):SOURCE.index('\naccess(){')]


class SetupResources(unittest.TestCase):
    def run_settings(self, **changes):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'huge-state'
            state.write_text(changes.pop('INITIAL', 'off'))
            trace = Path(temporary) / 'trace'
            env = dict(os.environ, here=str(ROOT), LAPLACE_LOCKS=temporary,
                       LAPLACE_HOST_LOCK=str(Path(temporary) / 'host.lock'),
                       LAPLACE_HOST_LOCK_WAIT_SECONDS='0', STATE=str(state), TRACE=str(trace),
                       PGUSER='test-postgres', PGBIN='/fixture/bin', PGDATA='/fixture/data',
                       SERVICE='test-pg', MODE='try', NEED='16994', FREE='17503', GROUP='122',
                       PENDING='', INGEST='0', BUSY='0', ADOPT='1')
            env.update(changes)
            program = r'''
set -euo pipefail
part() { :; }
say() { echo "$*" >> "$TRACE"; }
ingesting() { [[ $INGEST == 1 ]]; }
tune_apply() { echo tune >> "$TRACE"; }
tune_check() { echo verified >> "$TRACE"; }
declared() { printf 'huge_pages %s\n' "$MODE"; }
q() {
  case "$1" in
    'SHOW huge_pages_status') cat "$STATE" ;;
    'SHOW shared_memory_size_in_huge_pages') printf '%s\n' "$NEED" ;;
    *pending_restart*) printf '%s\n' "$PENDING" ;;
    *) : ;;
  esac
}
runuser() {
  echo 'Resource sizing must query the running postmaster, not execute another postgres' >&2
  return 99
}
awk() { if [[ ${@: -1} == /proc/meminfo ]]; then echo "$FREE"; else command awk "$@"; fi; }
sysctl() { [[ "$*" == '-n vm.hugetlb_shm_group' ]]; echo "$GROUP"; }
id() { [[ "$*" == "-G $PGUSER" ]]; echo '122 121'; }
systemctl() {
  [[ "$*" == "restart $SERVICE.service" ]]
  echo restart >> "$TRACE"
  [[ $ADOPT != 1 ]] || echo on > "$STATE"
}
ready() { echo ready >> "$TRACE"; }
if [[ $BUSY == 1 ]]; then exec 9>>"$LAPLACE_HOST_LOCK"; flock -x 9; fi
''' + SETTINGS + '\nsettings\nsettings\necho complete >> "$TRACE"\n'
            result = subprocess.run(['bash', '-c', program], env=env, text=True, capture_output=True, timeout=10)
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_available_pages_are_adopted_once_even_without_pending_settings(self):
        result, trace = self.run_settings()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count('restart'), 1)
        self.assertEqual(trace.count('verified'), 2)
        self.assertIn('complete', trace)

    def test_already_converged_or_disabled_does_not_restart(self):
        for changes in ({'INITIAL': 'on'}, {'MODE': 'off', 'GROUP': '0'}):
            result, trace = self.run_settings(**changes)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('restart', trace)

    def test_insufficient_pages_and_missing_permissions_refuse_restart(self):
        for changes, message in (({'FREE': '1'}, 'Huge pages unavailable'),
                                 ({'GROUP': '0'}, 'Huge page access is not configured')):
            result, trace = self.run_settings(**changes)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertNotIn('restart', trace)
            self.assertNotIn('complete', trace)

    def test_failed_adoption_is_not_reported_as_success(self):
        result, trace = self.run_settings(ADOPT='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace.count('restart'), 1)
        self.assertIn('failed to adopt', result.stderr)
        self.assertNotIn('complete', trace)

    def test_ingestion_and_deployment_lock_prevent_settings_changes(self):
        for changes in ({'INGEST': '1'}, {'BUSY': '1'}):
            result, trace = self.run_settings(**changes)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('tune', trace)
            self.assertNotIn('restart', trace)

    def test_group_is_derived_or_preserved_and_other_workload_is_not_overwritten(self):
        for current, expected, success in (('0', '345', True), ('678', '678', True), ('999', '', False)):
            program = r'''
set -euo pipefail
PGUSER=fixture-postgres
sysctl() { echo "$CURRENT"; }
id() { if [[ $1 == -g ]]; then echo 345; else echo '345 678'; fi; }
''' + GROUP + '\nhugepage_access_group\n'
            result = subprocess.run(['bash', '-c', program], env=dict(os.environ, CURRENT=current),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
