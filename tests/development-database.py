#!/usr/bin/env python3
"""Failure boundaries before a development bootstrap can touch another database."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('development_database', Path(__file__).resolve().parents[1] / 'development/application-database.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = dict(database='development', role='runtime', owner='schema_owner', admin_role='administrator',
                           password='a' * 64, client_address='100.64.1.2', work=self.directory.name,
                           lock=self.directory.name + '/lock', psql='psql', admin_socket='/socket', port=5432,
                           migrator='/installed/migrator.dll')
        self.calls = []

    def execute(self, response):
        def run(arguments, **kwargs):
            statement = kwargs.get('input', '')
            self.calls.append(statement or arguments[0])
            return subprocess.CompletedProcess(arguments, 0, response(statement), '')
        with patch.object(module.sys, 'stdin', io.StringIO(json.dumps(self.config))), patch.object(module.subprocess, 'run', side_effect=run):
            module.main()

    def test_refuses_an_existing_database_owned_elsewhere_before_any_write(self):
        with self.assertRaisesRegex(ValueError, 'different owner'):
            self.execute(lambda statement: 'unrelated_owner')
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(self.calls[0].startswith('SELECT pg_get_userbyid'))

    def test_refuses_a_privileged_existing_runtime(self):
        def response(statement):
            if 'pg_get_userbyid' in statement: return 'schema_owner'
            if 'rolcanlogin' in statement: return 'f'
            return 't' if "rolname='runtime'" in statement else 'f'
        with self.assertRaisesRegex(ValueError, 'privileged role'):
            self.execute(response)
        self.assertTrue(all(statement.startswith('SELECT') for statement in self.calls))

    def test_does_not_reuse_the_administrator_as_runtime(self):
        self.config['role'] = 'administrator'
        with self.assertRaisesRegex(ValueError, 'different roles'):
            self.execute(lambda statement: self.fail('database boundary was reached'))
        self.assertEqual(self.calls, [])

    def test_invalid_secret_never_reaches_the_database(self):
        self.config['password'] = "invalid'password"
        with self.assertRaisesRegex(ValueError, 'generated application credential'):
            self.execute(lambda statement: self.fail('database boundary was reached'))
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
