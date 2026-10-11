#!/usr/bin/env python3
"""Restore an application backup into a disposable database and execute the installed API against it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import signal
import socket
import subprocess
import tempfile
import time
import uuid


def environment(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
            raise ValueError(f'Invalid environment declaration in {path}')
        parsed = shlex.split(value)
        values[key] = parsed[0] if len(parsed) == 1 else value
    return values


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--archive', type=Path)
    source.add_argument('--archive-directory', type=Path)
    parser.add_argument('--source-database', required=True)
    parser.add_argument('--pgbin', type=Path, required=True)
    parser.add_argument('--pgsocket', required=True)
    parser.add_argument('--pgport', type=int, required=True)
    parser.add_argument('--pg-os-user', required=True)
    parser.add_argument('--database-owner', required=True)
    parser.add_argument('--runtime-user', required=True)
    parser.add_argument('--app-dir', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--api-port', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run through the host administrator so the rehearsal can use its existing DB and runtime identities')
    if not args.pgsocket.startswith('/') or not 1024 <= args.api_port <= 65535:
        parser.error('The restore requires an explicit local PostgreSQL socket and unprivileged API port')
    # Fail before creating any state if the selected API port belongs to an existing process.
    with socket.socket() as port:
        port.bind(('127.0.0.1', args.api_port))
    if args.archive_directory:
        archives = [path for path in args.archive_directory.glob('*.dump')
                    if '-' + args.source_database + '-' in path.name]
        if not archives:
            raise ValueError('No application backup exists in the declared archive directory')
        archive = max(archives, key=lambda path: path.stat().st_mtime).resolve(strict=True)
    else:
        archive = args.archive.resolve(strict=True)
    archive_hash = digest(archive)
    expected = Path(str(archive) + '.sha256').read_text().split()[0]
    if archive_hash != expected:
        raise ValueError('Backup checksum mismatch; nothing restored')
    runtime = pwd.getpwnam(args.runtime_user)
    config = environment(args.app_dir / 'laplace-api.env')
    app_connection = config['LAPLACE_APP_DB']
    source_match = re.search(r'(?i)(?:^|;)\s*Database\s*=\s*([^;]+)', app_connection)
    if not source_match:
        raise ValueError('The installed application must declare a separate application database')
    source_db = source_match.group(1).strip()
    if source_db != args.source_database:
        raise ValueError('The declared recovery database differs from the installed application database')
    database = 'laplace_restore_' + uuid.uuid4().hex[:16]
    token = uuid.uuid4().hex
    args.work_dir.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='app-restore-', dir=args.work_dir))
    scratch.chmod(0o700)
    os.chown(scratch, runtime.pw_uid, runtime.pw_gid)
    started = time.monotonic()
    created = False
    process = None
    receipt = {'host': socket.gethostname(), 'archive': str(archive), 'archive_sha256': archive_hash,
               'backup_modified_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(archive.stat().st_mtime)),
               'source_database': source_db, 'restored_database': database, 'scratch': str(scratch),
               'scope': 'Application database restore and installed API; selected knowledge remains unchanged',
               'installed_revision': (args.app_dir / '.laplace-source-revision').read_text().strip(), 'passed': False}

    def pg(tool, *arguments):
        command = ['runuser', '-u', args.pg_os_user, '--', str(args.pgbin / tool),
                   '-h', args.pgsocket, '-p', str(args.pgport), *arguments]
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        if result.returncode:
            (scratch / 'database-error.log').write_text(result.stderr)
            raise RuntimeError(f'{tool} failed; private diagnostic: {scratch / "database-error.log"}')
        return result.stdout.strip()

    def as_runtime():
        os.setgroups(os.getgrouplist(args.runtime_user, runtime.pw_gid))
        os.setgid(runtime.pw_gid)
        os.setuid(runtime.pw_uid)

    try:
        pg('createdb', '--template=template0', '--owner=' + args.database_owner, database)
        created = True
        pg('psql', '-X', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', f'COMMENT ON DATABASE "{database}" IS \'restore-drill:{token}\'')
        pg('pg_restore', '--exit-on-error', '--single-transaction', '--no-owner', '--role=' + args.database_owner,
           '-d', database, str(archive))
        tables = pg('psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', database, '-c',
                    "SELECT tablename FROM pg_tables WHERE schemaname='app' ORDER BY tablename").splitlines()
        if not {'tenants', 'users', 'api_keys', 'billing_entitlements'}.issubset(tables):
            raise ValueError('Restored archive lacks required application tables')
        receipt['restored_application_tables'] = len(tables)
        keys_before = int(pg('psql', '-XAt', '-d', database, '-c', 'SELECT count(*) FROM app.api_keys'))
        receipt['restore_seconds'] = round(time.monotonic() - started, 3)
        child_env = dict(os.environ, HOME=runtime.pw_dir)
        child_env.update(config)
        child_env.update(environment(args.prefix / 'secrets/operator.env'))
        child_env.pop('LAPLACE_API_KEY', None)
        child_env['LAPLACE_APP_DB'] = re.sub(r'(?i)(^|;)\s*Database\s*=\s*[^;]+',
                                           lambda m: m.group(1) + 'Database=' + database, app_connection)
        # The rehearsal serves only on a fresh loopback port and never starts provider/bootstrap background work.
        child_env.update(LAPLACE_API_PORT=str(args.api_port), LAPLACE_SKIP_HOSTED_SERVICES='1',
                         LAPLACE_OPS_LOG_DIR=str(scratch / 'logs'), LAPLACE_DATA_PROTECTION_KEYS=str(scratch / 'keys'),
                         LAPLACE_INSTALL_PREFIX=str(args.prefix))
        pgpass_source = Path(child_env.get('PGPASSFILE') or Path(runtime.pw_dir) / '.pgpass')
        pgpass_lines = pgpass_source.read_text().splitlines()
        restored_lines = []
        for line in pgpass_lines:
            if not line or line.startswith('#'):
                continue
            fields = re.split(r'(?<!\\):', line)
            if len(fields) == 5 and fields[2] in (source_db, '*'):
                fields[2] = database
                restored_lines.append(':'.join(fields))
        if not restored_lines:
            raise ValueError('The runtime identity has no pgpass entry for the application database')
        pgpass = scratch / 'pgpass'
        pgpass.write_text('\n'.join(pgpass_lines + restored_lines) + '\n')
        pgpass.chmod(0o600)
        os.chown(pgpass, runtime.pw_uid, runtime.pw_gid)
        child_env['PGPASSFILE'] = str(pgpass)
        with (scratch / 'api.log').open('wb') as log:
            process = subprocess.Popen(['/usr/bin/dotnet', str(args.app_dir / 'Laplace.Endpoints.OpenAICompat.dll')],
                                       cwd=args.app_dir, env=child_env, preexec_fn=as_runtime,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            verifier = args.app_dir / 'operations/scripts/verify-application-release.py'
            result = subprocess.run(['/usr/bin/python3', str(verifier), '--base', f'http://127.0.0.1:{args.api_port}',
                                     '--state-file', str(scratch / 'verification.json'), '--timeout-seconds', '60'],
                                    env=child_env, preexec_fn=as_runtime, capture_output=True, text=True, timeout=150)
            (scratch / 'verification.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(f'Restored API verification failed; private diagnostic: {scratch / "verification.log"}')
            receipt['application_verification'] = json.loads((scratch / 'verification.json').read_text())
            keys_after = int(pg('psql', '-XAt', '-d', database, '-c', 'SELECT count(*) FROM app.api_keys'))
            receipt['verification_keys_written_to_restored_database'] = keys_after - keys_before
            if keys_after - keys_before != 1:
                raise ValueError('The verification API did not issue its temporary key in the restored application database')
            receipt['passed'] = True
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
        try:
            if created:
                marker = pg('psql', '-XAt', '-d', 'postgres', '-c',
                            f"SELECT shobj_description(oid,'pg_database') FROM pg_database WHERE datname='{database}'")
                if marker != 'restore-drill:' + token:
                    raise RuntimeError('Restore database ownership marker changed; refusing cleanup')
                pg('dropdb', '--force', database)
                receipt['disposable_database_removed'] = True
        except Exception:
            receipt['passed'] = False
            receipt['cleanup_failed'] = True
            raise
        finally:
            (scratch / 'pgpass').unlink(missing_ok=True)
            receipt['elapsed_seconds'] = round(time.monotonic() - started, 3)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(receipt, indent=2) + '\n')
            print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
