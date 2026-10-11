#!/usr/bin/env python3
"""Install the declared development app database without granting runtime DDL."""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    config = json.load(sys.stdin)
    database, role, owner = (config[name] for name in ('database', 'role', 'owner'))
    if not all(re.fullmatch(r'[a-z][a-z0-9_-]*', name) for name in (database, role, owner, config['admin_role'])):
        raise ValueError('Invalid database or role name')
    if len({role, owner, config['admin_role']}) != 3:
        raise ValueError('Runtime, owner and administrator must be different roles')
    if not re.fullmatch('[0-9a-f]{64}', config['password']):
        raise ValueError('Expected generated application credential')
    client = ipaddress.ip_address(config['client_address'])
    work = Path(config['work'])
    work.mkdir(parents=True, exist_ok=True)
    lock = open(config['lock'], 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install(config, work)
    finally:
        lock.close()


def install(config, work):
    database, role, owner = (config[name] for name in ('database', 'role', 'owner'))
    client = ipaddress.ip_address(config['client_address'])
    arguments = [config['psql'], '-X', '-w', '-v', 'ON_ERROR_STOP=1', '-At',
                 '-h', config['admin_socket'], '-p', str(int(config['port'])), '-U', config['admin_role']]

    def sql(statement, target='postgres'):
        result = subprocess.run(arguments + ['-d', target], input=statement, text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError('Application database provisioning failed; inspect the database server log')
        return result.stdout.strip()

    existing_owner = sql('SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=' + literal(database))
    if existing_owner and existing_owner != owner:
        raise ValueError('Existing application database has a different owner; refusing to repurpose it')
    for name, login in ((owner, False), (role, True)):
        existing = sql('SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls '
                       'FROM pg_roles WHERE rolname=' + literal(name))
        if existing == 't':
            raise ValueError('Refusing an existing privileged role')
        if not existing:
            sql(f'CREATE ROLE "{name}" ' + ('LOGIN PASSWORD ' + literal(config['password']) if login else 'NOLOGIN') +
                ' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS')
        if not login and sql('SELECT rolcanlogin FROM pg_roles WHERE rolname=' + literal(name)) != 'f':
            raise ValueError('Application owner must not be a login')
    if not existing_owner:
        sql(f'CREATE DATABASE "{database}" OWNER "{owner}"')
    sql(f'REVOKE CONNECT ON DATABASE "{database}" FROM PUBLIC; GRANT CONNECT ON DATABASE "{database}" TO "{role}"')

    # The authenticated local deployment identity assumes the non-login schema
    # owner only for migration. Its privileges never enter the API's environment.
    environment = dict(os.environ)
    environment['LAPLACE_APP_DB'] = (f"Host={config['admin_socket']};Port={config['port']};"
        f"Username={config['admin_role']};Database={database};Options=-c role={owner}")
    environment['LAPLACE_OPS_LOG_DIR'] = str(work / 'logs')
    migration = subprocess.run(['dotnet', config['migrator'], 'app-up'], env=environment,
                               capture_output=True, text=True, timeout=120)
    (work / 'migration.log').write_text(migration.stdout + migration.stderr)
    if migration.returncode:
        raise RuntimeError('Application migration failed; inspect ' + str(work / 'migration.log'))
    sql(f'GRANT USAGE ON SCHEMA app TO "{role}"; '
        f'GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA app TO "{role}"; '
        f'GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA app TO "{role}"; '
        f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner}" IN SCHEMA app GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO "{role}"; '
        f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner}" IN SCHEMA app GRANT USAGE,SELECT ON SEQUENCES TO "{role}";', database)

    hba = Path(sql('SHOW hba_file'))
    remote = hba.with_name('pg_hba.remote.conf')
    original = json.loads(sql('SELECT to_json(pg_read_file(' + literal(str(hba)) + '))'))
    previous = json.loads(sql('SELECT to_json(COALESCE(pg_read_file(' + literal(str(remote)) + ',0,1048576,true),\'\'))'))
    rule = f'hostssl {database} {role} {client}/{client.max_prefixlen} scram-sha-256'
    updated = previous if rule in previous.splitlines() else previous.rstrip() + '\n' + rule + '\n'
    include = 'include_if_exists pg_hba.remote.conf'

    def write(path, content):
        if '\\' in content or '\x00' in content:
            raise ValueError('HBA escaping requires an explicit administrator update')
        sql('COPY (SELECT unnest(string_to_array(' + literal(content.rstrip('\n')) + ", E'\\n'))) TO " + literal(str(path)))

    try:
        if updated != previous:
            write(remote, updated)
        if include not in original.splitlines():
            write(hba, include + '\n' + original)
        if sql('SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL') != '0':
            raise ValueError('Generated HBA did not validate')
        if sql('SELECT pg_reload_conf()') != 't':
            raise ValueError('Configuration reload failed')
    except BaseException:
        write(remote, previous)
        write(hba, original)
        sql('SELECT pg_reload_conf()')
        raise
    print(json.dumps({'database': database, 'runtime_role': role, 'owner': owner, 'client': str(client),
                      'runtime_superuser': False, 'runtime_owns_schema': False, 'migrations': 'passed'}))


if __name__ == '__main__':
    main()
