"""Compatibility entry point for the monorepo-owned browser route installer."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('machine', root / 'machine-env.py')
    machine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(machine)
    declaration = Path(os.environ.get('LAPLACE_MACHINE_ENV') or '/etc/laplace/machine.env')
    config = machine.resolve(declaration, os.environ, explicit=bool(os.environ.get('LAPLACE_MACHINE_ENV')))
    config.update({key: value for key, value in os.environ.items() if value})
    monorepo = config.get('LAPLACE_MONOREPO')
    if not monorepo and config.get('LAPLACE_SRC'):
        monorepo = str(Path(config['LAPLACE_SRC']) / 'Laplace')
    if not monorepo or not Path(monorepo).is_absolute():
        raise SystemExit('Declare an absolute LAPLACE_MONOREPO or LAPLACE_SRC in the machine configuration.')
    installer = Path(monorepo) / 'deploy/linux/configure-nginx.py'
    if not installer.is_file():
        raise SystemExit('Missing monorepo browser installer: ' + str(installer))
    arguments = sys.argv[1:]
    if '--configuration' not in arguments and not any(arg.startswith('--configuration=') for arg in arguments):
        if config.get('LAPLACE_PRIVATE_ORIGINS'):
            arguments = ['--configuration', config['LAPLACE_PRIVATE_ORIGINS'], *arguments]
    print('Using the monorepo-owned browser route installer: ' + str(installer), file=sys.stderr)
    raise SystemExit(subprocess.call([sys.executable, str(installer), *arguments]))


if __name__ == '__main__':
    main()
