"""Exercise peer-role provisioning against a disposable PostgreSQL 18 cluster.

Usage: python3 tests/database-peer.py --pgbin /declared/postgresql/bin
Runs as the ordinary operator; never connects to an installed cluster.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pgbin', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise ValueError('This disposable cluster test must run unprivileged')
    user = pwd.getpwuid(os.geteuid()).pw_name
    with tempfile.TemporaryDirectory(prefix='laplace-peer-') as temporary:
        root = Path(temporary)
        data = root / 'pgdata'
        ctl = [str(args.pgbin / 'pg_ctl'), '-D', str(data)]
        def run(argv, **kwargs):
            result = subprocess.run(argv, text=True, capture_output=True, timeout=45, **kwargs)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return result.stdout.strip()
        run([str(args.pgbin / 'initdb'), '-D', str(data), '--no-locale', '-U', 'fixture_owner', '-A', 'trust'])
        (data / 'pg_hba.conf').write_text('local all fixture_owner peer map=fixture\n')
        (data / 'pg_ident.conf').write_text(f'fixture {user} fixture_owner\n')
        run(ctl + ['-l', str(root / 'postgres.log'), '-o', f"-F -k {root} -c listen_addresses='' -p 35439", '-w', 'start'])
        try:
            sqlargs = [str(args.pgbin / 'psql'), '-XwAt', '-v', 'ON_ERROR_STOP=1', '-h', str(root),
                       '-p', '35439', '-U', 'fixture_owner', '-d', 'postgres', '-f', '-']
            run(sqlargs, input='CREATE SCHEMA app; CREATE TABLE app.tenants(id integer); '
                              'CREATE SCHEMA substrate; CREATE TABLE substrate.facts(id integer); '
                              'INSERT INTO substrate.facts VALUES(1); '
                              'CREATE TABLE substrate.cells(id integer) PARTITION BY HASH (id); '
                              'CREATE TABLE substrate.cells_h0 PARTITION OF substrate.cells FOR VALUES WITH (MODULUS 2, REMAINDER 0); '
                              'INSERT INTO substrate.cells_h0 VALUES(2);')
            config = {'database': 'postgres', 'role': 'fixture_runtime', 'admin_role': 'fixture_owner',
                      'schema_owner': 'fixture_owner', 'peer_user': user, 'lock': str(root / 'host.lock'),
                      'psql': str(args.pgbin / 'psql'), 'admin_socket': str(root), 'port': 35439, 'connection_limit': 2}
            for _ in range(2):
                result = json.loads(run([sys.executable, str(ROOT / 'secrets/database-role.py')], input=json.dumps(config)))
                assert result['authentication'] == 'peer'
            peer = [v if v != 'fixture_owner' else 'fixture_runtime' for v in sqlargs]
            assert run(peer, input='SELECT current_user; SELECT count(*) FROM substrate.facts;') == 'fixture_runtime\n1'
            # Default privileges must cover newly migrated objects too.
            run(sqlargs, input='CREATE TABLE substrate.later(id integer); INSERT INTO substrate.later VALUES(1);')
            assert run(peer, input='SELECT count(*) FROM substrate.later;') == '1'
            # The runtime refreshes the statistics of what it writes: ANALYZE skips, with only a
            # WARNING, a table or partition it may not MAINTAIN (Laplace#1879). A partition created
            # after provisioning is covered by the default privileges.
            run(sqlargs, input='CREATE TABLE substrate.cells_h1 PARTITION OF substrate.cells FOR VALUES WITH (MODULUS 2, REMAINDER 1);')
            analyzed = subprocess.run(peer, input='ANALYZE substrate.cells; ANALYZE substrate.later; ANALYZE substrate.facts;',
                                      text=True, capture_output=True, timeout=15)
            assert analyzed.returncode == 0 and 'WARNING' not in analyzed.stderr, analyzed.stderr
            assert run(sqlargs, input="SELECT reltuples FROM pg_class WHERE relname='cells_h0';") == '1'
            assert run(sqlargs, input="SELECT has_table_privilege('fixture_runtime', 'app.tenants', 'MAINTAIN');") == 'f'
            for statement in ('SELECT * FROM app.tenants;', 'SET ROLE fixture_owner;', 'CREATE TABLE substrate.forbidden(id integer);'):
                result = subprocess.run(peer, input=statement, text=True, capture_output=True, timeout=15)
                assert result.returncode and 'permission denied' in result.stderr, result.stderr
            assert run(sqlargs, input="SELECT rolpassword IS NULL FROM pg_authid WHERE rolname='fixture_runtime';") == 't'
            assert (data / 'pg_ident.runtime.conf').read_text().count('laplace_runtime') == 1
            print('PASS disposable PostgreSQL: peer mapping, idempotence, native SQL reads, future-object grants, MAINTAIN (ANALYZE without a skip) on every table and partition, passwordless role, application/DDL/owner denials')
        finally:
            run(ctl + ['-m', 'immediate', '-w', 'stop'])


if __name__ == '__main__':
    main()
