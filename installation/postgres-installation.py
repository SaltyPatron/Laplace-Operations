#!/usr/bin/env python3
"""Consolidate a custom PostgreSQL host without creating, dropping or restarting a cluster."""
import argparse
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(argv):
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL='C'), timeout=120)
    if result.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout.strip()


def machine(path):
    spec = importlib.util.spec_from_file_location('machine_env', ROOT / 'machine-env.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.resolve(path, {}, explicit=True)


def packages():
    result = subprocess.run(['dpkg-query', '-W', '-f=${Package}\t${db:Status-Status}\n', 'postgresql*'],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot inventory PostgreSQL packages')
    return sorted(line.split('\t')[0] for line in result.stdout.splitlines()
                  if line.endswith('\tinstalled'))


def proposal(selected):
    if not selected:
        return []
    output = run(['apt-get', '-s', '--no-auto-remove', 'remove', *selected])
    removed = sorted(re.findall(r'^Remv ([^ :]+)', output, re.M))
    if removed != selected or re.search(r'^Inst ', output, re.M):
        raise ValueError('Package resolver would change dependencies outside the selected PostgreSQL packages')
    return removed


def inspect(config):
    prefix = Path(config['LAPLACE_PG_DIR']).resolve(strict=True)
    pgbin = prefix / 'bin'
    if prefix.is_relative_to('/usr/lib/postgresql'):
        raise ValueError('This host still selects a distribution PostgreSQL; install and qualify its custom build first')
    if Path(run([pgbin / 'pg_config', '--bindir'])).resolve() != pgbin:
        raise ValueError('pg_config does not belong to the declared PostgreSQL installation')
    version = run([pgbin / 'postgres', '--version'])
    expected = next(line.split('\t')[1] for line in (ROOT / 'dependencies.tsv').read_text().splitlines()
                    if line.startswith('postgresql\t'))
    if version != 'postgres (PostgreSQL) ' + expected:
        raise ValueError('Custom PostgreSQL differs from the pinned dependency version: ' + expected)
    selected = packages()
    commands = sorted(path.name for path in pgbin.iterdir() if path.is_file() and os.access(path, os.X_OK))
    for name in commands:
        alias = Path('/usr/local/bin') / name
        if alias.exists() and alias.resolve() != pgbin / name:
            raise ValueError('An existing command has another owner: ' + str(alias))
    if shutil.which('pg_lsclusters') and run(['pg_lsclusters', '-h']):
        raise ValueError('A distribution-managed cluster remains configured; adopt it before removing its binaries')
    service = config['LAPLACE_PGSERVICE'] + '.service'
    run(['systemctl', 'is-active', '--quiet', service])
    start = run(['systemctl', 'show', service, '-p', 'ExecStart', '--value'])
    if f'path={pgbin / "postgres"} ;' not in start:
        raise ValueError('The selected service does not start the declared PostgreSQL executable')
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if (process / 'comm').read_text().strip() == 'postgres':
                executable = (process / 'exe').resolve(strict=True)
                if executable != pgbin / 'postgres':
                    raise ValueError('Another PostgreSQL executable is running: ' + str(executable))
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            if os.geteuid() == 0:
                raise
    # Environment values and passwords are never included in the result.
    for path in Path('/etc/systemd/system').rglob('*'):
        if path.is_file() and path.suffix in ('.service', '.conf'):
            try:
                content = path.read_text()
            except PermissionError:
                if os.geteuid() == 0:
                    raise
                continue
            if re.search(r'/usr/lib/postgresql/|/usr/bin/(?:psql|pg_config|pg_dump|pg_restore|pg_ctl|initdb)\b|pg_ctlcluster', content):
                raise ValueError('Installed service still selects distribution tools: ' + str(path))
    for path in prefix.rglob('*'):
        if path.is_symlink() and path.resolve().is_relative_to('/usr/lib/postgresql'):
            raise ValueError('Custom installation still depends on a distribution file: ' + str(path))
    connection = [pgbin / 'psql', '-X', '-w', '-v', 'ON_ERROR_STOP=1', '-At',
                  '-h', config.get('LAPLACE_PGSOCKET', '/tmp'), '-p', config['LAPLACE_PGPORT']]
    if os.geteuid() == 0:
        connection = ['runuser', '-u', config['LAPLACE_PGUSER'], '--', *connection]
    else:
        connection += ['-U', config['LAPLACE_ROLE']]

    def sql(database, statement):
        return run([*connection, '-d', database, '-c', statement])

    data = sql('postgres', 'SHOW data_directory')
    if Path(data).resolve() != Path(config['LAPLACE_PGDATA']).resolve():
        raise ValueError('The connected server uses a different data directory')
    databases = json.loads(sql('postgres', "SELECT json_agg(datname ORDER BY datname) FROM pg_database WHERE datallowconn"))
    extensions = {}
    for database in databases:
        if sql(database, "SELECT DISTINCT probin FROM pg_proc WHERE probin LIKE '/usr/lib/postgresql/%'"):
            raise ValueError('Database functions still load distribution PostgreSQL modules: ' + database)
        extensions[database] = sql(database, "SELECT extname || ':' || extversion FROM pg_extension ORDER BY extname")
    return {'host': os.uname().nodename, 'prefix': str(prefix), 'version': version,
            'process_ownership_check': 'verified' if os.geteuid() == 0 else 'requires_root_readback',
            'service': service, 'pid': run(['systemctl', 'show', service, '-p', 'MainPID', '--value']),
            'data': data, 'databases': databases, 'extensions': extensions, 'commands': commands,
            'remove_packages': proposal(selected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--machine', type=Path, default=Path(os.environ.get('LAPLACE_MACHINE_ENV', '/etc/laplace/machine.env')))
    parser.add_argument('--check', action='store_true', help='Inspect the real host and print the exact removal proposal')
    args = parser.parse_args()
    config = machine(args.machine)
    if args.check:
        print(json.dumps(inspect(config), indent=2))
        return
    if os.geteuid() != 0:
        raise ValueError('Consolidation requires sudo ./setup.sh postgres; --check needs no elevation')
    with (Path(config['LAPLACE_LOCKS']) / 'host-resource.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = inspect(config)
        directory = Path(config['LAPLACE_WORK']) / 'logs/postgres-installation'
        directory.mkdir(parents=True, exist_ok=True)
        receipt = directory / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json')
        result = {'before': before, 'status': 'started'}
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        try:
            for name in before['commands']:
                alias = Path('/usr/local/bin') / name
                if not alias.is_symlink():
                    alias.symlink_to(Path(before['prefix']) / 'bin' / name)
            if before['remove_packages']:
                # Remove packages, never purge or autoremove. Their retained configuration
                # and database directories are outside this operation's deletion scope.
                subprocess.run(['apt-get', '-y', '--no-auto-remove', 'remove', *before['remove_packages']],
                               env=dict(os.environ, DEBIAN_FRONTEND='noninteractive'), check=True)
            after = inspect(config)
            if after['remove_packages'] or any(before[k] != after[k] for k in ('prefix', 'pid', 'data', 'databases', 'extensions')):
                raise RuntimeError('PostgreSQL installation or live database state changed unexpectedly')
            result.update(status='passed', after=after)
        except Exception as error:
            result.update(status='failed', error=str(error))
            raise
        finally:
            receipt.write_text(json.dumps(result, indent=2) + '\n')
            print('PostgreSQL consolidation receipt: ' + str(receipt))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('PostgreSQL consolidation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
