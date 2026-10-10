"""Exercise the real selector's Tier-0 preflight without credentials or a live DB."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("knowledge_sync", ROOT / "secrets/knowledge-sync.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class KnowledgeCompatibility(unittest.TestCase):
    def test_failed_activation_restores_all_configuration_before_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('machine.env', 'api.env', 'pgpass')]
            for path in paths[:2]:
                path.write_text('ORIGINAL=value\n')
                path.chmod(0o600)
            observed = []
            def recover():
                observed.append([p.read_text() if p.exists() else None for p in paths])
            with self.assertRaisesRegex(RuntimeError, 'activation failed'):
                with selector.configuration_transaction(paths, recover):
                    for path in paths:
                        path.write_text('CANDIDATE=value\n')
                    raise RuntimeError('activation failed')
            self.assertEqual(observed, [['ORIGINAL=value\n', 'ORIGINAL=value\n', None]])
            for path in paths[:2]:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_successful_activation_keeps_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'machine.env'
            path.write_text('before')
            with selector.configuration_transaction([path], lambda: self.fail('unexpected recovery')):
                path.write_text('after')
            self.assertEqual(path.read_text(), 'after')

    def test_selection_uses_identity_not_knowledge_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "app").mkdir()
            artifact = root / "tier zero.bin"
            receipt = bytes(range(16))
            artifact.write_bytes(struct.pack("<II", 0x4652504C, 4) + bytes(120) + receipt)
            config = root / "app/laplace-api.env"
            for value in (str(artifact), '"' + str(artifact) + '"'):
                config.write_text("LAPLACE_PERFCACHE_BIN=" + value + "\n")
                before = config.read_bytes(), artifact.read_bytes()
                self.assertEqual(selector.validate_knowledge_receipt(root, receipt.hex()), receipt.hex())
                with self.assertRaisesRegex(ValueError, "incompatible"):
                    selector.validate_knowledge_receipt(root, "ff" * 16)
                self.assertEqual(before, (config.read_bytes(), artifact.read_bytes()))
            artifact.write_bytes(struct.pack("<II", 0x4652504C, 999) + bytes(120) + receipt)
            with self.assertRaisesRegex(ValueError, "Unsupported"):
                selector.validate_knowledge_receipt(root, receipt.hex())


if __name__ == "__main__":
    unittest.main()
