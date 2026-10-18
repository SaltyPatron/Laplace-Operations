#!/usr/bin/env python3
"""The substrate's writer roles may MAINTAIN what they write (Laplace#1879).

Since PostgreSQL 17, ANALYZE needs MAINTAIN on a table and on every leaf partition. A role
without it is not refused: each table is skipped with only a WARNING, its reltuples stays -1,
and the site reads a seeded database as empty. Both declared provisioning paths grant it on
every non-public substrate schema, for existing tables and (default privileges) future ones.
tests/database-peer.py proves the effect against a disposable PostgreSQL 18 cluster.
"""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class WindowsDevelopment(unittest.TestCase):
    script = (ROOT / 'development/configure-windows.ps1').read_text()

    def test_substrate_role_gets_maintain_outside_public(self):
        self.assertIn("$permissions=if($schema -eq 'public'){'SELECT'}else{'SELECT,INSERT,UPDATE,DELETE,MAINTAIN'}", self.script)
        self.assertIn('GRANT $permissions ON ALL TABLES IN SCHEMA $schema TO $($c.substrate_role)', self.script)

    def test_future_tables_of_every_owner_get_it(self):
        # db-reset creates the extension's tables as postgres, not as the administrator
        owners = self.script.index('$owners=@($c.admin_role)+')
        self.assertRegex(self.script[owners:], r"pg_get_userbyid\(relowner\) FROM pg_class WHERE relnamespace='\$schema'::regnamespace AND relkind IN \('r','p'\)")
        self.assertIn('ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA $schema GRANT $permissions ON TABLES TO $($c.substrate_role)', self.script)
        self.assertIn('$($defaults -join', self.script)
        self.assertIn("if($owner -notmatch '^[a-zA-Z0-9_]+$'){throw", self.script)


class RemoteRuntime(unittest.TestCase):
    def test_grants_maintain_on_substrate_schemas_only(self):
        spec = importlib.util.spec_from_file_location('database_role', ROOT / 'secrets/database-role.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            config = dict(database='substrate', role='runtime', admin_role='administrator', password='a' * 64,
                          client_address='100.64.1.2', lock=directory + '/lock', psql='psql',
                          admin_socket='/socket', port=5432)
            statements = []

            def run(arguments, **kwargs):
                statement = kwargs.get('input', '')
                statements.append(statement)
                if statement.startswith('SHOW hba_file'):
                    return subprocess.CompletedProcess(arguments, 1, '', 'stop after the grants')
                output = 'laplace\npublic' if 'FROM pg_namespace' in statement else ''
                return subprocess.CompletedProcess(arguments, 0, output, '')
            with patch.object(module.sys, 'stdin', io.StringIO(json.dumps(config))), \
                    patch.object(module.subprocess, 'run', side_effect=run), \
                    self.assertRaises(RuntimeError):
                module.main()
        grants = next(s for s in statements if s.startswith('BEGIN'))
        self.assertIn('GRANT pg_read_all_stats, pg_signal_backend TO "runtime"', grants)
        self.assertIn('GRANT SELECT,INSERT,UPDATE,DELETE,MAINTAIN ON ALL TABLES IN SCHEMA "laplace" TO "runtime"', grants)
        self.assertIn('ALTER DEFAULT PRIVILEGES FOR ROLE "administrator" IN SCHEMA "laplace" GRANT SELECT,INSERT,UPDATE,DELETE,MAINTAIN ON TABLES TO "runtime"', grants)
        self.assertIn('GRANT SELECT ON ALL TABLES IN SCHEMA "public" TO "runtime"', grants)
        self.assertNotRegex(grants, r'MAINTAIN[^;]*"public"')


if __name__ == '__main__':
    unittest.main()
