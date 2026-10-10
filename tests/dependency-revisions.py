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
        self.assertEqual(result, {'native': 'a' * 40, 'postgres': 'a' * 40, 'engine': 'b' * 40})

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


if __name__ == '__main__':
    unittest.main()
