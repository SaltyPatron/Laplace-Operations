"""Exercise HTTP ingestion and replay with scoped SQL rights in a disposable database.

Usage: python3 tests/modular-ingestion.py --config DECLARATION --release PACKAGE --admin-role ROLE
       [--candidate-upgrade path/to/laplace--old--new.sql]
The optional SQL is applied only inside this fixture, before shared installation.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', required=True)
parser.add_argument('--release', required=True)
parser.add_argument('--admin-role', required=True, help='Explicit fixture administrator, authenticated by the configured local socket')
parser.add_argument('--candidate-upgrade')
args = parser.parse_args()
config = json.loads(Path(args.config).read_text())
release = Path(args.release)
ops = module('modular', ROOT / 'installation/modular.py')
deploy = module('mcp', Path(config['source']) / 'Laplace-MCP/deployment.py')
deploy.verify_package(release)
name = 'modular_admit_' + uuid.uuid4().hex[:12]
def connquote(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"


config.update(database=name, role=name,
    connection=f"host={connquote(config['socket'])} port={config['port']} user={connquote(args.admin_role)} dbname={name}")
psql = [str(Path(config['pgbin']) / 'psql'), '-XwAt', '-v', 'ON_ERROR_STOP=1',
        '-h', config['socket'], '-p', str(config['port']), '-U', args.admin_role, '-f', '-']


def sql(database, statement):
    result = subprocess.run(psql + ['-d', database], input=statement, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


try:
    with tempfile.TemporaryDirectory(prefix='modular-admission-') as temporary:
        config['state'] = temporary
        env = deploy.runtime_environment(config, release)
        with (Path(temporary) / 'deploy.log').open('w+') as log:
            result = subprocess.run([str(release / 'bin/laplace'), 'deploy'], env=env, cwd=temporary,
                                    stdout=log, stderr=log, timeout=120)
            if result.returncode:
                log.seek(0)
                raise RuntimeError(log.read())
        if args.candidate_upgrade:
            sql(name, '\n'.join(line for line in Path(args.candidate_upgrade).read_text().splitlines()
                                 if not line.startswith('\\echo')))
        sql(name, ops.grants(config))
        env['LAPLACE_CONNINFO'] += " options='-c role=" + name + "'"
        sample = Path(temporary) / 'fixture.txt'
        sample.write_text('Laplace installation verification.\n')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        with (Path(temporary) / 'service.log').open('w+') as log:
            service = subprocess.Popen([str(release / 'bin/lpm'), 'serve', '127.0.0.1', str(port)],
                                       env=env, cwd=temporary, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if service.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(log.read())
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            break
                    except OSError:
                        time.sleep(.1)
                observed = []
                for _ in range(2):
                    result = deploy.request('http://127.0.0.1:' + str(port), '/v1/ingest', {'path': str(sample)})
                    assert result.get('exit') == 0, result
                    if 'permission denied' in result.get('log', '') or 'skipping' in result.get('log', ''):
                        raise AssertionError(result)
                    counts = sql(name, 'SELECT count(*) FROM public.entity; SELECT count(*) FROM public.physicality;')
                    values = [int(v) for v in counts.splitlines()]
                    assert all(v > 0 for v in values), values
                    observed.append(values)
                assert observed[0] == observed[1], observed
                print(json.dumps({'scope': 'HTTP ingestion into disposable database under scoped SQL rights; peer login separate',
                    'package': release.name, 'entity_path_counts': observed, 'http_ingest': 'passed', 'replay': 'passed'}))
            finally:
                service.terminate()
                service.wait(timeout=10)
finally:
    sql('postgres', f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE);')
    sql('postgres', f'''DO $$ BEGIN IF EXISTS(SELECT FROM pg_roles WHERE rolname='{name}') THEN
EXECUTE 'REVOKE SET ON PARAMETER session_replication_role FROM "{name}"'; END IF; END $$;
DROP ROLE IF EXISTS "{name}";''')
