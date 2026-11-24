import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('resolver', Path(__file__).resolve().parents[1] / '.github/scripts/resolve-dependencies.py')
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


LOCK = dict.fromkeys(resolver.COMPONENTS, 'd' * 40)


def github(main='a' * 40, merged='ahead', against_lock='ahead'):
    """A GitHub double: main's head, the triggering revision's place in main, and its place against the lock."""
    def request(path):
        if '/compare/' in path:
            base = path.rsplit('/compare/', 1)[1].split('...')[0]
            return {'status': against_lock if base == 'd' * 40 else merged}
        return {'sha': main}
    return request


class Revisions(unittest.TestCase):
    def test_push_deploys_the_locked_set_without_reading_main(self):
        self.assertEqual(resolver.resolve('owner', 'push', {}, lambda _: self.fail('a push read main'), LOCK), LOCK)

    def test_operator_advance_takes_every_main(self):
        self.assertEqual(resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'advance': 'true'}}, github(), LOCK),
                         dict.fromkeys(resolver.COMPONENTS, 'a' * 40))

    def test_operator_can_retain_a_qualified_engine_from_main_history(self):
        result = resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'b' * 40}}, github(), LOCK)
        self.assertEqual(result['engine'], 'b' * 40)
        self.assertEqual(result['native'], 'd' * 40)
        with self.assertRaisesRegex(ValueError, 'main history'):
            resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'b' * 40}},
                             github(merged='diverged'), LOCK)
        with self.assertRaisesRegex(ValueError, 'full commit'):
            resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'main'}},
                             lambda _: self.fail('invalid revision reached GitHub'), LOCK)

    def test_dispatch_replaces_only_its_component(self):
        result = resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
            'repository': 'owner/Laplace-Engine', 'sha': 'b' * 40}}, github(), LOCK)
        self.assertEqual(result, dict(LOCK, engine='b' * 40))

    def test_late_dispatch_never_moves_a_component_back(self):
        result = resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
            'repository': 'owner/Laplace-MCP', 'sha': 'c' * 40}}, github(against_lock='behind'), LOCK)
        self.assertEqual(result['mcp'], 'd' * 40)

    def test_untrusted_payloads_fail_before_api_access(self):
        for repo, sha in [('stranger/Laplace-Native', 'b' * 40), ('owner/Laplace-Native', 'main'),
                          ('owner/Laplace-Native', 'a";echo unsafe'), (None, None)]:
            with self.subTest(repo=repo, sha=sha), self.assertRaises(ValueError):
                resolver.resolve('owner', 'repository_dispatch', {'client_payload': {'repository': repo, 'sha': sha}},
                                 lambda _: self.fail('invalid payload reached GitHub'), LOCK)

    def test_unmerged_revision_rejected(self):
        with self.assertRaisesRegex(ValueError, 'main history'):
            resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
                'repository': 'owner/Laplace-Engine', 'sha': 'b' * 40}}, github(merged='diverged'), LOCK)


class VersionLock(unittest.TestCase):
    def test_repository_lock_names_every_component(self):
        self.assertEqual(set(resolver.read_lock()), set(resolver.COMPONENTS))

    def test_write_keeps_the_header_and_reports_change(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'components.lock.tsv'
            path.write_text('# header\n' + ''.join(f'{k}\t{n}\t{"d" * 40}\n' for k, n in resolver.COMPONENTS.items()))
            self.assertFalse(resolver.write_lock(LOCK, path))
            self.assertTrue(resolver.write_lock(dict(LOCK, engine='e' * 40), path))
            self.assertEqual(resolver.read_lock(path)['engine'], 'e' * 40)
            self.assertTrue(path.read_text().startswith('# header\n'))
            with self.assertRaises(ValueError):
                resolver.write_lock(dict(LOCK, engine='main'), path)
            path.write_text(path.read_text().replace('Laplace-MCP', 'Elsewhere'))
            with self.assertRaises(ValueError):
                resolver.read_lock(path)


class EngineQualification(unittest.TestCase):
    def setUp(self):
        self.mutations = []
        self.run = {'id': 9, 'head_sha': 'a' * 40, 'head_branch': 'main',
                    'path': '.github/workflows/laplace.yml', 'event': 'push',
                    'status': 'in_progress', 'html_url': 'https://github.com/owner/Laplace-Engine/actions/runs/9'}

    def qualify(self, state='active', conclusion='success', runs=None, main='a' * 40):
        calls = []
        def request(path):
            calls.append(path)
            if path.endswith('/actions/workflows/laplace.yml'):
                return {'state': state}
            if '/actions/runs?' in path:
                if any(m[0].endswith('/rerun-failed-jobs') for m in self.mutations):
                    self.run['run_attempt'] = 2
                return {'workflow_runs': [self.run] if runs is None else runs(calls)}
            if '/jobs?' in path:
                return {'jobs': [{'name': 'engine', 'status': 'completed' if conclusion else 'in_progress',
                                  'conclusion': conclusion}]}
            if path.endswith('/commits/main'):
                return {'sha': main}
            self.fail('Unexpected endpoint: ' + path)
        return resolver.qualify_engine('owner', 'a' * 40, request,
            lambda path, method, body: self.mutations.append((path, method, body)),
            sleep=lambda _: None, attempts=2)

    def test_successful_engine_job_qualifies_while_optional_jobs_finish(self):
        self.assertEqual(self.qualify(), 9)
        self.assertEqual(self.mutations, [])

    def test_disabled_required_workflow_is_enabled_and_missing_run_dispatched(self):
        def runs(_):
            return [self.run] if len(self.mutations) == 2 else []
        self.assertEqual(self.qualify(state='disabled_manually', runs=runs), 9)
        self.assertEqual(self.mutations, [
            ('/repos/owner/Laplace-Engine/actions/workflows/laplace.yml/enable', 'PUT', None),
            ('/repos/owner/Laplace-Engine/actions/workflows/laplace.yml/dispatches', 'POST', {'ref': 'main'})])

    def test_failed_or_skipped_engine_is_rerun_once_then_rejected(self):
        for conclusion in ('failure', 'skipped', 'timed_out'):
            self.mutations.clear(); self.run.pop('run_attempt', None)
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(ValueError, 'after one rerun'):
                self.qualify(conclusion=conclusion)
            self.assertEqual(self.mutations, [
                ('/repos/owner/Laplace-Engine/actions/runs/9/rerun-failed-jobs', 'POST', None)])

    def test_cancelled_engine_run_is_run_again_while_its_revision_is_main(self):
        with self.assertRaises(TimeoutError):
            self.qualify(conclusion='cancelled')
        self.assertEqual(self.mutations, [
            ('/repos/owner/Laplace-Engine/actions/workflows/laplace.yml/dispatches', 'POST', {'ref': 'main'})])

    def test_cancelled_engine_run_of_a_superseded_revision_yields(self):
        self.assertIsNone(self.qualify(conclusion='cancelled', main='b' * 40))
        self.assertEqual(self.mutations, [])

    def test_invalid_workflow_run_without_jobs_is_rejected(self):
        self.run['status'] = 'completed'
        with self.assertRaisesRegex(ValueError, 'qualification failed'):
            self.qualify(conclusion=None)

    def test_rerun_that_passes_qualifies(self):
        def request_runs(_):
            if self.mutations:
                self.run['run_attempt'] = 2
            return [self.run]
        conclusions = iter(['failure', 'success'])
        self.run['status'] = 'completed'
        state = {'c': None}
        def request(path):
            if path.endswith('/actions/workflows/laplace.yml'):
                return {'state': 'active'}
            if '/actions/runs?' in path:
                return {'workflow_runs': request_runs(path)}
            if '/jobs?' in path:
                state['c'] = next(conclusions)
                return {'jobs': [{'name': 'engine', 'status': 'completed', 'conclusion': state['c']}]}
            self.fail('Unexpected endpoint: ' + path)
        self.assertEqual(resolver.qualify_engine('owner', 'a' * 40, request,
            lambda path, method, body: self.mutations.append((path, method, body)),
            sleep=lambda _: None, attempts=3), 9)

    def test_other_revision_cannot_qualify_selected_revision(self):
        self.run['head_sha'] = 'b' * 40
        self.assertIsNone(self.qualify(main='b' * 40))

    def test_queued_engine_cannot_qualify_release(self):
        with self.assertRaises(TimeoutError):
            self.qualify(conclusion=None)


if __name__ == '__main__':
    unittest.main()
