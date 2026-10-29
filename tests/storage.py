#!/usr/bin/env python3
"""Exercise actual POSIX collection with private output trees and real locks."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('storage', Path(__file__).resolve().parents[1] / 'installation/storage.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


@unittest.skipIf(os.name == 'nt', 'POSIX filesystem and flock contract')
class Storage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='laplace-storage-')
        self.root = Path(self.temporary.name)
        self.work, self.build, self.source = [self.root / part for part in ('work', 'build', 'source')]
        self.site = self.work / 'mono-site'
        self.prefix = self.root / 'runtime'
        self.config = dict(prefix=str(self.prefix))
        self.environment = patch.dict(os.environ, {'GITHUB_WORKSPACE': str(self.source / 'Laplace'), 'LAPLACE_HOST_LOCK_WAIT_SECONDS': '0'})
        self.environment.start()
        for path in (self.site, self.build, self.source, self.prefix / 'releases'):
            path.mkdir(parents=True)
        self.active, self.held, self.rollback, self.old = [self.release(letter, time) for letter, time in zip('abcd', (4, 3, 2, 1))]
        (self.prefix / 'current').symlink_to(self.active)

    def tearDown(self):
        self.temporary.cleanup()
        self.environment.stop()

    def release(self, letter, time):
        path = self.prefix / 'releases' / (letter * 64)
        path.mkdir()
        (path / 'package.json').write_text(json.dumps({'schema': 'laplace.modular-package/v1', 'files': {'test': 'hash'}}))
        (path / 'test').write_text('payload')
        os.utime(path, (time, time))
        return path

    def plan(self, **kwargs):
        return storage.plan(self.work, self.build, self.source, self.site, self.config,
                            references={self.held / 'test'}, **kwargs)

    def test_liveness_rollback_real_collection_and_idempotence(self):
        state = storage.collect(self.plan())
        self.assertEqual(state['removed'], [str(self.old)])
        for path in (self.active, self.held, self.rollback):
            self.assertTrue(path.exists())
        self.assertEqual(storage.collect(self.plan())['removed'], [])

    def test_unknown_visibility_retains_native_releases(self):
        self.assertFalse(any(entry['retire'] for entry in self.plan(unknown=True)['entries']))

    def test_native_resources_share_immutable_blobs_and_orphans_follow_release_retirement(self):
        import hashlib
        import fcntl
        store = self.prefix / 'assets'
        def blob(payload):
            identity = hashlib.sha256(payload).hexdigest()
            path = store / 'blobs' / identity[:2] / identity
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            return path
        shared, expired = blob(b'shared grammar'), blob(b'expired cache')
        os.link(shared, self.active / 'grammar.so')
        os.link(shared, self.old / 'grammar.so')
        os.link(expired, self.old / 'highway.bin')
        # Adding the payload changes directory mtime; this remains the oldest release.
        os.utime(self.old, (1, 1))
        with (store / '.build.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            storage.collect(self.plan())
            self.assertTrue(expired.exists(), 'A publisher lost its unlinked blob')
        state = storage.collect(self.plan())
        self.assertFalse(expired.exists())
        self.assertIn(str(expired), state['removed'])
        self.assertTrue(os.path.samefile(shared, self.active / 'grammar.so'))
        self.assertEqual(storage.collect(self.plan())['removed'], [])

    def leased_releases(self):
        for path in (self.active, self.held, self.rollback, self.old):
            times = path.stat()
            receipt = json.loads((path / 'package.json').read_text())
            receipt.update(runtime_lease='flock-v1')
            receipt['files']['.runtime-lease'] = 'empty-file'
            (path / 'package.json').write_text(json.dumps(receipt))
            (path / '.runtime-lease').touch()
            os.utime(path, ns=(times.st_atime_ns, times.st_mtime_ns))

    def test_runtime_lease_protects_a_client_started_after_the_audit(self):
        import fcntl
        self.leased_releases()
        state = self.plan(unknown=True)
        with (self.old / '.runtime-lease').open() as lease:
            fcntl.flock(lease, fcntl.LOCK_SH)
            self.assertEqual(storage.collect(state)['removed'], [])
            self.assertTrue(self.old.exists())
            self.assertIn('live_runtime_lease', next(e for e in state['entries'] if e['path'] == str(self.old))['reasons'])
        self.assertEqual(storage.collect(self.plan(unknown=True))['removed'], [str(self.old)])

    def test_runtime_lease_does_not_hide_unobservable_database_cache_references(self):
        self.leased_releases()
        self.assertFalse(any(e['retire'] for e in self.plan(unknown=True, cache_unknown=True)['entries']))

    def test_explicit_replacement_retires_legacy_releases_but_preserves_selected_and_known_references(self):
        state = self.plan(unknown=True, replace_unselected=True)
        self.assertEqual(set(storage.collect(state)['removed']), {str(self.old), str(self.rollback)})
        self.assertTrue(self.active.exists())
        self.assertTrue(self.held.exists())

    def test_job_work_waits_for_consumers_and_preserves_recovery(self):
        for name in ('stage', 'bundle'):
            (self.site / name).mkdir()
        self.assertFalse(any(entry['kind'] == 'delivery_work' for entry in self.plan()['entries']))
        pending = self.source / 'Laplace/build/.api-publish-backup'
        pending.parent.mkdir(parents=True)
        pending.write_text('unresolved')
        state = self.plan(finish_job=True)
        self.assertTrue(state['recovery_pending'])
        self.assertTrue(all(not entry['retire'] for entry in state['entries'] if entry['kind'] == 'delivery_work'))
        pending.unlink()
        storage.collect(self.plan(finish_job=True))
        self.assertFalse((self.site / 'stage').exists())

    def test_symlink_and_source_boundaries_are_checked_before_any_delete(self):
        (self.old / 'outside').symlink_to(self.root / 'outside')
        (self.old / '.git').mkdir()
        os.utime(self.old, (1, 1))
        with self.assertRaisesRegex(ValueError, 'source checkout'):
            storage.collect(self.plan())
        self.assertTrue(self.old.exists())
        with self.assertRaisesRegex(ValueError, 'escaped'):
            storage.validate_tree(self.old, self.work)

    def test_nested_symlinks_are_unlinked_without_following(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('kept')
        (self.old / 'link').symlink_to(outside)
        os.utime(self.old, (1, 1))
        storage.collect(self.plan())
        self.assertTrue((outside / 'keep').is_file())

    def test_exclusive_host_lock_cannot_be_bypassed(self):
        with storage.host_lock(self.work / 'locks/host-resource.lock'):
            with self.assertRaises(BlockingIOError):
                with storage.host_lock(self.work / 'locks/host-resource.lock'):
                    self.fail('competing cleanup acquired a held lock')

    def test_another_ci_run_owns_its_staging_between_steps(self):
        (self.site / 'stage').mkdir()
        (self.site / '.delivery-owner.json').write_text(json.dumps({'repository': 'owner/repo', 'run': '123'}))
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '456', 'GH_TOKEN': '', 'GITHUB_TOKEN': ''}):
            state = self.plan(finish_job=True)
            self.assertTrue(state['delivery_held'])
            self.assertFalse(next(entry for entry in state['entries'] if entry['kind'] == 'delivery_work')['retire'])
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '123'}):
            state = self.plan(finish_job=True)
            self.assertTrue(next(entry for entry in state['entries'] if entry['kind'] == 'delivery_work')['retire'])

    def test_new_delivery_cannot_take_ownership_of_pending_recovery(self):
        owner = self.site / '.delivery-owner.json'
        original = json.dumps({'repository': 'owner/repo', 'run': '1'})
        owner.write_text(original)
        marker = self.source / 'Laplace/build/.api-publish-backup'
        marker.parent.mkdir(parents=True)
        marker.write_text('recovery')
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '2'}):
            with self.assertRaisesRegex(ValueError, 'Recovery is pending'):
                storage.begin_delivery(self.site, self.source)
        self.assertEqual(owner.read_text(), original)

    def test_unrelated_repositories_do_not_gate_laplace_cleanup(self):
        (self.source / 'Hart.NBA/.git').mkdir(parents=True)
        self.assertEqual(storage.collect(self.plan())['removed'], [str(self.old)])

    def test_unobservable_registry_protects_builds_without_blocking_other_owners(self):
        (self.source / 'Laplace-Archive/.git').mkdir(parents=True)
        build = self.build / 'worktrees/wt-repair-0123456789ab'
        build.mkdir(parents=True)
        state = self.plan()
        self.assertFalse(next(entry for entry in state['entries'] if entry['kind'] == 'abandoned_build')['retire'])
        self.assertEqual(storage.collect(state)['removed'], [str(self.old)])
        self.assertTrue(build.exists())


if __name__ == '__main__':
    unittest.main()
