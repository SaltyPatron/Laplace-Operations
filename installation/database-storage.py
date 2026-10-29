#!/usr/bin/env python3
"""Retire disconnected Native ingestion loads using the declared local identity."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess


def collect(pgbin, connection, environment, databases=None, prefix=()):
    command = [*prefix, str(Path(pgbin) / ('psql.exe' if os.name == 'nt' else 'psql')),
               '-XwAtq', '-v', 'ON_ERROR_STOP=1', *connection]

    def query(database, sql):
        result = subprocess.run([*command, '-d', database], input=sql, text=True,
                                capture_output=True, env=environment, timeout=60)
        if result.returncode:
            raise ValueError(f'Native stage cleanup failed in {database}: {result.stderr.strip()}')
        return result.stdout.strip()

    if databases is None:
        databases = query('postgres', """SELECT datname FROM pg_catalog.pg_database
WHERE datallowconn AND NOT datistemplate
AND pg_catalog.has_database_privilege(oid,'CONNECT') ORDER BY datname;
""").splitlines()
    # Resolve the installed namespace through extension membership. No schema
    # guesses, search_path changes, client-side row deletion, or table-name sweep.
    sql = """SELECT pg_catalog.format(
 'SELECT coalesce(json_agg(r),''[]''::json) FROM %I.laplace_stage_retire() r',n.nspname)
FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace
JOIN pg_catalog.pg_proc p ON p.pronamespace=n.oid AND p.proname='laplace_stage_retire' AND p.pronargs=0
JOIN pg_catalog.pg_depend d ON d.classid='pg_catalog.pg_proc'::regclass AND d.objid=p.oid
 AND d.refclassid='pg_catalog.pg_extension'::regclass AND d.refobjid=e.oid AND d.deptype='e'
WHERE e.extname='laplace'
\\gexec
"""
    results = []
    for database in databases:
        output = query(database, sql)
        results.append(dict(database=database, status='passed' if output else 'not_installed',
                            loads=json.loads(output) if output else []))
    return results


def collect_declared(config, windows=False):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    environment['PGCONNECT_TIMEOUT'] = '10'
    prefix, databases = [], None
    if windows:
        targets = [target for target in config['targets'] if target.get('authentication') == 'sspi'
                   and target['host'].lower() == socket.gethostname().lower()]
        if len(targets) != 1:
            raise ValueError('Native stage cleanup requires the declared local database host')
        target = targets[0]
        pgbin = Path(target['prefix']) / 'bin'
        connection = ['-h', target['host'], '-p', str(target['port']), '-U', config['role']]
        databases = target['databases']
        environment.update(PGSSLMODE='verify-full', PGREQUIREAUTH='sspi',
                           PGSSLROOTCERT=str(Path(config['state']) / 'hart-desktop-postgresql.crt'),
                           PGPASSFILE=str(Path(config['state']) / 'unused-no-password-file'))
    else:
        if config['host'].lower() != socket.gethostname().lower():
            raise ValueError('Native stage cleanup declaration belongs to another host')
        pgbin = config['pgbin']
        role = (config.get('operator_client') or {}).get('role') or os.environ.get('LAPLACE_ROLE', 'laplace')
        if os.geteuid() == 0:
            prefix, role = ['runuser', '-u', config['pg_os_user'], '--'], config['pg_os_user']
        connection = ['-h', config['socket'], '-p', str(config['port']), '-U', role]
    return collect(pgbin, connection, environment, databases, prefix)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    declarations = parser.add_mutually_exclusive_group(required=True)
    declarations.add_argument('--windows-config', type=Path)
    declarations.add_argument('--modular-config', type=Path)
    args = parser.parse_args()
    config = json.loads((args.windows_config or args.modular_config).read_text(encoding='utf-8-sig'))
    print(json.dumps(collect_declared(config, windows=args.windows_config is not None)))


if __name__ == '__main__':
    main()
