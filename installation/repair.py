#!/usr/bin/env python3
"""Repair a declared existing host and check backups without changing serving databases."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import stat
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def checked(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, **kwargs)
    if result.returncode:
        # Commands can include database diagnostics or secret-store output.
        raise RuntimeError(f'{Path(argv[0]).name} failed (exit {result.returncode}); no success receipt issued')
    return result.stdout


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def storage_report(config):
    """Measure the existing host's allocated storage without reading file contents."""
    if socket.gethostname().split('.')[0].lower() != config['host']:
        raise ValueError('The installation declaration belongs to another host')
    if os.geteuid() != 0:
        raise ValueError('Use sudo ./setup.sh repair --storage-report to include protected files and open deleted files')
    roots = [Path(path) for path in config['storage_report_roots']]
    for path in roots:
        if not path.is_absolute() or '..' in path.parts or not path.is_dir():
            raise ValueError('Storage report roots must be existing absolute directories')
    result = {'host': config['host'], 'observed_utc': datetime.now(timezone.utc).isoformat(),
              'scope': 'allocated storage and open-file metadata; no contents, deletion or service changes',
              'roots': {}, 'status': 'complete'}
    for path in roots:
        usage = shutil.disk_usage(path)
        measurements = {}
        commands = {
            'filesystem': ['findmnt', '--json', '--target', str(path), '--output', 'TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE%'],
            'directory_bytes': ['du', '--one-file-system', '--block-size=1', '--max-depth=2', str(path)],
            'large_files': ['find', str(path), '-xdev', '-type', 'f', '-size', '+256M', '-printf', '%b\t%s\t%u\t%g\t%p\n'],
        }
        for name, command in commands.items():
            try:
                observed = subprocess.run(command, capture_output=True, text=True, timeout=180)
                measurements[name] = {'exit': observed.returncode, 'output': observed.stdout, 'errors': observed.stderr}
                if observed.returncode:
                    result['status'] = 'incomplete'
            except subprocess.TimeoutExpired:
                measurements[name] = {'error': 'measurement exceeded 180 seconds'}
                result['status'] = 'incomplete'
        result['roots'][str(path)] = {'total_bytes': usage.total, 'used_bytes': usage.used,
                                     'free_bytes': usage.free, **measurements}
    # lsof's field output contains process names, file sizes and paths, not arguments or file contents.
    try:
        deleted = subprocess.run(['lsof', '-nP', '+L1', '-Fpcfns'], capture_output=True, text=True, timeout=60)
        result['unlinked_open_files'] = {'exit': deleted.returncode, 'output': deleted.stdout, 'errors': deleted.stderr}
        if deleted.returncode not in (0, 1) or (deleted.returncode == 1 and deleted.stderr):
            result['status'] = 'incomplete'
    except (OSError, subprocess.TimeoutExpired) as error:
        result['unlinked_open_files'] = {'error': str(error)}
        result['status'] = 'incomplete'
    directory = Path(config['machine']['LAPLACE_WORK']) / 'logs/storage'
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8] + '.json')
    with target.open('x') as stream:
        os.chmod(target, 0o600)
        stream.write(json.dumps(result, indent=2) + '\n')
    if os.environ.get('SUDO_UID', '').isdigit():
        os.chown(target, int(os.environ['SUDO_UID']), -1)
    print('Storage metadata report (' + result['status'] + '): ' + str(target), flush=True)
    if result['status'] != 'complete':
        raise ValueError('Some storage measurements failed; inspect the saved report')


def archive_rotated_log(config, source, destination, check=False):
    """Move an explicitly selected closed rotation after durable, exact copying."""
    if config['host'] != socket.gethostname().split('.')[0].lower():
        raise ValueError('Repair declaration belongs to another host')
    source = source.absolute()
    if (source.is_symlink() or not source.resolve().is_relative_to(Path('/var/log'))
            or not re.fullmatch(r'.+\.\d+(?:\.gz)?', source.name)):
        raise ValueError('Select a closed, numbered log rotation under /var/log')
    before = source.stat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError('Selected rotation is not a regular file')
    if destination is None:
        declared = config.get('log_archive_directory')
        if not declared:
            raise ValueError('Declare log_archive_directory for this host or pass --archive-directory')
        destination = Path(declared)
    if not destination.is_absolute() or '..' in destination.parts or destination == Path('/'):
        raise ValueError('Declare an absolute log archive directory')
    ancestor = destination
    while not ancestor.exists():
        ancestor = ancestor.parent
    if ancestor.stat().st_dev == before.st_dev:
        raise ValueError('The log archive must have space on a different filesystem')
    if shutil.disk_usage(ancestor).free < before.st_size + 1024 ** 3:
        raise ValueError('Log archive does not have space for the selected rotation and 1 GiB reserve')
    result = {'source': str(source), 'archive_directory': str(destination), 'bytes': before.st_size}
    if check:
        return {**result, 'preflight': 'passed', 'archived': False}
    if os.geteuid() != 0:
        raise ValueError('Log storage repair requires sudo ./setup.sh repair --archive-rotated-log PATH')
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.is_symlink() or destination.stat().st_uid != 0 or destination.stat().st_mode & 0o022:
        raise ValueError('Log archive directory must be root-owned, not a symlink, and not writable by other users')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    target = destination / (source.name + '.' + stamp)
    with source.open('rb') as incoming, target.open('xb') as outgoing:
        os.chmod(target, 0o600)
        expected = hashlib.sha256()
        for chunk in iter(lambda: incoming.read(8 * 1024 * 1024), b''):
            expected.update(chunk)
            outgoing.write(chunk)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    after = source.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError('Rotation changed during copying; original preserved')
    if digest(target) != expected.hexdigest():
        raise ValueError('Archived bytes differ; original preserved')
    result.update(archive=str(target), sha256=expected.hexdigest(), archived=True)
    receipt = destination / (stamp + '.json')
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    receipt.chmod(0o600)
    # The copy and its receipt survive a crash before the original is unlinked.
    with receipt.open('rb') as stream:
        os.fsync(stream.fileno())
    directory = os.open(destination, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    current = source.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (current.st_ino, current.st_size, current.st_mtime_ns):
        raise ValueError('Rotation changed during archive verification; original preserved')
    source.unlink()
    result['source_filesystem_free_bytes'] = shutil.disk_usage(source.parent).free
    return result


def checked_archive(directory, database):
    candidates = [p for p in directory.glob('*.dump') if '-' + database + '-' in p.name and not p.is_symlink()]
    if not candidates:
        raise ValueError('No application backup in the declared landing directory')
    archive = max(candidates, key=lambda p: p.stat().st_mtime_ns)
    actual = digest(archive)
    checksum = Path(str(archive) + '.sha256')
    if checksum.is_symlink() or checksum.read_text().split()[0] != actual:
        raise ValueError('Landed application backup checksum mismatch')
    return archive, actual


def machine_text(path, declarations):
    parser = load_module('machine_env', ROOT / 'machine-env.py')
    current = parser.resolve(path, {}, explicit=False)
    for key, value in declarations.items():
        if not re.fullmatch(r'LAPLACE_[A-Z0-9_]+', key) or not isinstance(value, str) or '\n' in value:
            raise ValueError('Invalid public machine declaration')
        if key in current and current[key] != value:
            raise ValueError(f'Existing {key} differs from the selected installation; refusing to overwrite it')
    text = path.read_text() if path.exists() else '# Public installation declaration; secrets remain in their private stores.\n'
    missing = {k: v for k, v in declarations.items() if k not in current}
    return text.rstrip() + '\n' + ''.join(k + '=' + shlex.quote(v) + '\n' for k, v in missing.items())


def preflight(config):
    if socket.gethostname().split('.')[0].lower() != config['host']:
        raise ValueError('The installation declaration belongs to another host')
    machine = config['machine']
    for key in ('LAPLACE_SRC', 'LAPLACE_BUILD', 'LAPLACE_WORK', 'LAPLACE_DEPS', 'LAPLACE_DATA',
                'LAPLACE_INSTALL_PREFIX', 'LAPLACE_PG_DIR', 'LAPLACE_LOCKS'):
        path = Path(machine[key])
        if not path.is_absolute() or not path.is_dir():
            raise ValueError(f'{key} must name an existing absolute directory')
    for path in config['required_mounts']:
        checked(['mountpoint', '-q', path], timeout=10)
    for service in config['required_services']:
        checked(['systemctl', 'is-active', '--quiet', service], timeout=10)
    for tool in ('psql', 'pg_restore'):
        checked([str(Path(machine['LAPLACE_PG_DIR']) / 'bin' / tool), '--version'], timeout=10)
    return machine_text(Path(config['machine_file']), machine)


def restore_landing(config):
    machine, backup = config['machine'], config['backup']
    archive, checksum = checked_archive(Path(backup['landing']), backup['source_database'])
    database = 'laplace_repair_' + uuid.uuid4().hex
    common = ['runuser', '-u', machine['LAPLACE_PGUSER'], '--']
    pgbin = Path(machine['LAPLACE_PG_DIR']) / 'bin'
    connection = ['-h', backup['pgsocket'], '-p', machine['LAPLACE_PGPORT']]

    def sql(statement, target='postgres'):
        return checked(common + [str(pgbin / 'psql'), '-XwAt', '-v', 'ON_ERROR_STOP=1',
            *connection, '-d', target, '-f', '-'], input=statement, text=True, timeout=60).strip()

    if Path(sql('SHOW data_directory')).resolve() != Path(machine['LAPLACE_PGDATA']).resolve():
        raise ValueError('Connected PostgreSQL data directory differs from this installation')
    created = False
    try:
        sql(f'CREATE DATABASE "{database}" TEMPLATE template0;')
        created = True
        sql(f'REVOKE ALL ON DATABASE "{database}" FROM PUBLIC;')
        with archive.open('rb') as stream:
            checked(common + [str(pgbin / 'pg_restore'), '-w', *connection, '-d', database,
                '--no-owner', '--no-acl', '--exit-on-error', '--single-transaction'], stdin=stream, timeout=300)
        tables = int(sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='app'", database))
        if not tables:
            raise ValueError('Restored application schema contains no tables')
        rows = json.loads(sql("SELECT json_build_object('tenants',(SELECT count(*) FROM app.tenants),"
                              "'users',(SELECT count(*) FROM app.users))", database))
        if digest(archive) != checksum:
            raise ValueError('Landed backup changed during the restore rehearsal')
        return {'archive': str(archive), 'sha256': checksum, 'app_tables': tables, 'rows': rows,
                'restored_database_removed': True, 'scope': 'database restore and SQL reads; API recovery is a separate check'}
    finally:
        if created:
            # Only the freshly created UUID database is eligible for removal.
            sql(f'DROP DATABASE "{database}" WITH (FORCE);')


def restore_vaultwarden(directory):
    archives = list((directory / 'vaultwarden').glob('vw-*.tar.gz'))
    if not archives:
        raise ValueError('No Vaultwarden backup available')
    archive = max(archives, key=lambda p: p.stat().st_mtime_ns)
    with tempfile.TemporaryDirectory(prefix='.restore-', dir=directory) as temporary:
        database = Path(temporary) / 'db.sqlite3'
        with tarfile.open(archive, 'r:gz') as tar:
            members = [m for m in tar.getmembers() if m.name in ('db.sqlite3', './db.sqlite3')]
            if len(members) != 1 or not members[0].isfile():
                raise ValueError('Vaultwarden archive must contain one regular database file')
            with tar.extractfile(members[0]) as source, database.open('wb') as target:
                import shutil
                shutil.copyfileobj(source, target)
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as connection:
            if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                raise ValueError('Restored Vaultwarden database failed its integrity check')
            tables = connection.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
            if not tables:
                raise ValueError('Restored Vaultwarden database has no tables')
        return {'archive': str(archive), 'sha256': digest(archive), 'sqlite_integrity': 'ok', 'tables': tables,
                'scope': 'extracted SQLite integrity; full Vaultwarden and OpenBao recovery remain separate'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', type=Path)
    parser.add_argument('--check', action='store_true', help='Unprivileged installed-host preflight; makes no changes')
    parser.add_argument('--storage-report', action='store_true', help='Save allocated-space and open-file metadata from declared existing volumes; no deletion or service changes')
    parser.add_argument('--archive-rotated-log', type=Path, help='Preserve one explicitly selected closed log rotation on another filesystem to recover space')
    parser.add_argument('--archive-directory', type=Path, help='Log archive destination; defaults to this host declaration\'s log_archive_directory')
    args = parser.parse_args()
    declaration = args.installation or Path(__file__).with_name(socket.gethostname().split('.')[0].lower() + '.json')
    config = json.loads(declaration.read_text())
    if args.storage_report:
        if args.check or args.archive_rotated_log or args.archive_directory:
            parser.error('--storage-report cannot be combined with repair or archive options')
        storage_report(config)
        return
    if args.archive_rotated_log:
        print(json.dumps(archive_rotated_log(config, args.archive_rotated_log, args.archive_directory, args.check)))
        return
    proposed = preflight(config)
    if args.check:
        print(json.dumps({'preflight': 'passed', 'host': config['host'], 'installation': str(declaration),
                          'privileged_installation': 'not run', 'backup_restore': 'not run'}))
        return
    if os.geteuid() != 0:
        parser.error('Use sudo ./setup.sh repair for installation; --check needs no sudo')
    sync = load_module('knowledge_sync', ROOT / 'secrets/knowledge-sync.py')
    machine = Path(config['machine_file'])
    receipt_dir = Path(config['receipt_directory'])
    receipt_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
    receipt = receipt_dir / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8] + '.json')
    result = {'host': config['host'], 'installation_sha256': digest(declaration), 'status': 'failed',
              'started_utc': datetime.now(timezone.utc).isoformat(), 'scope': 'host configuration and backup repair'}
    git = ['git', '-c', f'safe.directory={ROOT}', '-C', str(ROOT)]
    result['operations_revision'] = checked(git + ['rev-parse', 'HEAD'], text=True, timeout=10).strip()
    result['dirty_source'] = bool(checked(git + ['status', '--porcelain'], text=True, timeout=10).strip())
    try:
        with open(Path(config['machine']['LAPLACE_LOCKS']) / 'host-resource.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Recheck after acquiring the same host lock used by deployment and ingestion.
            proposed = preflight(config)
            machine.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            with sync.configuration_transaction([machine], lambda: None):
                sync.atomic(machine, proposed, 0o644, 0, 0)
                result['machine_configuration'] = 'installed'
                print('Checking the landed application backup by restoring into a disposable database...', flush=True)
                result['landed_application_backup'] = restore_landing(config)
                print('Repairing the existing secrets backup job and taking a checked backup...', flush=True)
                backup = config['backup']
                environment = dict(os.environ, SECRETS_BACKUP_DIR=backup['secrets_directory'],
                    VAULTWARDEN_DATA_DIR=backup['vaultwarden_data'], BAO_SNAPSHOT_TOKEN_FILE=backup['snapshot_token'],
                    BAO_ADDR=backup['bao_address'], SECRETS_BACKUP_MOUNT=backup['backup_mount'],
                    SECRETS_DATA_MOUNT=backup['data_mount'])
                checked(['bash', str(ROOT / 'secrets/install-backup.sh')], env=environment, timeout=300)
                result['vaultwarden_archive'] = restore_vaultwarden(Path(config['backup']['secrets_directory']))
                for service in config['required_services']:
                    checked(['systemctl', 'is-active', '--quiet', service], timeout=10)
                result['status'] = 'passed'
    except Exception as error:
        result['error'] = str(error)
        result['machine_configuration'] = 'previous configuration restored'
        raise
    finally:
        result['finished_utc'] = datetime.now(timezone.utc).isoformat()
        sync.atomic(receipt, json.dumps(result, indent=2) + '\n', 0o644, 0, 0)
        print(f'Repair {result["status"]}; receipt: {receipt}', flush=True)


if __name__ == '__main__':
    main()
