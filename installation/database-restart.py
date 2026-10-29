#!/usr/bin/env python3
"""Provision or inspect the single declared PostgreSQL restart controller."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def selection(config):
    if config['host'].lower() != socket.gethostname().lower():
        raise ValueError('Restart controller declaration selects another host')
    unit = config['database_service'].removesuffix('.service') + '.service'
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@-]*\.service', unit):
        raise ValueError('Invalid declared PostgreSQL service')
    for name in ('database_data', 'pgbin', 'host_lock', 'pgsocket'):
        path = Path(config[name])
        if not path.is_absolute() or '..' in path.parts or path == Path('/'):
            raise ValueError('Invalid absolute restart controller path: ' + name)
    for name in ('pg_os_user', 'database', 'database_owner'):
        if not re.fullmatch(r'[a-z][a-z0-9_-]*', config[name]):
            raise ValueError('Invalid restart controller identity: ' + name)
    if not isinstance(config['port'], int) or not 0 < config['port'] < 65536:
        raise ValueError('Invalid PostgreSQL port')
    return unit, Path(config['database_data']), Path(config['host_lock']).parent


def files(config):
    unit, data, locks = selection(config)
    program = '''#!/bin/sh
set -eu
unit=UNIT
data=DATA
locks=LOCKS
pid=$(systemctl show "$unit" -p MainPID --value)
[ "$pid" != 0 ] && [ "$pid" = "$(head -n 1 "$data/postmaster.pid")" ] || {
  echo 'PostgreSQL service and cluster PID disagree; no restart requested' >&2; exit 1;
}
for l in "$locks"/ingest-*.lock; do
  [ -e "$l" ] || continue
  flock -n "$l" true || { echo 'An ingest holds the cluster; no restart requested' >&2; exit 1; }
done
exec systemctl restart "$unit"
'''.replace('unit=UNIT\n', 'unit=' + shlex.quote(unit) + '\n').replace(
        'data=DATA\n', 'data=' + shlex.quote(str(data)) + '\n').replace(
        'locks=LOCKS\n', 'locks=' + shlex.quote(str(locks)) + '\n')
    service = ('[Unit]\nDescription=Restart the declared PostgreSQL cluster\n[Service]\n'
               'Type=oneshot\nExecStart=/usr/local/sbin/laplace-pg-restart\n')
    path = ('[Unit]\nDescription=PostgreSQL restart requests\n[Path]\nPathChanged=' +
            str(locks / 'restart-pg').replace('%', '%%') + '\n[Install]\nWantedBy=multi-user.target\n')
    return {'/usr/local/sbin/laplace-pg-restart': (program, 0o755),
            '/etc/systemd/system/laplace-pg-restart.service': (service, 0o644),
            '/etc/systemd/system/laplace-pg-restart.path': (path, 0o644)}


def verify_cluster(config):
    unit, data, locks = selection(config)
    if os.geteuid() != 0:
        raise ValueError('Restart controller provisioning requires the host administrator')
    statement = "SHOW data_directory; SELECT split_part(pg_read_file('postmaster.pid'),chr(10),1)"
    result = subprocess.run(['runuser', '-u', config['pg_os_user'], '--', str(Path(config['pgbin']) / 'psql'),
        '-X', '-w', '-At', '-v', 'ON_ERROR_STOP=1', '-h', config['pgsocket'], '-p', str(config['port']),
        '-d', config['database'], '-c', statement], check=True, capture_output=True, text=True, timeout=20)
    values = result.stdout.strip().splitlines()
    pid = subprocess.check_output(['systemctl', 'show', unit, '-p', 'MainPID', '--value'], text=True).strip()
    if len(values) != 2 or Path(values[0]).resolve() != data.resolve() or pid == '0' or pid != values[1]:
        raise ValueError('The selected PostgreSQL service does not own the connected cluster')
    if not locks.is_dir():
        raise ValueError('The declared host lock directory is missing')


def converge(config, *, install=False):
    verify_cluster(config)
    expected = files(config)
    changed = []
    for name, (content, mode) in expected.items():
        path = Path(name)
        if path.is_symlink() or (path.exists() and path.stat().st_uid != 0):
            raise ValueError('Restart controller is not a root-owned regular path: ' + name)
        if not path.is_file() or path.read_text() != content or path.stat().st_mode & 0o777 != mode:
            changed.append(name)
    if install:
        for name in changed:
            path = Path(name)
            descriptor, pending = tempfile.mkstemp(prefix='.laplace-restart-', dir=path.parent)
            try:
                with os.fdopen(descriptor, 'w') as stream:
                    stream.write(expected[name][0])
                    os.fchmod(stream.fileno(), expected[name][1])
                    os.fchown(stream.fileno(), 0, 0)
                os.replace(pending, path)
            finally:
                Path(pending).unlink(missing_ok=True)
        if changed:
            subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'enable', '--now', 'laplace-pg-restart.path'], check=True)
    elif changed:
        raise ValueError('Restart controller differs from the selected cluster: ' + ', '.join(changed))
    print(json.dumps({'restart_controller': 'verified', 'service': selection(config)[0],
                      'database_data': config['database_data'], 'changed': changed if install else []}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, default=ROOT / 'secrets/application-runtime-installation.json')
    parser.add_argument('--target', default='production')
    parser.add_argument('--environment', action='store_true', help='Use the host provisioning environment')
    parser.add_argument('--install', action='store_true', help='Install the controller after live service/cluster validation')
    args = parser.parse_args()
    if args.environment:
        config = dict(host=socket.gethostname(), database_service=os.environ['LAPLACE_PGSERVICE'],
                      database_data=os.environ['LAPLACE_PGDATA'], pgbin=str(Path(os.environ['LAPLACE_PG_DIR']) / 'bin'),
                      pgsocket=os.environ.get('LAPLACE_PGSOCKET', '/tmp'), port=int(os.environ.get('LAPLACE_PGPORT', '5432')),
                      pg_os_user=os.environ['LAPLACE_PGUSER'], database='postgres', database_owner=os.environ['LAPLACE_ROLE'],
                      host_lock=os.environ.get('LAPLACE_HOST_LOCK', str(Path(os.environ['LAPLACE_LOCKS']) / 'host-resource.lock')))
    else:
        config = json.loads(args.configuration.read_text())[args.target]
    converge(config, install=args.install)


if __name__ == '__main__':
    main()
