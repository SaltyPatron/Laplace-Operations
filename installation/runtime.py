#!/usr/bin/env python3
"""Compatibility entry point for the monorepo-owned runtime installer."""
import importlib.util
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    spec = importlib.util.spec_from_file_location('machine', ROOT / 'machine-env.py')
    machine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(machine)
    config = {**machine.resolve(Path(os.environ.get('LAPLACE_MACHINE_ENV') or '/etc/laplace/machine.env'),
                               os.environ, explicit=bool(os.environ.get('LAPLACE_MACHINE_ENV'))), **os.environ}
    repository = Path(config.get('LAPLACE_MONOREPO') or
                      str(Path(config.get('LAPLACE_SRC') or ROOT.parent) / 'Laplace'))
    installer = repository / 'deploy/linux/runtime/install.py'
    if not repository.is_absolute() or not installer.is_file():
        raise ValueError('Monorepo runtime setup moved to Laplace/deploy/linux/site-host.sh. '
                         'Update the declared Laplace checkout; installer missing: ' + str(installer))
    os.execv(sys.executable, [sys.executable, str(installer), *sys.argv[1:]])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
