import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('idle', Path(__file__).resolve().parents[1] / 'cloud/idle-stop.py')
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class CloudIdle(unittest.TestCase):
    def test_each_run_holds_its_own_lease_and_legacy_delivery_is_preserved(self):
        records = {'laplace-lease': 'old 200', 'laplace-lease-1-2': '2 300', 'laplace-lease-3-4': '4 90', 'other': 'unrelated'}
        self.assertEqual(idle.active_leases(records, 100), ['laplace-lease', 'laplace-lease-1-2'])
        del records['laplace-lease']
        self.assertEqual(idle.active_leases(records, 100), ['laplace-lease-1-2'])
        self.assertEqual(idle.active_leases(records, 301), [])

    def test_corrupt_lease_cannot_trigger_shutdown(self):
        for value in ('', 'run', 'run nonsense', 'run -1', 'too many fields 200'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                idle.active_leases({'laplace-lease-1-2': value}, 100)

    def test_build_and_test_processes_are_busy_but_idle_serving_is_not(self):
        for command in (['/runner/bin/Runner.Worker'], ['cmake', '--build', '/work'], ['ctest'],
                        ['ninja'], ['icx', 'source.c'], ['dotnet', 'test'], ['bash', '/repo/ingest.sh']):
            self.assertTrue(idle.is_work(command), command)
        for command in (['postgres'], ['laplace-api'], ['dotnet', 'Laplace.Endpoints.OpenAICompat.dll'], ['sshd'], ['lpm', 'serve']):
            self.assertFalse(idle.is_work(command), command)


if __name__ == '__main__':
    unittest.main()
