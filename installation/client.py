#!/usr/bin/env python3
"""Run the installed modular Engine as the configured human client identity."""
import json
import os
from pathlib import Path
import re
import socket
import sys


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
    if role == host['role']:
        raise ValueError('The human client requires its own database identity, not the MCP peer identity')
    work = Path(profile['work'])
    if not work.is_absolute() or '..' in work.parts or work == Path('/'):
        raise ValueError('Client work directory must be absolute')
    for key in ('prefix', 'state', 'pgdata'):
        protected = Path(host[key]).resolve()
        if work.resolve().is_relative_to(protected) or protected.is_relative_to(work.resolve()):
            raise ValueError('Client work directory overlaps installed runtime or database state')
    data = Path(profile['data'])
    if not data.is_absolute() or '..' in data.parts:
        raise ValueError('Client data directory must be absolute')
    if not data.is_dir():
        raise ValueError('Missing declared client data directory: ' + str(data))
    release = (Path(host['prefix']) / 'current').resolve(strict=True)
    package = json.loads((release / 'package.json').read_text())
    if package.get('schema') != 'laplace.modular-package/v1':
        raise ValueError('Selected release is not a modular Laplace package')
    executable = release / 'bin/laplace'
    if not executable.is_file():
        raise ValueError('Installed Engine is missing: ' + str(executable))
    def conn(value):
        return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"
    connection = ' '.join(key + '=' + conn(value) for key, value in (
        ('host', host['socket']), ('port', host['port']), ('dbname', host['database']), ('user', role)))
    environment = {
        'LAPLACE_CONNINFO': connection, 'LAPLACE_TIER0': host['tier0'], 'LAPLACE_FLAGS': host['flags'],
        'LAPLACE_HIGHWAY': host['highway'], 'LAPLACE_GRAMMARS': host['grammars'], 'LAPLACE_UCD': host['ucd'],
        'LAPLACE_WORK': str(work), 'LAPLACE_DATA': str(data), 'LAPLACE_ENGINE': str(executable),
        'LAPLACE_RECIPES': str(release / 'share/recipes'),
        'LAPLACE_FIRMWARE': str(release / 'share/firmware/program.firmware'),
        'OMP_NUM_THREADS': str(host['threads']), 'MKL_NUM_THREADS': '1', 'LAPLACE_BATCH_MB': str(host['batch_mb']),
    }
    return executable, environment, {'implementation': 'laplace', 'configuration': str(configuration),
        'installation': str(installation), 'release': str(release), 'executable': str(executable),
        'database_host': host['socket'], 'database': host['database'], 'database_role': role,
        'work': str(work), 'data': str(data), 'revisions': package['revisions']}


def process_environment(environment):
    # The named client controls selection; do not inherit another implementation's
    # LAPLACE_* values from a developer shell. libpq uses the human's own credential store.
    inherited = {k: v for k, v in os.environ.items() if not k.startswith('LAPLACE_')}
    return {**inherited, **environment}


def main():
    configuration = Path(os.environ.get('LAPLACE_CLIENT_CONFIG') or
                         str(Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'laplace/client.json'))
    executable, environment, description = selected(configuration)
    if sys.argv[1:] == ['--where']:
        print(json.dumps(description, indent=2))
        return
    Path(environment['LAPLACE_WORK']).mkdir(parents=True, exist_ok=True)
    os.execve(executable, [str(executable), *sys.argv[1:]], process_environment(environment))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print('laplace: ' + str(error), file=sys.stderr)
        sys.exit(1)
