"""Deploy the selected installed Engine without building or retargeting it."""
import argparse
from pathlib import Path
import socket
import subprocess

import client


def deploy(configuration, psql, *, drop=False):
    executable, environment, selected = client.selected(Path(configuration))
    if selected['database_host'].lower() not in {socket.gethostname().lower(), 'localhost', '127.0.0.1', '::1'}:
        raise ValueError('Installed desktop deployment requires the local database host')
    database = selected['database']
    if not database or database.lower() in {'postgres', 'template0', 'template1'}:
        raise ValueError('The selected database is not an application database')
    psql = Path(psql)
    if not psql.is_file():
        raise ValueError('The declared PostgreSQL client is missing')
    for path in (environment['LAPLACE_TIER0'], environment['LAPLACE_FLAGS'],
                 environment['LAPLACE_FLAGS'] + '.layout', environment['LAPLACE_HIGHWAY']):
        if not Path(path).is_file() or not Path(path).stat().st_size:
            raise ValueError('Missing installed deployment artifact: ' + path)
    env = client.process_environment(environment)
    if drop:
        # The final dbname overrides the selected content database for this one
        # maintenance connection. psql quotes the target as an SQL identifier.
        # Active clients cause DROP to fail; this operation never terminates them.
        maintenance = environment['LAPLACE_CONNINFO'] + " dbname='postgres'"
        subprocess.run([str(psql), '-X', '-w', '-d', maintenance, '-v', 'ON_ERROR_STOP=1',
                        '-v', 'laplace_database=' + database], env=env, check=True,
                       input="SELECT format('DROP DATABASE IF EXISTS %I', :'laplace_database')\n\\gexec\n", text=True)
    subprocess.run([str(executable), 'deploy', '--configure-server-cache'], env=env, check=True)
    grants = (
        "DO $$ BEGIN "
        "IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'laplace_modular_web') THEN "
        "EXECUTE format('GRANT CONNECT ON DATABASE %I TO laplace_modular_web', current_database()); "
        "GRANT USAGE ON SCHEMA public TO laplace_modular_web; "
        "GRANT SELECT ON ALL TABLES IN SCHEMA public TO laplace_modular_web; "
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO laplace_modular_web; "
        "END IF; "
        "END $$;"
    )
    subprocess.run([str(psql), '-X', '-w', '-d', environment['LAPLACE_CONNINFO'],
                    '-v', 'ON_ERROR_STOP=1', '-qc', grants], env=env, check=True)
    return selected


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', required=True, type=Path)
    parser.add_argument('--psql', required=True, type=Path)
    parser.add_argument('--drop', action='store_true')
    args = parser.parse_args()
    deploy(args.configuration, args.psql, drop=args.drop)
