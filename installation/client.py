#!/usr/bin/env python3
"""Run the installed modular Engine as the configured human client identity."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

INPUT_ROOTS = {'source': 'LAPLACE_SRC', 'models': 'LAPLACE_MODELS'}


def selected(configuration):
    profile = json.loads(configuration.read_text())
    if profile.get('schema') != 'laplace.modular-client/v1':
        raise ValueError('Expected a modular Laplace client declaration')
    installation = Path(profile['installation'])
    if not installation.is_absolute():
        raise ValueError('Client installation path must be absolute')
    host = json.loads(installation.read_text())
    if host.get('schema') != 'laplace.modular-installation/v1':
        raise ValueError('Client does not select an installed modular runtime')
    if host['host'].split('.')[0].lower() != socket.gethostname().split('.')[0].lower():
        raise ValueError('The selected installed modular runtime belongs to another host')
    role = profile['role']
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,62}', role):
        raise ValueError('Invalid client database identity')
    if role == host.get('role'):
        raise ValueError('The human client requires its own database identity, not the MCP peer identity')
    work = Path(profile['work'])
    if not work.is_absolute() or '..' in work.parts or work == Path('/'):
        raise ValueError('Client work directory must be absolute')
    for key in ('prefix', 'state', 'pgdata'):
        if key not in host:
            continue
        protected = Path(host[key]).resolve()
        if work.resolve().is_relative_to(protected) or protected.is_relative_to(work.resolve()):
            raise ValueError('Client work directory overlaps installed runtime or database state')
    data = Path(profile['data'])
    if not data.is_absolute() or '..' in data.parts:
        raise ValueError('Client data directory must be absolute')
    if not data.is_dir():
        raise ValueError('Missing declared client data directory: ' + str(data))
    release = Path(host['release']).resolve(strict=True) if host.get('release') else (Path(host['prefix']) / 'current').resolve(strict=True)
    if not release.is_relative_to(Path(host['prefix']).resolve()):
        raise ValueError('Release is outside the declared installation')
    package = json.loads((release / 'package.json').read_text())
    if package.get('schema') != 'laplace.modular-package/v1':
        raise ValueError('Selected release is not a modular Laplace package')
    executable = release / ('bin/laplace.exe' if os.name == 'nt' else 'bin/laplace')
    if not executable.is_file():
        raise ValueError('Installed Engine is missing: ' + str(executable))
    def conn(value):
        return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"
    target = {'host': host['socket'], 'port': host['port'], 'dbname': host['database'], 'user': role}
    options = profile.get('connection', {})
    if set(options) - {'hostaddr', 'sslmode', 'sslrootcert', 'passfile', 'connect_timeout', 'require_auth'}:
        raise ValueError('Unsupported client connection option; passwords belong in the credential store')
    target.update(options)
    authentication = options.get('require_auth')
    if authentication is not None:
        if authentication != 'sspi' or os.name != 'nt':
            raise ValueError('Explicit client authentication must be Windows SSPI')
        if host['socket'].lower() not in {socket.gethostname().lower(), 'localhost', '127.0.0.1', '::1'}:
            raise ValueError('SSPI client selection requires the local Windows database')
    if os.name == 'nt' and target.get('sslmode') != 'verify-full':
        raise ValueError('The Windows network client requires full database certificate verification')
    connection = ' '.join(key + '=' + conn(value) for key, value in target.items())
    environment = {
        'LAPLACE_CONNINFO': connection, 'LAPLACE_TIER0': host['tier0'], 'LAPLACE_FLAGS': host['flags'],
        'LAPLACE_HIGHWAY': host['highway'], 'LAPLACE_GRAMMARS': host['grammars'], 'LAPLACE_UCD': host['ucd'],
        'LAPLACE_WORK': str(work), 'LAPLACE_DATA': str(data), 'LAPLACE_ENGINE': str(executable),
        'LAPLACE_RECIPES': str(release / 'share/recipes'),
        'LAPLACE_FIRMWARE': str(release / 'share/firmware/program.firmware'),
        'OMP_NUM_THREADS': str(host['threads']), 'MKL_NUM_THREADS': '1', 'LAPLACE_BATCH_MB': str(host['batch_mb']),
    }
    inputs = {}
    for key, variable in INPUT_ROOTS.items():
        if key not in profile:
            continue
        path = Path(profile[key])
        if not path.is_absolute() or '..' in path.parts or any(c in str(path) for c in '\r\n\0'):
            raise ValueError('Client input root must be absolute: ' + key)
        # Inputs may be absent on this machine. The recipe estate reports that
        # source as absent; unrelated sources and commands remain usable.
        inputs[key] = str(path)
        environment[variable] = str(path)
    if authentication == 'sspi':
        environment['LAPLACE_DATABASE_AUTHENTICATION'] = 'sspi'
    return executable, environment, {'implementation': 'laplace', 'configuration': str(configuration),
        'installation': str(installation), 'release': str(release), 'executable': str(executable),
        'database_host': host['socket'], 'database': host['database'], 'database_role': role,
        'work': str(work), 'data': str(data), 'inputs': inputs, 'revisions': package['revisions']}


def process_environment(environment):
    # The named client controls selection; do not inherit another implementation's
    # LAPLACE_* values from a developer shell. libpq uses the human's own credential store.
    inherited = {k: v for k, v in os.environ.items() if not k.startswith('LAPLACE_')}
    if environment.get('LAPLACE_DATABASE_AUTHENTICATION') == 'sspi':
        inherited = {k: v for k, v in inherited.items() if not k.upper().startswith('PG')}
    # Intel's explicit affinity selection takes precedence; do not also request
    # the contradictory OpenMP binding setting inherited from a developer shell.
    if inherited.get('KMP_AFFINITY'):
        inherited.pop('OMP_PROC_BIND', None)
    return {**inherited, **environment}


def main():
    configuration = Path(os.environ.get('LAPLACE_CLIENT_CONFIG') or
                         str(Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'laplace/client.json'))
    executable, environment, description = selected(configuration)
    if sys.argv[1:] == ['--where']:
        print(json.dumps(description, indent=2))
        return
    if sys.argv[1:2] == ['mcp']:
        lpm = executable.with_name('lpm.exe' if os.name == 'nt' else 'lpm')
        if lpm.is_file():
            executable = lpm
            args = sys.argv[1:] if len(sys.argv) == 2 else sys.argv[2:]
            Path(environment['LAPLACE_WORK']).mkdir(parents=True, exist_ok=True)
            if os.name == 'nt':
                sys.exit(subprocess.run([str(executable), *args], env=process_environment(environment)).returncode)
            os.execve(executable, [str(executable), *args], process_environment(environment))
    Path(environment['LAPLACE_WORK']).mkdir(parents=True, exist_ok=True)
    if os.name == 'nt':
        sys.exit(subprocess.run([str(executable), *sys.argv[1:]], env=process_environment(environment)).returncode)
    os.execve(executable, [str(executable), *sys.argv[1:]], process_environment(environment))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print('laplace: ' + str(error), file=sys.stderr)
        sys.exit(1)
