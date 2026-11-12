import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('resolver', Path(__file__).resolve().parents[1] / '.github/scripts/resolve-dependencies.py')
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class Revisions(unittest.TestCase):
    def test_push_resolves_every_component(self):
        self.assertEqual(resolver.resolve('owner', 'push', {}, lambda _: {'sha': 'a' * 40}),
                         dict.fromkeys(resolver.COMPONENTS, 'a' * 40))

    def test_operator_can_retain_a_qualified_engine_from_main_history(self):
        result = resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'b' * 40}},
            lambda path: {'status': 'ahead'} if '/compare/' in path else {'sha': 'a' * 40})
        self.assertEqual(result['engine'], 'b' * 40)
        self.assertEqual(result['native'], 'a' * 40)
        with self.assertRaisesRegex(ValueError, 'main history'):
            resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'b' * 40}},
                lambda path: {'status': 'diverged'} if '/compare/' in path else {'sha': 'a' * 40})
        with self.assertRaisesRegex(ValueError, 'full commit'):
            resolver.resolve('owner', 'workflow_dispatch', {'inputs': {'engine_revision': 'main'}},
                             lambda _: self.fail('invalid revision reached GitHub'))

    def test_delayed_dispatch_preserves_triggering_revision(self):
        result = resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
            'repository': 'owner/Laplace-Engine', 'sha': 'b' * 40}},
            lambda path: {'status': 'ahead'} if '/compare/' in path else {'sha': 'a' * 40})
        self.assertEqual(result, {'native': 'a' * 40, 'postgres': 'a' * 40, 'engine': 'b' * 40, 'mcp': 'a' * 40})

    def test_modular_mcp_dispatch_preserves_triggering_revision(self):
        result = resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
            'repository': 'owner/Laplace-MCP', 'sha': 'c' * 40}},
            lambda path: {'status': 'ahead'} if '/compare/' in path else {'sha': 'a' * 40})
        self.assertEqual(result['mcp'], 'c' * 40)

    def test_untrusted_payloads_fail_before_api_access(self):
        for repo, sha in [('stranger/Laplace-Native', 'b' * 40), ('owner/Laplace-Native', 'main'),
                          ('owner/Laplace-Native', 'a";echo unsafe'), (None, None)]:
            with self.subTest(repo=repo, sha=sha), self.assertRaises(ValueError):
                resolver.resolve('owner', 'repository_dispatch', {'client_payload': {'repository': repo, 'sha': sha}},
                                 lambda _: self.fail('invalid payload reached GitHub'))

    def test_unmerged_revision_rejected(self):
        with self.assertRaisesRegex(ValueError, 'main history'):
            resolver.resolve('owner', 'repository_dispatch', {'client_payload': {
                'repository': 'owner/Laplace-Engine', 'sha': 'b' * 40}},
                lambda path: {'status': 'diverged'} if '/compare/' in path else {'sha': 'a' * 40})


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

    def test_failed_or_skipped_engine_is_rejected(self):
        for conclusion in ('failure', 'skipped', 'timed_out'):
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(ValueError, 'qualification failed'):
                self.qualify(conclusion=conclusion)

    def test_cancelled_engine_run_is_run_again_while_its_revision_is_main(self):
        with self.assertRaises(TimeoutError):
            self.qualify(conclusion='cancelled')
        self.assertEqual(self.mutations, [
            ('/repos/owner/Laplace-Engine/actions/workflows/laplace.yml/dispatches', 'POST', {'ref': 'main'})])

    def test_cancelled_engine_run_of_a_superseded_revision_cannot_qualify(self):
        with self.assertRaisesRegex(ValueError, 'no longer main'):
            self.qualify(conclusion='cancelled', main='b' * 40)
        self.assertEqual(self.mutations, [])

    def test_invalid_workflow_run_without_jobs_is_rejected(self):
        self.run['status'] = 'completed'
        with self.assertRaisesRegex(ValueError, 'qualification failed'):
            self.qualify(conclusion=None)

    def test_other_revision_cannot_qualify_selected_revision(self):
        self.run['head_sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'no longer main'):
            self.qualify(main='b' * 40)

    def test_queued_engine_cannot_qualify_release(self):
        with self.assertRaises(TimeoutError):
            self.qualify(conclusion=None)


if __name__ == '__main__':
    unittest.main()
