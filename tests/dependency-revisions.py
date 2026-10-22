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


class NativeInputs(unittest.TestCase):
    def request(self, missing=(), expired=False, revision='a' * 40):
        def read(path):
            if '/actions/runs?' in path:
                return {'workflow_runs': [{'id': 7, 'head_sha': revision, 'head_branch': 'main',
                    'path': '.github/workflows/laplace.yml', 'event': 'push'}]}
            if '/jobs?' in path:
                return {'jobs': [{'name': name, 'conclusion': 'failure' if name in missing else 'success'}
                    for name in ('native (icx-release)', 'native (gcc-release)', 'isa')]}
            if '/artifacts?' in path:
                return {'artifacts': [{'name': 'native-prepared-inputs', 'expired': expired}]}
            self.fail('Unexpected endpoint: ' + path)
        return read

    def test_verified_closure_can_be_selected_while_dispatch_finishes(self):
        self.assertEqual(resolver.verified_native_run('owner', 'a' * 40, self.request()), 7)

    def test_each_compiler_and_isa_must_have_passed(self):
        for name in ('native (icx-release)', 'native (gcc-release)', 'isa'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                resolver.verified_native_run('owner', 'a' * 40, self.request(missing=(name,)))

    def test_expired_artifact_is_rejected(self):
        with self.assertRaises(ValueError):
            resolver.verified_native_run('owner', 'a' * 40, self.request(expired=True))

    def test_artifact_from_another_revision_is_rejected(self):
        with self.assertRaises(ValueError):
            resolver.verified_native_run('owner', 'a' * 40, self.request(revision='b' * 40))


if __name__ == '__main__':
    unittest.main()
