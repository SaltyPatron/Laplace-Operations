"""Read Windows ACLs after real staging, receipt replacement and blob linking."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('artifacts', ROOT / 'installation/artifact_store.py')
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


@unittest.skipUnless(os.name == 'nt', 'Windows artifact access contract')
class ArtifactAccess(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='laplace-artifact-access-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(['icacls.exe', str(self.root), '/grant', '*S-1-5-11:(OI)(CI)RX', '/Q'],
                       capture_output=True, text=True, check=True)

    def acl(self, path):
        # The additional inherited principal represents the enrolled operator
        # when the creating token instead owns secure tempfiles as Administrators.
        quoted = str(path).replace("'", "''")
        command = "$a=Get-Acl -LiteralPath '" + quoted + "'; " + """
@{protected=$a.AreAccessRulesProtected; inherited_read=@($a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) |
Where-Object {$_.IdentityReference.Value -eq 'S-1-5-11' -and $_.IsInherited -and $_.AccessControlType -eq 'Allow' -and
([int]$_.FileSystemRights -band 1)}).Count}|ConvertTo-Json -Compress
"""
        result = subprocess.run(['pwsh', '-NoProfile', '-Command', command], capture_output=True,
                                text=True, check=True)
        value = json.loads(result.stdout)
        self.assertFalse(value['protected'], (path, value))
        self.assertGreater(value['inherited_read'], 0, (path, value))

    def test_staging_and_descendants_inherit_store_access(self):
        stage = artifacts.staging_directory(self.root, '.publish-')
        payload = stage / 'payload'
        payload.mkdir()
        (payload / 'assembly.dll').write_bytes(b'published output')
        artifacts.atomic(stage / 'artifact.json', {'schema': 'test-artifact'})
        final = self.root / 'published'
        stage.rename(final)
        for path in (final, final / 'payload', final / 'payload/assembly.dll', final / 'artifact.json'):
            self.acl(path)

    def test_atomic_receipt_replacement_keeps_inherited_access(self):
        path = self.root / 'artifact.json'
        for version in (1, 2):
            artifacts.atomic(path, {'version': version})
            self.assertEqual(json.loads(path.read_text()), {'version': version})
            self.acl(path)

    def test_blob_links_keep_parent_access_without_resetting_existing_readers(self):
        source = self.root / 'source.bin'
        source.write_bytes(b'cache payload')
        target = self.root / 'package/tier0.bin'
        store = self.root / 'store'
        digest = artifacts.materialize_file(source, target, store)
        blob = store / 'blobs' / digest[:2] / digest
        self.assertTrue(os.path.samefile(blob, target))
        self.acl(blob)
        self.acl(target)
        subprocess.run(['icacls.exe', str(blob), '/grant', '*S-1-5-20:R', '/Q'],
                       capture_output=True, text=True, check=True)
        before = subprocess.check_output(['icacls.exe', str(blob)], text=True)
        artifacts.materialize_file(source, self.root / 'other/tier0.bin', store)
        self.assertEqual(subprocess.check_output(['icacls.exe', str(blob)], text=True), before)


if __name__ == '__main__':
    unittest.main()
