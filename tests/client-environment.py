"""Verify MCP search configuration survives the operator identity boundary."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('client', ROOT / 'installation/client.py')
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ClientEnvironment(unittest.TestCase):
    def test_search_settings_survive_without_overriding_the_selected_runtime(self):
        search = {
            'LAPLACE_CODE_SOURCE': 'Laplace Workspace',
            'LAPLACE_CODE_HUB': '2048',
            'LAPLACE_CODE_NODES': '200000',
            'LAPLACE_CODE_BRIDGE': '1',
            'LAPLACE_CODE_INGEST': 'workspace-code',
        }
        inherited = dict(search, LAPLACE_CONNINFO='wrong database',
                         LAPLACE_TIER0='/wrong/tier0.bin', LAPLACE_UNKNOWN='discard',
                         PATH='/usr/bin')
        selected = {'LAPLACE_CONNINFO': 'selected database', 'LAPLACE_TIER0': '/selected/tier0.bin'}
        with patch.dict(os.environ, inherited, clear=True):
            actual = client.process_environment(selected)
        for key, value in {**search, **selected, 'PATH': '/usr/bin'}.items():
            self.assertEqual(actual[key], value)
        self.assertNotIn('LAPLACE_UNKNOWN', actual)

    def test_sspi_still_removes_inherited_postgres_credentials(self):
        inherited = {'PGPASSWORD': 'wrong-password', 'PGUSER': 'wrong-user',
                     'LAPLACE_CODE_SOURCE': 'Laplace Workspace'}
        with patch.dict(os.environ, inherited, clear=True):
            actual = client.process_environment({'LAPLACE_DATABASE_AUTHENTICATION': 'sspi'})
        self.assertEqual(actual['LAPLACE_CODE_SOURCE'], inherited['LAPLACE_CODE_SOURCE'])
        self.assertFalse(any(key.upper().startswith('PG') for key in actual))


if __name__ == '__main__':
    unittest.main()
